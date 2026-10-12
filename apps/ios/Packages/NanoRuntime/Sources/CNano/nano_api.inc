struct asr_nano_context {
    asr_decoder decoder;
    std::string vad_path;
    std::string text;
    std::string error;
    ~asr_nano_context() { free_decoder(decoder); }
};

static void nano_check_cancel(const enc_model & m) {
    if (m.cancel && m.cancel(m.cancel_user)) throw std::runtime_error("cancelled");
}

extern "C" ASR_NANO_API asr_nano_context * asr_nano_open(
    const char * encoder, const char * decoder, const char * vad, const char * language,
    int32_t threads, asr_nano_cancel_callback cancel, void * user, char * error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    try {
        if (!encoder || !decoder) throw std::runtime_error("Missing model path");
        auto handle = std::make_unique<asr_nano_context>();
        auto & em = handle->decoder.em;
        em.threads = std::max(1, std::min(threads, 4));
        em.cancel = cancel;
        em.cancel_user = user;
        nano_check_cancel(em);
        if (!load_decoder(encoder, decoder, 1.0f, language ? language : "", handle->decoder)) {
            nano_check_cancel(em);
            throw std::runtime_error("Could not load the Fun-ASR-Nano encoder or decoder");
        }
        nano_check_cancel(em);
        handle->vad_path = vad ? vad : "";
        return handle.release();
    } catch (const std::exception & ex) {
        if (error && capacity) snprintf(error, capacity, "%s", ex.what());
        return nullptr;
    } catch (...) {
        if (error && capacity) snprintf(error, capacity, "Unknown native model loading error");
        return nullptr;
    }
}

extern "C" ASR_NANO_API int32_t asr_nano_transcribe(asr_nano_context * h, const float * samples, size_t count) {
    if (!h) return -1;
    h->text.clear(); h->error.clear();
    try {
        nano_check_cancel(h->decoder.em);
        if ((!samples && count) || count > 30 * 16000) throw std::runtime_error("Nano accepts at most 30 seconds per recording");
        for (size_t i = 0; i < count; ++i) {
            if (!std::isfinite(samples[i]) || samples[i] < -1.0f || samples[i] > 1.0f)
                throw std::runtime_error("Audio must be finite Float32 samples in [-1,1]");
        }
        if (count < WINLEN) return 0;
        std::vector<std::pair<size_t, size_t>> windows;
        if (!h->vad_path.empty()) {
            std::vector<float> pcm(samples, samples + count);
            std::vector<std::pair<int, int>> segments;
            if (!funasr_vad_segments(h->vad_path, pcm, 10000, segments, h->decoder.em.threads))
                throw std::runtime_error("FSMN-VAD inference failed");
            nano_check_cancel(h->decoder.em);
            for (auto & s : segments) {
                size_t start = std::min(count, size_t(std::max(0, s.first)) * 16);
                size_t end = std::min(count, size_t(std::max(0, s.second)) * 16);
                if (end > start) windows.push_back({start, end});
            }
        } else {
            windows.push_back({0, count});
        }
        for (auto & window : windows) {
            for (size_t start = window.first; start < window.second; start += 10 * 16000) {
                nano_check_cancel(h->decoder.em);
                size_t length = std::min(size_t(10 * 16000), window.second - start);
                if (length < WINLEN) continue;
                auto text = clean_asr_text(asr_decode_window(h->decoder, samples + start, length, 256));
                nano_check_cancel(h->decoder.em);
                if (!text.empty()) {
                    if (!h->text.empty()) h->text += "\n";
                    h->text += text;
                }
            }
        }
        return 0;
    } catch (const std::exception & ex) {
        h->text.clear(); h->error = ex.what();
        return h->error == "cancelled" ? -2 : -1;
    } catch (...) {
        h->text.clear(); h->error = "Unknown native inference error";
        return -1;
    }
}
extern "C" ASR_NANO_API const char * asr_nano_text(const asr_nano_context * h) { return h ? h->text.c_str() : ""; }
extern "C" ASR_NANO_API const char * asr_nano_error(const asr_nano_context * h) { return h ? h->error.c_str() : "Invalid Nano context"; }
extern "C" ASR_NANO_API void asr_nano_close(asr_nano_context * h) { delete h; }
