// SettingsView.swift — 账号、连接、版本与签名信息、退出
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingSignOut = false
    @State private var copied = false

    var body: some View {
        ZStack {
            AuroraBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    topBar
                    identityCard
                    infoCard
                    securityCard
                    signOutButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert("退出登录？", isPresented: $confirmingSignOut) {
            Button("退出", role: .destructive) {
                Task {
                    await store.signOut()
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机的访问令牌会从钥匙串清除，服务端会吊销这次的刷新令牌。")
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
    }

    /* ── 账号 ─────────────────────────────────────────────── */

    private var identityCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Palette.brand)
                    .frame(width: 54, height: 54)
                    .shadow(color: Palette.plasma.opacity(0.45), radius: 14, y: 6)
                Text(store.user?.initial ?? "A")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.user?.displayName ?? "未登录")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(store.user?.email ?? "—")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(store.user?.roleLabel ?? "—")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Palette.cyan.opacity(0.14)))
        }
        .padding(16)
        .glassPanel(radius: 24)
    }

    /* ── 连接 / 版本 / 签名 ───────────────────────────────── */

    private var infoCard: some View {
        VStack(spacing: 0) {
            row("antenna.radiowaves.left.and.right", "服务端", AppConfig.apiBaseDisplay, copyable: true)
            divider
            row("number", "版本", AppConfig.versionLabel)
            divider
            row("shippingbox", "Bundle ID", AppConfig.bundleIdentifier)
            divider
            row("hammer", "构建渠道", AppConfig.distributionChannel)
        }
        .padding(.vertical, 4)
        .glassPanel(radius: 24)
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.mint)
                Text("安全与签名")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
            }

            Text("""
            · 令牌只存钥匙串（本机、首次解锁后可读），退出登录即清除
            · 15 分钟访问令牌 + 可旋转刷新令牌，复用会被判定为泄露并吊销全部会话
            · 自签重签后钥匙串数据会随描述文件变化而失效，属正常现象，重新登录即可
            """)
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(Palette.textDim)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 24, tint: Palette.mint)
    }

    private func row(_ symbol: String, _ label: String, _ value: String, copyable: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 20)

            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.textDim)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)

            if copyable {
                Button {
                    UIPasteboard.general.string = value
                    Haptics.success()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(copied ? Palette.mint : Palette.cyan)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(height: 1)
            .padding(.leading, 48)
    }

    /* ── 退出 ─────────────────────────────────────────────── */

    private var signOutButton: some View {
        Button {
            Haptics.impact(.medium)
            confirmingSignOut = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 13, weight: .bold))
                Text("退出登录")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Palette.coral)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.coral.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.coral.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}
