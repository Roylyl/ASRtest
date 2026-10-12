package com.roylyl.asrtest

import com.roylyl.asrtest.engines.StandardEngineFactory
import java.io.File
import java.util.concurrent.CancellationException

interface AsrEngine : AutoCloseable {
    fun accept(samples: FloatArray): String
    fun finish(): String
    fun cancel() {}
}

data class ModelSpec(val id: String, val title: String, val framework: String,
                     val streaming: Boolean, val languages: String, val parameters: Long?, val repo: String) {
    val maxSeconds: Int get() = if (streaming) 600 else 30
    companion object {
        val all = listOf(
            ModelSpec("zipformer", "Zipformer Small·中英", "sherpa-onnx", true, "中英", null, "https://github.com/k2-fsa/sherpa-onnx"),
            ModelSpec("whisperTiny", "Whisper tiny·多语言", "whisper.cpp", false, "多语言", 39_000_000, "https://github.com/ggml-org/whisper.cpp"),
            ModelSpec("whisperBase", "Whisper base·多语言", "whisper.cpp", false, "多语言", 74_000_000, "https://github.com/ggml-org/whisper.cpp"),
            ModelSpec("voskChinese", "Vosk·中文", "Vosk 0.3.47", true, "中文", null, "https://github.com/alphacep/vosk-api"),
            ModelSpec("voskEnglish", "Vosk·English", "Vosk 0.3.47", true, "英文", null, "https://github.com/alphacep/vosk-api"),
            ModelSpec("senseVoice", "SenseVoiceSmall INT8", "sherpa-onnx", false, "中英粤日韩", 234_000_000, "https://github.com/QwenAudio/SenseVoice"),
            ModelSpec("paraformer", "Paraformer Streaming INT8", "sherpa-onnx", true, "中英", 220_000_000, "https://github.com/modelscope/FunASR"),
            ModelSpec("nano", "Fun-ASR-Nano Q4", "Fun-ASR/llama.cpp", false, "中英日", 800_000_000, "https://github.com/QwenAudio/Fun-ASR")
        )
        fun get(id: String): ModelSpec = all.first { it.id == id }
    }
}

object EngineFactory {
    fun create(model: ModelSpec, root: File, threads: Int, language: String, itn: Boolean): AsrEngine {
        if (model.id !in listOf("whisperTiny", "whisperBase", "nano"))
            return StandardEngineFactory.create(model.id, root, threads, language, itn)
        return BufferedNativeEngine(model, root, threads, language)
    }
}

private class BufferedNativeEngine(private val spec: ModelSpec, root: File, threads: Int,
                                   private val language: String) : AsrEngine {
    @Volatile private var handle = if (spec.id == "nano") NativeBridge.nanoCreate(
        File(root,"funasr-encoder-f16.gguf").path, File(root,"qwen3-0.6b-q4km.gguf").path,
        File(root,"fsmn-vad.gguf").path, language, threads)
    else NativeBridge.whisperCreate(File(root, if (spec.id == "whisperTiny") "ggml-tiny.bin" else "ggml-base.bin").path, threads)
    @Volatile private var canceled = false
    private val chunks = ArrayList<FloatArray>()
    private var count = 0
    override fun accept(samples: FloatArray): String {
        if (canceled) throw CancellationException("用户主动停止")
        require(count + samples.size <= 30 * 16000) { "此非流式模型每轮最多30秒" }
        chunks.add(samples.copyOf()); count += samples.size
        return ""
    }
    override fun finish(): String {
        if (canceled) throw CancellationException("用户主动停止")
        if (count == 0) return ""
        val audio = FloatArray(count); var offset = 0
        chunks.forEach { it.copyInto(audio, offset); offset += it.size }; chunks.clear()
        val result = if (spec.id == "nano") NativeBridge.nanoTranscribe(handle, audio)
        else NativeBridge.whisperTranscribe(handle, audio, language)
        if (canceled) throw CancellationException("用户主动停止")
        return result.trim()
    }
    override fun cancel() {
        canceled = true
        val h = handle
        if (h != 0L) { if (spec.id == "nano") NativeBridge.nanoCancel(h) else NativeBridge.whisperCancel(h) }
    }
    override fun close() {
        val h = handle; handle = 0
        if (h != 0L) { if (spec.id == "nano") NativeBridge.nanoClose(h) else NativeBridge.whisperClose(h) }
        chunks.clear()
    }
}
