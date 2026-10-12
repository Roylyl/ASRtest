#include <stdio.h>
#include <string.h>
#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>
#include <whisper/whisper.h>
#include "vosk_api.h"
int main(int argc, char**argv) {
 if(argc!=2)return 64;
 char enc[2048],dec[2048],join[2048],tok[2048],wm[2048],vm[2048];
 snprintf(enc,sizeof(enc),"%s/zipformer/encoder-epoch-99-avg-1.int8.onnx",argv[1]);
 snprintf(dec,sizeof(dec),"%s/zipformer/decoder-epoch-99-avg-1.onnx",argv[1]);
 snprintf(join,sizeof(join),"%s/zipformer/joiner-epoch-99-avg-1.int8.onnx",argv[1]);
 snprintf(tok,sizeof(tok),"%s/zipformer/tokens.txt",argv[1]);
 snprintf(wm,sizeof(wm),"%s/whisperTiny/ggml-tiny.bin",argv[1]);
 snprintf(vm,sizeof(vm),"%s/voskEnglish",argv[1]);
 SherpaOnnxOnlineRecognizerConfig c={0};
 c.feat_config.sample_rate=16000;c.feat_config.feature_dim=80;
 c.model_config.transducer.encoder=enc;c.model_config.transducer.decoder=dec;c.model_config.transducer.joiner=join;
 c.model_config.tokens=tok;c.model_config.num_threads=1;c.model_config.provider="cpu";c.model_config.model_type="zipformer";
 c.decoding_method="greedy_search";c.max_active_paths=4;
 const SherpaOnnxOnlineRecognizer*r=SherpaOnnxCreateOnlineRecognizer(&c);
 if(!r){puts("sherpa create failed");return 1;}
 const SherpaOnnxOnlineStream*s=SherpaOnnxCreateOnlineStream(r);
 if(!s){SherpaOnnxDestroyOnlineRecognizer(r);return 2;}
 SherpaOnnxDestroyOnlineStream(s);SherpaOnnxDestroyOnlineRecognizer(r);puts("sherpa create/stream/free PASS");
 struct whisper_context_params p=whisper_context_default_params();p.use_gpu=false;
 struct whisper_context*w=whisper_init_from_file_with_params(wm,p);
 if(!w){puts("whisper create failed");return 3;}whisper_free(w);puts("whisper create/free PASS");
 vosk_set_log_level(-1);VoskModel*v=vosk_model_new(vm);
 if(!v){puts("vosk create failed");return 4;}
 VoskRecognizer*vr=vosk_recognizer_new(v,16000);
 if(!vr){vosk_model_free(v);return 5;}
 vosk_recognizer_free(vr);vosk_model_free(v);puts("vosk create/recognizer/free PASS");
 puts("ALL THREE RUNTIMES PASS");return 0;
}
