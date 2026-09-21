import SwiftUI
import AVFoundation

struct ASRBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if !reduceTransparency {
                LinearGradient(colors: [.blue.opacity(scheme == .dark ? 0.14 : 0.09), .cyan.opacity(0.035), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

private struct ASRGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let interactive: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: 26))
        } else {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

struct ASRGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 16) { content() } }
        else { content() }
    }
}

extension View {
    func asrGlass(interactive: Bool = false) -> some View { modifier(ASRGlassSurface(interactive: interactive)) }
    func asrContentSurface() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
    }
    @ViewBuilder func asrGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
    @ViewBuilder func asrScrollEdges() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectStyle(.soft, for: .all) }
        else { self }
    }
    @ViewBuilder func asrTabBehavior() -> some View {
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior(.never) }
        else { self }
    }
}

struct ModelEmblem: View {
    let id: ModelID
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: id.uiSymbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(id.uiColor)
            .frame(width: size, height: size)
            .background(id.uiColor.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

struct ModelSelectorButton: View {
    @EnvironmentObject private var model: ASRController
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ModelEmblem(id: model.selectedModel, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前模型").font(.caption).foregroundStyle(.secondary)
                    Text(model.selectedModel.title).font(.headline).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(model.selectedModel.uiFramework).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(18).contentShape(RoundedRectangle(cornerRadius: 26))
        }.buttonStyle(.plain).asrGlass(interactive: true)
            .disabled(!model.canConfigureModel)
            .accessibilityLabel("当前模型，\(model.selectedModel.title)，选择模型")
            .accessibilityHint("打开八组内置模型的选择列表")
    }
}

struct ModelSelectionView: View {
    @EnvironmentObject private var model: ASRController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelID.allCases) { id in
                        Button {
                            if model.selectedModel != id { model.selectModel(id) }
                            dismiss()
                        } label: {
                            HStack(spacing: 13) {
                                ModelEmblem(id: id)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(id.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text("\(id.streaming ? "流式" : "录音后转写") · \(modelSize(id))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if id == model.selectedModel {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(!model.canConfigureModel || !model.availableModels.contains(id))
                            .accessibilityIdentifier("model.\(id.rawValue)")
                            .accessibilityValue(id == model.selectedModel ? "已选择" : "")
                    }
                } header: { Text("8 组内置模型") } footer: {
                    Text("全部在本机运行。切换时释放上一组，只加载当前选择的模型。Fun-ASR-Nano 为实验性移植。")
                }
            }.scrollContentBackground(.hidden).background(ASRBackdrop())
                .navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

extension ModelID {
    var uiColor: Color {
        switch self {
        case .zipformer: .blue
        case .whisperTiny, .whisperBase: .indigo
        case .voskChinese, .voskEnglish: .green
        case .senseVoice: .teal
        case .paraformer: .cyan
        case .nano: .orange
        }
    }
    var uiSymbol: String {
        switch self {
        case .zipformer, .paraformer: "waveform"
        case .whisperTiny, .whisperBase: "quote.bubble"
        case .voskChinese, .voskEnglish: "waveform.circle"
        case .senseVoice: "ear"
        case .nano: "cpu"
        }
    }
    var uiFramework: String {
        switch self {
        case .zipformer, .senseVoice, .paraformer: "sherpa-onnx"
        case .whisperTiny, .whisperBase: "whisper.cpp"
        case .voskChinese, .voskEnglish: "Vosk"
        case .nano: "Fun-ASR / llama.cpp"
        }
    }
}

func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
// The UI uses readable labels; recording metadata retains the original device name and UID.
func inputDisplayName(_ raw: String) -> String {
    let parts = raw.components(separatedBy: " · ")
    guard parts.count == 2 else { return raw }
    let port = AVAudioSession.Port(rawValue: parts[1])
    if port == .builtInMic { return "内建麦克风" }
    let kind: String
    switch port {
    case .bluetoothHFP: kind = "蓝牙麦克风"
    case .headsetMic: kind = "耳机麦克风"
    case .usbAudio: kind = "USB 音频"
    case .lineIn: kind = "线路输入"
    default: return parts[0] == parts[1] ? parts[0] : raw
    }
    return "\(parts[0]) · \(kind)"
}
func modelSize(_ id: ModelID) -> String {
    guard let asset = AssetManifest.current.asset(id) else { return "清单未就绪" }
    return ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file)
}
