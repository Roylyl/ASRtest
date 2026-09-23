import Foundation

struct BatchRecordLink: Codable, Sendable {
    let groupID: String
    let itemID: String
    let index: Int
    let total: Int
    let filename: String
}

struct SessionRecord: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var startedAt = Date()
    var modelID: ModelID
    var modelName: String
    var framework: String
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
    var options: RecognitionOptions
    var device: String
    var input: String
    var inputUID: String
    var hardwareSampleRate: Double
    var modelRevision: String?
    var modelFiles: [ModelFile]
    var text = ""
    var audioSeconds = 0.0
    var inferenceMS = 0.0
    var firstOutputMS: Double?
    var stopWaitMS = 0.0
    var loadMS = 0.0
    var state = "未完成"
    var reason = ""
    var error: String?
    // Optional so records written by ASRtest 1.0.0 remain decodable.
    var batch: BatchRecordLink?
    var metricDefinition = "流式：接收/解码/取结果及结束调用；非流式：结束转写调用。均不含采集、重采样、界面或日志，不是严格模型RTF。"
}
struct SessionStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sessions", isDirectory: true)
    }
    private static func validID(_ id: String) -> Bool { UUID(uuidString: id) != nil && !id.contains("/") && !id.contains("\\") }
    static func url(_ id: String, extension ext: String = "json") -> URL {
        // Preserve the nonthrowing API without allowing a damaged record to escape Sessions.
        let name = validID(id) ? id : "invalid-session"
        let suffix = ["json", "jsonl"].contains(ext) ? ext : "json"
        return directory.appendingPathComponent(name).appendingPathExtension(suffix)
    }
    static func save(_ record: SessionRecord) throws {
        guard validID(record.id), record.schemaVersion == 1 else { throw ASRError.message("测试记录标识或版本无效。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folderValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else { throw ASRError.message("日志目录不可用。") }
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url(record.id), options: .atomic)
    }
    static func all() -> [SessionRecord] {
        guard let folder = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folder.isDirectory == true, folder.isSymbolicLink != true,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size <= 16 * 1024 * 1024,
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
                  record.schemaVersion == 1, validID(record.id),
                  record.id == file.deletingPathExtension().lastPathComponent else { return nil }
            return record
        }.sorted { $0.startedAt > $1.startedAt }
    }
    static func delete(_ record: SessionRecord) throws {
        guard validID(record.id) else { throw ASRError.message("测试记录标识无效。") }
        for ext in ["json", "jsonl"] {
            let file = url(record.id, extension: ext)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
