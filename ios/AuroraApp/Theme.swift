// Theme.swift — 视觉系统：极光色板、玻璃面板、动效与触感
import SwiftUI
import UIKit

enum Palette {
    static let void = Color(hex: 0x05060B)
    static let ink = Color(hex: 0x0A0C16)

    static let stroke = Color.white.opacity(0.10)
    static let strokeStrong = Color.white.opacity(0.22)

    static let text = Color(hex: 0xF4F6FF)
    static let textDim = Color(hex: 0xF4F6FF).opacity(0.62)
    static let textFaint = Color(hex: 0xF4F6FF).opacity(0.38)

    static let aurora = Color(hex: 0x6D5BFF)
    static let plasma = Color(hex: 0xC94BFF)
    static let cyan = Color(hex: 0x27E1F5)
    static let mint = Color(hex: 0x33E6A8)
    static let coral = Color(hex: 0xFF6B8A)
    static let amber = Color(hex: 0xFFC05A)

    static var brand: LinearGradient {
        LinearGradient(colors: [aurora, plasma, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var doneGradient: LinearGradient {
        LinearGradient(colors: [mint, cyan], startPoint: .leading, endPoint: .trailing)
    }

    static var hotGradient: LinearGradient {
        LinearGradient(colors: [coral, plasma], startPoint: .leading, endPoint: .trailing)
    }

    static func priorityGradient(_ priority: Int) -> LinearGradient {
        switch priority {
        case 2: return hotGradient
        case 0: return LinearGradient(colors: [cyan, mint], startPoint: .bottom, endPoint: .top)
        default: return LinearGradient(colors: [aurora, plasma], startPoint: .bottom, endPoint: .top)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

/* ── 背景：三团缓慢漂移的极光 ───────────────────────────────── */
struct AuroraBackground: View {
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                Palette.void

                Circle()
                    .fill(Palette.aurora)
                    .frame(width: w * 1.05, height: w * 1.05)
                    .blur(radius: 95)
                    .opacity(0.55)
                    .offset(x: drift ? -w * 0.30 : -w * 0.06, y: drift ? -h * 0.32 : -h * 0.20)

                Circle()
                    .fill(Palette.plasma)
                    .frame(width: w * 0.92, height: w * 0.92)
                    .blur(radius: 95)
                    .opacity(0.48)
                    .offset(x: drift ? w * 0.32 : w * 0.14, y: drift ? -h * 0.06 : h * 0.12)

                Circle()
                    .fill(Palette.cyan)
                    .frame(width: w * 0.80, height: w * 0.80)
                    .blur(radius: 85)
                    .opacity(0.36)
                    .offset(x: drift ? w * 0.06 : -w * 0.12, y: drift ? h * 0.34 : h * 0.18)

                LinearGradient(
                    colors: [Color.clear, Palette.void.opacity(0.55), Palette.void.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // 顶部极细高光，制造玻璃质感
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: h * 0.28)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: w, height: h)
            .clipped()
            .onAppear {
                withAnimation(.easeInOut(duration: 13).repeatForever(autoreverses: true)) {
                    drift = true
                }
            }
        }
        .ignoresSafeArea()
    }
}

/* ── 玻璃面板 ─────────────────────────────────────────────── */
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 24
    var tint: Color = .white

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.07), tint.opacity(0.015)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Palette.strokeStrong, Palette.stroke],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 14)
            )
    }
}

extension View {
    func glassPanel(radius: CGFloat = 24, tint: Color = .white) -> some View {
        modifier(GlassPanel(radius: radius, tint: tint))
    }
}

/* ── 按钮样式 ─────────────────────────────────────────────── */
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                Capsule()
                    .fill(Palette.brand)
                    .overlay(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
            .shadow(color: Palette.plasma.opacity(enabled ? 0.45 : 0), radius: configuration.isPressed ? 10 : 22, y: 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(active ? Palette.text : Palette.textDim)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(active ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(
                Capsule().strokeBorder(active ? Color.white.opacity(0.28) : Palette.stroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct FabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? 8 : 0))
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/* ── 触感 ─────────────────────────────────────────────────── */
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/* ── 时间文案 ─────────────────────────────────────────────── */
enum Span {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func ago(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86400: return "\(Int(seconds / 3600)) 小时前"
        case ..<(86400 * 7): return "\(Int(seconds / 86400)) 天前"
        default: return dayFormatter.string(from: date)
        }
    }

    static func due(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 " + minuteFormatter.string(from: date) }
        if calendar.isDateInTomorrow(date) { return "明天 " + minuteFormatter.string(from: date) }
        return dayFormatter.string(from: date)
    }
}
