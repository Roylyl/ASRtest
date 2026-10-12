#include "trace.h"
#include "whisper.h"
#include <fstream>
#include <vector>
#include <iostream>
int main(int argc,char ** argv){
 if(argc!=5){std::cerr<<"model raw_float32 output_json model_id\n";return 2;}
 std::ifstream audio(argv[2],std::ios::binary|std::ios::ate);size_t length=audio.tellg();audio.seekg(0);std::vector<float> pcm(length/sizeof(float));audio.read(reinterpret_cast<char *>(pcm.data()),length);
 auto cp=whisper_context_default_params();cp.use_gpu=false;cp.flash_attn=false;auto * ctx=whisper_init_from_file_with_params(argv[1],cp);if(!ctx)return 3;
 auto options=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);options.n_threads=2;options.translate=false;options.no_context=true;options.print_realtime=false;options.print_progress=false;options.print_timestamps=false;options.print_special=false;options.temperature=0;options.temperature_inc=0;options.language="auto";
 profileReset();int code=whisper_full(ctx,options,pcm.data(),pcm.size());std::string text;int tokens=0;if(code==0)for(int i=0;i<whisper_full_n_segments(ctx);i++){text+=whisper_full_get_segment_text(ctx,i);tokens+=whisper_full_n_tokens(ctx,i);}
 profileWrite(argv[3],argv[4],code,text,pcm.size(),tokens);whisper_print_timings(ctx);whisper_free(ctx);return code==0?0:4;
}
