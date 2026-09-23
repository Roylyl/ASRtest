import Foundation

extension ModelID {
    var title: String {
        switch self {
        case .zipformer: "Zipformer Small · 中英"
        case .whisperTiny: "Whisper tiny · 多语言"
        case .whisperBase: "Whisper base · 多语言"
        case .voskChinese: "Vosk · 中文"
        case .voskEnglish: "Vosk · English"
        case .senseVoice: "SenseVoiceSmall"
        case .paraformer: "Paraformer Streaming · 中英"
        case .nano: "Fun-ASR-Nano · Q4"
        }
    }
    var framework: String {
        switch self {
        case .zipformer, .senseVoice, .paraformer: "sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2"
        case .whisperTiny, .whisperBase: "whisper.cpp 1.9.4"
        case .voskChinese, .voskEnglish: "Vosk · 社区运行库 970d3d5（核心版本未知）"
        case .nano: "Fun-ASR / llama.cpp · CPU"
        }
    }
    var streaming: Bool { [.zipformer, .paraformer, .voskChinese, .voskEnglish].contains(self) }
    var languages: String {
        switch self {
        case .zipformer, .paraformer: "中文、英文"
        case .whisperTiny, .whisperBase: "多语言（本工具重点测试中文、英文）"
        case .voskChinese: "中文"
        case .voskEnglish: "英文"
        case .senseVoice: "中文、英文、粤语、日语、韩语"
        case .nano: "中文、英文、日语"
        }
    }
    var languageChoices: [(String, String)] {
        switch self {
        case .whisperTiny, .whisperBase: [("auto","自动"),("zh","中文"),("en","English")]
        case .senseVoice: [("auto","自动"),("zh","中文"),("en","English"),("yue","粤语"),("ja","日语"),("ko","韩语")]
        case .nano: [("auto","自动"),("zh","中文"),("en","English"),("ja","日语")]
        default: []
        }
    }
    var maximumSeconds: Double { streaming ? 600 : 30 }
    var repo: URL {
        let string: String = switch self {
        case .zipformer: "https://github.com/k2-fsa/sherpa-onnx"
        case .whisperTiny, .whisperBase: "https://github.com/ggml-org/whisper.cpp"
        case .voskChinese, .voskEnglish: "https://github.com/alphacep/vosk-api"
        case .senseVoice: "https://github.com/QwenAudio/SenseVoice"
        case .paraformer: "https://github.com/modelscope/FunASR"
        case .nano: "https://github.com/QwenAudio/Fun-ASR"
        }
        return URL(string: string)!
    }
    var notes: String {
        switch self {
        case .zipformer: "中英 2023-02-16 / chunk 32。Encoder、joiner INT8；decoder FP32。"
        case .whisperTiny, .whisperBase: "多语言版。录音后转写；CPU、greedy、不翻译。本工具每轮最多30秒。"
        case .voskChinese: "vosk-model-small-cn-0.22；保持完整模型目录。"
        case .voskEnglish: "vosk-model-small-en-us-0.15；单独英文模型。"
        case .senseVoice: "2024-07-17 INT8 ONNX。非流式识别，可设置语言和逆文本归一化。"
        case .paraformer: "中英流式 INT8 encoder/decoder，非 Zipformer。该模型不提供词级时间戳。"
        case .nano: "本地音频编码器＋Q4_K_M解码器。实验性移植；停止后分段转写，每轮最多30秒。"
        }
    }
}
struct ModelFile: Codable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
    let url: String?
}
struct ModelAsset: Codable, Sendable {
    let id: String
    let revision: String?
    let files: [ModelFile]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}
struct AssetManifest: Codable, Sendable {
    let models: [ModelAsset]
    static let current: AssetManifest = {
        guard let url = Bundle.main.url(forResource: "ModelsManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(models: [])
        }
        return value
    }()
    func asset(_ id: ModelID) -> ModelAsset? { models.first { $0.id == id.rawValue } }
}
