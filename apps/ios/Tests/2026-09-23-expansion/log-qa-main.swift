import Foundation
struct ASRError: LocalizedError { let message: String; var errorDescription: String? { message }; static func message(_ value: String) -> ASRError { ASRError(message: value) } }
enum ModelID: String, Codable, Sendable { case zipformer; var title: String { "Zipformer Small" } }
struct RecognitionOptions: Codable, Sendable { var language = "auto" }
struct ModelFile: Codable, Sendable { var path = "model.onnx" }
enum BatchImport { static let maximumFiles = 100 }
enum WatchASRLogStore { static var directory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASRTEST_TEST_ROOT"]!, isDirectory: true).appendingPathComponent("WatchLogs", isDirectory: true) } }
let one = BatchLogItem(id: UUID().uuidString, filename: "a.wav")
let two = BatchLogItem(id: UUID().uuidString, filename: "b.wav", status: .failed, error: "bad wav")
var group = BatchLogGroup(name: "QA", model: .zipformer, options: RecognitionOptions(), items: [one,two])
var record = SessionRecord(modelID: .zipformer, modelName: "Zipformer Small", framework: "sherpa", options: RecognitionOptions(), device: "test", input: "a.wav", inputUID: "batch-file", hardwareSampleRate: 16000, modelRevision: nil, modelFiles: [])
record.text = "hello"; record.batch = BatchRecordLink(groupID: group.id, itemID: one.id, index: 1, total: 2, filename: "a.wav")
try SessionStore.save(record)
try Data("{\"event\":\"summary\"}\n".utf8).write(to: SessionStore.url(record.id, extension: "jsonl"))
group.items[0].status = .completed; group.items[0].recordID = record.id; group.close(stopped: false)
try BatchLogStore.save(group)
assert(SessionStore.all().count == 1)
assert(BatchLogStore.all().count == 1)
let zip = try AllLogsExport.create()
print("ZIP=\(zip.path)")
try BatchLogStore.delete(group.id)
assert(SessionStore.all().isEmpty && BatchLogStore.all().isEmpty)
print("LOG_QA_OK")
