import Foundation
import AVFoundation

// Exercises the actual iOS native adapters in one linked simulator process.
// This is a lifecycle and file-input regression, not an accuracy benchmark.
@main struct StandardEngineSmoke {
    static func read(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    static func run(_ engine: any NativeASREngine, audio: [Float]) throws -> String {
        try engine.begin()
        var final: [String] = []
        var partialCount = 0
        for offset in stride(from: 0, to: audio.count, by: 1600) {
            let update = try engine.accept(Array(audio[offset..<min(offset + 1600, audio.count)]))
            final += update.finalSegments
            if !update.partial.isEmpty { partialCount += 1 }
        }
        final += try engine.finish().finalSegments
        let duplicateFinish = try engine.finish()
        precondition(duplicateFinish.finalSegments.isEmpty && duplicateFinish.partial.isEmpty)
        let result = final.joined(separator: " ")
        print("  segments=\(final.count) partial_updates=\(partialCount) text=\(result)")
        return result
    }
    static func main() throws {
        precondition(CommandLine.arguments.count == 4, "Arguments: model-library English-16k.wav Chinese-16k.wav")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let english = try read(CommandLine.arguments[2])
        let chinese = try read(CommandLine.arguments[3])
        let worker = DispatchQueue(label: "ASRtest.standard-engine-smoke")
        try worker.sync {
            for id in [ModelID.zipformer, .whisperTiny, .voskEnglish, .senseVoice, .paraformer, .whisperBase, .voskChinese] {
                print("MODEL \(id.rawValue)")
                let flag = CancellationFlag()
                let engine = try makeStandardEngine(id: id, cancellation: flag)
                let options = RecognitionOptions(language: "auto", threads: 2, useITN: true)
                let start = ProcessInfo.processInfo.systemUptime
                try engine.load(root: root.appendingPathComponent(id.rawValue), options: options)
                let audio = [.zipformer, .senseVoice, .paraformer, .voskChinese].contains(id) ? chinese : english
                let first = try run(engine, audio: audio)
                precondition(!first.isEmpty, "Expected nonempty output on the speech fixture")
                let second = try run(engine, audio: audio)
                precondition(first == second, "Repeated-session transcript changed")
                let empty = try run(engine, audio: [])
                precondition(empty.isEmpty, "Empty session should not produce text")
                try engine.begin()
                _ = try engine.accept(Array(audio.prefix(1600)))
                flag.cancel()
                do { _ = try engine.finish(); preconditionFailure("Cancellation should throw") }
                catch { precondition(error.localizedDescription.contains("取消")) }
                flag.reset()
                _ = try run(engine, audio: [])
                if [.whisperTiny, .whisperBase, .senseVoice].contains(id) {
                    try engine.begin()
                    do { _ = try engine.accept([Float](repeating: 0, count: 480_001)); preconditionFailure("Expected limit rejection") }
                    catch { precondition(error.localizedDescription.contains("30 秒")) }
                    _ = try engine.finish()
                }
                if id == .paraformer {
                    _ = try run(engine, audio: Array(audio.prefix(1600)))
                }
                if [.zipformer, .paraformer, .voskChinese, .voskEnglish].contains(id) {
                    try engine.begin()
                    let sequence = audio + [Float](repeating: 0, count: 48_000) + audio
                    var finals: [String] = []
                    for offset in stride(from: 0, to: sequence.count, by: 1600) {
                        finals += try engine.accept(Array(sequence[offset..<min(offset+1600, sequence.count)])).finalSegments
                    }
                    finals += try engine.finish().finalSegments
                    precondition(finals.count >= 2, "Two utterances separated by silence should finalize independently")
                    print("  PASS endpoint restart segments=\(finals.count)")
                }
                if id == .whisperTiny {
                    try engine.begin()
                    _ = try engine.accept(audio)
                    let cancelDone = DispatchSemaphore(value: 0)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { flag.cancel(); cancelDone.signal() }
                    do { _ = try engine.finish(); preconditionFailure("Whisper decode cancellation should throw") }
                    catch { precondition(error.localizedDescription.contains("取消")) }
                    cancelDone.wait()
                    flag.reset()
                    let recovered = try run(engine, audio: audio)
                    precondition(recovered == first)
                    print("  PASS Whisper cancellation during native inference and successful next round")
                }
                engine.unload()
                try engine.load(root: root.appendingPathComponent(id.rawValue), options: options)
                let reloadedEmpty = try run(engine, audio: [])
                precondition(reloadedEmpty.isEmpty)
                engine.unload()
                print("PASS \(id.rawValue) repeated speech, empty, cancellation/reuse, unload/reload; seconds=\(ProcessInfo.processInfo.systemUptime-start)")
            }
        }
        print("PASS all seven standard models in one native process")
    }
}
