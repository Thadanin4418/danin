import SwiftUI
import UIKit

@main
struct SoraninApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
        .onChange(of: scenePhase) { _, _ in
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
