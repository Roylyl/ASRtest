#include "trace.h"
#include "asr_nano.h"
#include <fstream>
#include <vector>
#include <iostream>
int main(int argc,char **argv){
 if(argc!=6){std::cerr<<"encoder decoder vad raw_float32 output_json\n";return 2;}
 std::ifstream audio(argv[4],std::ios::binary|std::ios::ate);size_t length=audio.tellg();audio.seekg(0);std::vector<float> pcm(length/sizeof(float));audio.read(reinterpret_cast<char *>(pcm.data()),length);
 char error[1024]{};auto * ctx=asr_nano_open(argv[1],argv[2],argv[3],"",2,nullptr,nullptr,error,sizeof(error));if(!ctx){std::cerr<<error;return 3;}
 profileReset();int code=asr_nano_transcribe(ctx,pcm.data(),pcm.size());profileWrite(argv[5],"nano",code,asr_nano_text(ctx),pcm.size(),-1);if(code!=0)std::cerr<<asr_nano_error(ctx);asr_nano_close(ctx);return code==0?0:4;
}
