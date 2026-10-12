#ifndef ASR_NANO_H
#define ASR_NANO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define ASR_NANO_API __attribute__((visibility("default")))
typedef struct asr_nano_context asr_nano_context;
typedef int32_t (*asr_nano_cancel_callback)(void * user);
// Call all handle operations on one serial worker. The callback may be called
// by compute workers and must be thread-safe; its user must outlive the handle.
ASR_NANO_API asr_nano_context * asr_nano_open(const char * encoder, const char * decoder,
    const char * vad, const char * language, int32_t threads,
    asr_nano_cancel_callback cancel, void * user, char * error, size_t error_capacity);
// Input is finite 16 kHz mono Float32 in [-1,1], at most 30 seconds.
// 0 success, -1 error, -2 cancelled. A call replaces the previous result.
ASR_NANO_API int32_t asr_nano_transcribe(asr_nano_context *, const float *, size_t count);
ASR_NANO_API const char * asr_nano_text(const asr_nano_context *);
ASR_NANO_API const char * asr_nano_error(const asr_nano_context *);
ASR_NANO_API void asr_nano_close(asr_nano_context *);
#ifdef __cplusplus
}
#endif
#endif
