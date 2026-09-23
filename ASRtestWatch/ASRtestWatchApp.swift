import SwiftUI

@main struct ASRtestWatchApp: App {
    @StateObject private var asr = WatchASRController()
    var body: some Scene { WindowGroup { WatchContentView().environmentObject(asr) } }
}
