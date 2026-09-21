// SPDX-License-Identifier: Apache-2.0
import Foundation
import NanoRuntime

private let nanoCancellationCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { user in
    guard let user else { return 1 }
    return Unmanaged<CancellationFlag>.fromOpaque(user).takeUnretainedValue().isCancelled ? 1 : 0
}

// The app's serial recognition worker owns all context and audio access.
// CancellationFlag is queried safely from native model-loading/compute callbacks.
final class NanoEngine: NativeASREngine {
    private let cancellation: CancellationFlag
    private var context: OpaquePointer?
    private var audio: [Float] = []
    private var recording = false
    private static let maximumSamples = 30 * 16_000

    init(cancellation: CancellationFlag) { self.cancellation = cancellation }
    deinit { unload() }

    func load(root: URL, options: RecognitionOptions) throws {
        unload()
        try checkCancellation()
        let encoder = root.appendingPathComponent("funasr-encoder-f16.gguf")
        let decoder = root.appendingPathComponent("qwen3-0.6b-q4km.gguf")
        let vad = root.appendingPathComponent("fsmn-vad.gguf")
        for file in [encoder, decoder, vad] where !FileManager.default.fileExists(atPath: file.path) {
            throw ASRError.message("Nano 模型文件不存在：\(file.lastPathComponent)")
        }
        let language: String
        switch options.language.lowercased() {
        case "zh", "zh-cn", "chinese", "中文": language = "中文"
        case "en", "en-us", "english", "英文", "英语": language = "英文"
        case "ja", "japanese", "日文", "日语": language = "日文"
        default: language = ""
        }
        var error = [CChar](repeating: 0, count: 1024)
        context = asr_nano_open(encoder.path, decoder.path, vad.path, language,
                               Int32(max(1, min(options.threads, 4))),
                               nanoCancellationCallback,
                               Unmanaged.passUnretained(cancellation).toOpaque(),
                               &error, error.count)
        guard context != nil else {
            try checkCancellation()
            throw ASRError.message("Nano 加载失败：\(String(cString: error))")
        }
        if cancellation.isCancelled { unload(); throw ASRError.message("识别已取消") }
    }

    func begin() throws {
        guard context != nil else { throw ASRError.message("Nano 模型尚未加载") }
        try checkCancellation()
        audio.removeAll(keepingCapacity: true)
        audio.reserveCapacity(Self.maximumSamples)
        recording = true
    }

    func accept(_ samples: [Float]) throws -> EngineUpdate {
        guard recording else { throw ASRError.message("Nano 录音尚未开始") }
        try checkCancellation()
        guard samples.count <= Self.maximumSamples - audio.count else {
            throw ASRError.message("Nano 当前最多识别 30 秒录音，请停止后再开始新录音")
        }
        audio.append(contentsOf: samples)
        return EngineUpdate()
    }

    func finish() throws -> EngineUpdate {
        guard let context else { throw ASRError.message("Nano 模型尚未加载") }
        guard recording else { return EngineUpdate() }
        recording = false
        defer { audio.removeAll(keepingCapacity: true) }
        try checkCancellation()
        let status = audio.withUnsafeBufferPointer { asr_nano_transcribe(context, $0.baseAddress, $0.count) }
        try checkCancellation()
        guard status == 0 else {
            let detail = asr_nano_error(context).map { String(cString: $0) } ?? "未知错误"
            throw ASRError.message(status == -2 ? "识别已取消" : "Nano 识别失败：\(detail)")
        }
        let text = asr_nano_text(context).map { String(cString: $0) } ?? ""
        let segments = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return EngineUpdate(finalSegments: segments)
    }

    func unload() {
        recording = false
        audio.removeAll(keepingCapacity: false)
        if let context { asr_nano_close(context) }
        context = nil
    }

    private func checkCancellation() throws {
        if cancellation.isCancelled { throw ASRError.message("识别已取消") }
    }
}
