import Foundation
import SherpaOnnxC
import whisper
import VoskC

// Adapted from the three working ASRtest iOS projects. Native handles are owned
// by the shared serial worker; only CancellationFlag is accessed cross-thread.
func makeStandardEngine(id: ModelID, cancellation: CancellationFlag) throws -> any NativeASREngine {
    switch id {
    case .zipformer, .paraformer:
        return SherpaStreamingEngine(id: id, cancellation: cancellation)
    case .whisperTiny, .whisperBase:
        return WhisperEngine(id: id, cancellation: cancellation)
    case .voskChinese, .voskEnglish:
        return VoskEngine(cancellation: cancellation)
    case .senseVoice:
        return SenseVoiceEngine(cancellation: cancellation)
    case .nano:
        throw ASRError.message("Fun-ASR-Nano 需要专用本地运行库。")
    }
}

private let engineSampleRate: Int32 = 16_000
private let offlineSampleLimit = 30 * 16_000

private func modelFile(_ root: URL, _ name: String) throws -> String {
    let file = root.appendingPathComponent(name)
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue,
          FileManager.default.isReadableFile(atPath: file.path),
          let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
          size.int64Value > 0 else { throw ASRError.message("模型文件缺失或不可读：\(name)") }
    return file.path
}
private func checkCancellation(_ flag: CancellationFlag) throws {
    if flag.isCancelled { throw ASRError.message("识别已取消。") }
}
private func threadCount(_ options: RecognitionOptions) throws -> Int32 {
    guard (1...8).contains(options.threads) else { throw ASRError.message("推理线程数须为 1 至 8。") }
    return Int32(options.threads)
}
private func validatedAudio(_ samples: [Float]) throws -> [Float] {
    guard samples.count <= Int(Int32.max) else { throw ASRError.message("单次音频缓冲过大。") }
    guard samples.allSatisfy({ $0.isFinite }) else { throw ASRError.message("音频中包含无效采样值。") }
    return samples
}
private func appendOffline(_ samples: [Float], to audio: inout [Float]) throws {
    guard samples.count <= offlineSampleLimit - audio.count else {
        throw ASRError.message("本测试工具的单轮非流式录音上限为 30 秒，请分段测试。")
    }
    audio.append(contentsOf: try validatedAudio(samples))
}
private func segments(_ text: String) -> [String] {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? [] : [clean]
}
private final class CStringPool {
    private var values: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        values.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { values.forEach { free($0) } }
}

private final class SherpaStreamingEngine: NativeASREngine {
    private let id: ModelID
    private let cancellation: CancellationFlag
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var sampleCount = 0
    private var partial = ""
    init(id: ModelID, cancellation: CancellationFlag) { self.id = id; self.cancellation = cancellation }
    deinit { unload() }

    func load(root: URL, options: RecognitionOptions) throws {
        guard stream == nil else { throw ASRError.message("请先结束当前识别会话。") }
        unload()
        let strings = CStringPool()
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = engineSampleRate
        config.feat_config.feature_dim = 80
        config.model_config.tokens = strings.add(try modelFile(root, "tokens.txt"))
        config.model_config.provider = strings.add("cpu")
        config.model_config.num_threads = try threadCount(options)
        if id == .zipformer {
            config.model_config.transducer.encoder = strings.add(try modelFile(root, "encoder-epoch-99-avg-1.int8.onnx"))
            config.model_config.transducer.decoder = strings.add(try modelFile(root, "decoder-epoch-99-avg-1.onnx"))
            config.model_config.transducer.joiner = strings.add(try modelFile(root, "joiner-epoch-99-avg-1.int8.onnx"))
            config.model_config.model_type = strings.add("zipformer")
        } else {
            config.model_config.paraformer.encoder = strings.add(try modelFile(root, "encoder.int8.onnx"))
            config.model_config.paraformer.decoder = strings.add(try modelFile(root, "decoder.int8.onnx"))
            config.model_config.model_type = strings.add("paraformer")
        }
        config.decoding_method = strings.add("greedy_search")
        config.max_active_paths = 4
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 1.4
        config.rule3_min_utterance_length = 20
        let created = withExtendedLifetime(strings) { SherpaOnnxCreateOnlineRecognizer(&config) }
        guard let created else { throw ASRError.message("sherpa-onnx 流式模型加载失败，请检查模型文件。") }
        recognizer = created
    }
    func begin() throws {
        try checkCancellation(cancellation)
        guard let recognizer, stream == nil else { throw ASRError.message("模型尚未就绪或上一轮尚未结束。") }
        guard let created = SherpaOnnxCreateOnlineStream(recognizer) else { throw ASRError.message("无法创建流式识别会话。") }
        stream = created; sampleCount = 0; partial = ""
    }
    func accept(_ samples: [Float]) throws -> EngineUpdate {
        try checkCancellation(cancellation)
        guard let stream, let recognizer else { throw ASRError.message("流式识别会话尚未开始。") }
        let audio = try validatedAudio(samples)
        guard !audio.isEmpty else { return EngineUpdate(partial: partial) }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, engineSampleRate, audio, Int32(audio.count))
        sampleCount += audio.count
        try decodeReady()
        partial = try result()
        if SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0 {
            let finalized = segments(partial)
            SherpaOnnxOnlineStreamReset(recognizer, stream)
            partial = ""
            return EngineUpdate(finalSegments: finalized)
        }
        return EngineUpdate(partial: partial)
    }
    func finish() throws -> EngineUpdate {
        guard let stream else { return EngineUpdate() }
        defer {
            SherpaOnnxDestroyOnlineStream(stream)
            self.stream = nil; partial = ""; sampleCount = 0
        }
        try checkCancellation(cancellation)
        guard sampleCount > 0 else { return EngineUpdate() }
        // Padding belongs to model finalization, never to the recorded duration.
        let tailCount = id == .zipformer ? 10_560 : 4_800
        let tail = [Float](repeating: 0, count: tailCount)
        SherpaOnnxOnlineStreamAcceptWaveform(stream, engineSampleRate, tail, Int32(tail.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        if id == .paraformer {
            // v1.13.8 accepts the final short feature chunk only with this flag.
            SherpaOnnxOnlineStreamSetOption(stream, "is_final", "1")
        }
        try decodeReady()
        return EngineUpdate(finalSegments: segments(try result()))
    }
    private func decodeReady() throws {
        guard let recognizer, let stream else { return }
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
            try checkCancellation(cancellation)
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
        try checkCancellation(cancellation)
    }
    private func result() throws -> String {
        guard let recognizer, let stream,
              let value = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else {
            throw ASRError.message("无法获取流式识别结果。")
        }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(value) }
        return value.pointee.text.map { String(cString: $0) } ?? ""
    }
    func unload() {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }; stream = nil
        if let recognizer { SherpaOnnxDestroyOnlineRecognizer(recognizer) }; recognizer = nil
        sampleCount = 0; partial = ""
    }
}

private final class SenseVoiceEngine: NativeASREngine {
    private let cancellation: CancellationFlag
    private var recognizer: OpaquePointer?
    private var audio: [Float] = []
    private var active = false
    init(cancellation: CancellationFlag) { self.cancellation = cancellation }
    deinit { unload() }
    func load(root: URL, options: RecognitionOptions) throws {
        guard !active else { throw ASRError.message("请先结束当前识别会话。") }
        unload()
        guard ["auto", "zh", "en", "ja", "ko", "yue"].contains(options.language) else {
            throw ASRError.message("SenseVoice 不支持所选语言提示。")
        }
        let strings = CStringPool()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = engineSampleRate
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = strings.add(try modelFile(root, "model.int8.onnx"))
        config.model_config.sense_voice.language = strings.add(options.language)
        config.model_config.sense_voice.use_itn = options.useITN ? 1 : 0
        config.model_config.tokens = strings.add(try modelFile(root, "tokens.txt"))
        config.model_config.num_threads = try threadCount(options)
        config.model_config.provider = strings.add("cpu")
        config.model_config.model_type = strings.add("sense_voice")
        config.decoding_method = strings.add("greedy_search")
        config.max_active_paths = 4
        let created = withExtendedLifetime(strings) { SherpaOnnxCreateOfflineRecognizer(&config) }
        guard let created else { throw ASRError.message("SenseVoiceSmall 本地模型加载失败。") }
        recognizer = created
    }
    func begin() throws {
        try checkCancellation(cancellation)
        guard recognizer != nil, !active else { throw ASRError.message("模型尚未就绪或上一轮尚未结束。") }
        audio.removeAll(keepingCapacity: true); active = true
    }
    func accept(_ samples: [Float]) throws -> EngineUpdate {
        try checkCancellation(cancellation)
        guard active else { throw ASRError.message("识别会话尚未开始。") }
        try appendOffline(samples, to: &audio)
        return EngineUpdate()
    }
    func finish() throws -> EngineUpdate {
        guard active, let recognizer else { return EngineUpdate() }
        defer { active = false; audio.removeAll(keepingCapacity: true) }
        try checkCancellation(cancellation)
        guard !audio.isEmpty else { return EngineUpdate() }
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw ASRError.message("无法创建 SenseVoice 会话。") }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, engineSampleRate, audio, Int32(audio.count))
        // The C API has no abort callback. The serial worker retains the handles
        // until this synchronous call returns, then discards cancelled output.
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        try checkCancellation(cancellation)
        guard let value = SherpaOnnxGetOfflineStreamResult(stream) else { throw ASRError.message("SenseVoice 未返回有效结果。") }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(value) }
        let text = value.pointee.text.map { String(cString: $0) } ?? ""
        return EngineUpdate(finalSegments: segments(text))
    }
    func unload() {
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }; recognizer = nil
        active = false; audio.removeAll()
    }
}

private final class WhisperEngine: NativeASREngine {
    private let id: ModelID
    private let cancellation: CancellationFlag
    private var context: OpaquePointer?
    private var options = RecognitionOptions()
    private var audio: [Float] = []
    private var active = false
    init(id: ModelID, cancellation: CancellationFlag) { self.id = id; self.cancellation = cancellation }
    deinit { unload() }
    func load(root: URL, options: RecognitionOptions) throws {
        guard !active else { throw ASRError.message("请先结束当前识别会话。") }
        unload()
        _ = try threadCount(options)
        guard options.language == "auto" || options.language.withCString({ whisper_lang_id($0) }) >= 0 else {
            throw ASRError.message("Whisper 不支持所选语言提示。")
        }
        let name = id == .whisperTiny ? "ggml-tiny.bin" : "ggml-base.bin"
        let path = try modelFile(root, name)
        var params = whisper_context_default_params()
        params.use_gpu = false; params.flash_attn = false
        guard let loaded = whisper_init_from_file_with_params(path, params) else { throw ASRError.message("Whisper 模型加载失败。") }
        guard whisper_is_multilingual(loaded) != 0 else {
            whisper_free(loaded)
            throw ASRError.message("此配置需要 Whisper 多语言版，不使用 .en 模型。")
        }
        context = loaded; self.options = options
    }
    func begin() throws {
        try checkCancellation(cancellation)
        guard context != nil, !active else { throw ASRError.message("模型尚未就绪或上一轮尚未结束。") }
        audio.removeAll(keepingCapacity: true); active = true
    }
    func accept(_ samples: [Float]) throws -> EngineUpdate {
        try checkCancellation(cancellation)
        guard active else { throw ASRError.message("识别会话尚未开始。") }
        try appendOffline(samples, to: &audio)
        return EngineUpdate()
    }
    func finish() throws -> EngineUpdate {
        guard active, let context else { return EngineUpdate() }
        defer { active = false; audio.removeAll(keepingCapacity: true) }
        try checkCancellation(cancellation)
        guard !audio.isEmpty else { return EngineUpdate() }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = try threadCount(options)
        params.translate = false; params.no_context = true
        params.print_realtime = false; params.print_progress = false
        params.print_timestamps = false; params.print_special = false
        params.temperature = 0; params.temperature_inc = 0
        params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        params.abort_callback = { raw in
            guard let raw else { return false }
            return Unmanaged<CancellationFlag>.fromOpaque(raw).takeUnretainedValue().isCancelled
        }
        let code = options.language.withCString { language in
            params.language = language
            return audio.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
        try checkCancellation(cancellation)
        guard code == 0 else { throw ASRError.message("Whisper 转写失败，错误码 \(code)。") }
        var output: [String] = []
        for index in 0..<whisper_full_n_segments(context) {
            guard let text = whisper_full_get_segment_text(context, index) else { continue }
            output.append(contentsOf: segments(String(cString: text)))
        }
        return EngineUpdate(finalSegments: output)
    }
    func unload() {
        if let context { whisper_free(context) }; context = nil
        active = false; audio.removeAll()
    }
}

private final class VoskEngine: NativeASREngine {
    private let cancellation: CancellationFlag
    private var model: OpaquePointer?
    private var recognizer: OpaquePointer?
    private var partial = ""
    init(cancellation: CancellationFlag) { self.cancellation = cancellation }
    deinit { unload() }
    func load(root: URL, options: RecognitionOptions) throws {
        guard recognizer == nil else { throw ASRError.message("请先结束当前识别会话。") }
        unload()
        _ = try modelFile(root, "am/final.mdl")
        _ = try modelFile(root, "conf/model.conf")
        vosk_set_log_level(-1)
        guard let created = vosk_model_new(root.path) else { throw ASRError.message("Vosk 模型加载失败，请检查完整模型目录。") }
        model = created
        // The existing Vosk iOS binary does not expose a per-recognizer thread
        // setting or dynamic bilingual selection; each directory is one model.
    }
    func begin() throws {
        try checkCancellation(cancellation)
        guard let model, recognizer == nil else { throw ASRError.message("模型尚未就绪或上一轮尚未结束。") }
        guard let created = vosk_recognizer_new(model, Float(engineSampleRate)) else { throw ASRError.message("无法创建 Vosk 会话。") }
        vosk_recognizer_set_words(created, 1)
        recognizer = created; partial = ""
    }
    func accept(_ samples: [Float]) throws -> EngineUpdate {
        try checkCancellation(cancellation)
        guard let recognizer else { throw ASRError.message("识别会话尚未开始。") }
        let audio = try validatedAudio(samples)
        guard !audio.isEmpty else { return EngineUpdate(partial: partial) }
        // Preserve the proven PCM16 path; Vosk float API has a different scale.
        let pcm = audio.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
        let code = pcm.withUnsafeBufferPointer { vosk_recognizer_accept_waveform_s(recognizer, $0.baseAddress, Int32($0.count)) }
        try checkCancellation(cancellation)
        guard code >= 0 else { throw ASRError.message("Vosk 音频处理失败。") }
        if code == 1 {
            let text = try result(vosk_recognizer_result(recognizer), field: "text")
            partial = ""
            return EngineUpdate(finalSegments: segments(text))
        }
        partial = try result(vosk_recognizer_partial_result(recognizer), field: "partial")
        return EngineUpdate(partial: partial)
    }
    func finish() throws -> EngineUpdate {
        guard let recognizer else { return EngineUpdate() }
        defer { vosk_recognizer_free(recognizer); self.recognizer = nil; partial = "" }
        try checkCancellation(cancellation)
        let text = try result(vosk_recognizer_final_result(recognizer), field: "text")
        try checkCancellation(cancellation)
        return EngineUpdate(finalSegments: segments(text))
    }
    private func result(_ pointer: UnsafePointer<CChar>?, field: String) throws -> String {
        guard let pointer, let data = String(cString: pointer).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[field] as? String else { throw ASRError.message("Vosk 返回了无效结果。") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func unload() {
        if let recognizer { vosk_recognizer_free(recognizer) }; recognizer = nil
        if let model { vosk_model_free(model) }; model = nil
        partial = ""
    }
}
