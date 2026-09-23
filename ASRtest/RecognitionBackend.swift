import Foundation
import AVFoundation

struct RecognitionSnapshot: Sendable {
    var partial = ""
    var segments: [String] = []
    var audioSeconds = 0.0
    var acceptMS = 0.0
    var decodeMS = 0.0
    var firstMS: Double?
    var stopWaitMS = 0.0
    var logURL: URL?
    var error: String?
    var text: String { (segments + (partial.isEmpty ? [] : [partial])).joined(separator: "\n") }
}
enum ValidationConfig {
    static let sampleRate = 16_000
    static let maxPendingBuffers = 20
}
final class RecognitionBackend: @unchecked Sendable {
    private let worker: DispatchQueue
    let cancellation: CancellationFlag
    private var engine: (any NativeASREngine)?
    private(set) var selectedModel: ModelID = .zipformer
    private(set) var options = RecognitionOptions()
    private var active = false
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var snapshot = RecognitionSnapshot()
    private var record: SessionRecord?
    var currentRecordID: String? { checkQueue(); return active ? record?.id : nil }
    private var writer: FileHandle?
    private var startTime = 0.0
    private var loadMS = 0.0
    private var lastPublish = 0.0
    private var lastSave = 0.0
    private var acceptedFrames = 0
    private var lastPartial = ""
    var onUpdate: (@Sendable (RecognitionSnapshot) -> Void)?
    init(queue: DispatchQueue, cancellation: CancellationFlag) { worker = queue; self.cancellation = cancellation }
    private func checkQueue() { dispatchPrecondition(condition: .onQueue(worker)) }
    deinit { engine?.unload(); try? writer?.close() }
    func load(model: ModelID, options: RecognitionOptions) throws -> Double {
        checkQueue()
        guard !active else { throw ASRError.message("请先结束本轮测试。") }
        engine?.unload(); engine = nil
        selectedModel = model; self.options = options
        cancellation.reset()
        let store = ModelStore()
        guard let root = store.installedURL(model) else { throw ASRError.message("内置模型文件不完整，请重新编译并安装完整 App。") }
        try store.validate(model)
        let next: any NativeASREngine
        if model == .nano {
            #if canImport(NanoRuntime)
            next = NanoEngine(cancellation: cancellation)
            #else
            throw ASRError.message("Fun-ASR-Nano 本地运行库尚未接入此构建。")
            #endif
        } else { next = try makeStandardEngine(id: model, cancellation: cancellation) }
        let started = ProcessInfo.processInfo.systemUptime
        do { try next.load(root: root, options: options) }
        catch { next.unload(); throw error }
        engine = next
        loadMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return loadMS
    }
    func unload() { checkQueue(); guard !active else { return }; engine?.unload(); engine = nil }
    @discardableResult func begin(rate: Double, device: String, input: String, inputUID: String, batch: BatchRecordLink? = nil) throws -> String {
        checkQueue()
        guard let engine, !active else { throw ASRError.message("识别引擎尚未就绪。") }
        snapshot = RecognitionSnapshot(); acceptedFrames = 0
        lastPartial = ""; startTime = 0; lastPublish = 0; lastSave = 0
        let asset = AssetManifest.current.asset(selectedModel)
        record = SessionRecord(modelID: selectedModel, modelName: selectedModel.title, framework: selectedModel.framework,
            options: options, device: device, input: input, inputUID: inputUID, hardwareSampleRate: rate,
            modelRevision: asset?.revision, modelFiles: asset?.files ?? [], loadMS: loadMS)
        record?.batch = batch
        active = true
        if let record {
            try SessionStore.save(record)
            let file = SessionStore.url(record.id, extension: "jsonl")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw ASRError.message("无法创建本轮日志。") }
            writer = try FileHandle(forWritingTo: file); snapshot.logURL = SessionStore.url(record.id)
            try log("config", ["model_id": selectedModel.rawValue, "framework": selectedModel.framework,
                "language": options.language, "threads": [.voskChinese, .voskEnglish].contains(selectedModel) ? NSNull() : options.threads as Any, "use_itn": selectedModel == .senseVoice ? options.useITN as Any : NSNull(),
                "input": input, "input_uid": inputUID, "hardware_sample_rate_hz": rate,
                "recognizer_sample_rate_hz": 16000, "mode": selectedModel.streaming ? "streaming" : "record_then_transcribe",
                "raw_audio_saved": false, "max_audio_seconds": selectedModel.maximumSeconds])
        }
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        guard let inputFormat, let conversion = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw ASRError.message("无法转换输入音频。") }
        converter = conversion
        try engine.begin()
        return record!.id
    }
    func markCaptureStart(_ time: Double) { checkQueue(); startTime = time }
    func consume(_ mono: [Float]) throws {
        checkQueue()
        guard active, !mono.isEmpty, !cancellation.isCancelled, let inputFormat, let converter else { return }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(mono.count) * 16000 / inputFormat.sampleRate) + 256)) else { throw ASRError.message("音频缓冲创建失败。") }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, flag in
            if supplied { flag.pointee = .noDataNow; return nil }
            supplied = true; flag.pointee = .haveData; return input
        }
        if status == .error { throw error ?? ASRError.message("音频转换失败。") as NSError }
        try accept(output)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPublish > 0.15 || snapshot.audioSeconds >= selectedModel.maximumSeconds { onUpdate?(snapshot); lastPublish = now }
        if now - lastSave > 1 { try saveRecord(state: "未完成"); lastSave = now }
    }
    private func accept(_ buffer: AVAudioPCMBuffer) throws {
        let frames = min(Int(buffer.frameLength), max(0, Int(selectedModel.maximumSeconds * 16000) - acceptedFrames))
        guard frames > 0, let data = buffer.floatChannelData, let engine else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: frames))
        acceptedFrames += frames; snapshot.audioSeconds = Double(acceptedFrames) / 16000
        let update: EngineUpdate
        do {
            let started = ProcessInfo.processInfo.systemUptime
            defer {
                if selectedModel.streaming { snapshot.acceptMS += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
            }
            update = try engine.accept(samples)
        }
        try apply(update)
    }
    private func apply(_ update: EngineUpdate) throws {
        for segment in update.finalSegments where !segment.isEmpty {
            snapshot.segments.append(segment); try log("segment", ["text": segment])
        }
        snapshot.partial = update.partial
        if snapshot.firstMS == nil, (!update.partial.isEmpty || !update.finalSegments.isEmpty), startTime > 0 {
            snapshot.firstMS = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
        }
        if lastPartial != update.partial { try log("partial", ["text": update.partial]); lastPartial = update.partial }
    }
    func finish(reason: String, failure: String?, stopTime: Double = 0) -> RecognitionSnapshot {
        checkQueue()
        guard active else { return RecognitionSnapshot(error: failure) }
        snapshot.error = failure
        defer { active = false; converter = nil; inputFormat = nil; try? writer?.close(); writer = nil }
        var failedDuringDrain = false
        let shouldTranscribe = selectedModel.streaming || ["user_stop", "duration_limit", "file_test"].contains(reason)
        if failure != nil || !shouldTranscribe { cancellation.cancel() }
        do {
            if !cancellation.isCancelled, let converter {
                for _ in 0..<16 {
                    let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
                    var error: NSError?
                    let state = converter.convert(to: output, error: &error) { _, flag in flag.pointee = .endOfStream; return nil }
                    if state == .error { throw error ?? ASRError.message("结束音频转换失败。") as NSError }
                    try accept(output)
                    if state == .endOfStream || output.frameLength == 0 { break }
                }
            }
        } catch {
            snapshot.error = snapshot.error ?? error.localizedDescription
            failedDuringDrain = true; cancellation.cancel()
        }
        // finish always runs once: adapters also release native session state on cancellation.
        if let engine {
            var update: EngineUpdate?
            do {
                let started = ProcessInfo.processInfo.systemUptime
                defer { snapshot.decodeMS += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                update = try engine.finish()
            } catch {
                snapshot.error = snapshot.error ?? error.localizedDescription
            }
            if let update, !cancellation.isCancelled {
                do { try apply(update) }
                catch { snapshot.error = snapshot.error ?? error.localizedDescription }
            }
        }
        if cancellation.isCancelled { snapshot.error = snapshot.error ?? "本轮已取消。" }
        snapshot.stopWaitMS = stopTime > 0 ? max(0, (ProcessInfo.processInfo.systemUptime - stopTime) * 1000) : 0
        let state = (failure != nil || failedDuringDrain) ? "异常" : (cancellation.isCancelled ? "已取消" : (snapshot.error == nil ? "已完成" : "异常"))
        do {
            record?.reason = reason
            try saveRecord(state: state)
            try log("summary", ["state": state, "reason": reason, "text": snapshot.text,
                "audio_seconds": snapshot.audioSeconds, "native_call_ms": snapshot.acceptMS + snapshot.decodeMS,
                "stop_wait_ms": snapshot.stopWaitMS, "error": snapshot.error as Any? ?? NSNull()])
            try writer?.synchronize()
        } catch { snapshot.error = "保存记录失败：\(error.localizedDescription)" }
        return snapshot
    }
    private func saveRecord(state: String) throws {
        guard var value = record else { return }
        value.text = snapshot.text; value.audioSeconds = snapshot.audioSeconds
        value.inferenceMS = snapshot.acceptMS + snapshot.decodeMS; value.firstOutputMS = snapshot.firstMS
        value.stopWaitMS = snapshot.stopWaitMS; value.state = state; value.error = snapshot.error
        try SessionStore.save(value); record = value
    }
    private func log(_ event: String, _ fields: [String: Any]) throws {
        var row = fields; row["event"] = event; row["session_id"] = record?.id ?? ""
        row["timestamp_unix_ms"] = Int(Date().timeIntervalSince1970 * 1000)
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
        try writer?.write(contentsOf: data)
    }
}
