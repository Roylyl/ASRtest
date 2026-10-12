#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Integrate retained compute attempts into the user's single comparison file."""
import argparse
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("target",type=Path,help="Existing comparison Markdown to update")
TARGET=parser.parse_args().target
OUT=ROOT/'results/flops-attempt'
text=TARGET.read_text(encoding='utf-8').split('## 六、计算量统计尝试与限制',1)[0].rstrip()
onnx=json.loads((OUT/'onnx-attempt-summary.json').read_text())
ggml={key:json.loads((OUT/f'{key}-zh_short.json').read_text()) for key in ('whisperTiny','whisperBase','nano')}
pmu=json.loads((ROOT/'results/instruction-attempt/attempt-summary.json').read_text())
keys=['zipformer','whisperTiny','whisperBase','voskChinese','voskEnglish','senseVoice','paraformer','nano']
short={
    'zipformer':'部分统计：单编码块核心0.336960GOPs；预测网络/joiner另列',
    'whisperTiny':'部分统计：本句执行图逻辑82.544289GOPs',
    'whisperBase':'部分统计：本句执行图逻辑196.545393GOPs',
    'voskChinese':'已尝试；公开接口无计数器，缺Kaldi结构工具',
    'voskEnglish':'已尝试；同一工具阻塞，未重复必然失败命令',
    'senseVoice':'部分统计：固定特征前向核心84.047994GOPs',
    'paraformer':'部分统计：单encoder/decoder核心5.736610/0.399446GOPs',
    'nano':'部分统计：本句执行图逻辑83.814463GOPs',
}
updated=[];index=0
for line in text.splitlines():
    if line.startswith('|') and '<br>本机FLOPs/GOPs/MIPS：未测' in line:
        cells=line.split('|')[1:-1]
        assert len(cells)==8
        official=cells[2].split('<br>本机FLOPs/GOPs/MIPS：未测',1)[0]
        cells[2]=official+'<br>'+short[keys[index]]+'<br>完整ASR计数/MIPS尚未取得；范围与尝试详情见第六节'
        line='|'+'|'.join(cells)+'|';index+=1
    updated.append(line)
assert index==8,'Expected eight unchanged main model rows before first integration'
text='\n'.join(updated)
text=text.replace('计算量：官方资料/本机','计算量：官方资料/补充统计')
text=text.replace('当前未进行算子/指令剖析，不由RTF、CPU利用率、参数量或文件大小反推。','本次已尝试部分算子统计与设备指令采集，完整ASR计数仍未取得，详情见第六节；不由RTF、CPU利用率、参数量或文件大小反推。')

lines=['## 六、计算量统计尝试与限制',
    '', '补充尝试日期：2026-10-12。这轮取得了部分逻辑操作量和手机指令计数观测，但未取得八组模型统一范围的完整ASR FLOPs/GOPs或纯推理MIPS。以下明确列出执行环境、输入、已计范围和实际阻塞；没有把未计项当作零，也没有将部分值写成完整计算量。',
    '### 6.1 ONNX组件前向统计', '',
    '在macOSCPU上使用ONNX Runtime1.19.2，单线程、关闭图优化，六个组件均实际执行一次。输入为固定形状的合成特征/零缓存，未执行整段音频的端到端转写。按实际执行张量形状统计MatMul/Gemm/Conv等核心运算，1次乘法加1次累加计2次逻辑操作；下表GOPs表示十亿次操作的数量，不是每秒速度。',
    '|模型组件|实际固定输入与调用范围|已计矩阵/卷积核心GOPs|已计核心节点数|',
    '|---|---|---:|---:|']
case_labels=['Zipformer encoder','Zipformer decoder','Zipformer joiner','SenseVoiceSmall','Paraformer encoder','Paraformer decoder']
case_inputs=['x[1,39,80]；32个新fbank帧，初始缓存为零；单块',
    'y[1,2]；空白token历史；单次预测网络调用',
    '两个[1,512]向量；单次joiner调用',
    'x[1,167,560]；约10秒对应的固定特征长度；单次离线前向',
    'speech[1,18,560]；10个LFR帧加左右缓存；单encoder块',
    'encoder18帧；固定1个acoustic token；16份零缓存；单decoder调用']
for label,meaning,case in zip(case_labels,case_inputs,onnx['cases']):
    lines.append(f"|{label}|{meaning}|{case['knownMatrixConvolutionCoreGops']:.9f}|{case['countedCoreNodeCount']}|")
lines += ['', '这些值只覆盖固定组件调用的矩阵/卷积核心。没有计入前端特征提取、外部LFR/CMVN、bias、归一化、激活、softmax、动态量化修正及CTC/Transducer搜索等。Transducer的decoder/joiner调用次数、Paraformer CIF产生的token长度随音频和输出变化，因此不能把单次组件值随意乘以时长，当作整段ASR计算量。',
    '首次解析时，ORT省略了部分预打包矩阵B的shape。分析保存的原始trace后，使用实际A归约维度K与实际输出元素数按2×K×输出元素数补齐核心计数，没有重新推理或重读权重。完整ASR字段仍为null；这属于macOS上的逻辑量统计，不是红米运行速度或机器指令数。',
    '### 6.2 Whisper与Nano实际转写的逻辑图统计', '',
    '使用与Android部署相同的固定源码和权重，在隔离的macOSCPU工具中加入图节点统计，对zh_short的5.4285625秒、16kHz单声道音频完成真实转写。现有APK和JNI运行库未改动。矩阵乘法按MAC=2计算，另计ADD/MUL/SCALE等简单逐元素算术；累积本次实际调用的逻辑图shape。',
    '|模型|已覆盖的执行图逻辑GOPs/本句|本次图执行情况|转写状态|',
    '|---|---:|---|---|']
descriptions={'whisperTiny':'27次图调用；最终19个文本/特殊token',
              'whisperBase':'28次图调用；最终20个文本/特殊token',
              'nano':'1次VAD图、1次encoder/adaptor图、13次llama_decode'}
labels={'whisperTiny':'Whisper tiny multilingual','whisperBase':'Whisper base multilingual','nano':'Fun-ASR-Nano F16/Q4_K_M'}
for key in ('whisperTiny','whisperBase','nano'):
    v=ggml[key]
    lines.append(f"|{labels[key]}|{v['covered_logical_arithmetic_operations']/1e9:.6f}|{descriptions[key]}|成功|")
lines += ['', 'Whisper仍使用默认30秒音频上下文，短音频会补齐后编码，不能把该值写成“每秒固定计算量”。Whisper尚未覆盖NORM/SOFT_MAX/UNARY；Nano还未覆盖RMS_NORM、RoPE、GLU和融合FLASH_ATTN_EXT。图外FFT/fbank/log-mel、采样/logits处理、量化/反量化、数据类型转换及VAD后处理也没有完整计数。',
    '统计入口在计算前读取拟执行图元数据；本次三次转写均成功，无失败或取消记录。CPU后端可能融合算子或跳过NOP，所以这些值是逻辑图中的已覆盖算术量，不是独立kernel调用或CPU真实指令数。Nano Q4矩阵使用数学等效MAC口径，也不能称为实际浮点指令数。完整FLOPs/GOPs字段继续保留null。',
    '### 6.3 Vosk两组的工具阻塞', '',
    '实际读取Android部署libvosk.so的动态符号，找到36个vosk_公开接口，未发现计算量或算子执行次数接口。中文及英文final.mdl可观察到TDNN、Affine、Linear、BatchNorm等组件标签，但标签不能确定完整矩阵维度、优化后的计算图和音频分块执行次数。',
    '本机未找到nnet3-info/nnet3-copy/nnet-am-info/fstinfo。实际调用nnet3-info解析中文final.mdl，得到以下错误；工具不存在，因此没有对英文重复同一必然失败命令：',
    '```text', "FileNotFoundError: [Errno 2] No such file or directory: 'nnet3-info'", '```',
    '即使补上结构工具，完整Vosk仍包含MFCC、在线i-vector、动态FST搜索、剪枝和lattice生成，需要具体执行次数及统计规则。此轮未编译完整Kaldi或下载大型依赖，未用模型大小或运行时间推算其计算量。',
    '### 6.4 红米Simpleperf指令采集', '',
    '手机为同一台红米、Android13，ASRtest为Debug版本。系统Simpleperf能够列出instructions硬件事件，但初始直接采集返回权限错误；切换App身份后，部分调用产生0计数和辅助子进程限制。0未作为有效MIPS结果。',
    '```text', 'failed to open perf event file for event_type instructions:u: Permission denied', "Running child command in app uid isn't allowed.", '```',
    '随后使用NDK29提供的arm64 Simpleperf，并将工具放入App私有目录。按工具提示由ADB shell临时将security.perf_harden从1设为0，在一次真实Whisper tiny转写期间采集3秒窗口。取得以下非零观测：',
    '', '|项目|观测结果与范围|', '|---|---|',
    f"|采集时间|{pmu['startedAt']}至{pmu['endedAt']}；包含准备、采集及结束处理|",
    f"|instructions:u|{pmu['instructionCountReported']:,}条，App用户态指令；非纯推理专用计数|",
    f"|计数窗口墙钟时长|{pmu['elapsedWindowSeconds']:.6f}s|",
    f"|按墙钟汇总的窗口MIPS|{pmu['wholeProcessUserWallClockMips']:.2f}；计数÷窗口秒数÷10⁶，整个App进程聚合|",
    '|Simpleperf原始速率行|3.086G/sec；按AOSP同类实现解释，分母是汇总perf事件time_running，不是上述墙钟时间|',
    '|警告|仍有8条App UID子命令限制，与逐CPU辅助PMU探测失败相符；辅助容量/复用检查未完成，不能仅凭该警告否定已输出的非零计数|',
    '|工作负载|该次Whisper tiny转写完成；采集窗口未严格与accept/finish纯识别区间对齐|',
    '|恢复|security.perf_harden已恢复为原值1，临时设备统计工具已移除|',
    '', '这说明手机上已观察到非零指令计数，并非完全无法采集。辅助PMU探测受限，且窗口包含App进程中的其他工作、可能覆盖模型准备，不能把6229.18MIPS或工具的3.086G/sec直接填成该模型纯推理MIPS，更不能推广到其余七组。AOSP main的同类实现使用累计事件time_running作为速率分母，未核对本次NDK二进制对应的精确源码提交；不把time_running笼统写成独立测得的用户CPU时间。原日志为stdout/stderr拼接，警告执行顺序的解释依据源码，而非日志行先后。纯推理MIPS还需要与识别阶段一致的开始/结束边界，以及明确线程、用户态/内核态和事件覆盖范围。',
    '### 6.5 本轮结论与原始证据', '',
    '本轮成功取得六个ONNX组件的部分核心操作量、三组GGML模型真实转写的部分逻辑操作量，以及红米上的一段指令计数观测；尚未取得八组统一范围的完整ASR FLOPs/GOPs或纯推理MIPS。主表已改为“已尝试、完整值尚未取得”，部分数据和实际错误保留在本节，没有用参考值或不完整统计填成完整实测。',
    f'- ONNX输入、执行trace、逐节点计数和首次解析修正：[onnx-attempt-summary.json]({ROOT}/results/flops-attempt/onnx-attempt-summary.json)、[原始执行日志]({ROOT}/results/flops-attempt/onnx-run.log)、[已有trace重分析日志]({ROOT}/results/flops-attempt/onnx-reanalysis.log)。',
    f'- Whisper/Nano实际转写及未覆盖算子：[统计尝试说明.md]({ROOT}/results/flops-attempt/统计尝试说明.md)、[Whisper tiny]({ROOT}/results/flops-attempt/whisperTiny-zh_short.json)、[Whisper base]({ROOT}/results/flops-attempt/whisperBase-zh_short.json)、[Nano]({ROOT}/results/flops-attempt/nano-zh_short.json)。',
    f'- Vosk实际工具调用和结构/API检查：[vosk-attempt.md]({ROOT}/results/flops-attempt/vosk-attempt.md)、[vosk-attempt.json]({ROOT}/results/flops-attempt/vosk-attempt.json)。',
    f'- 红米权限尝试、非零指令计数、采集区间与恢复状态：[attempt-summary.json]({ROOT}/results/instruction-attempt/attempt-summary.json)、[实际工作负载计数日志]({ROOT}/results/instruction-attempt/ndk-private-real-workload-stat.log)、[该次真实转写]({ROOT}/results/instruction-attempt/real-workload-result.json)。',
    f'- Simpleperf分母与辅助警告的独立源码分析：[source-review/analysis.md]({ROOT}/results/instruction-attempt/source-review/analysis.md)。',
    f'- 工具源码：[ONNX统计脚本]({ROOT}/scripts/profile_onnx_gops_attempt.py)、[GGML统计脚本]({ROOT}/scripts/profile_ggml_operations.py)、[指令采集脚本]({ROOT}/scripts/attempt_instruction_count.py)。',
    '', '官方工具说明：https://onnxruntime.ai/docs/performance/tune-performance/profiling-tools.html',
    'Android Simpleperf命令及统计口径：https://android.googlesource.com/platform/system/extras/+/master/simpleperf/doc/executable_commands_reference.md',
    'AOSP统计实现：https://android.googlesource.com/platform/system/extras/+/master/simpleperf/cmd_stat.cpp',
    'AOSP计数汇总实现：https://android.googlesource.com/platform/system/extras/+/master/simpleperf/cmd_stat_impl.h',
    'AOSP子进程限制实现：https://android.googlesource.com/platform/system/extras/+/master/simpleperf/workload.cpp']
TARGET.write_text(text+'\n\n'+'\n'.join(lines)+'\n',encoding='utf-8')
print(TARGET)
