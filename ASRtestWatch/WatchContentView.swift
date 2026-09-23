import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var asr: WatchASRController
    private let unavailableModels = ["Zipformer Small", "Whisper base", "Vosk 中文", "Vosk 英文",
                                     "SenseVoiceSmall", "Paraformer Streaming", "Fun-ASR-Nano Q4"]
    private var experimentEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    var body: some View {
        TabView {
            modelPage
            testPage
            logsPage
            settingsPage
        }.tabViewStyle(.page(indexDisplayMode: .always))
            .onAppear { asr.runSilentSmokeIfRequested() }
    }
    private var modelPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("模型").font(.headline)
                Text("Whisper tiny · 多语言").font(.subheadline.weight(.semibold))
                Label("尚未真机验证 · 实验入口", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2).foregroundStyle(.orange)
                Text("watchOS CPU 运行库与模型已打包；实体手表本地推理尚未完成验证。录音后转写，最长 30 秒。")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text("其他模型 · 不可用").font(.caption)
                ForEach(unavailableModels, id: \.self) { name in
                    Label(name, systemImage: "minus.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("未接入 watchOS 本地运行库；iPhone 不代算。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var testPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("本地转写").font(.headline)
                Text(asr.finalText.isEmpty ? (asr.recording ? "录音中；停止后显示最终文字" : "准备开始") : asr.finalText)
                    .font(.subheadline)
                Text(asr.status).font(.caption2).foregroundStyle(.secondary)
                if asr.audioSeconds > 0 {
                    Text(String(format: "音频 %.1f 秒 · 推理 %.0f ms", asr.audioSeconds, asr.inferenceMS))
                        .font(.caption2).monospacedDigit()
                }
                Button { asr.recording ? asr.stop() : asr.start() } label: {
                    Label(asr.recording ? "停止并转写" : "试验录音", systemImage: asr.recording ? "stop.fill" : "mic.fill")
                }.buttonStyle(.borderedProminent).disabled(asr.busy || !experimentEnabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var logsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("手表日志").font(.headline)
                Button("导出到 iPhone") { asr.transfer.export(asr.logs) }
                    .buttonStyle(.bordered).disabled(asr.logs.isEmpty)
                Text(asr.transfer.connection).font(.caption2).foregroundStyle(.secondary)
                ForEach(asr.logs) { log in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(log.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                        Text(log.finalText.isEmpty ? (log.error ?? log.status) : log.finalText).font(.caption2).lineLimit(4)
                        Text(asr.transfer.state(log.id)).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    Divider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("设置").font(.headline)
                Picker("识别语言", selection: $asr.language) {
                    Text("自动").tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                Text("Whisper tiny 多语言 · CPU · 2 线程 · 16 kHz。只在手表本地推理；不上传音频。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
