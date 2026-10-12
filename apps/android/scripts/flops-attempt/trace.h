#pragma once
#include "ggml.h"
#include "ggml-backend.h"
#include <string>
void profileReset();
void profileBeginGraph(const char * stage);
void profileGraph(ggml_cgraph * graph, const char * stage);
bool profileEval(ggml_tensor * tensor, bool ask, void * user);
void profileWrite(const char * path, const char * model, int code, const std::string & text, size_t samples, int output_tokens);
