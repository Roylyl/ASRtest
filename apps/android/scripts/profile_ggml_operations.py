#!/usr/bin/env python3
"""Run same-source CPU graph traces in isolated host tools, never modify APK/JNI.

Counters report partial logical arithmetic operations. They are not phone FLOPS,
MIPS, a complete operator count, or counts derived from parameters/runtime.
"""
from pathlib import Path
import argparse
import array
import json
import shutil
import subprocess
import sys
import wave

from project_paths import APP_ROOT, REPO_ROOT, MODEL_LIBRARY, DEMO_CORPUS, WHISPER_SOURCE, LLAMA_SOURCE, android_sdk, repo_relative

ROOT = APP_ROOT
TOOLS = ROOT / 'scripts/flops-attempt'
OUT = ROOT / 'results/flops-attempt'
CMAKE = android_sdk() / 'cmake/3.22.1/bin/cmake'
NINJA = CMAKE.with_name('ninja')


def run(command, log):
    print(' '.join(map(str, command)), flush=True)
    with log.open('w') as stream:
        subprocess.run(list(map(str, command)), stdout=stream, stderr=subprocess.STDOUT, check=True)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Source trace insertion must match exactly once: ' + old[:90])
    return text.replace(old, new)


def cmake_common():
    return '''cmake_minimum_required(VERSION 3.22)
project(ASROperationTrace LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_BUILD_TYPE Release)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH armv8-a CACHE STRING "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_ACCELERATE OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
'''


def prepare_whisper():
    folder = OUT / 'whisper-source'
    if not folder.exists():
        shutil.copytree(WHISPER_SOURCE, folder, ignore=shutil.ignore_patterns('.git', 'build'))
    original = (WHISPER_SOURCE / 'src/whisper.cpp').read_text()
    traced = '#include "trace.h"\n' + original
    traced = replace_once(traced, 'const bool t = (ggml_backend_sched_graph_compute(sched, graph) == GGML_STATUS_SUCCESS);',
                          'profileGraph(graph, "whisper_graph");\n    const bool t = (ggml_backend_sched_graph_compute(sched, graph) == GGML_STATUS_SUCCESS);')
    (folder / 'src/whisper.cpp').write_text(traced)
    project = OUT / 'whisper-tool'
    project.mkdir(exist_ok=True)
    content = cmake_common() + f'''set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
add_subdirectory("{folder}" whisper-core)
target_include_directories(whisper PRIVATE "{TOOLS}")
add_executable(probe_whisper "{TOOLS}/probe_whisper.cpp" "{TOOLS}/trace.cpp")
target_include_directories(probe_whisper PRIVATE "{TOOLS}")
target_link_libraries(probe_whisper PRIVATE whisper)
'''
    (project / 'CMakeLists.txt').write_text(content)
    return project, 'probe_whisper'


def prepare_nano():
    project = OUT / 'nano-tool'
    project.mkdir(exist_ok=True)
    for name in ('nano_api.inc', 'asr_nano.h'):
        shutil.copy2(ROOT / 'native/nano' / name, project / name)
    source = (ROOT / 'native/nano/nano_core.cpp').read_text()
    source = '#include "trace.h"\n' + source
    source = replace_once(source, 'auto status = ggml_backend_graph_compute(be,gf);',
                          'profileGraph(gf, "nano_encoder_adaptor");\n    auto status = ggml_backend_graph_compute(be,gf);')
    source = replace_once(source, 'cp.abort_callback=nano_abort; cp.abort_callback_data=&d.em;',
                          'cp.abort_callback=nano_abort; cp.abort_callback_data=&d.em;\n    cp.cb_eval=profileEval; cp.cb_eval_user_data=nullptr;')
    source = replace_once(source, 'int r=llama_decode(ctx,b);',
                          'profileBeginGraph("nano_llama_decode_calls");\n    int r=llama_decode(ctx,b);')
    (project / 'nano_core.cpp').write_text(source)
    vad = (ROOT / 'native/nano/funasr_vad.h').read_text()
    vad = replace_once(vad, 'bool ok=ggml_backend_graph_compute(be,gf)==GGML_STATUS_SUCCESS;',
                       'profileGraph(gf, "nano_fsmn_vad");\n  bool ok=ggml_backend_graph_compute(be,gf)==GGML_STATUS_SUCCESS;')
    (project / 'funasr_vad.h').write_text(vad)
    content = cmake_common() + f'''set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(LLAMA_HTTPLIB OFF CACHE BOOL "" FORCE)
add_subdirectory("{LLAMA_SOURCE}" llama-core)
add_executable(probe_nano nano_core.cpp "{TOOLS}/probe_nano.cpp" "{TOOLS}/trace.cpp")
target_include_directories(probe_nano PRIVATE . "{TOOLS}")
target_link_libraries(probe_nano PRIVATE llama ggml)
'''
    (project / 'CMakeLists.txt').write_text(content)
    return project, 'probe_nano'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models', nargs='+', choices=['whisperTiny', 'whisperBase', 'nano'],
                        default=['whisperTiny', 'whisperBase', 'nano'])
    parser.add_argument('--corpus', default='zh_short')
    parser.add_argument('--jobs', default='6')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(DEMO_CORPUS / f'{args.corpus}.wav'), 'rb') as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
            raise ValueError('Trace corpus must be 16kHz mono PCM16')
        integers = array.array('h', audio.readframes(audio.getnframes()))
        if sys.byteorder != 'little':
            integers.byteswap()
    pcm = OUT / f'{args.corpus}.f32'
    array.array('f', (sample / 32768.0 for sample in integers)).tofile(pcm.open('wb'))
    cases = [('whisper', prepare_whisper)] if any(m.startswith('whisper') for m in args.models) else []
    if 'nano' in args.models:
        cases.append(('nano', prepare_nano))
    binaries = {}
    for name, prepare in cases:
        folder, target = prepare()
        build = OUT / f'{name}-build'
        run([CMAKE, '-S', folder, '-B', build, '-G', 'Ninja', f'-DCMAKE_MAKE_PROGRAM={NINJA}'], OUT / f'{name}-configure.log')
        run([CMAKE, '--build', build, '--target', target, '-j', args.jobs], OUT / f'{name}-build.log')
        binaries[name] = build / target
    models = MODEL_LIBRARY
    for model in args.models:
        if model.startswith('whisper'):
            weights = models / model / ('ggml-tiny.bin' if model == 'whisperTiny' else 'ggml-base.bin')
            command = [binaries['whisper'], weights, pcm, OUT / f'{model}-{args.corpus}.json', model]
        else:
            folder = models / 'nano'
            command = [binaries['nano'], folder / 'funasr-encoder-f16.gguf', folder / 'qwen3-0.6b-q4km.gguf',
                       folder / 'fsmn-vad.gguf', pcm, OUT / f'{model}-{args.corpus}.json']
        run(command, OUT / f'{model}-{args.corpus}.log')
        result = json.loads((OUT / f'{model}-{args.corpus}.json').read_text())
        result['execution_location'] = 'macOS CPU same-source probe; not Android timing or hardware instruction measurement'
        result['inference_settings'] = {'threads': 2, 'language': 'auto', 'CPU_only': True,
                                        'Whisper_greedy_temperature': 0,
                                        'Whisper_default_audio_context_seconds': 30}
        (OUT / f'{model}-{args.corpus}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(model, result['status'], result['partial_GOPs'], 'partial GOPs; complete FLOPs unavailable', flush=True)


if __name__ == '__main__':
    main()
