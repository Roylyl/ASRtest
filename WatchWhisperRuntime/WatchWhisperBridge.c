#include "WatchWhisper.h"
#include "whisper.h"
#include <string.h>
#include <limits.h>

void *asr_watch_whisper_create(const char *model_path) {
    if (!model_path) return NULL;
    return whisper_init_from_file_with_params(model_path, whisper_context_default_params());
}

int asr_watch_whisper_transcribe(void *opaque, const float *pcm, int sample_count,
                                 int threads, const char *language, char *output, int output_capacity) {
    if (!opaque || !pcm || sample_count <= 0 || !output || output_capacity <= 0) return -1;
    output[0] = '\0';
    struct whisper_context *ctx = (struct whisper_context *) opaque;
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_context = true;
    params.n_threads = threads < 1 ? 1 : (threads > 2 ? 2 : threads);
    params.language = language && language[0] ? language : "auto";
    if (whisper_full(ctx, params, pcm, sample_count) != 0) return -2;
    int used = 0;
    const int segments = whisper_full_n_segments(ctx);
    for (int i = 0; i < segments; i++) {
        const char *part = whisper_full_get_segment_text(ctx, i);
        if (!part) continue;
        size_t length = strlen(part);
        if (length > (size_t)(output_capacity - used - 1)) return -3;
        memcpy(output + used, part, length);
        used += (int)length;
        output[used] = '\0';
    }
    return 0;
}

void asr_watch_whisper_destroy(void *opaque) {
    if (opaque) whisper_free((struct whisper_context *) opaque);
}
