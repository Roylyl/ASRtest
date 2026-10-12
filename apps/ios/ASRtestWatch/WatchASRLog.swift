import Foundation
import WatchConnectivity

struct WatchASRLog: Codable, Identifiable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var startedAt = Date()
    var endedAt = Date()
    var modelID = "whisperTiny"
    var modelName = "Whisper tiny · 多语言"
    var language = "auto"
    var partials: [String] = [] // Non-streaming Whisper has no partial text.
    var finalText = ""
    var audioSeconds = 0.0
    var modelLoadMS: Double?
    var inferenceMS = 0.0
    var status = "未完成"
    var error: String?
}

enum WatchASRLogStore {
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ASRLogs", isDirectory: true) }
    static func url(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }
    static func save(_ log: WatchASRLog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(log).write(to: url(log.id), options: .atomic)
    }
    static func all() -> [WatchASRLog] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(WatchASRLog.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

final class WatchASRTransfer: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var states: [String: String] = UserDefaults.standard.dictionary(forKey: "watchDeliveryStates") as? [String: String] ?? [:]
    @Published private(set) var connection = "正在连接 iPhone"
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
        else { connection = "此设备不支持 WatchConnectivity" }
    }
    func state(_ id: String) -> String { states[id] ?? "仅保存在手表" }
    private func setState(_ value: String, for id: String) {
        states[id] = value
        UserDefaults.standard.set(states, forKey: "watchDeliveryStates")
    }
    func export(_ logs: [WatchASRLog]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            connection = "连接尚未激活，请稍后重试"; return
        }
        for log in logs where states[log.id] != "iPhone 已接收" {
            let file = WatchASRLogStore.url(log.id)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            setState("已排队，等待传送", for: log.id)
            WCSession.default.transferFile(file, metadata: ["asrtestWatchLog": true, "id": log.id])
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.connection = error?.localizedDescription ?? (state == .activated ? "可传送日志" : "连接尚未激活") }
    }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?["id"] as? String else { return }
        DispatchQueue.main.async {
            guard self.states[id] != "iPhone 已接收" else { return }
            self.setState(error == nil ? "已传送，待 iPhone 确认" : "传送失败：\(error!.localizedDescription)", for: id)
        }
    }
    func session(_ session: WCSession, didReceiveUserInfo info: [String: Any] = [:]) {
        guard let id = info["asrtestWatchLogReceipt"] as? String else { return }
        DispatchQueue.main.async { self.setState("iPhone 已接收", for: id) }
    }
}
