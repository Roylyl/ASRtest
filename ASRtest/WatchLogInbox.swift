import Foundation
import WatchConnectivity

struct WatchASRLog: Codable, Identifiable, Sendable {
    var schemaVersion: Int
    var id: String
    var startedAt: Date
    var endedAt: Date
    var modelID: String
    var modelName: String
    var language: String
    var partials: [String]
    var finalText: String
    var audioSeconds: Double
    var modelLoadMS: Double?
    var inferenceMS: Double
    var status: String
    var error: String?
}

enum WatchASRLogStore {
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WatchLogs", isDirectory: true) }
    static func url(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ASRError.message("手表日志标识无效") }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }
    static func all() -> [WatchASRLog] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> WatchASRLog? in
            guard file.pathExtension == "json",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) < 2_000_000,
                  let data = try? Data(contentsOf: file),
                  let log = try? JSONDecoder().decode(WatchASRLog.self, from: data),
                  log.schemaVersion == 1, log.id == file.deletingPathExtension().lastPathComponent else { return nil }
            return log
        }.sorted { $0.startedAt > $1.startedAt }
    }
    static func importFile(_ file: URL, expectedID: String?) throws -> String {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size < 2_000_000 else { throw ASRError.message("手表日志文件无效") }
        let data = try Data(contentsOf: file)
        let log = try JSONDecoder().decode(WatchASRLog.self, from: data)
        guard log.schemaVersion == 1, UUID(uuidString: log.id) != nil,
              log.id == expectedID, log.modelID == "whisperTiny",
              log.endedAt >= log.startedAt, log.audioSeconds.isFinite, (0...30.5).contains(log.audioSeconds),
              log.inferenceMS.isFinite, log.inferenceMS >= 0,
              log.modelLoadMS.map({ $0.isFinite && $0 >= 0 }) ?? true,
              log.partials.count <= 1_000 else { throw ASRError.message("手表日志字段无效") }
        let destination = try url(log.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else { throw ASRError.message("相同日志 ID 内容不一致") }
        } else { try data.write(to: destination, options: .atomic) }
        return log.id
    }
    static func delete(_ log: WatchASRLog) throws { try FileManager.default.removeItem(at: url(log.id)) }
}

final class WatchLogInbox: NSObject, WCSessionDelegate {
    var received: ((URL, String?, @escaping (String) -> Void) -> Void)?
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["asrtestWatchLog"] as? Bool == true,
              let id = file.metadata?["id"] as? String, UUID(uuidString: id) != nil else { return }
        // WCSession's source URL is short-lived. Stage it before returning.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("ASRtest-watch-\(UUID().uuidString).json")
        do { try FileManager.default.copyItem(at: file.fileURL, to: staged) }
        catch { return }
        received?(staged, id, { savedID in session.transferUserInfo(["asrtestWatchLogReceipt": savedID]) })
    }
}
