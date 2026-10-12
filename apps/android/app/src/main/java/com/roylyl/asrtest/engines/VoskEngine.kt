package com.roylyl.asrtest.engines

import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import kotlin.math.roundToInt

/** Vosk Android 0.3.47; the runtime does not expose a recognizer thread-count setter. */
internal class VoskEngine(root: File) : CancellableEngine() {
    private val model: Model
    private val recognizer: Recognizer
    private val transcript = Transcript()
    private var partial = ""
    private var count = 0

    init {
        modelFile(root, "am/final.mdl")
        model = Model(root.absolutePath)
        try {
            recognizer = Recognizer(model, SAMPLE_RATE.toFloat())
            recognizer.setWords(true)
        } catch (error: Throwable) {
            model.close()
            throw error
        }
    }

    override fun accept(samples: FloatArray): String {
        checkAccept()
        validAudio(samples)
        require(samples.size <= STREAMING_SAMPLE_LIMIT - count) { "流式单轮音频上限为600秒。" }
        if (samples.isEmpty()) return transcript.visible(partial)
        // Retain iOS's PCM16 path. Vosk's float input uses a different amplitude scale.
        val pcm = ShortArray(samples.size) { (samples[it] * 32768f).roundToInt().coerceIn(-32768, 32767).toShort() }
        val complete = recognizer.acceptWaveForm(pcm, pcm.size)
        count += samples.size
        checkActive()
        if (complete) {
            transcript.add(result(recognizer.result, "text"))
            partial = ""
        } else {
            partial = result(recognizer.partialResult, "partial")
        }
        return transcript.visible(partial)
    }

    override fun finish(): String {
        checkActive()
        if (finished) return transcript.visible()
        transcript.add(result(recognizer.finalResult, "text"))
        checkActive()
        finished = true
        partial = ""
        return transcript.visible()
    }

    private fun result(json: String, field: String): String {
        val value = JSONObject(json)
        require(value.has(field) && value.get(field) is String) { "Vosk返回了无效结果。" }
        return value.getString(field).trim()
    }

    override fun close() {
        if (closed) return
        closed = true
        try { recognizer.close() } finally { model.close() }
    }
}
