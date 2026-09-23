#ifndef ASRTEST_WATCH_WHISPER_H
#define ASRTEST_WATCH_WHISPER_H
#ifdef __cplusplus
extern "C" {
#endif
void *asr_watch_whisper_create(const char *model_path);
int asr_watch_whisper_transcribe(void *context, const float *pcm, int sample_count,
                                 int threads, const char *language, char *output, int output_capacity);
void asr_watch_whisper_destroy(void *context);
#ifdef __cplusplus
}
#endif
#endif
