#pragma once
#include <jni.h>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

// Handles are opaque registry IDs. An ongoing decode keeps the context alive
// after close, so a concurrent UI cancellation never reads freed memory.
template<class T> class HandleRegistry {
    std::mutex mutex_;
    std::unordered_map<jlong, std::shared_ptr<T>> handles_;
    jlong next_ = 1;
public:
    jlong add(std::shared_ptr<T> h) {
        std::lock_guard<std::mutex> guard(mutex_);
        const jlong id = next_++;
        handles_.emplace(id, std::move(h));
        return id;
    }
    std::shared_ptr<T> get(jlong id) {
        std::lock_guard<std::mutex> guard(mutex_);
        const auto it = handles_.find(id);
        return it == handles_.end() ? nullptr : it->second;
    }
    void remove(jlong id) {
        std::shared_ptr<T> old;
        {
            std::lock_guard<std::mutex> guard(mutex_);
            const auto it = handles_.find(id);
            if (it == handles_.end()) return;
            old = std::move(it->second);
            handles_.erase(it);
        }
        old->cancelled.store(true);
    }
};

inline void jniError(JNIEnv * env, const std::string & message, bool cancelled = false) {
    if (env->ExceptionCheck()) return;
    auto cls = env->FindClass(cancelled ? "java/util/concurrent/CancellationException" :
                                           "java/lang/IllegalStateException");
    if (cls) env->ThrowNew(cls, message.c_str());
}

inline std::string jniString(JNIEnv * env, jstring value) {
    if (!value) throw std::runtime_error("Missing string argument");
    const char * p = env->GetStringUTFChars(value, nullptr);
    if (!p) throw std::runtime_error("Cannot read string argument");
    std::string result(p);
    env->ReleaseStringUTFChars(value, p);
    return result;
}

inline jstring jniUtf8(JNIEnv * env, const std::string & value) {
    // Native ASR returns UTF-8, whereas NewStringUTF expects Modified UTF-8.
    auto bytes = env->NewByteArray(static_cast<jsize>(value.size()));
    if (!bytes) return nullptr;
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(value.size()),
                           reinterpret_cast<const jbyte *>(value.data()));
    auto cls = env->FindClass("java/lang/String");
    auto constructor = cls ? env->GetMethodID(cls, "<init>", "([BLjava/lang/String;)V") : nullptr;
    auto charset = env->NewStringUTF("UTF-8");
    jstring result = constructor && charset ? static_cast<jstring>(env->NewObject(cls, constructor, bytes, charset)) : nullptr;
    env->DeleteLocalRef(bytes);
    if (charset) env->DeleteLocalRef(charset);
    if (cls) env->DeleteLocalRef(cls);
    return result;
}

inline std::vector<float> jniPcm(JNIEnv * env, jfloatArray input) {
    if (!input) throw std::runtime_error("Missing PCM input");
    const jsize count = env->GetArrayLength(input);
    if (count > 30 * 16000) throw std::runtime_error("ASR accepts at most 30 seconds of 16 kHz mono PCM per call");
    std::vector<float> pcm(static_cast<size_t>(count));
    if (count) env->GetFloatArrayRegion(input, 0, count, pcm.data());
    if (env->ExceptionCheck()) throw std::runtime_error("Cannot read PCM input");
    for (float v : pcm) {
        if (!std::isfinite(v) || v < -1.0f || v > 1.0f)
            throw std::runtime_error("Audio must be finite Float32 in [-1,1]");
    }
    return pcm;
}
