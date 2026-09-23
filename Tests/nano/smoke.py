#!/usr/bin/env python3
"""Exercise the same C ABI on macOS; does not substitute for iPhone validation."""
from pathlib import Path
import ctypes as C
import json
import resource
import struct
import threading
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK = ROOT / "Packages/NanoRuntime/.build-native/macosx/Release/CNano.framework/CNano"
MODEL = ROOT / "ModelLibrary/nano"
lib = C.CDLL(str(FRAMEWORK))
cancel_type = C.CFUNCTYPE(C.c_int32, C.c_void_p)
cancelled = threading.Event()
@cancel_type
def callback(_): return int(cancelled.is_set())

lib.asr_nano_open.argtypes = [C.c_char_p, C.c_char_p, C.c_char_p, C.c_char_p, C.c_int32, cancel_type, C.c_void_p, C.c_char_p, C.c_size_t]
lib.asr_nano_open.restype = C.c_void_p
lib.asr_nano_transcribe.argtypes = [C.c_void_p, C.POINTER(C.c_float), C.c_size_t]
lib.asr_nano_transcribe.restype = C.c_int32
for name in ["asr_nano_text", "asr_nano_error"]:
    fn = getattr(lib, name)
    fn.argtypes = [C.c_void_p]; fn.restype = C.c_char_p
lib.asr_nano_close.argtypes = [C.c_void_p]
error = C.create_string_buffer(1024)
begin = time.monotonic()
handle = lib.asr_nano_open(str(MODEL / "funasr-encoder-f16.gguf").encode(), str(MODEL / "qwen3-0.6b-q4km.gguf").encode(), str(MODEL / "fsmn-vad.gguf").encode(), "中文".encode(), 2, callback, None, error, len(error))
assert handle, error.value.decode()
report = {"platform": "macOS arm64 (same C ABI; not an iPhone test)", "load_seconds": time.monotonic() - begin, "checks": {}}
try:
    with wave.open(str(ROOT / "Vendor/Fun-ASR/runtime/llama.cpp/tests/sample.wav")) as wav:
        assert (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) == (16000, 1, 2)
        frames = wav.readframes(wav.getnframes())
        values = [v / 32768 for (v,) in struct.iter_unpack("<h", frames)]
    samples = (C.c_float * len(values))(*values)
    begin = time.monotonic()
    assert lib.asr_nano_transcribe(handle, samples, len(samples)) == 0, lib.asr_nano_error(handle)
    report["transcribe_seconds"] = time.monotonic() - begin
    text = lib.asr_nano_text(handle).decode()
    report["transcript"] = text
    assert "滨海新区" in text and "有房" in text, text
    report["checks"]["official_sample_contains_expected_words"] = True
    assert lib.asr_nano_transcribe(handle, None, 0) == 0
    assert lib.asr_nano_text(handle) == b""
    report["checks"]["empty_input_clears_previous_result"] = True
    silent = (C.c_float * 16000)()
    assert lib.asr_nano_transcribe(handle, silent, len(silent)) == 0
    assert lib.asr_nano_text(handle) == b""
    report["checks"]["silence_produces_no_text"] = True
    invalid = (C.c_float * 1)(float("nan"))
    assert lib.asr_nano_transcribe(handle, invalid, 1) == -1
    report["checks"]["nonfinite_input_rejected"] = True
    cancelled.set()
    assert lib.asr_nano_transcribe(handle, samples, len(samples)) == -2
    cancelled.clear()
    report["checks"]["pre_cancel"] = True
    timer = threading.Timer(0.15, cancelled.set)
    timer.start()
    begin = time.monotonic()
    try:
        assert lib.asr_nano_transcribe(handle, samples, len(samples)) == -2, lib.asr_nano_error(handle)
    finally:
        timer.join()
    report["cancel_seconds"] = time.monotonic() - begin
    assert lib.asr_nano_text(handle) == b""
    report["checks"]["cancel_during_compute"] = True
    cancelled.clear()
    assert lib.asr_nano_transcribe(handle, samples, len(samples)) == 0, lib.asr_nano_error(handle)
    assert lib.asr_nano_text(handle).decode() == text
    report["checks"]["reusable_after_cancel"] = True
finally:
    lib.asr_nano_close(handle)
report["maximum_resident_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
(ROOT / "Tests/nano/macos-results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(report, indent=2, ensure_ascii=False))
