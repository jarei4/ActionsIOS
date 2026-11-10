// AuroraApp.swift — 应用入口
import SwiftUI

@main
struct AuroraApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Palette.aurora)
        }
    }
}
