import SwiftUI

@main
struct AnotherGlassApp: App {
    @StateObject private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CompanionView(model: model)
                .tint(GlassStyle.accent)
                .foregroundStyle(GlassStyle.ink)
                .preferredColorScheme(.dark)
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase) { _, phase in
                    // An incoming permission sheet makes the app inactive briefly.
                    if phase != .inactive { model.sceneChanged(isForeground: phase == .active) }
                }
        }
    }
}
