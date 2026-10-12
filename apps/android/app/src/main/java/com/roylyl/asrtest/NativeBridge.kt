package com.roylyl.asrtest

/** Offline CPU runtimes. Call create/transcribe/close on a serial worker; cancel is thread-safe. */
object NativeBridge {
    init {
        System.loadLibrary("asr_whisper")
        System.loadLibrary("asr_nano")
    }

    external fun whisperCreate(modelPath: String, threads: Int): Long
    external fun whisperTranscribe(handle: Long, pcm16k: FloatArray, language: String): String
    external fun whisperCancel(handle: Long)
    external fun whisperClose(handle: Long)

    /** language: auto, zh, en or ja; the prompt is fixed for this context. */
    external fun nanoCreate(encoderPath: String, decoderPath: String, vadPath: String,
                            language: String, threads: Int): Long
    external fun nanoTranscribe(handle: Long, pcm16k: FloatArray): String
    external fun nanoCancel(handle: Long)
    external fun nanoClose(handle: Long)
}
