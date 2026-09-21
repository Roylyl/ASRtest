// SPDX-License-Identifier: Apache-2.0
// Adapted from Apache-2.0 QwenAudio/Fun-ASR at 0339018ba74a7defa3b6b6a96718d17b816be77b
// funasr-cli: end-to-end Fun-ASR-Nano in C++ on the llama.cpp / ggml stack.
//
//   wav(16k mono) -> kaldi fbank -> SAN-M encoder + adaptor (ggml) ->
//   low-frame-rate truncation -> [prefix tokens | audio embeds | suffix tokens]
//   -> Qwen3 LLM (llama.cpp) -> transcription.
//
// This is the whisper.cpp-style single-binary path: no Python at runtime.
//
//   funasr-cli --enc funasr-encoder.gguf -m qwen3-0.6b.gguf -a audio.wav
//
// Streaming (--stream): 16 kHz s16le mono PCM on stdin, models load once, emits
//   READY           after all models are loaded and stdin can accept audio
//   LOCKED <text>   DynamicStreamingVAD-confirmed segment (committed, like python)
//   PARTIAL <text>  unstable transcript of the in-progress segment (or empty when it ends)
//   DONE            after stdin EOF + trailing-segment flush
// Audio is analyzed at the documented 720ms SDK cadence. Partial decode is
// latest-wins, so a slow preview never blocks PCM ingestion or delays a final segment.

#include "ggml.h"
#include "ggml-cpu.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "gguf.h"
#include "llama.h"

#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// any audio (wav/mp3/flac, any rate/channels) -> 16 kHz mono f32, via miniaudio
#include "asr_nano.h"
#include <algorithm>
#include <memory>
#include <stdexcept>
// built-in FSMN-VAD front end (single-binary --vad segmentation)
#include "funasr_vad.h"
#include <utility>

// ======================= kaldi fbank + LFR =======================
static const int FS=16000, WINLEN=400, SHIFT=160, NFFT=512, NMEL=80, LFR_M=7, LFR_N=6;
static const float PREEMPH=0.97f, LOWF=20.0f, HIGHF=8000.0f;
static inline float mel(float f){ return 1127.0f*logf(1.0f+f/700.0f); }
static void fft(std::vector<float>&re,std::vector<float>&im,int n){
    for(int i=1,j=0;i<n;i++){int b=n>>1;for(;j&b;b>>=1)j^=b;j^=b;if(i<j){std::swap(re[i],re[j]);std::swap(im[i],im[j]);}}
    for(int len=2;len<=n;len<<=1){double a=-2.0*M_PI/len;float wr=cosf(a),wi=sinf(a);
        for(int i=0;i<n;i+=len){float cr=1,ci=0;for(int k=0;k<len/2;k++){
            float ur=re[i+k],ui=im[i+k];float vr=re[i+k+len/2]*cr-im[i+k+len/2]*ci,vi=re[i+k+len/2]*ci+im[i+k+len/2]*cr;
            re[i+k]=ur+vr;im[i+k]=ui+vi;re[i+k+len/2]=ur-vr;im[i+k+len/2]=ui-vi;
            float n2=cr*wr-ci*wi;ci=cr*wi+ci*wr;cr=n2;}}}
}
// returns [T x 560] row-major, sets T
static std::vector<float> compute_fbank(std::vector<float> wav, int & T_out) {
    for (auto & v : wav) v *= 32768.0f;
    std::vector<float> win(WINLEN);
    for (int i=0;i<WINLEN;i++) win[i]=0.54f-0.46f*cosf(2.0f*M_PI*i/(WINLEN-1));
    const int NBIN=NFFT/2+1; float bw=(float)FS/NFFT, ml=mel(LOWF), mh=mel(HIGHF), dm=(mh-ml)/(NMEL+1);
    std::vector<std::vector<float>> fb(NMEL, std::vector<float>(NBIN,0.0f));
    for(int m=0;m<NMEL;m++){float L=ml+m*dm,C=ml+(m+1)*dm,R=ml+(m+2)*dm;
        for(int k=0;k<NBIN;k++){float mf=mel(bw*k); if(mf>L&&mf<R) fb[m][k]=mf<=C?(mf-L)/(C-L):(R-mf)/(R-C);}}
    int N=wav.size(); int T=(N-WINLEN)/SHIFT+1;
    std::vector<std::vector<float>> feat(T, std::vector<float>(NMEL));
    std::vector<float> re(NFFT),im(NFFT),fr(WINLEN);
    const float fl=1.1920929e-07f;
    for(int t=0;t<T;t++){const float*s=wav.data()+t*SHIFT;
        double mn=0;for(int i=0;i<WINLEN;i++)mn+=s[i];mn/=WINLEN;
        for(int i=0;i<WINLEN;i++)fr[i]=s[i]-(float)mn;
        for(int i=WINLEN-1;i>0;i--)fr[i]-=PREEMPH*fr[i-1];fr[0]-=PREEMPH*fr[0];
        for(int i=0;i<NFFT;i++){re[i]=i<WINLEN?fr[i]*win[i]:0.0f;im[i]=0.0f;}
        fft(re,im,NFFT);
        for(int m=0;m<NMEL;m++){float e=0;for(int k=0;k<NBIN;k++)if(fb[m][k]>0)e+=fb[m][k]*(re[k]*re[k]+im[k]*im[k]);
            feat[t][m]=logf(e>fl?e:fl);}}
    // LFR
    const int pad=(LFR_M-1)/2; int T_lfr=(T+LFR_N-1)/LFR_N;
    std::vector<std::vector<float>> pd; pd.reserve(T+pad+LFR_M);
    for(int i=0;i<pad;i++)pd.push_back(feat[0]);
    for(int t=0;t<T;t++)pd.push_back(feat[t]);
    while((int)pd.size()<(T_lfr-1)*LFR_N+LFR_M)pd.push_back(feat[T-1]);
    int D=LFR_M*NMEL; std::vector<float> out((size_t)T_lfr*D);
    for(int i=0;i<T_lfr;i++)for(int j=0;j<LFR_M;j++)
        memcpy(&out[(size_t)i*D+j*NMEL],pd[i*LFR_N+j].data(),NMEL*sizeof(float));
    T_out=T_lfr; return out;
}

// ======================= ggml SAN-M encoder + adaptor =======================
struct cfg { int d_model=512,n_head=4,num_blocks=50,tp_blocks=20,kernel=11,adp_llm=1024,adp_layers=2,adp_head=8; };
struct enc_model { cfg c; int threads=2; asr_nano_cancel_callback cancel=nullptr; void* cancel_user=nullptr; ggml_context*ctx_w=nullptr; std::map<std::string,ggml_tensor*> t;
    ggml_tensor* g(const std::string&n){auto it=t.find(n);if(it==t.end()){throw std::runtime_error("Missing encoder tensor: " + n);}return it->second;} };
static bool nano_abort(void * data) {
    auto * m = static_cast<enc_model *>(data);
    return m->cancel && m->cancel(m->cancel_user);
}
static const float LN_EPS=1e-5f;
static bool load_enc(const char*p, enc_model&m){
    gguf_init_params gp={false,&m.ctx_w}; gguf_context*g=gguf_init_from_file(p,gp); if(!g)return false;
    auto rd=[&](const char*k,int d){int i=gguf_find_key(g,k);return i<0?d:(int)gguf_get_val_u32(g,i);};
    m.c.d_model=rd("funasr.enc.output_size",512); m.c.n_head=rd("funasr.enc.attention_heads",4);
    m.c.num_blocks=rd("funasr.enc.num_blocks",50); m.c.tp_blocks=rd("funasr.enc.tp_blocks",20);
    m.c.kernel=rd("funasr.enc.kernel_size",11); m.c.adp_llm=rd("funasr.adp.llm_dim",1024);
    m.c.adp_layers=rd("funasr.adp.n_layer",2); m.c.adp_head=rd("funasr.adp.attention_heads",8);
    int n=gguf_get_n_tensors(g); for(int i=0;i<n;i++){const char*nm=gguf_get_tensor_name(g,i);m.t[nm]=ggml_get_tensor(m.ctx_w,nm);}
    gguf_free(g);
    if (m.c.d_model!=512 || m.c.n_head!=4 || m.c.num_blocks!=50 || m.c.tp_blocks!=20 ||
        m.c.kernel!=11 || m.c.adp_llm!=1024 || m.c.adp_layers!=2 || m.c.adp_head!=8)
        throw std::runtime_error("Unsupported Nano encoder architecture");
    return true;
}
static ggml_tensor* lin(ggml_context*c,ggml_tensor*w,ggml_tensor*b,ggml_tensor*x){auto y=ggml_mul_mat(c,w,x);return b?ggml_add(c,y,b):y;}
static ggml_tensor* lnorm(ggml_context*c,ggml_tensor*x,ggml_tensor*g,ggml_tensor*b){return ggml_add(c,ggml_mul(c,ggml_norm(c,x,LN_EPS),g),b);}
static ggml_tensor* sanm_attn(ggml_context*c,enc_model&m,const std::string&p,ggml_tensor*x,int T){
    const int D=m.c.d_model,H=m.c.n_head,dk=D/H,K=m.c.kernel;
    ggml_tensor*qkv=lin(c,m.g(p+"linear_q_k_v.weight"),m.g(p+"linear_q_k_v.bias"),x); size_t nb1=qkv->nb[1];
    ggml_tensor*q=ggml_cont(c,ggml_view_2d(c,qkv,D,T,nb1,0));
    ggml_tensor*k=ggml_cont(c,ggml_view_2d(c,qkv,D,T,nb1,(size_t)D*sizeof(float)));
    ggml_tensor*v=ggml_cont(c,ggml_view_2d(c,qkv,D,T,nb1,(size_t)2*D*sizeof(float)));
    const int pad=(K-1)/2; ggml_tensor*fk=m.g(p+"fsmn_block.weight");
    ggml_tensor*vp=ggml_pad_ext(c,v,0,0,pad,pad,0,0,0,0); ggml_tensor*fsmn=v;
    for(int j=0;j<K;j++){auto sl=ggml_view_2d(c,vp,D,T,vp->nb[1],(size_t)j*vp->nb[1]);
        auto wj=ggml_view_1d(c,fk,D,(size_t)j*fk->nb[1]); fsmn=ggml_add(c,fsmn,ggml_mul(c,ggml_cont(c,sl),wj));}
    q=ggml_permute(c,ggml_reshape_3d(c,q,dk,H,T),0,2,1,3); k=ggml_permute(c,ggml_reshape_3d(c,k,dk,H,T),0,2,1,3);
    ggml_tensor*vh=ggml_cont(c,ggml_permute(c,ggml_reshape_3d(c,v,dk,H,T),1,2,0,3));
    ggml_tensor*kq=ggml_soft_max(c,ggml_scale(c,ggml_mul_mat(c,k,q),1.0f/sqrtf((float)dk)));
    ggml_tensor*o=ggml_cont_2d(c,ggml_permute(c,ggml_mul_mat(c,vh,kq),0,2,1,3),D,T);
    return ggml_add(c,lin(c,m.g(p+"linear_out.weight"),m.g(p+"linear_out.bias"),o),fsmn);
}
static ggml_tensor* sanm_layer(ggml_context*c,enc_model&m,const std::string&p,ggml_tensor*x,int T,bool res){
    auto r=x; auto h=lnorm(c,x,m.g(p+"norm1.weight"),m.g(p+"norm1.bias"));
    auto sa=sanm_attn(c,m,p+"self_attn.",h,T); x=res?ggml_add(c,r,sa):sa; r=x;
    h=lnorm(c,x,m.g(p+"norm2.weight"),m.g(p+"norm2.bias"));
    h=lin(c,m.g(p+"feed_forward.w_1.weight"),m.g(p+"feed_forward.w_1.bias"),h); h=ggml_relu(c,h);
    h=lin(c,m.g(p+"feed_forward.w_2.weight"),m.g(p+"feed_forward.w_2.bias"),h); return ggml_add(c,r,h);
}
static ggml_tensor* adp_layer(ggml_context*c,enc_model&m,const std::string&p,ggml_tensor*x,int T){
    const int D=m.c.adp_llm,H=m.c.adp_head,dk=D/H; auto r=x;
    auto h=lnorm(c,x,m.g(p+"norm1.weight"),m.g(p+"norm1.bias"));
    auto q=ggml_permute(c,ggml_reshape_3d(c,lin(c,m.g(p+"self_attn.linear_q.weight"),m.g(p+"self_attn.linear_q.bias"),h),dk,H,T),0,2,1,3);
    auto k=ggml_permute(c,ggml_reshape_3d(c,lin(c,m.g(p+"self_attn.linear_k.weight"),m.g(p+"self_attn.linear_k.bias"),h),dk,H,T),0,2,1,3);
    auto vh=ggml_cont(c,ggml_permute(c,ggml_reshape_3d(c,lin(c,m.g(p+"self_attn.linear_v.weight"),m.g(p+"self_attn.linear_v.bias"),h),dk,H,T),1,2,0,3));
    auto kq=ggml_soft_max(c,ggml_scale(c,ggml_mul_mat(c,k,q),1.0f/sqrtf((float)dk)));
    auto o=ggml_cont_2d(c,ggml_permute(c,ggml_mul_mat(c,vh,kq),0,2,1,3),D,T);
    x=ggml_add(c,r,lin(c,m.g(p+"self_attn.linear_out.weight"),m.g(p+"self_attn.linear_out.bias"),o)); r=x;
    h=lnorm(c,x,m.g(p+"norm2.weight"),m.g(p+"norm2.bias"));
    h=lin(c,m.g(p+"feed_forward.w_1.weight"),m.g(p+"feed_forward.w_1.bias"),h); h=ggml_relu(c,h);
    h=lin(c,m.g(p+"feed_forward.w_2.weight"),m.g(p+"feed_forward.w_2.bias"),h); return ggml_add(c,r,h);
}
static void add_posenc(std::vector<float>&x,int T,int depth){
    double inc=log(10000.0)/(depth/2.0-1.0);
    for(int t=0;t<T;t++){double pos=t+1;for(int i=0;i<depth/2;i++){double its=exp(i*-inc),st=pos*its;
        x[(size_t)t*depth+i]+=(float)sin(st);x[(size_t)t*depth+depth/2+i]+=(float)cos(st);}}
}
// fbank [T x F] -> adaptor out [T x adp_llm] row-major
static std::vector<float> run_encoder(enc_model&m,std::vector<float> fbank,int T,int F,int&Dout){
    float sc=sqrtf((float)m.c.d_model); for(auto&v:fbank)v*=sc; add_posenc(fbank,T,F);
    ggml_backend_t be=ggml_backend_cpu_init();
    // no_alloc means this arena holds metadata, not activation tensors.
    size_t arena = ggml_tensor_overhead()*65536 + ggml_graph_overhead_custom(32768, false);
    ggml_init_params cp={arena,nullptr,true}; ggml_context*c=ggml_init(cp);
    if (!be || !c) throw std::runtime_error("Encoder allocation failed");
    auto backend_guard = std::unique_ptr<ggml_backend, decltype(&ggml_backend_free)>(be, ggml_backend_free);
    auto context_guard = std::unique_ptr<ggml_context, decltype(&ggml_free)>(c, ggml_free);
    ggml_tensor*inp=ggml_new_tensor_2d(c,GGML_TYPE_F32,F,T); ggml_set_input(inp);
    ggml_tensor*x=sanm_layer(c,m,"audio_encoder.encoders0.0.",inp,T,false);
    for(int i=0;i<m.c.num_blocks-1;i++) x=sanm_layer(c,m,"audio_encoder.encoders."+std::to_string(i)+".",x,T,true);
    x=lnorm(c,x,m.g("audio_encoder.after_norm.weight"),m.g("audio_encoder.after_norm.bias"));
    for(int i=0;i<m.c.tp_blocks;i++) x=sanm_layer(c,m,"audio_encoder.tp_encoders."+std::to_string(i)+".",x,T,true);
    x=lnorm(c,x,m.g("audio_encoder.tp_norm.weight"),m.g("audio_encoder.tp_norm.bias"));
    x=lin(c,m.g("audio_adaptor.linear1.weight"),m.g("audio_adaptor.linear1.bias"),x); x=ggml_relu(c,x);
    x=lin(c,m.g("audio_adaptor.linear2.weight"),m.g("audio_adaptor.linear2.bias"),x);
    for(int i=0;i<m.c.adp_layers;i++) x=adp_layer(c,m,"audio_adaptor.blocks."+std::to_string(i)+".",x,T);
    ggml_set_output(x);
    ggml_cgraph*gf=ggml_new_graph_custom(c,32768,false); ggml_build_forward_expand(gf,x);
    ggml_gallocr_t ga=ggml_gallocr_new(ggml_backend_cpu_buffer_type());
    auto alloc_guard = std::unique_ptr<ggml_gallocr, decltype(&ggml_gallocr_free)>(ga, ggml_gallocr_free);
    if (!ggml_gallocr_alloc_graph(ga,gf)) throw std::runtime_error("Encoder compute buffer allocation failed");
    ggml_backend_tensor_set(inp,fbank.data(),0,ggml_nbytes(inp));
    ggml_backend_cpu_set_n_threads(be,m.threads);
    ggml_backend_cpu_set_abort_callback(be,nano_abort,&m);
    auto status = ggml_backend_graph_compute(be,gf);
    if (status != GGML_STATUS_SUCCESS) throw std::runtime_error(nano_abort(&m) ? "cancelled" : "Encoder computation failed");
    Dout=(int)x->ne[0]; std::vector<float> out((size_t)Dout*T); ggml_backend_tensor_get(x,out.data(),0,ggml_nbytes(x));
    return out;
}

// ======================= LLM (llama.cpp) =======================
static int decode_batch(llama_context*ctx,int n,llama_token*tok,float*embd,int n_embd,int&n_past,bool last_logits){
    std::vector<llama_pos> pos(n); std::vector<int32_t> nsid(n,1);
    std::vector<llama_seq_id> s0(1,0); std::vector<llama_seq_id*> sid(n); std::vector<int8_t> lg(n,0);
    for(int i=0;i<n;i++){pos[i]=n_past+i;sid[i]=s0.data();}
    if(last_logits) lg[n-1]=1;
    llama_batch b={n,tok,embd,pos.data(),nsid.data(),sid.data(),lg.data()};
    int r=llama_decode(ctx,b);
    if (r != 0) throw std::runtime_error(r == 2 ? "cancelled" : "LLM decode failed");
    n_past+=n; return r;
}

// ---- encoder + LLM bundle, loaded once, reused per decode window ----
struct asr_decoder {
    enc_model em;
    llama_model* model=nullptr;
    const llama_vocab* vocab=nullptr;
    llama_context* ctx=nullptr;
    llama_sampler* smpl=nullptr;
    std::vector<llama_token> pre, suf;
};
static void free_decoder(asr_decoder&d){
    if(d.smpl) llama_sampler_free(d.smpl);
    if(d.ctx) llama_free(d.ctx);
    if(d.model) llama_model_free(d.model);
    if(d.em.ctx_w) ggml_free(d.em.ctx_w);
    d = asr_decoder{};
}
static bool load_decoder(const char*enc_path, const char*llm_path, float rep,
                         const std::string&lang, asr_decoder&d){
    if(!load_enc(enc_path,d.em)) return false;
    ggml_backend_load_all();
    llama_model_params mp=llama_model_default_params();
mp.n_gpu_layers=0;
    mp.use_extra_bufts=false; // Keep quantized weights mmap-backed; avoid a second repacked copy.
    mp.progress_callback=[](float, void * data) { return !nano_abort(data); };
    mp.progress_callback_user_data=&d.em;
    d.model=llama_model_load_from_file(llm_path,mp); if(!d.model) return false;
    d.vocab=llama_model_get_vocab(d.model);
    llama_context_params cp=llama_context_default_params();
    cp.n_ctx=512; cp.n_batch=256; cp.n_ubatch=128; cp.n_outputs_max=1;
    cp.n_threads=d.em.threads; cp.n_threads_batch=d.em.threads;
    cp.abort_callback=nano_abort; cp.abort_callback_data=&d.em;
    d.ctx=llama_init_from_model(d.model,cp);
    if(!d.ctx){fprintf(stderr,"failed to create llama context\n");return false;}
    auto sp=llama_sampler_chain_default_params(); d.smpl=llama_sampler_chain_init(sp);
    if(rep!=1.0f) llama_sampler_chain_add(d.smpl,llama_sampler_init_penalties(256,rep,0.0f,0.0f));
    llama_sampler_chain_add(d.smpl,llama_sampler_init_greedy());
    // prompt mirrors FunASRNano.get_prompt(): 语音转写：" / 语音转写成<lang>："
    std::string prefix="<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\n语音转写";
    if(!lang.empty()) prefix+="成"+lang;
    prefix+="：";
    const char*suffix="<|im_end|>\n<|im_start|>assistant\n";
    auto tokenize=[&](const std::string&s){int n=-llama_tokenize(d.vocab,s.c_str(),s.size(),nullptr,0,false,true);
        std::vector<llama_token> v(n); llama_tokenize(d.vocab,s.c_str(),s.size(),v.data(),n,false,true); return v;};
    d.pre=tokenize(prefix); d.suf=tokenize(suffix);
    return true;
}
// Decode one 16k-mono window (seconds*16000 samples, [-1,1]) into text.
static std::string asr_decode_window(asr_decoder&d, const float*pcm, size_t n, int npred){
    if (nano_abort(&d.em)) throw std::runtime_error("cancelled");
    std::vector<float> seg(pcm, pcm+n);
    int T=0; auto fbank=compute_fbank(seg,T);
    int D=0; auto adp=run_encoder(d.em,fbank,T,560,D);
    int ol=1+(T-3+2)/2; ol=1+(ol-3+2)/2; int n_aud=(ol-1)/2+1;
    if (n_aud < 1 || n_aud > T || D != llama_model_n_embd(d.model))
        throw std::runtime_error("Incompatible audio embeddings");
    llama_sampler_reset(d.smpl);

    llama_memory_clear(llama_get_memory(d.ctx), true);  // fresh context per chunk
    int n_past=0;
    decode_batch(d.ctx,d.pre.size(),d.pre.data(),nullptr,0,n_past,false);
    decode_batch(d.ctx,n_aud,nullptr,adp.data(),D,n_past,false);
    decode_batch(d.ctx,d.suf.size(),d.suf.data(),nullptr,0,n_past,true);
    std::string out;
    llama_token tk=llama_sampler_sample(d.smpl,d.ctx,-1);
    for(int i=0;i<npred;i++){
        if (nano_abort(&d.em)) throw std::runtime_error("cancelled");
        if(llama_vocab_is_eog(d.vocab,tk))break;
        char buf[256]; int k=llama_token_to_piece(d.vocab,tk,buf,sizeof(buf),0,true);
        if(k>0) out.append(buf,k);
        decode_batch(d.ctx,1,&tk,nullptr,0,n_past,true);
        tk=llama_sampler_sample(d.smpl,d.ctx,-1);
    }
    return out;
}

// ---- text cleanup, mirroring serve_realtime_ws.py ----
// _clean_asr_text(): strip <tags>, [brackets], a few artifact chars/tokens, collapse spaces.
static std::string clean_asr_text(const std::string& in){
    std::string s; s.reserve(in.size());
    for(size_t i=0;i<in.size();){
        char c=in[i];
        if(c=='<'){ size_t e=in.find('>',i); if(e!=std::string::npos){ i=e+1; continue; } }
        if(c=='['){ size_t e=in.find(']',i); if(e!=std::string::npos){ i=e+1; continue; } }
        if(c==']'||c=='&'||c=='|'){ i++; continue; }
        // full-width artifacts Ｏ(EF BC AF) ＆(EF BC 86) ｜(EF BD 9C)
        if(i+2<in.size() && (unsigned char)in[i]==0xEF &&
           (((unsigned char)in[i+1]==0xBC && ((unsigned char)in[i+2]==0xAF || (unsigned char)in[i+2]==0x86)) ||
            ((unsigned char)in[i+1]==0xBD && (unsigned char)in[i+2]==0x9C))){ i+=3; continue; }
        s+=c; i++;
    }
    auto erase_all=[&](const char*sub){ size_t p; while((p=s.find(sub))!=std::string::npos) s.erase(p,strlen(sub)); };
    erase_all("/sil"); erase_all("endofbreak"); erase_all("FFFF");
    // collapse whitespace + trim
    std::string t; t.reserve(s.size());
    bool ws=false;
    for(char c:s){ if(c==' '||c=='\t'||c=='\n'||c=='\r'||c=='\f'||c=='\v'){ ws=true; continue; }
        if(ws && !t.empty()) t+=' '; ws=false; t+=c; }
    return t;
}

#include "nano_api.inc"
