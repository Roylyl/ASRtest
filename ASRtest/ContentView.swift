import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            TestView().tabItem { Label("测试", systemImage: "waveform").accessibilityIdentifier("tab.test") }
            LibraryView().tabItem { Label("日志及模型", systemImage: "list.bullet.rectangle").accessibilityIdentifier("tab.library") }
            SettingsView().tabItem { Label("设置", systemImage: "slider.horizontal.3").accessibilityIdentifier("tab.settings") }
        }.tint(.blue).asrTabBehavior()
    }
}

private struct TestView: View {
    @EnvironmentObject private var model: ASRController
    @State private var choosingModel = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 24) {
                                VStack(alignment: .leading, spacing: 18) {
                                    modelHeader; inputInfo; recordingControls; BatchPanel()
                                }.frame(maxWidth: 390)
                                VStack(alignment: .leading, spacing: 18) { resultsColumn }
                                    .frame(maxWidth: 620)
                            }.frame(maxWidth: 1050)
                        } else {
                            VStack(alignment: .leading, spacing: 20) {
                                modelHeader; resultsColumn; inputInfo; BatchPanel()
                            }.frame(maxWidth: 720)
                        }
                    }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                }.asrScrollEdges().background(ASRBackdrop())
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if geometry.size.width < 760 { recordingControls }
                    }
            }
                .navigationTitle("ASRtest")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { ModelDetail(id: model.selectedModel) } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("当前模型信息")
                    }
                }
                .sheet(isPresented: $choosingModel) { ModelSelectionView() }
        }
    }
    private var modelHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelSelectorButton { choosingModel = true }.accessibilityIdentifier("test.modelSelector")
            HStack(alignment: .top, spacing: 8) {
                if [.loading, .authorizing, .preparing, .batch].contains(model.phase) {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(model.phase == .recording ? .red : (model.phase == .failed ? .orange : .green))
                        .frame(width: 7, height: 7).padding(.top, 5).accessibilityHidden(true)
                }
                Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("test.status")
                Spacer(minLength: 0)
            }.padding(.horizontal, 4)
        }
    }
    private var resultsColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            transcript; metrics
            if let error = model.result.error {
                Label { Text(error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.subheadline).foregroundStyle(.red).padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading).asrContentSurface()
            }
            if let file = model.result.logURL, !model.canStop, model.phase != .stopping && model.phase != .batch {
                ShareLink(item: file) { Label("导出本轮记录", systemImage: "doc.badge.arrow.up").frame(maxWidth: .infinity) }
                    .asrGlassButton().controlSize(.large)
            }
            Text("本轮上限 \(Int(model.selectedModel.maximumSeconds)) 秒。识别调用耗时不含录音等待与重采样，统计说明见记录详情。")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("识别结果", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Text(model.selectedModel.streaming ? "流式" : "录音后转写")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if model.result.text.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.phase == .recording ? "waveform" : "mic")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(.blue)
                    Text(model.phase == .recording ? (model.selectedModel.streaming ? "正在聆听" : "正在录音") : "准备开始")
                        .font(.headline)
                    Text(model.selectedModel.streaming ? "开始录音后，识别文字会显示在这里" : "停止录音后，在本机完成转写")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: 100).padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.result.segments.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.body).lineSpacing(6).textSelection(.enabled)
                    }
                    if !model.result.partial.isEmpty {
                        Text(model.result.partial).font(.body).lineSpacing(6).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
            }
            HStack {
                Label("本地识别", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.result.text.isEmpty {
                    ShareLink(item: model.result.text) { Image(systemName: "square.and.arrow.up") }
                        .asrGlassButton().accessibilityLabel("分享识别文字")
                }
            }
        }.padding(20).asrContentSurface().accessibilityIdentifier("test.transcript")
    }
    private var metrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本轮信息").font(.headline).padding(.horizontal, 4)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricTile(title: "音频时长", value: seconds(model.result.audioSeconds), symbol: "waveform")
                MetricTile(title: "识别调用耗时", value: milliseconds(model.result.acceptMS + model.result.decodeMS), symbol: "cpu")
                MetricTile(title: "停止后等待", value: milliseconds(model.result.stopWaitMS), symbol: "clock")
                MetricTile(title: "模型加载", value: milliseconds(model.loadMS), symbol: "square.stack.3d.up")
            }
        }
    }
    private var inputInfo: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mic.fill").foregroundStyle(.blue).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text("实际输入").font(.caption).foregroundStyle(.secondary)
                Text(inputDisplayName(model.actualInput)).font(.subheadline).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).asrContentSurface()
    }
    private var recordingControls: some View {
        ASRGlassGroup {
            HStack(spacing: 12) {
                if model.phase == .stopping {
                    HStack(spacing: 9) { ProgressView(); Text("正在完成识别").font(.subheadline) }
                        .frame(maxWidth: .infinity, minHeight: 52).asrGlass()
                    Button { model.stop(reason: "user_cancel") } label: { Label("取消", systemImage: "xmark").frame(minHeight: 30) }
                        .asrGlassButton().controlSize(.large).accessibilityIdentifier("test.cancel")
                } else {
                    Button { model.start() } label: {
                        Label("开始录音", systemImage: "mic.fill").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 30)
                    }.asrGlassButton(prominent: true).controlSize(.large).buttonBorderShape(.capsule)
                        .disabled(!model.canStart).accessibilityIdentifier("test.start")
                    Button { model.stop() } label: {
                        Label("停止", systemImage: "stop.fill").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 30)
                    }.tint(.red).asrGlassButton(prominent: model.canStop).controlSize(.large).buttonBorderShape(.capsule)
                        .disabled(!model.canStop).accessibilityIdentifier("test.stop")
                }
            }
        }.frame(maxWidth: 720).padding(.horizontal, 20).padding(.vertical, 10).frame(maxWidth: .infinity)
    }
}

private struct BatchPanel: View {
    @EnvironmentObject private var model: ASRController
    @State private var importing = false
    private let wav = UTType(filenameExtension: "wav") ?? .audio
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("批量 WAV 测试", systemImage: "square.stack.3d.up").font(.headline)
            Text(model.batchMessage).font(.subheadline).foregroundStyle(.secondary)
            if let group = model.activeBatch, model.phase == .batch {
                ProgressView(value: Double(group.finishedCount), total: Double(max(1, group.items.count)))
                Text("\(group.finishedCount)/\(group.items.count) · \(group.model.title)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let selection = model.batchSelection {
                Text("已暂存 \(selection.files.count) 个文件 · 本轮固定 \(model.selectedModel.title)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { importing = true } label: { Label("选择 WAV", systemImage: "folder") }
                    .disabled(!model.canConfigureModel || model.batchImporting)
                Spacer()
                if model.phase == .batch {
                    Button("停止批量测试", role: .destructive) { model.stopBatch() }
                } else {
                    Button("开始本轮") { model.startBatch() }.disabled(!model.canBatch)
                }
            }.buttonStyle(.bordered)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).asrContentSurface()
            .fileImporter(isPresented: $importing, allowedContentTypes: [wav], allowsMultipleSelection: true) { outcome in
                switch outcome {
                case .success(let urls): model.importBatch(urls)
                case .failure(let error): model.reportBatchImportError(error.localizedDescription)
                }
            }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                .minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).asrContentSurface()
            .accessibilityElement(children: .combine)
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var model: ASRController
    @State private var mode = 0
    @State private var pendingDelete: SessionRecord?
    @State private var pendingBatchDelete: BatchLogGroup?
    @State private var pendingWatchDelete: WatchASRLog?
    @State private var confirmingClear = false
    var body: some View {
        NavigationStack {
            List {
                if mode == 0 {
                    if let error = model.historyError { Text(error).font(.footnote).foregroundStyle(.red) }
                    if model.records.isEmpty && model.batchGroups.isEmpty {
                        ContentUnavailableView("暂无测试记录", systemImage: "waveform.path", description: Text("完成一轮测试后，文字与运行信息会自动保存在这里。"))
                            .listRowBackground(Color.clear)
                    }
                    if !model.batchGroups.isEmpty {
                        Section("批量测试") {
                            ForEach(model.batchGroups) { group in
                                NavigationLink { BatchDetail(group: group) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(group.name).font(.headline)
                                        Text("\(group.status) · \(group.completedCount)/\(group.items.count) 完成 · \(group.failedCount) 失败")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 5)
                                }.swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("删除", role: .destructive) { pendingBatchDelete = group }.disabled(!model.canConfigureModel) }
                            }
                        }
                    }
                    Section("单次测试") { ForEach(model.records.filter { $0.batch == nil }) { record in
                        NavigationLink { RecordDetail(record: record) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(alignment: .top) {
                                    Text(record.modelName).font(.headline)
                                    Spacer(minLength: 8)
                                    Text(record.state).font(.caption).foregroundStyle(record.state == "异常" ? .red : .secondary)
                                }
                                Text(record.text.isEmpty ? (record.error ?? "无识别文字") : record.text).lineLimit(3).font(.subheadline)
                                HStack {
                                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text(seconds(record.audioSeconds)).monospacedDigit()
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 7)
                        }.swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("删除", role: .destructive) { pendingDelete = record }.disabled(!model.canConfigureModel) }
                    } }
                    Section {
                        Button { model.exportAllLogs() } label: { Label("导出全部日志 ZIP", systemImage: "square.and.arrow.up") }
                            .disabled(!model.canConfigureModel)
                        if let url = model.exportURL { ShareLink(item: url) { Label("分享已生成的 ZIP", systemImage: "doc.zipper") } }
                        Button("清空全部日志", role: .destructive) { confirmingClear = true }
                            .disabled(!model.canConfigureModel)
                    } footer: { Text("导出包含完整 JSON、JSONL 和批量组索引，不包含音频及模型。") }
                    Section("查看 Apple Watch 上的日志") {
                        if model.watchLogs.isEmpty {
                            Text("尚无 iPhone 已确认入库的手表日志。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(model.watchLogs) { log in
                            NavigationLink { WatchLogDetail(log: log) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(log.modelName).font(.headline)
                                    Text(log.finalText.isEmpty ? (log.error ?? log.status) : log.finalText)
                                        .font(.subheadline).lineLimit(2)
                                    Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("删除", role: .destructive) { pendingWatchDelete = log }.disabled(!model.canConfigureModel) }
                        }
                    }
                } else {
                    Section {
                        ForEach(ModelID.allCases) { id in
                            NavigationLink { ModelDetail(id: id) } label: {
                                HStack(spacing: 13) {
                                    ModelEmblem(id: id)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(id.title).font(.body.weight(.medium))
                                        Text("\(id.streaming ? "流式" : "录音后转写") · \(modelSize(id))").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if id == model.selectedModel { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                                }.padding(.vertical, 5)
                            }.accessibilityIdentifier("library.model.\(id.rawValue)")
                        }
                    } footer: { Text("八组模型全部内置。选择模型可查看框架、语言、文件和来源。") }
                }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(ASRBackdrop()).asrScrollEdges()
                .frame(maxWidth: 900).frame(maxWidth: .infinity).background(ASRBackdrop())
                .safeAreaInset(edge: .top, spacing: 0) {
                    Picker("内容", selection: $mode) { Text("测试日志").tag(0); Text("模型信息").tag(1) }
                        .pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 10)
                }
                .navigationTitle("日志及模型信息")
                .toolbar {
                    if mode == 0 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { model.reloadHistory() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新测试日志")
                        }
                    }
                }
                .refreshable { model.reloadHistory() }.onAppear { model.reloadHistory() }
                .alert("删除这条测试记录？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                    Button("删除", role: .destructive) { if let pendingDelete { model.deleteRecord(pendingDelete) }; pendingDelete = nil }
                    Button("取消", role: .cancel) { pendingDelete = nil }
                } message: { Text("同时删除这条记录的详细日志。") }
                .alert("删除这组批量测试？", isPresented: Binding(get: { pendingBatchDelete != nil }, set: { if !$0 { pendingBatchDelete = nil } })) {
                    Button("删除", role: .destructive) { if let pendingBatchDelete { model.deleteBatch(pendingBatchDelete) }; pendingBatchDelete = nil }
                    Button("取消", role: .cancel) { pendingBatchDelete = nil }
                } message: { Text("同时删除组内每个文件的完整转写和过程日志。") }
                .alert("清空全部日志？", isPresented: $confirmingClear) {
                    Button("清空", role: .destructive) { model.clearLogs() }
                    Button("取消", role: .cancel) {}
                } message: { Text("此操作删除本机测试日志与批量组；不会删除模型。") }
                .alert("删除这条手表日志？", isPresented: Binding(get: { pendingWatchDelete != nil }, set: { if !$0 { pendingWatchDelete = nil } })) {
                    Button("删除", role: .destructive) { if let pendingWatchDelete { model.deleteWatchLog(pendingWatchDelete) }; pendingWatchDelete = nil }
                    Button("取消", role: .cancel) { pendingWatchDelete = nil }
                } message: { Text("只删除 iPhone 本机副本，手表本地记录不受影响。") }
        }
    }
}

private struct WatchLogDetail: View {
    let log: WatchASRLog
    var body: some View {
        List {
            Section("最终转写") { Text(log.finalText.isEmpty ? "无文字" : log.finalText).textSelection(.enabled) }
            if !log.partials.isEmpty {
                Section("过程文字") { ForEach(log.partials, id: \.self) { Text($0).textSelection(.enabled) } }
            }
            Section("测试信息") {
                LabeledContent("模型", value: log.modelName)
                LabeledContent("语言", value: log.language)
                LabeledContent("状态", value: log.status)
                LabeledContent("时间", value: log.startedAt.formatted(date: .numeric, time: .standard))
                LabeledContent("音频时长", value: seconds(log.audioSeconds))
                LabeledContent("推理耗时", value: milliseconds(log.inferenceMS))
                if let load = log.modelLoadMS { LabeledContent("模型加载", value: milliseconds(load)) }
                if let error = log.error { Text(error).foregroundStyle(.red) }
            }
        }.scrollContentBackground(.hidden).background(ASRBackdrop())
            .navigationTitle("手表日志").navigationBarTitleDisplayMode(.inline)
    }
}

private struct BatchDetail: View {
    let group: BatchLogGroup
    @EnvironmentObject private var model: ASRController
    var body: some View {
        List {
            Section {
                LabeledContent("模型", value: group.model.title)
                LabeledContent("状态", value: group.status)
                LabeledContent("语言", value: group.options.language)
                LabeledContent("开始", value: group.startedAt.formatted(date: .numeric, time: .standard))
                if let reason = group.stopReason { Text(reason).foregroundStyle(.secondary) }
            }
            Section("文件结果") {
                ForEach(group.items) { item in
                    if let id = item.recordID, let record = model.records.first(where: { $0.id == id }) {
                        NavigationLink { RecordDetail(record: record) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.filename).font(.headline)
                                Text(item.status.rawValue + " · " + (record.text.isEmpty ? "无转写文字" : record.text))
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.filename).font(.headline)
                            Text(item.status.rawValue + " · " + (item.error ?? "暂无结果"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(ASRBackdrop())
            .navigationTitle("批量测试详情").navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecordDetail: View {
    let record: SessionRecord
    var body: some View {
        List {
            Section("识别文字") { Text(record.text.isEmpty ? "无文字" : record.text).textSelection(.enabled) }
            Section("测试信息") {
                LabeledContent("模型", value: record.modelName)
                LabeledContent("推理框架", value: record.framework)
                LabeledContent("时间", value: record.startedAt.formatted(date: .numeric, time: .standard))
                LabeledContent("状态", value: record.state)
                LabeledContent("音频时长", value: seconds(record.audioSeconds))
                LabeledContent("识别调用耗时", value: milliseconds(record.inferenceMS))
                LabeledContent("停止后等待", value: milliseconds(record.stopWaitMS))
                LabeledContent("实际输入", value: inputDisplayName(record.input))
                LabeledContent("设备", value: record.device)
                LabeledContent("语言选项", value: record.options.language)
                if let batch = record.batch {
                    LabeledContent("批量文件", value: batch.filename)
                    LabeledContent("批次序号", value: "\(batch.index)/\(batch.total)")
                    LabeledContent("批次 ID", value: batch.groupID).font(.caption).textSelection(.enabled)
                }
                if let error = record.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("指标说明") { Text(record.metricDefinition).font(.footnote) }
            Section {
                ShareLink(item: SessionStore.url(record.id)) { Label("导出记录 JSON", systemImage: "square.and.arrow.up") }
                if FileManager.default.fileExists(atPath: SessionStore.url(record.id, extension: "jsonl").path) {
                    ShareLink(item: SessionStore.url(record.id, extension: "jsonl")) { Label("导出详细日志 JSONL", systemImage: "doc.text") }
                }
            }
        }.scrollContentBackground(.hidden).background(ASRBackdrop()).asrScrollEdges()
            .frame(maxWidth: 900).frame(maxWidth: .infinity).background(ASRBackdrop())
            .navigationTitle("测试详情").navigationBarTitleDisplayMode(.inline)
    }
}
private struct ModelDetail: View {
    let id: ModelID
    @EnvironmentObject private var model: ASRController
    var body: some View {
        List {
            Section {
                LabeledContent("名称", value: id.title)
                LabeledContent("推理框架", value: id.framework)
                LabeledContent("语言", value: id.languages)
                LabeledContent("识别方式", value: id.streaming ? "原生流式" : "录音后转写")
                LabeledContent("文件大小", value: modelSize(id))
                LabeledContent("内置文件", value: model.availableModels.contains(id) ? "已内置" : "文件异常")
                LabeledContent("当前可用状态", value: id == model.selectedModel ? (model.phase == .ready ? "已加载，可测试" : model.status) : "选择模型后校验并加载")
                Text(id.notes).font(.subheadline)
            }
            Section("来源") {
                Link(destination: id.repo) { Text(id.repo.absoluteString).textSelection(.enabled) }
                if let asset = AssetManifest.current.asset(id) {
                    if let revision = asset.revision { LabeledContent("模型版本", value: revision).font(.caption).textSelection(.enabled) }
                    ForEach(asset.files, id: \.path) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.path).font(.subheadline).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            if let link = file.url, let url = URL(string: link) { Link("模型文件来源", destination: url).font(.caption) }
                        }
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(ASRBackdrop()).asrScrollEdges()
            .frame(maxWidth: 900).frame(maxWidth: .infinity).background(ASRBackdrop())
            .navigationTitle("模型信息").navigationBarTitleDisplayMode(.inline)
    }
}
private struct SettingsView: View {
    @EnvironmentObject private var model: ASRController
    @State private var choosingModel = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ModelSelectorButton { choosingModel = true }
                        .accessibilityIdentifier("settings.modelSelector")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.status)
                        Text("八组模型已内置。选择后即可离线测试，一次只加载当前模型。")
                    }
                }
                Section {
                    Picker("输入源", selection: Binding(get: { model.selectedInputID }, set: { model.selectInput($0) })) {
                        Text("系统默认").tag("")
                        ForEach(model.inputs) { input in Text(inputDisplayName(input.name)).tag(input.id) }
                        if !model.selectedInputID.isEmpty && !model.inputs.contains(where: { $0.id == model.selectedInputID }) {
                            Text("已断开的输入设备").tag(model.selectedInputID)
                        }
                    }.disabled(!model.canStart)
                    HStack {
                        Label("自动刷新", systemImage: "arrow.triangle.2.circlepath").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.refreshInputs() } label: {
                            Label(model.refreshingInputs ? "刷新中" : "刷新", systemImage: "arrow.clockwise")
                        }.asrGlassButton().controlSize(.small).disabled(!model.canStart)
                            .accessibilityLabel("刷新输入源")
                    }
                } header: { Label("麦克风输入", systemImage: "mic") } footer: { Text(model.inputMessage) }
                Section {
                    if !model.selectedModel.languageChoices.isEmpty {
                        Picker("语言", selection: Binding(get: { model.selectedLanguage }, set: { model.selectLanguage($0) })) {
                            ForEach(model.selectedModel.languageChoices, id: \.0) { value in Text(value.1).tag(value.0) }
                        }.disabled(!model.canConfigureModel)
                    } else { LabeledContent("语言", value: model.selectedModel.languages) }
                    if ![.voskChinese, .voskEnglish].contains(model.selectedModel) {
                        Picker("CPU 线程", selection: Binding(get: { model.options.threads }, set: { model.setThreads($0) })) {
                            ForEach([1, 2, 4], id: \.self) { Text("\($0)").tag($0) }
                        }.disabled(!model.canConfigureModel)
                    }
                    if model.selectedModel == .senseVoice {
                        Toggle("文本归一化（ITN）", isOn: Binding(get: { model.options.useITN }, set: { model.setITN($0) }))
                            .disabled(!model.canConfigureModel)
                    }
                    LabeledContent("单轮录音上限", value: "\(Int(model.selectedModel.maximumSeconds)) 秒")
                    NavigationLink("当前模型详情") { ModelDetail(id: model.selectedModel) }
                } header: { Label("识别设置", systemImage: "slider.horizontal.3") }
                Section {
                    LabeledContent("应用", value: "ASRtest")
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0")
                    Label("全部识别在本机完成", systemImage: "iphone").font(.subheadline)
                } header: { Text("关于") } footer: {
                    Text("不保存原始录音。测试记录保存在本机，可从日志页导出。")
                }
            }.scrollContentBackground(.hidden).background(ASRBackdrop()).asrScrollEdges()
                .frame(maxWidth: 900).frame(maxWidth: .infinity).background(ASRBackdrop())
                .navigationTitle("设置")
                .sheet(isPresented: $choosingModel) { ModelSelectionView() }
        }
    }
}
