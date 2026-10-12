#include "trace.h"
#include <atomic>
#include <cstdint>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <vector>
namespace {
std::atomic<bool> enabled{false};
struct Count { uint64_t calls=0, elements=0, operations=0; std::string status; std::vector<std::string> shapes; };
std::map<std::string,Count> counts;
std::map<std::string,uint64_t> graphs;
std::string quote(const std::string & s) {std::ostringstream out;out<<'"';for(unsigned char c:s){if(c=='"'||c=='\\')out<<'\\'<<c;else if(c=='\n')out<<"\\n";else if(c=='\r')out<<"\\r";else if(c=='\t')out<<"\\t";else if(c>=32)out<<c;}out<<'"';return out.str();}
std::string shape(const ggml_tensor * t) {if(!t)return "null";std::ostringstream s;s<<'[';for(int i=0;i<4;i++){if(i)s<<',';s<<t->ne[i];}s<<']';return s.str();}
void node(ggml_tensor * t,const char * stage) {
 if(!enabled.load())return;
 const std::string op=ggml_op_name(t->op);auto & c=counts[std::string(stage)+"/"+op];c.calls++;c.elements+=ggml_nelements(t);
 static const std::set<std::string> simple={"ADD","SUB","MUL","DIV","ADD1","SQR","SCALE"};
 static const std::set<std::string> data={"NONE","DUP","CPY","CONT","RESHAPE","VIEW","PERMUTE","TRANSPOSE","GET_ROWS","SET_ROWS","IM2COL","PAD","REPEAT","CONCAT","DIAG_MASK_INF","DIAG_MASK_ZERO"};
 if(op=="MUL_MAT" && t->src[0]){c.operations+=2ULL*t->src[0]->ne[0]*ggml_nelements(t);c.status="covered_logical_MAC2";}
 else if(simple.count(op)){c.operations+=ggml_nelements(t);c.status="covered_elementwise";}
 else if(data.count(op)){c.status="memory_index_conversion_not_counted_as_FLOPs";}
 else{c.status="uncovered";}
 if(c.shapes.size()<2)c.shapes.push_back("{\"output\":"+shape(t)+",\"src0\":"+shape(t->src[0])+",\"src1\":"+shape(t->src[1])+"}");
}
}
void profileReset(){counts.clear();graphs.clear();enabled.store(true);}
void profileBeginGraph(const char * stage){if(enabled.load())graphs[stage]++;}
void profileGraph(ggml_cgraph * graph,const char * stage){profileBeginGraph(stage);for(int i=0;i<ggml_graph_n_nodes(graph);i++)node(ggml_graph_node(graph,i),stage);}
bool profileEval(ggml_tensor * t,bool ask,void *){if(ask)node(t,"nano_llm");return !ask;}
void profileWrite(const char * path,const char * model,int code,const std::string & text,size_t samples,int tokens){
 enabled.store(false);uint64_t sum=0;for(auto & pair:counts)sum+=pair.second.operations;
 std::ofstream out(path);out<<"{\n\"schema\":1,\"model\":"<<quote(model)<<",\"status\":"<<quote(code==0?"successful_partial_graph_operation_trace":"inference_failed_planned_graph_trace")<<",\"inference_code\":"<<code;
 out<<",\"audio_samples\":"<<samples<<",\"audio_seconds\":"<<double(samples)/16000<<",\"output_text\":"<<quote(text)<<",\"output_text_tokens\":"<<tokens;
 out<<",\"covered_logical_arithmetic_operations\":"<<sum<<",\"partial_GOPs\":"<<double(sum)/1e9;
 out<<",\"complete_FLOPs\":null,\"complete_GOPs\":null,\"MIPS\":null";
 out<<",\"definition\":\"Executed GGML graph shapes; dense matmul counts 2*K*output_elements, simple elementwise arithmetic counts output_elements. This is a partial logical arithmetic count, not hardware instructions or complete end-to-end FLOPs. Quantized matmul uses the same mathematical MAC2 convention; dequantization cost is excluded.\"";
 out<<",\"uncovered_outside_graph\":[\"CPU FFT/fbank or Whisper log-mel\",\"token sampling/logits processing\",\"tensor quantization/dequantization and datatype conversions\",\"VAD postprocessing/segmentation\"]";
 out<<",\"graph_calls\":{";bool first=true;for(auto & p:graphs){if(!first)out<<',';first=false;out<<quote(p.first)<<':'<<p.second;}out<<"},\n\"operators\":[";first=true;
 for(auto & p:counts){if(!first)out<<',';first=false;auto & c=p.second;out<<"\n{\"stage_op\":"<<quote(p.first)<<",\"executed_nodes\":"<<c.calls<<",\"output_elements\":"<<c.elements<<",\"counted_operations\":"<<c.operations<<",\"coverage\":"<<quote(c.status)<<",\"example_shapes\":[";for(size_t i=0;i<c.shapes.size();i++){if(i)out<<',';out<<c.shapes[i];}out<<"]}";}out<<"\n]}\n";
}
