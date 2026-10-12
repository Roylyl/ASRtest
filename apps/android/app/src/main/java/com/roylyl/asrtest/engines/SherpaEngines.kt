package com.roylyl.asrtest.engines

import com.k2fsa.sherpa.onnx.*
import java.io.File

internal class SherpaStreamingEngine(
    private val modelId: String,
    root: File,
    threads: Int,
) : CancellableEngine() {
    private val recognizer: OnlineRecognizer
    private val stream: OnlineStream
    private val transcript = Transcript()
    private var count = 0
    private var partial = ""

    init {
        val models = OnlineModelConfig(
            tokens = modelFile(root, "tokens.txt"),
            numThreads = threads,
            provider = "cpu",
            modelType = if (modelId == "zipformer") "zipformer" else "paraformer",
        )
        if (modelId == "zipformer") {
            models.transducer = OnlineTransducerModelConfig(
                encoder = modelFile(root, "encoder-epoch-99-avg-1.int8.onnx"),
                decoder = modelFile(root, "decoder-epoch-99-avg-1.onnx"),
                joiner = modelFile(root, "joiner-epoch-99-avg-1.int8.onnx"),
            )
        } else {
            models.paraformer = OnlineParaformerModelConfig(
                encoder = modelFile(root, "encoder.int8.onnx"),
                decoder = modelFile(root, "decoder.int8.onnx"),
            )
        }
        recognizer = OnlineRecognizer(config = OnlineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
            modelConfig = models,
            endpointConfig = EndpointConfig(),
            enableEndpoint = true,
            decodingMethod = "greedy_search",
            maxActivePaths = 4,
        ))
        try {
            stream = recognizer.createStream()
        } catch (error: Throwable) {
            recognizer.release()
            throw error
        }
    }

    override fun accept(samples: FloatArray): String {
        checkAccept()
        validAudio(samples)
        require(samples.size <= STREAMING_SAMPLE_LIMIT - count) { "流式单轮音频上限为600秒。" }
        if (samples.isEmpty()) return transcript.visible(partial)
        stream.acceptWaveform(samples, SAMPLE_RATE)
        count += samples.size
        decodeReady()
        partial = recognizer.getResult(stream).text
        if (recognizer.isEndpoint(stream)) {
            transcript.add(partial)
            recognizer.reset(stream)
            partial = ""
        }
        return transcript.visible(partial)
    }

    override fun finish(): String {
        checkActive()
        if (finished) return transcript.visible()
        if (count > 0) {
            // Model-finalization padding is excluded from recorded audio duration.
            val tail = if (modelId == "zipformer") 10_560 else 4_800
            stream.acceptWaveform(FloatArray(tail), SAMPLE_RATE)
            stream.inputFinished()
            if (modelId == "paraformer") stream.setOption("is_final", "1")
            decodeReady()
            transcript.add(recognizer.getResult(stream).text)
        }
        finished = true
        partial = ""
        return transcript.visible()
    }

    private fun decodeReady() {
        while (recognizer.isReady(stream)) {
            checkActive()
            recognizer.decode(stream)
        }
        checkActive()
    }

    override fun close() {
        if (closed) return
        closed = true
        try { stream.release() } finally { recognizer.release() }
    }
}

internal class SenseVoiceEngine(root: File, threads: Int, language: String, itn: Boolean) : CancellableEngine() {
    private val recognizer: OfflineRecognizer
    private val chunks = ArrayList<FloatArray>()
    private var count = 0
    private var text = ""

    init {
        require(language in listOf("auto", "zh", "en", "ja", "ko", "yue")) { "SenseVoice不支持所选语言。" }
        recognizer = OfflineRecognizer(config = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
            modelConfig = OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(
                    model = modelFile(root, "model.int8.onnx"),
                    language = language,
                    useInverseTextNormalization = itn,
                ),
                tokens = modelFile(root, "tokens.txt"),
                numThreads = threads,
                provider = "cpu",
                modelType = "sense_voice",
            ),
            decodingMethod = "greedy_search",
            maxActivePaths = 4,
        ))
    }

    override fun accept(samples: FloatArray): String {
        checkAccept()
        validAudio(samples)
        require(samples.size <= OFFLINE_SAMPLE_LIMIT - count) { "非流式单轮音频上限为30秒，请分段测试。" }
        if (samples.isNotEmpty()) { chunks.add(samples.copyOf()); count += samples.size }
        return "" // This backend has no live partial transcription.
    }

    override fun finish(): String {
        checkActive()
        if (finished) return text
        finished = true
        if (count == 0) return ""
        val samples = FloatArray(count)
        var offset = 0
        chunks.forEach { it.copyInto(samples, offset); offset += it.size }
        chunks.clear()
        val stream = recognizer.createStream()
        try {
            stream.acceptWaveform(samples, SAMPLE_RATE)
            checkActive()
            // This native synchronous call cannot be interrupted; cancellation discards its result.
            recognizer.decode(stream)
            checkActive()
            text = recognizer.getResult(stream).text.trim()
            return text
        } finally {
            stream.release()
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        chunks.clear()
        recognizer.release()
    }
}
