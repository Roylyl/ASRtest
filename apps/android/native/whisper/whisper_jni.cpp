#include "../common_jni.h"
#include "whisper.h"
#include <algorithm>
#include <android/log.h>

namespace {
struct WhisperHandle {
    whisper_context * context = nullptr;
    int threads = 2;
    std::atomic<bool> cancelled{false};
    ~WhisperHandle() { if (context) whisper_free(context); }
};
HandleRegistry<WhisperHandle> registry;
bool abortDecode(void * user) { return static_cast<WhisperHandle *>(user)->cancelled.load(); }
void nativeLog(ggml_log_level level, const char * text, void *) {
    __android_log_write(level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO,
                        "ASRWhisper", text);
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_roylyl_asrtest_NativeBridge_whisperCreate(JNIEnv * env, jobject, jstring path, jint threads) {
    try {
        auto h = std::make_shared<WhisperHandle>();
        h->threads = std::clamp(static_cast<int>(threads), 1, 4);
        auto model = jniString(env, path);
        auto options = whisper_context_default_params();
        options.use_gpu = false;
        options.flash_attn = false;
        whisper_log_set(nativeLog, nullptr);
        h->context = whisper_init_from_file_with_params(model.c_str(), options);
        if (!h->context) throw std::runtime_error("Cannot load local Whisper model: " + model);
        return registry.add(std::move(h));
    } catch (const std::exception & ex) { jniError(env, ex.what()); return 0; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_roylyl_asrtest_NativeBridge_whisperTranscribe(JNIEnv * env, jobject,
                                                    jlong id, jfloatArray input, jstring language) {
    try {
        auto h = registry.get(id);
        if (!h) throw std::runtime_error("Whisper context is closed");
        auto pcm = jniPcm(env, input);
        auto lang = jniString(env, language);
        if (lang.empty()) lang = "auto";
        if (lang != "auto" && whisper_lang_id(lang.c_str()) < 0)
            throw std::runtime_error("Unsupported Whisper language: " + lang);
        h->cancelled.store(false);
        if (pcm.size() < 400) return jniUtf8(env, "");
        auto options = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        options.n_threads = h->threads;
        options.translate = false;
        options.no_context = true;
        options.print_realtime = false;
        options.print_progress = false;
        options.print_timestamps = false;
        options.print_special = false;
        options.temperature = 0;
        options.temperature_inc = 0;
        options.language = lang.c_str();
        options.abort_callback = abortDecode;
        options.abort_callback_user_data = h.get();
        const int code = whisper_full(h->context, options, pcm.data(), static_cast<int>(pcm.size()));
        if (h->cancelled.load()) {
            jniError(env, "Whisper inference cancelled", true);
            return nullptr;
        }
        if (code != 0) throw std::runtime_error("Whisper inference failed: " + std::to_string(code));
        std::string result;
        for (int i = 0; i < whisper_full_n_segments(h->context); ++i) {
            const char * text = whisper_full_get_segment_text(h->context, i);
            if (text) result += text;
        }
        return jniUtf8(env, result);
    } catch (const std::exception & ex) { jniError(env, ex.what()); return nullptr; }
}

extern "C" JNIEXPORT void JNICALL
Java_com_roylyl_asrtest_NativeBridge_whisperCancel(JNIEnv *, jobject, jlong id) {
    if (auto h = registry.get(id)) h->cancelled.store(true);
}

extern "C" JNIEXPORT void JNICALL
Java_com_roylyl_asrtest_NativeBridge_whisperClose(JNIEnv *, jobject, jlong id) { registry.remove(id); }
