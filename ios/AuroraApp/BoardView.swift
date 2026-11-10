// BoardView.swift — 主控台：统计、搜索、筛选、滑动操作、毛玻璃条目
import SwiftUI

struct BoardView: View {
    @EnvironmentObject private var store: AppStore

    @State private var creating = false
    @State private var editing: Note?
    @State private var showSettings = false
    @State private var appeared = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    header
                    statStrip
                    searchBar
                    filterChips
                }
                .padding(.top, 8)
                .listRowStyle(top: 4, bottom: 2)
            }

            Section {
                contentRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .refreshable {
            await store.loadAll(silently: true)
            Haptics.impact(.light)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            fabBar
        }
        .sheet(isPresented: $creating) {
            NoteEditorView(existing: nil)
        }
        .sheet(item: $editing) { note in
            NoteEditorView(existing: note)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { appeared = true }
        }
    }

    /* ── 头部 ─────────────────────────────────────────────── */

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(Palette.textFaint)

                Text(store.user?.displayName ?? "极光")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.impact(.light)
                showSettings = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Palette.brand)
                        .frame(width: 44, height: 44)
                        .shadow(color: Palette.plasma.opacity(0.45), radius: 14, y: 6)
                    Text(store.user?.initial ?? "A")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Palette.mint)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Palette.void, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    /* ── 统计 ─────────────────────────────────────────────── */

    private var statStrip: some View {
        HStack(spacing: 12) {
            ringCard

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    statPill("待办", store.stats.open, Palette.aurora, "circle.dashed")
                    statPill("紧急", store.stats.urgent, Palette.coral, "flame.fill")
                }
                HStack(spacing: 10) {
                    statPill("完成", store.stats.done, Palette.mint, "checkmark.circle.fill")
                    statPill("逾期", store.stats.overdue, Palette.amber, "exclamationmark.triangle.fill")
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 18)
    }

    private var ringCard: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 9)

            Circle()
                .trim(from: 0, to: max(0.015, store.stats.progress))
                .stroke(Palette.brand, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.65, dampingFraction: 0.82), value: store.stats.progress)

            VStack(spacing: 0) {
                Text("\(Int((store.stats.progress * 100).rounded()))")
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("完成度")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .frame(width: 92, height: 92)
        .padding(13)
        .glassPanel(radius: 26)
    }

    private func statPill(_ label: String, _ value: Int, _ tint: Color, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textFaint)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassPanel(radius: 18, tint: tint)
    }

    /* ── 搜索与筛选 ───────────────────────────────────────── */

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.textFaint)

            TextField("搜索标题、正文、标签", text: $store.query)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !store.query.isEmpty {
                Button {
                    Haptics.impact(.light)
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassPanel(radius: 16)
        .animation(.easeOut(duration: 0.16), value: store.query.isEmpty)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(AppStore.Filter.allCases) { item in
                    Button {
                        Haptics.impact(.light)
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            store.filter = item
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 11, weight: .bold))
                            Text(item.label)
                            Text("\(store.count(for: item))")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .opacity(0.7)
                        }
                    }
                    .buttonStyle(ChipButtonStyle(active: store.filter == item))
                }
            }
            .padding(.vertical, 2)
        }
    }

    /* ── 列表主体 ─────────────────────────────────────────── */

    @ViewBuilder
    private var contentRows: some View {
        switch store.phase {
        case .booting, .loading:
            ForEach(0..<3, id: \.self) { _ in
                SkeletonRow()
                    .listRowStyle()
            }

        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.amber)
                Text("连不上服务端")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textDim)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await store.loadAll(silently: false) }
                } label: {
                    Text("重试")
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 180)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 12)
            .listRowStyle()

        case .signedOut:
            EmptyView()
                .listRowStyle()

        case .empty:
            emptyState
                .listRowStyle()

        case .ready:
            if store.visibleNotes.isEmpty {
                noMatchState
                    .listRowStyle()
            } else {
                ForEach(store.visibleNotes) { note in
                    NoteRow(note: note) {
                        Task { await store.toggleDone(note) }
                    }
                    .listRowStyle()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Haptics.impact(.rigid)
                            Task { await store.delete(note) }
                        } label: {
                            Label("删除", systemImage: "trash.fill")
                        }

                        Button {
                            Haptics.impact(.light)
                            editing = note
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }
                        .tint(Palette.aurora)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await store.toggleDone(note) }
                        } label: {
                            Label(
                                note.status == .open ? "完成" : "撤销",
                                systemImage: note.status == .open ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill"
                            )
                        }
                        .tint(Palette.mint)

                        Button {
                            Task { await store.togglePin(note) }
                        } label: {
                            Label(note.pinned ? "取消置顶" : "置顶", systemImage: note.pinned ? "pin.slash.fill" : "pin.fill")
                        }
                        .tint(Palette.amber)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Palette.brand)
                    .frame(width: 88, height: 88)
                    .opacity(0.20)
                    .blur(radius: 14)
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.brand)
            }
            Text("这里还很安静")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text("点右下角的加号，写下第一条。")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private var noMatchState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.textFaint)
            Text("当前筛选下没有条目")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.textDim)
            Button {
                Haptics.impact(.light)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    store.filter = .all
                    store.query = ""
                }
            } label: {
                Text("清除筛选")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.cyan)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /* ── 悬浮新建 ─────────────────────────────────────────── */

    private var fabBar: some View {
        HStack {
            Spacer()
            Button {
                Haptics.impact(.medium)
                creating = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Palette.brand)
                        .frame(width: 62, height: 62)
                        .shadow(color: Palette.plasma.opacity(0.55), radius: 20, y: 10)
                    Image(systemName: "plus")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .buttonStyle(FabButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }
}

/* ── 条目行 ───────────────────────────────────────────────── */

struct NoteRow: View {
    let note: Note
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Button(action: onToggle) {
                checkbox
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.amber)
                    }

                    Text(note.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(note.status == .done ? Palette.textDim : Palette.text)
                        .strikethrough(note.status == .done, color: Palette.textFaint)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(note.priorityLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.priorityGradient(note.priority)))
                }

                Text(note.preview)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    ForEach(Array(note.tags.prefix(3)), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.cyan.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Palette.cyan.opacity(0.12)))
                    }

                    if let due = note.dueDate {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .bold))
                            Text(Span.due(due))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(note.isOverdue ? Palette.coral : Palette.textFaint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(note.isOverdue ? Palette.coral.opacity(0.14) : Color.white.opacity(0.05)))
                    }

                    Spacer(minLength: 0)

                    Text(Span.ago(note.updatedDate))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.textFaint)
                }
            }
        }
        .padding(15)
        .glassPanel(radius: 20, tint: note.priority == 2 ? Palette.coral : Palette.aurora)
        .opacity(note.status == .done ? 0.72 : 1)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: note.status)
    }

    private var checkbox: some View {
        ZStack {
            Circle()
                .fill(note.status == .done
                      ? AnyShapeStyle(Palette.doneGradient)
                      : AnyShapeStyle(Color.white.opacity(0.05)))
                .frame(width: 26, height: 26)

            Circle()
                .strokeBorder(note.status == .done ? Color.clear : Palette.strokeStrong, lineWidth: 1.6)
                .frame(width: 26, height: 26)

            if note.status == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Palette.void)
            }
        }
        .contentShape(Circle())
    }
}

/* ── 骨架屏 ───────────────────────────────────────────────── */

struct SkeletonRow: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .frame(height: 14)
                .frame(maxWidth: 170, alignment: .leading)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(height: 11)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(height: 11)
                .frame(maxWidth: 210, alignment: .leading)
        }
        .padding(16)
        .glassPanel(radius: 20)
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

/* ── 行样式 ───────────────────────────────────────────────── */

extension View {
    func listRowStyle(top: CGFloat = 5, bottom: CGFloat = 5) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 18, bottom: bottom, trailing: 18))
    }
}
