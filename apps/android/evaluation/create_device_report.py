#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Create a compact report from the retained actual Android result files."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
DEMO = REPO_ROOT / 'shared/assets/evaluation/demo'
RUN = ROOT / 'evaluation/runs/full-device-run'
MODELS = [
    ('zipformer', 'Zipformer Small中英', '未披露', 'sherpa-onnx/ONNX Runtime；Transducer结构按块处理音频并维护缓存，输出流式文字。', 'https://github.com/k2-fsa/sherpa-onnx'),
    ('whisperTiny', 'Whisper tiny multilingual', '约39M', 'whisper.cpp；Transformer编码器/解码器，自回归生成文字，当前停止后转写。', 'https://github.com/ggml-org/whisper.cpp'),
    ('whisperBase', 'Whisper base multilingual', '约74M', 'whisper.cpp；与tiny同类结构，网络更大，当前停止后转写。', 'https://github.com/ggml-org/whisper.cpp'),
    ('voskChinese', 'Vosk small-cn-0.22', '未披露', 'Vosk/Kaldi；神经网络声学模型结合词典、语言模型与解码图，中文流式识别。', 'https://github.com/alphacep/vosk-api'),
    ('voskEnglish', 'Vosk small-en-us-0.15', '未披露', 'Vosk/Kaldi；使用独立英文声学及词汇资源，英文流式识别。', 'https://github.com/alphacep/vosk-api'),
    ('senseVoice', 'SenseVoiceSmall INT8', '约234M', 'sherpa-onnx；非自回归编码器及CTC转写，当前停止后输出最终文字。', 'https://github.com/QwenAudio/SenseVoice'),
    ('paraformer', 'Paraformer Streaming INT8', '约220M', 'sherpa-onnx；CIF特征对齐与非自回归预测，按块处理并维护流式缓存。', 'https://github.com/modelscope/FunASR'),
    ('nano', 'Fun-ASR-Nano F16/Q4_K_M', '约0.8B；VAD另计', '原生Fun-ASR/llama.cpp；SAN-M编码器及适配器接Qwen3-0.6B，自回归转写，配合本地FSMN-VAD。', 'https://github.com/QwenAudio/Fun-ASR'),
]

def percent(records, language):
    selected = [r for r in records if r.get('status') == 'completed' and r.get('language') == language and r.get('score')]
    units = sum(r['score']['referenceUnits'] for r in selected)
    errors = sum(r['score']['editDistance'] for r in selected)
    return f'{errors / units * 100:.2f}%' if units else '不适用'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "results/Android端侧ASR实测报告.md")
    args = parser.parse_args()
    driver = json.loads((RUN / 'driver.json').read_text())
    groups = {key: json.loads((RUN / f'benchmark-{key}.json').read_text()) for key, *_ in MODELS}
    completed = sum(r.get('status') == 'completed' for g in groups.values() for r in g['records'])
    skipped = sum(r.get('status') == 'skipped' for g in groups.values() for r in g['records'])
    failed = sum(r.get('status') == 'failed' for g in groups.values() for r in g['records'])
    device = driver['deviceBefore']
    lines = ['# Android端侧ASR实测报告',
        f"测试时间：{driver['startedAt']}至{driver['endedAt']}。设备：红米Note11 Pro+，系统报告型号{device['model']}；Android{device['androidVersion']}/API{device['apiLevel']}；SoC标识{device['soc']}；arm64-v8a；MemTotal=7,668,744KiB。",
        f'八组模型均在手机本地运行，采用四段合成演示音频、每段三轮，共96条计划记录：{completed}条完成、{skipped}条因Vosk单语范围而跳过、{failed}条失败。没有发生进程崩溃。重复运行不增加独立语料数量。',
        '本报告用于验证Android部署及初步比较运行表现。当前还没有用户真实录音，不能据此给出真实场景准确率结论。模型按固定顺序逐个运行，线程请求为2；Vosk由运行库管理线程。测量过程中没有重装App。',
        '## 一、方法与运行表现',
        '|模型|官方标称参数量|FLOPs/MIPS|峰值进程RSS(MiB)|累计RTF|完成/跳过|来源及基本原理|',
        '|---|---|---|---:|---:|---|---|']
    for key, title, params, principle, source in MODELS:
        records = groups[key]['records']
        ok = [r for r in records if r.get('status') == 'completed']
        audio = sum(r['audioSeconds'] for r in ok)
        compute = sum(r['inferenceMS'] for r in ok)
        rss = max(r['peakRssKB'] for r in ok) / 1024
        skip = sum(r.get('status') == 'skipped' for r in records)
        lines.append(f'|{title}|{params}|未测|{rss:.1f}|{compute / 1000 / audio:.3f}|{len(ok)}/{skip}|{source}<br>{principle}|')
    lines += ['RTF=累计识别调用耗时÷累计音频时长，不含模型加载、WAV读取、界面等待与日志写入；包含框架内部特征提取、解码及Nano VAD。RTF小于1表示这批已录音频的处理速度快于播放速度，不等同于流式交互延迟达标。Vosk跳过不支持的纯语言语料，因此累计RTF的语料范围与其他模型不同，不作严格同集排名。',
        '内存为整个App进程的VmRSS，每100ms采样，模型加载后取得基线，采样覆盖音频接收及完成推理；包含运行库、UI及分配器保留页面，不是模型独占内存。短暂峰值可能漏采，PSS只记录结束快照。数据来自前端改版前的同一识别后端；前端改版后的界面检查结果不混入本轮内存统计。',
        '参数量采用官方架构标称，不是运行时测得。FLOPs/MIPS没有进行算子/指令剖析，不能由耗时、RTF或CPU利用率反推；保留未测，不填估算值。',
        '## 二、识别效果',
        '|模型|中文CER|英文WER|混合字符CER|说明|',
        '|---|---:|---:|---:|---|']
    notes = {'senseVoice': '中文分数受数字ITN书写差异影响；应核对原文', 'whisperTiny': '数字及繁简书写差异也计入严格错误率', 'whisperBase': '数字及繁简差异；混合句存在漏字', 'voskChinese': '单语模型；英文不适用，混合结果只作观察', 'voskEnglish': '单语模型；中文不适用，混合结果只作观察', 'paraformer': '本次英文合成句转写不完整', 'nano': '四段合成样本匹配；样本有限，不能推广到真实场景', 'zipformer': '本次混合句的英文词有遗漏'}
    for key, title, *_ in MODELS:
        r = groups[key]['records']
        lines.append(f'|{title}|{percent(r,"zh")}|{percent(r,"en")}|{percent(r,"mixed")}|{notes[key]}|')
    lines += ['中文CER按字符、英文WER按词、中英混合按字符分别统计，不将三种单位混成一个总错误率。评分忽略大小写、标点和空白，不做数字读法或繁简转换；错误率可能超过100%。失败和跳过项不计入分母。中文两段合计38个参考字符，英文一句12词，混合一句31个字符；三轮重复不代表三倍独立样本。',
        '## 三、语料与后续实测',
        '|音频|语言|时长|参考文字|',
        '|---|---|---:|---|']
    for c in json.loads((DEMO / 'corpus.json').read_text()):
        lines.append(f"|{c['id']}|{c['language']}|{c['durationSeconds']:.3f}s|{c['reference']}|")
    lines += ['语音由本机macOS的Tingting/Samantha合成，混合句由中文/英文片段拼接；16kHz单声道WAV。后续加入手机真实录音，人工确认参考文字后，用同一录音逐模型重测。应分别观察安静/噪声、距离、长句及中英混说，并保留失败和完整文字，避免只看一个总分。',
        '## 四、文件与证据',
        f'工程：{ROOT}',
        f'APK：{ROOT}/dist/ASRtest-1.0.0-arm64-debug.apk',
        f'完整原始结果、JSONL和驱动元数据：{ROOT}/evaluation/runs/full-device-run/',
        f'逐条CSV、按语言汇总CSV及完整转写：{ROOT}/evaluation/runs/full-device-run/report/',
        f'模型参数与原理统计：{ROOT}/results/模型参数与统计口径.md',
        '八组模型资源已默认本地集成；没有网络推理回退。前端沿用蓝白分组卡片、系统深色模式、三页导航与宽屏双栏，逐条完整转写独立展示。界面实机截图及验证状态见工程README。']
    destination = args.output
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(destination)

if __name__ == '__main__':
    main()
