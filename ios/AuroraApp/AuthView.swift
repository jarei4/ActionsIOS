// AuthView.swift — 登录 / 创建账号（同一套视觉语言，零跳转）
import SwiftUI
import UIKit

struct AuthView: View {
    @EnvironmentObject private var store: AppStore

    private enum Mode: Hashable {
        case login
        case register
    }

    private enum Field: Hashable {
        case email
        case password
        case confirm
    }

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var reveal = false
    @State private var appeared = false

    @FocusState private var focus: Field?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 26) {
                mark
                headline
                card
                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) { appeared = true }
        }
    }

    /* ── 标识与标题 ───────────────────────────────────────── */

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Palette.brand)
                .frame(width: 88, height: 88)
                .shadow(color: Palette.plasma.opacity(0.55), radius: 28, y: 14)

            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 40, height: 40)

            Circle()
                .fill(Color.white)
                .frame(width: 13, height: 13)
        }
        .rotation3DEffect(.degrees(appeared ? 0 : -28), axis: (x: 1, y: 0.7, z: 0))
        .scaleEffect(appeared ? 1 : 0.84)
        .opacity(appeared ? 1 : 0)
    }

    private var headline: some View {
        VStack(spacing: 8) {
            Text("AURORA")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .tracking(6)
                .foregroundStyle(Palette.brand)
                .overlay(
                    Text("AURORA")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .tracking(6)
                        .foregroundStyle(Color.white.opacity(0.92))
                        .mask(
                            LinearGradient(
                                colors: [.white, .white.opacity(0.15)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )

            Text("极光控制台 · 你的条目只属于你")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.textDim)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
    }

    /* ── 表单卡片 ─────────────────────────────────────────── */

    private var card: some View {
        VStack(spacing: 16) {
            segmented

            field("envelope.fill", "邮箱", text: $email, field: .email, keyboard: .emailAddress)

            field("lock.fill", "密码", text: $password, secure: true, field: .password)

            if mode == .register {
                field("checkmark.shield.fill", "确认密码", text: $confirm, secure: true, field: .confirm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let hint = hint {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").font(.system(size: 11, weight: .bold))
                    Text(hint).font(.system(size: 12, weight: .medium, design: .rounded))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.amber)
                .transition(.opacity)
            }

            Button {
                submit()
            } label: {
                ZStack {
                    Text(mode == .login ? "进入控制台" : "创建并进入")
                        .opacity(store.authBusy ? 0 : 1)
                    if store.authBusy {
                        ProgressView().tint(.white)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: canSubmit && !store.authBusy))
            .disabled(!canSubmit || store.authBusy)

            Text(mode == .login
                 ? "首次使用请先创建账号，第一个账号自动成为主控。"
                 : "密码至少 8 位，且需包含大小写字母、数字、符号中的两类。")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(Palette.textFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .glassPanel(radius: 28)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 22)
        .animation(.easeInOut(duration: 0.22), value: mode)
        .animation(.easeInOut(duration: 0.18), value: hint)
    }

    private var segmented: some View {
        HStack(spacing: 4) {
            segment(.login, "登录")
            segment(.register, "创建账号")
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }

    private func segment(_ target: Mode, _ title: String) -> some View {
        Button {
            guard mode != target else { return }
            Haptics.impact(.light)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { mode = target }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(mode == target ? Palette.text : Palette.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(mode == target ? Color.white.opacity(0.13) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func field(
        _ symbol: String,
        _ placeholder: String,
        text: Binding<String>,
        secure: Bool = false,
        field: Field,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(focus == field ? Palette.cyan : Palette.textFaint)
                .frame(width: 22)

            Group {
                if secure && !reveal {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(Palette.text)
            .focused($focus, equals: field)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(secure ? .password : .username)
            .submitLabel(field == .confirm ? .go : .next)
            .onSubmit {
                switch field {
                case .email: focus = .password
                case .password: focus = mode == .register ? .confirm : nil
                case .confirm: submit()
                }
            }

            if secure {
                Button {
                    reveal.toggle()
                    Haptics.impact(.light)
                } label: {
                    Image(systemName: reveal ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(focus == field ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(focus == field ? Palette.cyan.opacity(0.65) : Palette.stroke, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.16), value: focus)
    }

    /* ── 页脚 ─────────────────────────────────────────────── */

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                Text(AppConfig.apiBaseDisplay)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Palette.textFaint)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))

            Text("\(AppConfig.versionLabel) · \(AppConfig.distributionChannel)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.textFaint.opacity(0.8))
        }
        .opacity(appeared ? 1 : 0)
    }

    /* ── 逻辑 ─────────────────────────────────────────────── */

    private var emailLooksValid: Bool {
        let value = email.trimmed
        return value.contains("@") && value.count >= 5 && !value.hasPrefix("@") && !value.hasSuffix("@")
    }

    private var passwordLooksValid: Bool { password.count >= 8 }

    private var canSubmit: Bool {
        switch mode {
        case .login:
            return emailLooksValid && passwordLooksValid
        case .register:
            return emailLooksValid && passwordLooksValid && confirm == password
        }
    }

    private var hint: String? {
        if mode == .register {
            if !password.isEmpty && !passwordLooksValid { return "密码至少 8 位" }
            if !confirm.isEmpty && confirm != password { return "两次输入的密码不一致" }
        }
        if !email.isEmpty && !emailLooksValid { return "邮箱格式看起来不对" }
        return nil
    }

    private func submit() {
        guard canSubmit, !store.authBusy else {
            Haptics.warning()
            return
        }
        focus = nil
        Task {
            switch mode {
            case .login:
                _ = await store.signIn(email: email, password: password)
            case .register:
                _ = await store.signUp(email: email, password: password)
            }
        }
    }
}
