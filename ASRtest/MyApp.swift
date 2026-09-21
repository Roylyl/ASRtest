// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@main
struct ASRtestApp: App {
    @StateObject private var controller = ASRController()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(controller) }
        .onChange(of: phase) { _, next in
            if next == .background { controller.stop(reason: "app_background") }
            if next == .active { controller.refreshInputsAutomatically(); controller.reloadHistory() }
        }
    }
}
