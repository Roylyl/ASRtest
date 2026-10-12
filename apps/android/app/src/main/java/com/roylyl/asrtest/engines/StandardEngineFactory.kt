package com.roylyl.asrtest.engines

import com.roylyl.asrtest.AsrEngine
import java.io.File
import java.util.concurrent.CancellationException

/** Real CPU backends using the same model files and finalization policy as ASRtest iOS. */
object StandardEngineFactory {
    fun create(modelId: String, modelRoot: File, threads: Int, language: String, itn: Boolean): AsrEngine {
        require(threads in 1..8) { "推理线程数须为1至8。" }
        require(modelRoot.isDirectory) { "模型目录不存在：${modelRoot.name}" }
        return when (modelId) {
            "zipformer", "paraformer" -> SherpaStreamingEngine(modelId, modelRoot, threads)
            "senseVoice" -> SenseVoiceEngine(modelRoot, threads, language, itn)
            "voskChinese", "voskEnglish" -> VoskEngine(modelRoot)
            else -> throw IllegalArgumentException("此适配器不支持模型：$modelId")
        }
    }
}

internal const val SAMPLE_RATE = 16_000
internal const val STREAMING_SAMPLE_LIMIT = 600 * SAMPLE_RATE
internal const val OFFLINE_SAMPLE_LIMIT = 30 * SAMPLE_RATE

internal fun modelFile(root: File, name: String): String {
    val file = File(root, name)
    require(file.isFile && file.canRead() && file.length() > 0) { "模型文件缺失或不可读：$name" }
    return file.absolutePath
}

internal fun validAudio(samples: FloatArray) {
    require(samples.all { it.isFinite() }) { "音频中包含无效采样值。" }
}

internal class Transcript {
    private val finalSegments = ArrayList<String>()
    fun add(text: String) { text.trim().takeIf { it.isNotEmpty() }?.let { finalSegments.add(it) } }
    fun visible(partial: String = ""): String =
        (finalSegments + listOfNotNull(partial.trim().takeIf { it.isNotEmpty() })).joinToString("\n")
}

internal abstract class CancellableEngine : AsrEngine {
    @Volatile private var cancelled = false
    protected var closed = false
    protected var finished = false
    override fun cancel() { cancelled = true }
    protected fun checkActive() {
        if (cancelled || Thread.currentThread().isInterrupted) throw CancellationException("识别已取消。")
        check(!closed) { "识别引擎已关闭。" }
    }
    protected fun checkAccept() {
        checkActive()
        check(!finished) { "当前识别会话已结束。" }
    }
}
