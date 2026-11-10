// AppStore.swift — 单一可变状态源：乐观更新 + 失败回滚 + 会话失效收敛
import Foundation
import SwiftUI

struct NoteDraft {
    var title: String = ""
    var content: String = ""
    var priority: Int = 1
    var tags: [String] = []
    var due: Date?

    var isValid: Bool { !title.trimmed.isEmpty }

    static func from(_ note: Note) -> NoteDraft {
        NoteDraft(
            title: note.title,
            content: note.body,
            priority: note.priority,
            tags: note.tags,
            due: note.dueDate
        )
    }
}

@MainActor
final class AppStore: ObservableObject {

    enum Phase: Equatable {
        case booting
        case signedOut
        case loading
        case empty
        case ready
        case failed(String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case open
        case done
        case pinned

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "全部"
            case .open: return "待办"
            case .done: return "完成"
            case .pinned: return "置顶"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2.fill"
            case .open: return "circle.dashed"
            case .done: return "checkmark.circle.fill"
            case .pinned: return "pin.fill"
            }
        }
    }

    struct Toast: Identifiable, Equatable {
        enum Kind: Equatable { case ok, warn, error }
        let id = UUID()
        let text: String
        let kind: Kind
    }

    @Published private(set) var user: User?
    @Published private(set) var notes: [Note] = []
    @Published private(set) var stats = Stats()
    @Published var query: String = ""
    @Published var filter: Filter = .all
    @Published private(set) var phase: Phase = .booting
    @Published private(set) var refreshing = false
    @Published private(set) var authBusy = false
    @Published var toast: Toast?

    let api = APIClient.shared

    init() {
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in
                self?.expireSession()
            }
        }
    }

    /* ── 派生数据 ─────────────────────────────────────────── */

    var visibleNotes: [Note] {
        let needle = query.trimmed.lowercased()
        return notes.filter { note in
            switch filter {
            case .all:
                break
            case .open:
                if note.status != .open { return false }
            case .done:
                if note.status != .done { return false }
            case .pinned:
                if !note.pinned { return false }
            }

            guard !needle.isEmpty else { return true }
            if note.title.lowercased().contains(needle) { return true }
            if note.body.lowercased().contains(needle) { return true }
            return note.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return notes.count
        case .open: return notes.filter { $0.status == .open }.count
        case .done: return notes.filter { $0.status == .done }.count
        case .pinned: return notes.filter(\.pinned).count
        }
    }

    var connectionLabel: String { AppConfig.apiBaseDisplay }

    /* ── 引导 ─────────────────────────────────────────────── */

    func bootstrap() async {
        guard api.restoreFromKeychain() else {
            phase = .signedOut
            return
        }

        if api.accessToken != nil, let me = try? await api.me() {
            user = me
            await loadAll(silently: false)
            return
        }

        do {
            try await api.refreshSession()
            user = try await api.me()
            await loadAll(silently: false)
        } catch {
            api.forget()
            user = nil
            phase = .signedOut
        }
    }

    /* ── 认证 ─────────────────────────────────────────────── */

    func signIn(email: String, password: String) async -> Bool {
        guard !authBusy else { return false }
        authBusy = true
        defer { authBusy = false }
        do {
            let session = try await api.login(email: email.trimmed, password: password)
            user = session.user
            Haptics.success()
            await loadAll(silently: false)
            show("欢迎回来，\(session.user.displayName)", .ok)
            return true
        } catch {
            Haptics.error()
            show(error.localizedDescription, .error)
            return false
        }
    }

    func signUp(email: String, password: String) async -> Bool {
        guard !authBusy else { return false }
        authBusy = true
        defer { authBusy = false }
        do {
            let session = try await api.register(email: email.trimmed, password: password)
            user = session.user
            Haptics.success()
            await loadAll(silently: false)
            show("账号已创建 · \(session.user.roleLabel)", .ok)
            return true
        } catch {
            Haptics.error()
            show(error.localizedDescription, .error)
            return false
        }
    }

    func signOut() async {
        await api.logout()
        user = nil
        notes = []
        stats = Stats()
        query = ""
        filter = .all
        phase = .signedOut
        Haptics.impact(.medium)
        show("已退出登录", .ok)
    }

    /* ── 数据 ─────────────────────────────────────────────── */

    func loadAll(silently: Bool = false) async {
        guard user != nil else { return }
        if !silently, notes.isEmpty { phase = .loading }
        refreshing = true
        defer { refreshing = false }

        do {
            async let listTask = api.notes()
            async let statsTask = api.stats()
            let list = try await listTask
            let summary = try await statsTask
            notes = list
            stats = summary
            phase = list.isEmpty ? .empty : .ready
        } catch {
            if let apiError = error as? APIError, apiError.isUnauthorized {
                expireSession()
            } else {
                if notes.isEmpty { phase = .failed(error.localizedDescription) }
                show(error.localizedDescription, .error)
            }
        }
    }

    func create(_ draft: NoteDraft) async -> Bool {
        do {
            let payload = NewNote(
                title: draft.title.trimmed,
                body: draft.content,
                priority: draft.priority,
                tags: draft.tags,
                due: draft.due.map { $0.timeIntervalSince1970 * 1000 }
            )
            let note = try await api.createNote(payload)
            notes.insert(note, at: 0)
            phase = .ready
            stats = (try? await api.stats()) ?? stats
            show("已创建「\(note.title)」", .ok)
            return true
        } catch {
            await recover(error)
            return false
        }
    }

    func update(_ note: Note, with draft: NoteDraft) async -> Bool {
        var patch = NotePatch(rev: note.rev)
        if draft.title.trimmed != note.title { patch.title = draft.title.trimmed }
        if draft.content != note.body { patch.body = draft.content }
        if draft.priority != note.priority { patch.priority = draft.priority }
        if draft.tags != note.tags { patch.tags = draft.tags }

        let newDue = draft.due.map { $0.timeIntervalSince1970 * 1000 }
        if let newDue {
            if let old = note.due {
                if abs(old - newDue) > 1000 { patch.dueMS = newDue }
            } else {
                patch.dueMS = newDue
            }
        } else if note.due != nil {
            patch.clearDue = true
        }

        do {
            let updated = try await api.patchNote(id: note.id, patch: patch)
            replace(updated)
            stats = (try? await api.stats()) ?? stats
            show("已保存", .ok)
            return true
        } catch let error as APIError where error.isConflict {
            Haptics.warning()
            show("这条已在别处更新，已刷新为最新", .warn)
            await loadAll(silently: true)
            return false
        } catch {
            await recover(error)
            return false
        }
    }

    func toggleDone(_ note: Note) async {
        let target: NoteStatus = note.status == .open ? .done : .open
        var optimistic = note
        optimistic.status = target
        replace(optimistic)
        Haptics.impact(target == .done ? .medium : .light)

        do {
            let updated = try await api.patchNote(
                id: note.id,
                patch: NotePatch(status: target.rawValue, rev: note.rev)
            )
            replace(updated)
            stats = (try? await api.stats()) ?? stats
        } catch {
            replace(note)
            await recover(error)
        }
    }

    func togglePin(_ note: Note) async {
        var optimistic = note
        optimistic.pinned.toggle()
        replace(optimistic)
        Haptics.impact(.light)

        do {
            let updated = try await api.patchNote(
                id: note.id,
                patch: NotePatch(pinned: optimistic.pinned, rev: note.rev)
            )
            replace(updated)
        } catch {
            replace(note)
            await recover(error)
        }
    }

    func delete(_ note: Note) async {
        let snapshot = notes
        notes.removeAll { $0.id == note.id }
        Haptics.impact(.rigid)
        do {
            try await api.deleteNote(id: note.id)
            stats = (try? await api.stats()) ?? stats
            if notes.isEmpty { phase = .empty }
        } catch {
            notes = snapshot
            await recover(error)
        }
    }

    /* ── 内部 ─────────────────────────────────────────────── */

    private func replace(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
    }

    private func recover(_ error: Error) async {
        if let apiError = error as? APIError, apiError.isUnauthorized {
            expireSession()
            return
        }
        show(error.localizedDescription, .error)
    }

    private func expireSession() {
        api.forget()
        user = nil
        notes = []
        stats = Stats()
        phase = .signedOut
        show("会话已失效，请重新登录", .warn)
    }

    private func show(_ text: String, _ kind: Toast.Kind) {
        let item = Toast(text: text, kind: kind)
        toast = item
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toast?.id == item.id { toast = nil }
        }
    }
}
