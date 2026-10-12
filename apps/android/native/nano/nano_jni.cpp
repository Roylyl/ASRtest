#include "../common_jni.h"
#include "asr_nano.h"
#include "llama.h"
#include <algorithm>
#include <android/log.h>

namespace {
struct NanoHandle {
    asr_nano_context * context = nullptr;
    std::atomic<bool> cancelled{false};
    ~NanoHandle() { if (context) asr_nano_close(context); }
};
HandleRegistry<NanoHandle> registry;
int32_t abortDecode(void * user) { return static_cast<NanoHandle *>(user)->cancelled.load() ? 1 : 0; }
void nativeLog(ggml_log_level level, const char * text, void *) {
    __android_log_write(level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO,
                        "ASRNano", text);
}
std::string promptLanguage(std::string language) {
    if (language.empty() || language == "auto") return "";
    if (language == "zh") return "中文";
    if (language == "en") return "英语";
    if (language == "ja") return "日语";
    throw std::runtime_error("Unsupported Nano language: " + language);
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_roylyl_asrtest_NativeBridge_nanoCreate(JNIEnv * env, jobject, jstring encoder,
    jstring decoder, jstring vad, jstring language, jint threads) {
    try {
        auto h = std::make_shared<NanoHandle>();
        auto enc = jniString(env, encoder);
        auto dec = jniString(env, decoder);
        auto vadPath = jniString(env, vad);
        auto lang = promptLanguage(jniString(env, language));
        llama_log_set(nativeLog, nullptr);
        ggml_log_set(nativeLog, nullptr);
        char error[1024]{};
        h->context = asr_nano_open(enc.c_str(), dec.c_str(), vadPath.c_str(), lang.c_str(),
            std::clamp(static_cast<int>(threads), 1, 4), abortDecode, h.get(), error, sizeof(error));
        if (!h->context) throw std::runtime_error(error[0] ? error : "Cannot load local Fun-ASR-Nano model");
        return registry.add(std::move(h));
    } catch (const std::exception & ex) { jniError(env, ex.what()); return 0; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_roylyl_asrtest_NativeBridge_nanoTranscribe(JNIEnv * env, jobject, jlong id, jfloatArray input) {
    try {
        auto h = registry.get(id);
        if (!h) throw std::runtime_error("Nano context is closed");
        auto pcm = jniPcm(env, input);
        h->cancelled.store(false);
        const int code = asr_nano_transcribe(h->context, pcm.data(), pcm.size());
        if (code == -2 || h->cancelled.load()) {
            jniError(env, "Nano inference cancelled", true);
            return nullptr;
        }
        if (code != 0) throw std::runtime_error(asr_nano_error(h->context));
        return jniUtf8(env, asr_nano_text(h->context));
    } catch (const std::exception & ex) { jniError(env, ex.what()); return nullptr; }
}

extern "C" JNIEXPORT void JNICALL
Java_com_roylyl_asrtest_NativeBridge_nanoCancel(JNIEnv *, jobject, jlong id) {
    if (auto h = registry.get(id)) h->cancelled.store(true);
}

extern "C" JNIEXPORT void JNICALL
Java_com_roylyl_asrtest_NativeBridge_nanoClose(JNIEnv *, jobject, jlong id) { registry.remove(id); }
