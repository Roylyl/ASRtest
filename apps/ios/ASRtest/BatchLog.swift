import Foundation

enum BatchItemStatus: String, Codable, Sendable {
    case queued = "待识别", reading = "读取中", recognizing = "识别中"
    case completed = "完成", failed = "失败", stopped = "已停止", skipped = "未运行"
    var terminal: Bool { [.completed, .failed, .stopped, .skipped].contains(self) }
}

struct BatchLogItem: Codable, Identifiable, Sendable {
    let id: String
    let filename: String
    var status: BatchItemStatus = .queued
    var recordID: String?
    var error: String?
    var audioSeconds: Double?
    var inferenceMS: Double?
}

struct BatchLogGroup: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var name: String
    var startedAt = Date()
    var endedAt: Date?
    let model: ModelID
    let options: RecognitionOptions
    var status = "进行中"
    var stopReason: String?
    var items: [BatchLogItem]
    var finishedCount: Int { items.filter { $0.status.terminal }.count }
    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    mutating func close(stopped: Bool, reason: String? = nil) {
        status = stopped ? "已停止" : "已完成"; stopReason = reason; endedAt = Date()
        for i in items.indices where !items[i].status.terminal {
            items[i].status = items[i].status == .queued ? .skipped : .stopped
            items[i].error = reason
        }
    }
}

enum BatchLogStore {
    static var directory: URL { SessionStore.directory.appendingPathComponent("BatchGroups", isDirectory: true) }
    static func url(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ASRError.message("批次标识无效。") }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }
    static func save(_ group: BatchLogGroup) throws {
        guard group.schemaVersion == 1, (1...BatchImport.maximumFiles).contains(group.items.count),
              Set(group.items.map(\.id)).count == group.items.count,
              group.items.allSatisfy({ UUID(uuidString: $0.id) != nil }) else {
            throw ASRError.message("批次内容无效。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(group).write(to: url(group.id), options: .atomic)
    }
    static func load(_ id: String) throws -> BatchLogGroup {
        let file = try url(id)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 2_000_000 else {
            throw ASRError.message("批次文件无效。")
        }
        let group = try JSONDecoder().decode(BatchLogGroup.self, from: Data(contentsOf: file))
        guard group.schemaVersion == 1, group.id == id else { throw ASRError.message("批次标识不匹配。") }
        return group
    }
    static func all() -> [BatchLogGroup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? load($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    static func recoverInterrupted() throws {
        for var group in all() where group.status == "进行中" {
            for i in group.items.indices where !group.items[i].status.terminal {
                if let id = group.items[i].recordID,
                   let record = SessionStore.all().first(where: { $0.id == id }),
                   record.batch?.groupID == group.id, record.batch?.itemID == group.items[i].id {
                    group.items[i].status = record.error == nil ? .completed : .failed
                    group.items[i].error = record.error
                    group.items[i].audioSeconds = record.audioSeconds
                    group.items[i].inferenceMS = record.inferenceMS
                }
            }
            group.close(stopped: true, reason: "上次运行中断；保留已写入结果。")
            group.status = "运行中断"
            try save(group)
        }
    }
    static func delete(_ id: String) throws {
        let group = try load(id)
        let records = SessionStore.all()
        for item in group.items {
            guard let recordID = item.recordID else { continue }
            if let record = records.first(where: { $0.id == recordID }) {
                guard record.batch?.groupID == id, record.batch?.itemID == item.id else {
                    throw ASRError.message("批次与记录关联不匹配，已取消删除。")
                }
            }
        }
        for item in group.items {
            if let id = item.recordID, let record = records.first(where: { $0.id == id }) { try SessionStore.delete(record) }
        }
        try FileManager.default.removeItem(at: url(id))
    }
}
