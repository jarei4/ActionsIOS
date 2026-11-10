// RootView.swift — 会话路由 + 全局提示层
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack {
            AuroraBackground()

            if store.user == nil {
                AuthView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 1.04))
                    ))
            } else {
                BoardView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay(alignment: .top) {
            ToastLayer()
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: store.user?.id)
        .task {
            await store.bootstrap()
        }
    }
}

struct ToastLayer: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            if let toast = store.toast {
                HStack(spacing: 10) {
                    Image(systemName: symbol(toast.kind))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint(toast.kind))
                    Text(toast.text)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(tint(toast.kind).opacity(0.5), lineWidth: 1))
                .shadow(color: tint(toast.kind).opacity(0.3), radius: 18, y: 8)
                .padding(.top, 10)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.toast?.id)
        .allowsHitTesting(false)
    }

    private func symbol(_ kind: AppStore.Toast.Kind) -> String {
        switch kind {
        case .ok: return "checkmark.seal.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func tint(_ kind: AppStore.Toast.Kind) -> Color {
        switch kind {
        case .ok: return Palette.mint
        case .warn: return Palette.amber
        case .error: return Palette.coral
        }
    }
}
