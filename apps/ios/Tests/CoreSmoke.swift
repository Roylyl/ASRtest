import Foundation
import AVFoundation

// Exercises the shared converter, engine lifecycle, and on-device JSON records.
@main struct CoreSmoke {
    static func read(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    static func main() throws {
        precondition(CommandLine.arguments.count == 5)
        let expectedHome = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL.path
        precondition(SessionStore.directory.standardizedFileURL.path.hasPrefix(expectedHome), "Core smoke must use isolated storage")
        print("Storage: \(SessionStore.directory.path)")
        precondition(AssetManifest.current.models.count == 8)
        let bundleModels = Bundle.main.resourceURL!.appendingPathComponent("ModelLibrary", isDirectory: true)
        for id in ModelID.allCases {
            let expected = bundleModels.appendingPathComponent(id.rawValue, isDirectory: true)
            precondition(ModelStore().installedURL(id)?.standardizedFileURL == expected.standardizedFileURL, "Every model must come from Bundle/ModelLibrary; no App Support fallback")
        }
        print("PASS all eight model roots are inside physical Bundle/ModelLibrary")
        let english = try read(CommandLine.arguments[1])
        let chinese = try read(CommandLine.arguments[2])
        let nanoSpeech = try read(CommandLine.arguments[4])
        let worker = DispatchQueue(label: "ASRtest.shared-core-smoke")
        let flag = CancellationFlag()
        let backend = RecognitionBackend(queue: worker, cancellation: flag)
        try worker.sync {
            for id in [ModelID.zipformer, .whisperTiny, .voskEnglish, .senseVoice, .paraformer, .whisperBase, .voskChinese, .nano] {
                _ = try backend.load(model: id, options: RecognitionOptions())
                let original = id == .nano ? nanoSpeech : ([.zipformer, .senseVoice, .paraformer, .voskChinese].contains(id) ? chinese : english)
                var firstText: String?
                for rate in [16_000, 48_000, 16_000] {
                    flag.reset()
                    try backend.begin(rate: Double(rate), device: "iOS Simulator file regression", input: "Synthetic file", inputUID: "file-regression")
                    backend.markCaptureStart(ProcessInfo.processInfo.systemUptime)
                    let audio = rate == 16_000 ? original : original.flatMap { [$0, $0, $0] }
                    for offset in stride(from: 0, to: audio.count, by: rate / 10) {
                        try backend.consume(Array(audio[offset..<min(offset + rate / 10, audio.count)]))
                    }
                    let result = backend.finish(reason: "file_test", failure: nil, stopTime: ProcessInfo.processInfo.systemUptime)
                    precondition(result.error == nil, result.error ?? "unknown")
                    precondition(!result.segments.isEmpty)
                    if rate == 16_000 {
                        if let firstText { precondition(firstText == result.text, "Same-rate repeated session changed") }
                        else { firstText = result.text }
                    }
                    if id == .nano { precondition(result.text.contains("滨海新区") && result.text.contains("有房")) }
                    precondition(result.partial.isEmpty)
                    precondition(abs(result.audioSeconds - Double(original.count) / 16_000) < 0.1)
                    let stored = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: result.logURL!))
                    precondition(stored.modelID == id && stored.state == "已完成" && stored.error == nil)
                    precondition(stored.hardwareSampleRate == Double(rate) && stored.inputUID == "file-regression")
                    precondition(stored.text == result.text && stored.inferenceMS > 0)
                    let lines = try String(contentsOf: result.logURL!.deletingPathExtension().appendingPathExtension("jsonl"), encoding: .utf8).split(separator: "\n")
                    let summary = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: Any]
                    precondition(summary["event"] as? String == "summary")
                    print("PASS core \(id.rawValue) rate=\(rate) duration=\(result.audioSeconds) text=\(result.text.replacingOccurrences(of: "\n", with: " | "))")
                }
                for failure in [false, true] {
                    flag.reset()
                    try backend.begin(rate: 16000, device: "cancellation test", input: "Synthetic file", inputUID: "file-regression")
                    try backend.consume(Array(original.prefix(1600)))
                    if !failure { flag.cancel() }
                    let interrupted = backend.finish(reason: failure ? "capture_error" : "audio_interruption", failure: failure ? "Injected audio error" : nil)
                    precondition(interrupted.error != nil)
                    flag.reset()
                    try backend.begin(rate: 16000, device: "reuse after interruption", input: "Synthetic file", inputUID: "file-regression")
                    let empty = backend.finish(reason: "file_test", failure: nil)
                    precondition(empty.error == nil && empty.text.isEmpty && empty.audioSeconds == 0)
                }
                print("PASS core \(id.rawValue) cancellation/failure cleanup and next round")
            }
            backend.unload()
        }
        print("PASS shared core all eight models, 16k/48k conversion, saved records, cancellation/failure reuse")
    }
}
