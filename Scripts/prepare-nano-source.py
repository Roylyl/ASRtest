#!/usr/bin/env python3
"""Adapt only the pinned official CLI's native inference core; leave vendor pristine."""
from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor/Fun-ASR"
OUT = ROOT / "Packages/NanoRuntime/Sources/CNano"
REV = "0339018ba74a7defa3b6b6a96718d17b816be77b"
LLAMA_REV = "8086439a4cea94c71a5dfb8fe4ad1546aebd640f"
for path, rev in [(VENDOR, REV), (VENDOR / "third_party/llama.cpp", LLAMA_REV)]:
    marker = path / ".asrtest-upstream.json"
    if not marker.is_file() or json.loads(marker.read_text()).get("commit") != rev:
        raise SystemExit(f"Unexpected source revision at {path}")

s = (VENDOR / "runtime/llama.cpp/funasr-cli/funasr-cli.cpp").read_text()
s = s[:s.index('// detect_and_fix_hallucination():')]

def replace(old, new):
    global s
    if s.count(old) != 1:
        raise SystemExit(f"Expected one match: {old[:90]}")
    s = s.replace(old, new)

replace('#define FUNASR_AUDIO_IMPLEMENTATION\n#include "funasr_audio.h"', '#include "asr_nano.h"\n#include <algorithm>\n#include <memory>\n#include <stdexcept>')
replace('struct enc_model { cfg c;', 'struct enc_model { cfg c; int threads=2; asr_nano_cancel_callback cancel=nullptr; void* cancel_user=nullptr;')
replace('fprintf(stderr,"missing %s\\n",n.c_str());exit(1);', 'throw std::runtime_error("Missing encoder tensor: " + n);')
replace('static const float LN_EPS=1e-5f;', '''static bool nano_abort(void * data) {
    auto * m = static_cast<enc_model *>(data);
    return m->cancel && m->cancel(m->cancel_user);
}
static const float LN_EPS=1e-5f;''')
replace('ggml_init_params cp={(size_t)1024*1024*1024,nullptr,true}; ggml_context*c=ggml_init(cp);', '''// no_alloc means this arena holds metadata, not activation tensors.
    size_t arena = ggml_tensor_overhead()*65536 + ggml_graph_overhead_custom(32768, false);
    ggml_init_params cp={arena,nullptr,true}; ggml_context*c=ggml_init(cp);
    if (!be || !c) throw std::runtime_error("Encoder allocation failed");
    auto backend_guard = std::unique_ptr<ggml_backend, decltype(&ggml_backend_free)>(be, ggml_backend_free);
    auto context_guard = std::unique_ptr<ggml_context, decltype(&ggml_free)>(c, ggml_free);''')
replace('ggml_gallocr_t ga=ggml_gallocr_new(ggml_backend_cpu_buffer_type()); ggml_gallocr_alloc_graph(ga,gf);', '''ggml_gallocr_t ga=ggml_gallocr_new(ggml_backend_cpu_buffer_type());
    auto alloc_guard = std::unique_ptr<ggml_gallocr, decltype(&ggml_gallocr_free)>(ga, ggml_gallocr_free);
    if (!ggml_gallocr_alloc_graph(ga,gf)) throw std::runtime_error("Encoder compute buffer allocation failed");''')
replace('ggml_backend_cpu_set_n_threads(be,8); ggml_backend_graph_compute(be,gf);', '''ggml_backend_cpu_set_n_threads(be,m.threads);
    ggml_backend_cpu_set_abort_callback(be,nano_abort,&m);
    auto status = ggml_backend_graph_compute(be,gf);
    if (status != GGML_STATUS_SUCCESS) throw std::runtime_error(nano_abort(&m) ? "cancelled" : "Encoder computation failed");''')
replace('ggml_gallocr_free(ga); ggml_free(c); ggml_backend_free(be); return out;', 'return out;')
start = s.index('#if defined(__APPLE__)')
end = s.index('#endif', start) + len('#endif')
s = s[:start] + '''mp.n_gpu_layers=0;
    mp.use_extra_bufts=false; // Keep quantized weights mmap-backed; avoid a second repacked copy.
    mp.progress_callback=[](float, void * data) { return !nano_abort(data); };
    mp.progress_callback_user_data=&d.em;''' + s[end:]
replace('cp.n_ctx=2048; cp.n_batch=2048; cp.n_ubatch=2048;', '''cp.n_ctx=512; cp.n_batch=256; cp.n_ubatch=128; cp.n_outputs_max=1;
    cp.n_threads=d.em.threads; cp.n_threads_batch=d.em.threads;
    cp.abort_callback=nano_abort; cp.abort_callback_data=&d.em;''')
replace('int r=llama_decode(ctx,b); n_past+=n; return r;', '''int r=llama_decode(ctx,b);
    if (r != 0) throw std::runtime_error(r == 2 ? "cancelled" : "LLM decode failed");
    n_past+=n; return r;''')
replace('std::vector<float> seg(pcm, pcm+n);', '''if (nano_abort(&d.em)) throw std::runtime_error("cancelled");
    std::vector<float> seg(pcm, pcm+n);''')
replace('for(int i=0;i<npred;i++){', '''for(int i=0;i<npred;i++){
        if (nano_abort(&d.em)) throw std::runtime_error("cancelled");''')
replace('int ol=1+(T-3+2)/2; ol=1+(ol-3+2)/2; int n_aud=(ol-1)/2+1;', '''int ol=1+(T-3+2)/2; ol=1+(ol-3+2)/2; int n_aud=(ol-1)/2+1;
    if (n_aud < 1 || n_aud > T || D != llama_model_n_embd(d.model))
        throw std::runtime_error("Incompatible audio embeddings");
    llama_sampler_reset(d.smpl);''')
# Unexpected encoder architectures must not reach graph construction with arbitrary dimensions.
replace('gguf_free(g); return true;', '''gguf_free(g);
    if (m.c.d_model!=512 || m.c.n_head!=4 || m.c.num_blocks!=50 || m.c.tp_blocks!=20 ||
        m.c.kernel!=11 || m.c.adp_llm!=1024 || m.c.adp_layers!=2 || m.c.adp_head!=8)
        throw std::runtime_error("Unsupported Nano encoder architecture");
    return true;''')
s = '// SPDX-License-Identifier: Apache-2.0\n// Adapted from Apache-2.0 QwenAudio/Fun-ASR at ' + REV + '\n' + s
s += '\n#include "nano_api.inc"\n'
if not (OUT / "nano_core.cpp").exists() or (OUT / "nano_core.cpp").read_text() != s:
    (OUT / "nano_core.cpp").write_text(s)
vad_source = VENDOR / "runtime/llama.cpp/funasr-common/funasr_vad.h"
if not (OUT / "funasr_vad.h").exists() or (OUT / "funasr_vad.h").read_bytes() != vad_source.read_bytes():
    shutil.copyfile(vad_source, OUT / "funasr_vad.h")
shutil.copyfile(VENDOR / "LICENSE", ROOT / "Packages/NanoRuntime/LICENSE-Fun-ASR")
shutil.copyfile(VENDOR / "third_party/llama.cpp/LICENSE", ROOT / "Packages/NanoRuntime/LICENSE-llama.cpp")
print("Prepared Nano native inference core from pinned sources")
