#include "asr_nano.h"
#include "whisper.h"
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

static int32_t never_cancel(void *) { return 0; }
static std::string whisper_text(whisper_context * ctx, const std::vector<float> & audio) {
    auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = 2; p.language = "zh"; p.translate = false;
    p.print_realtime = false; p.print_progress = false; p.print_timestamps = false;
    p.print_special = false; p.no_timestamps = true; p.single_segment = true;
    if (whisper_full(ctx, p, audio.data(), int(audio.size())) != 0) return "";
    std::string result;
    for (int i = 0; i < whisper_full_n_segments(ctx); ++i) result += whisper_full_get_segment_text(ctx, i);
    return result;
}
int main(int argc, char ** argv) {
    if (argc != 2) return 2;
    std::string root = argv[1];
    std::ifstream pcm(root + "/Tests/nano/sample.f32", std::ios::binary | std::ios::ate);
    if (!pcm) return 3;
    auto bytes = pcm.tellg(); pcm.seekg(0);
    std::vector<float> audio(size_t(bytes) / sizeof(float));
    pcm.read(reinterpret_cast<char *>(audio.data()), bytes);
    auto wp = whisper_context_default_params(); wp.use_gpu = false;
    auto * whisper = whisper_init_from_file_with_params((root + "/ModelLibrary/whisperTiny/ggml-tiny.bin").c_str(), wp);
    if (!whisper) return 4;
    std::string before = whisper_text(whisper, audio);
    std::string model = root + "/ModelLibrary/nano/";
    char error[1024] = {};
    auto * nano = asr_nano_open((model + "funasr-encoder-f16.gguf").c_str(),
        (model + "qwen3-0.6b-q4km.gguf").c_str(), (model + "fsmn-vad.gguf").c_str(),
        "中文", 2, never_cancel, nullptr, error, sizeof(error));
    if (!nano) { fprintf(stderr, "%s\n", error); whisper_free(whisper); return 5; }
    int status = asr_nano_transcribe(nano, audio.data(), audio.size());
    std::string nano_text = asr_nano_text(nano);
    std::string after = whisper_text(whisper, audio);
    fprintf(stdout, "WHISPER_BEFORE: %s\nNANO: %s\nWHISPER_AFTER: %s\n", before.c_str(), nano_text.c_str(), after.c_str());
    bool ok = status == 0 && !before.empty() && before == after && nano_text.find("滨海新区") != std::string::npos;
    asr_nano_close(nano); whisper_free(whisper);
    fprintf(stdout, "SIMULATOR_COEXISTENCE_%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 6;
}
