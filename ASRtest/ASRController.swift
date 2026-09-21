import Foundation
import AVFoundation
import Combine
import UIKit

/// Synchronizes tap submission with the stop barrier; bounds audio waiting for decode.
private final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = false
    private var pending = 0
    func open() { lock.lock(); accepting = true; lock.unlock() }
    func close() { lock.lock(); accepting = false; lock.unlock() }
    func submit(buffer: AVAudioPCMBuffer, queue: DispatchQueue,
                consume: @escaping @Sendable ([Float]) -> Void, failed: @escaping @Sendable () -> Void) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard pending < ValidationConfig.maxPendingBuffers, let channels = buffer.floatChannelData else {
            accepting = false; lock.unlock(); failed(); return
        }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { lock.unlock(); return }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
            for index in 0..<frames { mono[index] += channels[channel][index] / Float(count) }
        }
        pending += 1
        let copied = mono
        // Enqueue before releasing the lock, so close() creates a reliable submission barrier.
        queue.async { [self] in
            consume(copied)
            lock.lock(); pending -= 1; lock.unlock()
        }
        lock.unlock()
    }
}


/// Cancellation is shared by UI and capture queue, including the final gate-open step.
private final class CaptureTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func ifActive(_ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        action(); return true
    }
}

private struct AudioInput: Identifiable, Sendable {
    let id: String
    let name: String
}

/// All session mutations and engine operations run on this one background queue.
/// Synchronous AVAudioSession calls never execute on the main thread.
private final class CapturePipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "ASRtest.capture-and-recognition", qos: .userInitiated)
    let gate = AudioGate()
    let cancellation = CancellationFlag()
    lazy var backend = RecognitionBackend(queue: queue, cancellation: cancellation)
    private var engine: AVAudioEngine?
    private var tapInstalled = false

    private func checkQueue() { dispatchPrecondition(condition: .onQueue(queue)) }
    private func configure() throws {
        checkQueue()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(Double(ValidationConfig.sampleRate))
    }
    private func inputs() -> [AudioInput] {
        checkQueue()
        return (AVAudioSession.sharedInstance().availableInputs ?? []).map {
            AudioInput(id: $0.uid, name: "\($0.portName) · \($0.portType.rawValue)")
        }
    }
    func refresh() throws -> [AudioInput] {
        checkQueue()
        do {
            try configure()
            try AVAudioSession.sharedInstance().setActive(true)
            let value = inputs()
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return value
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }
    func start(selected: String, device: String, ticket: CaptureTicket,
               update: @escaping @Sendable (RecognitionSnapshot) -> Void,
               failed: @escaping @Sendable (String) -> Void) throws -> (String, [AudioInput])? {
        checkQueue()
        guard ticket.ifActive({}) else { return nil }
        try configure()
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)
        guard ticket.ifActive({}) else { return nil } // queued stop owns cleanup
        let available = inputs()
        if selected.isEmpty {
            try session.setPreferredInput(nil)
        } else {
            guard let port = session.availableInputs?.first(where: { $0.uid == selected }) else {
                throw ASRError.message("所选麦克风已不可用，请刷新并重新选择。")
            }
            try session.setPreferredInput(port)
            guard session.currentRoute.inputs.contains(where: { $0.uid == selected }) else {
                throw ASRError.message("系统未切换到所选麦克风，请重新选择后开始。")
            }
        }
        let actual = session.currentRoute.inputs.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
        let uid = session.currentRoute.inputs.map(\.uid).joined(separator: ",")
        let audio = AVAudioEngine()
        engine = audio
        let format = audio.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw ASRError.message("当前音频输入格式不可用，请重新连接麦克风。")
        }
        backend.onUpdate = update
        try backend.begin(rate: format.sampleRate, device: device, input: actual, inputUID: uid)
        guard ticket.ifActive({}) else { return nil }
        let gate = gate, queue = queue, backend = backend
        audio.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            gate.submit(buffer: buffer, queue: queue, consume: { samples in
                do { try backend.consume(samples) }
                catch { gate.close(); failed(error.localizedDescription) }
            }, failed: {
                failed("音频处理积压，已结束本轮；请记录问题并调整配置。")
            })
        }
        tapInstalled = true
        audio.prepare()
        try audio.start()
        backend.markCaptureStart(ProcessInfo.processInfo.systemUptime)
        guard ticket.ifActive({ gate.open() }) else { return nil }
        return (actual, available)
    }
    func stop(reason: String, failure: String?, stopTime: Double = 0) -> RecognitionSnapshot {
        checkQueue()
        gate.close()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop(); engine = nil
        var message = failure
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { message = message ?? "音频会话关闭失败：\(error.localizedDescription)" }
        return backend.finish(reason: reason, failure: message, stopTime: stopTime)
    }
}

@MainActor
final class ASRController: ObservableObject {
    enum Phase { case loading, ready, authorizing, preparing, recording, stopping, failed }
    struct InputSource: Identifiable { let id: String; let name: String }
    @Published private(set) var selectedModel: ModelID = .zipformer
    @Published private(set) var selectedLanguage = "auto"
    @Published private(set) var options = RecognitionOptions()
    @Published private(set) var availableModels: Set<ModelID> = []
    @Published private(set) var records: [SessionRecord] = []
    @Published private(set) var historyError: String?
    private var hasChosenInput = false
    var canConfigureModel: Bool { (phase == .ready || phase == .failed) && !refreshingInputs && !interrupted }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var status = "正在加载本地模型"
    @Published private(set) var loadMS = 0.0
    @Published private(set) var result = RecognitionSnapshot()
    @Published private(set) var inputs: [InputSource] = []
    @Published private(set) var selectedInputID = ""
    @Published private(set) var actualInput = "尚未开始采集"
    @Published private(set) var inputMessage = "输入设备会自动更新，也可点击刷新。"
    @Published private(set) var refreshingInputs = false
    private let pipeline = CapturePipeline()
    private var ticket: CaptureTicket?
    private var token: UUID?
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var interrupted = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var canStart: Bool { phase == .ready && !refreshingInputs && !interrupted }
    var canStop: Bool { phase == .recording || phase == .preparing }

    init() {
        availableModels = Set(ModelID.allCases.filter { ModelStore().installedURL($0) != nil })
        reloadHistory()
        let initial = ModelID(rawValue: UserDefaults.standard.string(forKey: "selectedModel") ?? "") ?? .zipformer
        selectedModel = initial
        if let data = UserDefaults.standard.data(forKey: "options"), let saved = try? JSONDecoder().decode(RecognitionOptions.self, from: data) { options = saved }
        if !initial.languageChoices.contains(where: { $0.0 == options.language }) { options.language = "auto" }
        selectedLanguage = options.language
        let settings = options
        let pipeline = pipeline
        pipeline.queue.async { [weak self] in
            do {
                let time = try pipeline.backend.load(model: initial, options: settings)
                Task { @MainActor [weak self] in
                    self?.loadMS = time; self?.phase = .ready; self?.status = "模型就绪"
                    self?.refreshInputsAutomatically()
                }
            } catch {
                Task { @MainActor [weak self] in self?.phase = .failed; self?.status = error.localizedDescription }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true
                    self.stop(reason: "audio_interruption")
                } else if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    self.interrupted = false
                    self.refreshInputsAutomatically()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // Ignore notifications caused by our own category/activation/preferred-input changes.
            if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                Task { @MainActor [weak self] in
                    self?.stop(reason: "audio_route_change")
                    self?.refreshInputsAutomatically()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.interrupted = false
                self?.stop(reason: "audio_services_reset")
                self?.refreshInputsAutomatically()
            }
        })
    }
    deinit {
        refreshTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        // Cleanup stays off the main thread even if the view is released during capture.
        ticket?.cancel(); pipeline.cancellation.cancel(); pipeline.gate.close()
        let pipeline = pipeline
        pipeline.queue.async { _ = pipeline.stop(reason: "controller_released", failure: nil) }
    }
    private func applyInputs(_ values: [AudioInput]) {
        inputs = values.map { InputSource(id: $0.id, name: $0.name) }
        if !hasChosenInput, let builtIn = values.first(where: { $0.name.contains(AVAudioSession.Port.builtInMic.rawValue) }) { selectedInputID = builtIn.id; hasChosenInput = true }
        inputMessage = !selectedInputID.isEmpty && !inputs.contains(where: { $0.id == selectedInputID })
            ? "所选设备已断开，请重新选择或使用系统默认。"
            : "设备列表自动更新，也可手动刷新。"
    }
    func selectInput(_ id: String) {
        guard canStart else { return }
        selectedInputID = id; hasChosenInput = true; inputMessage = "将在下一轮开始时使用所选输入源。"
    }
    func refreshInputsAutomatically() {
        pendingRefresh = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.pendingRefresh, self.canStart,
                  UIApplication.shared.applicationState == .active else { return }
            self.refreshInputs()
        }
    }
    func refreshInputs() {
        guard canStart, UIApplication.shared.applicationState == .active else { return }
        refreshTask?.cancel(); pendingRefresh = false
        refreshingInputs = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted, self.phase == .ready, !self.interrupted,
                      UIApplication.shared.applicationState == .active else {
                    self.refreshingInputs = false
                    if !granted { self.inputMessage = "请在系统设置中允许麦克风访问。" }
                    return
                }
                let pipeline = self.pipeline
                pipeline.queue.async { [weak self] in
                    let outcome = Result { try pipeline.refresh() }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.refreshingInputs = false
                        switch outcome {
                        case .success(let values): self.applyInputs(values)
                        case .failure(let error): self.inputMessage = error.localizedDescription
                        }
                        if self.pendingRefresh { self.refreshInputsAutomatically() }
                    }
                }
            }
        }
    }
    func start() {
        guard canStart, UIApplication.shared.applicationState == .active else { return }
        refreshTask?.cancel(); pendingRefresh = false
        pipeline.cancellation.reset()
        let id = UUID(); token = id
        phase = .authorizing; status = "等待麦克风授权"
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self, self.token == id, self.phase == .authorizing else { return }
                guard granted else {
                    self.phase = .ready; self.token = nil
                    self.status = "未获得麦克风权限，请在系统设置中允许访问。"; return
                }
                guard UIApplication.shared.applicationState == .active, !self.interrupted else {
                    self.stop(reason: "app_inactive"); return
                }
                self.prepare(id: id)
            }
        }
    }
    func selectModel(_ model: ModelID) {
        guard canConfigureModel else { return }
        refreshTask?.cancel(); pendingRefresh = false
        selectedModel = model
        if !model.languageChoices.contains(where: { $0.0 == options.language }) { options.language = "auto" }
        selectedLanguage = options.language
        UserDefaults.standard.set(model.rawValue, forKey: "selectedModel")
        loadSelectedModel()
    }
    private func loadSelectedModel() {
        phase = .loading; status = "正在校验并加载 " + selectedModel.title
        loadMS = 0; result = RecognitionSnapshot()
        let pipeline = pipeline, model = selectedModel, settings = options
        pipeline.queue.async { [weak self] in
            let outcome = Result { try pipeline.backend.load(model: model, options: settings) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.availableModels = Set(ModelID.allCases.filter { ModelStore().installedURL($0) != nil })
                switch outcome {
                case .success(let elapsed):
                    self.loadMS = elapsed; self.phase = .ready; self.status = "模型就绪"
                    self.refreshInputsAutomatically()
                case .failure(let error): self.phase = .failed; self.status = error.localizedDescription
                }
            }
        }
    }
    func selectLanguage(_ value: String) {
        guard canConfigureModel else { return }
        options.language = value; selectedLanguage = value; saveOptions(); loadSelectedModel()
    }
    func setThreads(_ value: Int) {
        guard canConfigureModel else { return }
        options.threads = max(1, min(4, value)); saveOptions(); loadSelectedModel()
    }
    func setITN(_ value: Bool) {
        guard canConfigureModel else { return }
        options.useITN = value; saveOptions(); loadSelectedModel()
    }
    private func saveOptions() { if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options") } }
    func reloadHistory() {
        Task { [weak self] in
            let values = await Task.detached(priority: .utility) { SessionStore.all() }.value
            self?.records = values
        }
    }
    func deleteRecord(_ value: SessionRecord) {
        guard phase != .recording && phase != .stopping && phase != .preparing else { return }
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do { try SessionStore.delete(value); return nil } catch { return error.localizedDescription }
            }.value
            self?.historyError = failure; self?.reloadHistory()
        }
    }
    private func prepare(id: UUID) {
        phase = .preparing; status = "正在准备录音"; result = RecognitionSnapshot()
        actualInput = "正在连接输入设备"
        let ticket = CaptureTicket(); self.ticket = ticket
        let pipeline = pipeline, selected = selectedInputID
        let modelID = selectedModel
        let device = "\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)"
        pipeline.queue.async { [weak self] in
            do {
                let value = try pipeline.start(selected: selected, device: device, ticket: ticket, update: { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.token == id else { return }
                        self.result = value
                        if value.audioSeconds >= modelID.maximumSeconds && self.phase == .recording {
                            self.stop(reason: "duration_limit")
                        }
                    }
                }, failed: { [weak self] message in
                    Task { @MainActor [weak self] in self?.fail(message, id: id) }
                })
                Task { @MainActor [weak self] in
                    guard let self, self.token == id, self.phase == .preparing, let value else { return }
                    self.actualInput = value.0; self.applyInputs(value.1)
                    self.phase = .recording; self.status = modelID.streaming ? "正在录音并识别" : "正在录音，停止后转写"
                }
            } catch {
                Task { @MainActor [weak self] in self?.fail(error.localizedDescription, id: id) }
            }
        }
    }
    private func fail(_ message: String, id: UUID) {
        guard token == id, phase != .stopping else { return }
        stop(reason: "error", failure: message)
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    func stop(reason: String = "user_stop", failure: String? = nil) {
        if ["user_cancel", "app_background", "app_inactive", "audio_route_change", "audio_interruption", "audio_services_reset", "background_expired"].contains(reason) {
            pipeline.cancellation.cancel()
            if phase == .stopping { status = "正在取消转写"; return }
        }
        if phase == .authorizing {
            token = nil; phase = .ready; status = "已取消，点击开始可重新录音"; return
        }
        guard canStop else { return }
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        phase = .stopping; status = selectedModel.streaming ? "正在结束本轮识别" : "正在本地转写"
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish ASR session") { [weak self] in
            Task { @MainActor [weak self] in self?.pipeline.cancellation.cancel(); self?.endBackgroundTask() }
        }
        ticket?.cancel()
        // Gate closure is immediate. Queued audio precedes stop, and late callbacks are rejected.
        pipeline.gate.close()
        let pipeline = pipeline, id = token
        pipeline.queue.async { [weak self] in
            let value = pipeline.stop(reason: reason, failure: failure, stopTime: stoppedAt)
            Task { @MainActor [weak self] in
                guard let self, self.token == id else { return }
                self.endBackgroundTask()
                self.result = value; self.reloadHistory(); self.phase = .ready; self.token = nil; self.ticket = nil
                self.status = value.error ?? failure ?? (reason == "audio_route_change"
                    ? "输入设备发生变化，本轮已结束；请确认输入源后重新开始。" : "本轮已完成")
                self.refreshInputsAutomatically()
            }
        }
    }
}
