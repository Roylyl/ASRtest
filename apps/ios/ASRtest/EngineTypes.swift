import Foundation

enum ModelID: String, CaseIterable, Codable, Identifiable, Sendable {
    case zipformer, whisperTiny, whisperBase, voskChinese, voskEnglish, senseVoice, paraformer, nano
    var id: String { rawValue }
}
struct RecognitionOptions: Codable, Equatable, Sendable {
    var language = "auto"
    var threads = 2
    var useITN = true
}
struct EngineUpdate: Sendable {
    var partial = ""
    // Newly finalized segments only, not the accumulated transcript.
    var finalSegments: [String] = []
}
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
enum ASRError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
// All operations except CancellationFlag.cancel run on the same serial worker queue.
// Native recognizers receive 16 kHz mono Float32. Vosk converts locally to PCM16.
protocol NativeASREngine: AnyObject {
    func load(root: URL, options: RecognitionOptions) throws
    func begin() throws
    func accept(_ samples: [Float]) throws -> EngineUpdate
    func finish() throws -> EngineUpdate
    func unload()
}
