// NoteEditorView.swift — 新建 / 编辑（同一组件，键盘友好，动效克制）
import SwiftUI

struct NoteEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let existing: Note?

    @State private var draft: NoteDraft
    @State private var tagsText: String
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var saving = false
    @State private var shake = false

    @FocusState private var titleFocused: Bool

    init(existing: Note? = nil) {
        self.existing = existing
        let base = existing.map(NoteDraft.from) ?? NoteDraft()
        _draft = State(initialValue: base)
        _tagsText = State(initialValue: base.tags.joined(separator: " "))
        _hasDue = State(initialValue: base.due != nil)
        _dueDate = State(initialValue: base.due ?? Date().addingTimeInterval(86_400))
    }

    var body: some View {
        ZStack {
            AuroraBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    topBar
                    titleField
                    contentField
                    priorityPicker
                    tagField
                    dueSection
                    saveButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 44)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if existing == nil { titleFocused = true }
        }
    }

    /* ── 顶栏 ─────────────────────────────────────────────── */

    private var topBar: some View {
        HStack {
            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                Text("取消")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textDim)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(existing == nil ? "新建条目" : "编辑条目")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text)

            Spacer()

            Text(existing == nil ? "创建" : "v\(existing?.rev ?? 1)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.bottom, 4)
    }

    /* ── 字段 ─────────────────────────────────────────────── */

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标题")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(Palette.textFaint)

            TextField("要做什么？", text: $draft.title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text)
                .focused($titleFocused)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.next)
                .padding(14)
                .glassPanel(radius: 18)
        }
    }

    private var contentField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("正文")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(Palette.textFaint)

            ZStack(alignment: .topLeading) {
                if draft.content.isEmpty {
                    Text("补充细节、链接、上下文…")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(Palette.textFaint)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draft.content)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 148)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
            }
            .glassPanel(radius: 18)
        }
    }

    private var priorityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("优先级")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(Palette.textFaint)

            HStack(spacing: 9) {
                priorityChip(0, "稍后", Palette.cyan)
                priorityChip(1, "常规", Palette.aurora)
                priorityChip(2, "紧急", Palette.coral)
            }
        }
    }

    private func priorityChip(_ value: Int, _ label: String, _ tint: Color) -> some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                draft.priority = value
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(draft.priority == value ? Color.white : tint)
                    .frame(width: 7, height: 7)
                Text(label)
            }
        }
        .buttonStyle(ChipButtonStyle(active: draft.priority == value))
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签 · 空格分隔，最多 4 个")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(Palette.textFaint)

            TextField("#发布 #复盘", text: $tagsText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(14)
                .glassPanel(radius: 18)
        }
    }

    private var dueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $hasDue.animation(.easeInOut(duration: 0.2))) {
                Text("设置截止时间")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.text)
            }
            .toggleStyle(.switch)
            .tint(Palette.aurora)

            if hasDue {
                DatePicker(
                    "",
                    selection: $dueDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .glassPanel(radius: 18)
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            ZStack {
                Text(existing == nil ? "创建" : "保存修改")
                    .opacity(saving ? 0 : 1)
                if saving {
                    ProgressView().tint(.white)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle(enabled: draft.isValid && !saving))
        .disabled(!draft.isValid || saving)
        .offset(x: shake ? 6 : 0)
        .animation(.spring(response: 0.18, dampingFraction: 0.3), value: shake)
        .padding(.top, 6)
    }

    /* ── 逻辑 ─────────────────────────────────────────────── */

    private func save() async {
        guard draft.isValid else {
            Haptics.warning()
            shake.toggle()
            return
        }
        guard !saving else { return }

        saving = true
        var final = draft
        final.title = draft.title.trimmed
        final.tags = Self.parseTags(tagsText)
        final.due = hasDue ? dueDate : nil

        let ok: Bool
        if let existing {
            ok = await store.update(existing, with: final)
        } else {
            ok = await store.create(final)
        }
        saving = false

        if ok {
            Haptics.success()
            dismiss()
        } else {
            Haptics.error()
        }
    }

    /// 与服务端 normalizeTags 保持同一规则：去 #、去重、最多 4 个、单个 ≤ 20 字
    static func parseTags(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let pieces = raw.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" || $0 == "\n" || $0 == "\t" })
        for piece in pieces {
            var tag = String(piece).trimmed
            if tag.hasPrefix("#") { tag.removeFirst() }
            guard !tag.isEmpty, tag.count <= 20, !seen.contains(tag) else { continue }
            seen.insert(tag)
            out.append(tag)
            if out.count == 4 { break }
        }
        return out
    }
}
