import Foundation
import AVFoundation
import Combine
import WatchWhisper

private final class WatchAudioCapture {
    let queue = DispatchQueue(label: "ASRtestWatch.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = false
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    var sampleCount: Int { samples.count } // only on queue
    func start() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let audio = AVAudioEngine()
        let format = audio.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let conversion = AVAudioConverter(from: mono, to: outputFormat) else {
            throw NSError(domain: "ASRtestWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "手表麦克风 PCM 格式不可用"])
        }
        inputFormat = mono; converter = conversion; samples.removeAll(keepingCapacity: false)
        engine = audio
        lock.lock(); accepting = true; lock.unlock()
        audio.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            self.lock.lock()
            guard self.accepting else { self.lock.unlock(); return }
            let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<count { for i in 0..<frames { mono[i] += channels[c][i] / Float(count) } }
            self.queue.async { self.append(mono) }
            self.lock.unlock()
        }
        audio.prepare()
        do { try audio.start() }
        catch { audio.inputNode.removeTap(onBus: 0); try? session.setActive(false); throw error }
    }
    private func append(_ mono: [Float]) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard samples.count < 30 * 16000, let inputFormat, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(mono.count) * 16000 / inputFormat.sampleRate) + 256)) else { return }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        var supplied = false; var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, flag in
            if supplied { flag.pointee = .noDataNow; return nil }
            supplied = true; flag.pointee = .haveData; return input
        }
        guard result != .error, let channel = output.floatChannelData else { return }
        let count = min(Int(output.frameLength), 30 * 16000 - samples.count)
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
    }
    func stop() -> [Float] {
        dispatchPrecondition(condition: .onQueue(queue))
        lock.lock(); accepting = false; lock.unlock()
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        if let converter {
            for _ in 0..<16 {
                let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
                var error: NSError?
                let state = converter.convert(to: output, error: &error) { _, flag in
                    flag.pointee = .endOfStream; return nil
                }
                if let channel = output.floatChannelData, output.frameLength > 0 {
                    let count = min(Int(output.frameLength), 30 * 16000 - samples.count)
                    if count > 0 { samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count)) }
                }
                if state == .endOfStream || state == .error || output.frameLength == 0 { break }
            }
        }
        converter = nil; inputFormat = nil
        let result = samples; samples = []
        return result
    }
}

@MainActor final class WatchASRController: ObservableObject {
    @Published private(set) var logs = WatchASRLogStore.all()
    @Published private(set) var status = "Whisper tiny 尚未完成实体手表验证"
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published private(set) var finalText = ""
    @Published private(set) var audioSeconds = 0.0
    @Published private(set) var inferenceMS = 0.0
    @Published var language = "auto"
    private let capture = WatchAudioCapture()
    let transfer = WatchASRTransfer()
    private var startedAt = Date()
    private var recordingID = UUID()
    private var smokeStarted = false
    func runSilentSmokeIfRequested() {
        #if DEBUG
        guard !smokeStarted, ProcessInfo.processInfo.arguments.contains("ASRTEST_WATCH_SMOKE") else { return }
        smokeStarted = true
        let capture = capture
        capture.queue.async { [weak self] in
            var log = WatchASRLog(modelName: "Whisper tiny · 模拟器静音自检", audioSeconds: 2)
            guard let path = Bundle.main.url(forResource: "ggml-tiny", withExtension: "bin"),
                  let context = path.path.withCString({ asr_watch_whisper_create($0) }) else {
                log.status = "自检失败"; log.error = "watchOS 模型加载失败"
                self?.finish(log); return
            }
            defer { asr_watch_whisper_destroy(context) }
            let pcm = [Float](repeating: 0, count: 32_000)
            var output = [CChar](repeating: 0, count: 32_768)
            let begin = ProcessInfo.processInfo.systemUptime
            let code = pcm.withUnsafeBufferPointer { buffer in
                "auto".withCString { language in
                    asr_watch_whisper_transcribe(context, buffer.baseAddress, Int32(pcm.count), 2,
                                                 language, &output, Int32(output.count))
                }
            }
            log.inferenceMS = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            log.endedAt = Date(); log.status = code == 0 ? "模拟器静音自检通过" : "自检失败"
            if code != 0 { log.error = "本地推理返回错误 \(code)" }
            self?.finish(log)
        }
        #endif
    }
    func start() {
        #if !DEBUG
        status = "尚未完成实体手表本地推理验证，当前模型不可用"
        return
        #endif
        guard !busy && !recording else { return }
        busy = true; finalText = ""; audioSeconds = 0; inferenceMS = 0; status = "正在申请麦克风权限"
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard allowed else { self.busy = false; self.status = "未获得麦克风权限"; return }
                let capture = self.capture
                capture.queue.async { [weak self] in
                    let outcome = Result { try capture.start() }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch outcome {
                        case .success:
                            self.startedAt = Date(); self.recording = true; self.busy = false
                            self.recordingID = UUID()
                            let id = self.recordingID
                            self.status = "录音中；停止后在手表本地转写（最多 30 秒）"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                                guard let self, self.recording, self.recordingID == id else { return }
                                self.stop()
                            }
                        case .failure(let error): self.busy = false; self.status = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
    func stop() {
        guard recording && !busy else { return }
        recording = false; busy = true; status = "手表本地转写中"
        let capture = capture, started = startedAt, language = language
        capture.queue.async { [weak self] in
            let pcm = capture.stop()
            let duration = Double(pcm.count) / 16000
            var log = WatchASRLog(startedAt: started, endedAt: Date(), language: language,
                                  audioSeconds: duration)
            guard let path = Bundle.main.url(forResource: "ggml-tiny", withExtension: "bin") else {
                log.status = "失败"; log.error = "Watch App 未包含 Whisper tiny 模型"
                self?.finish(log); return
            }
            guard !pcm.isEmpty else {
                log.status = "失败"; log.error = "未采集到音频"
                self?.finish(log); return
            }
            let loadStarted = ProcessInfo.processInfo.systemUptime
            guard let context = path.path.withCString({ asr_watch_whisper_create($0) }) else {
                log.status = "失败"; log.error = "手表无法加载 Whisper tiny；请检查可用内存"
                self?.finish(log); return
            }
            defer { asr_watch_whisper_destroy(context) }
            log.modelLoadMS = (ProcessInfo.processInfo.systemUptime - loadStarted) * 1000
            let begin = ProcessInfo.processInfo.systemUptime
            var output = [CChar](repeating: 0, count: 32_768)
            let result = pcm.withUnsafeBufferPointer { buffer in
                language.withCString { code in
                    asr_watch_whisper_transcribe(context, buffer.baseAddress, Int32(pcm.count), 2, code, &output, Int32(output.count))
                }
            }
            log.inferenceMS = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            if result == 0 { log.finalText = String(cString: output); log.status = "已完成" }
            else { log.status = "失败"; log.error = "本地推理返回错误 \(result)" }
            log.endedAt = Date()
            self?.finish(log)
        }
    }
    nonisolated private func finish(_ log: WatchASRLog) {
        let writeError: String?
        do { try WatchASRLogStore.save(log); writeError = nil }
        catch { writeError = "手表日志保存失败：\(error.localizedDescription)" }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.busy = false; self.finalText = log.finalText
            self.audioSeconds = log.audioSeconds; self.inferenceMS = log.inferenceMS
            self.status = writeError ?? log.error ?? "转写完成（手表本地）"
            self.logs = WatchASRLogStore.all()
            #if DEBUG
            if writeError == nil, ProcessInfo.processInfo.arguments.contains("ASRTEST_WATCH_EXPORT_SMOKE") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    self.transfer.export(self.logs)
                }
            }
            #endif
        }
    }
}
