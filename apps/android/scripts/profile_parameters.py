#!/usr/bin/env python3
"""Count stored tensor elements by reading headers, never loading weight data.

This is a model-format inventory, not runtime memory/FLOPs profiling. Rounded
official architecture counts are kept separate from the installed tensor count.
"""
import argparse
import importlib.util
import json
import math
import struct
from collections import Counter
from pathlib import Path

from project_paths import APP_ROOT, REPO_ROOT, MODEL_LIBRARY, DEMO_CORPUS, WHISPER_SOURCE, LLAMA_SOURCE, android_sdk, repo_relative

ROOT = APP_ROOT
GGML_TYPES = {0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q5_1",
              8: "Q8_0", 9: "Q8_1", 10: "Q2_K", 11: "Q3_K", 12: "Q4_K",
              13: "Q5_K", 14: "Q6_K", 15: "Q8_K", 30: "BF16"}


def read_exact(f, count):
    data = f.read(count)
    if len(data) != count:
        raise ValueError("Truncated model header")
    return data


def scalar(f, fmt):
    return struct.unpack("<" + fmt, read_exact(f, struct.calcsize("<" + fmt)))[0]


def gguf_string(f, keep=True):
    count = scalar(f, "Q")
    if count > 64 * 1024 * 1024:
        raise ValueError("Unreasonable GGUF string length")
    if keep:
        return read_exact(f, count).decode("utf-8")
    f.seek(count, 1)
    return None


def gguf_value(f, kind, keep=False):
    formats = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f",
               7: "?", 10: "Q", 11: "q", 12: "d"}
    if kind in formats:
        if keep:
            return scalar(f, formats[kind])
        f.seek(struct.calcsize("<" + formats[kind]), 1)
    elif kind == 8:
        return gguf_string(f, keep)
    elif kind == 9:
        subtype, count = scalar(f, "I"), scalar(f, "Q")
        if subtype in formats:
            f.seek(count * struct.calcsize("<" + formats[subtype]), 1)
        else:
            for _ in range(count):
                gguf_value(f, subtype, False)
    else:
        raise ValueError(f"Unsupported GGUF metadata type {kind}")
    return None


def summarize(path, tensors, metadata, excluded_buffers=()):
    total = sum(t["elements"] for t in tensors)
    fixed = sum(t["elements"] for t in tensors if t["name"] in excluded_buffers)
    dtype_elements = Counter()
    for t in tensors:
        dtype_elements[t["type"]] += t["elements"]
    return {"file": repo_relative(path), "file_bytes": path.stat().st_size,
            "tensor_count": len(tensors), "stored_tensor_elements": total,
            "known_fixed_buffer_elements": fixed,
            "stored_elements_excluding_known_fixed_buffers": total - fixed,
            "tensor_type_elements": dict(dtype_elements), "metadata": metadata,
            "tensors": tensors}


def gguf_profile(path):
    with path.open("rb") as f:
        if read_exact(f, 4) != b"GGUF":
            raise ValueError("Not a GGUF model")
        version = scalar(f, "I")
        if version not in (2, 3):
            raise ValueError(f"Unsupported GGUF version {version}")
        tensor_count, metadata_count = scalar(f, "Q"), scalar(f, "Q")
        metadata = {"gguf_version": version}
        for _ in range(metadata_count):
            key, kind = gguf_string(f), scalar(f, "I")
            keep = key in ("general.architecture", "general.name", "general.file_type",
                           "general.quantization_version", "general.alignment")
            value = gguf_value(f, kind, keep)
            if keep:
                metadata[key] = value
        tensors = []
        for _ in range(tensor_count):
            name, dimensions = gguf_string(f), scalar(f, "I")
            shape = [scalar(f, "Q") for _ in range(dimensions)]
            dtype, offset = scalar(f, "I"), scalar(f, "Q")
            tensors.append({"name": name, "shape": shape, "elements": math.prod(shape),
                            "type": GGML_TYPES.get(dtype, f"GGML_TYPE_{dtype}"),
                            "data_offset": offset})
        metadata["header_bytes_read_or_skipped"] = f.tell()
    # These snapshots are ordinary neural-network weight tensors. Their total is
    # exact as stored, not asserted to equal the source checkpoint's trainable count.
    return summarize(path, tensors, metadata)


def whisper_profile(path):
    with path.open("rb") as f:
        if scalar(f, "I") != 0x67676D6C:
            raise ValueError("Not a legacy Whisper GGML model")
        names = ["n_vocab", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer",
                 "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer", "n_mels", "ftype"]
        metadata = {key: scalar(f, "i") for key in names}
        mel, fft = scalar(f, "i"), scalar(f, "i")
        f.seek(mel * fft * 4, 1)  # mel-filter coefficients are not trainable weights
        vocabulary = scalar(f, "i")
        for _ in range(vocabulary):
            f.seek(scalar(f, "I"), 1)
        tensors = []
        while f.tell() < path.stat().st_size:
            dims, name_length, dtype = struct.unpack("<iii", read_exact(f, 12))
            if not 0 <= dims <= 4 or not 0 <= name_length <= 4096:
                raise ValueError("Invalid Whisper tensor header")
            shape = [scalar(f, "i") for _ in range(dims)]
            name = read_exact(f, name_length).decode("utf-8")
            count = math.prod(shape)
            # Installed tiny/base files are F16/F32. No approximation of storage
            # from bits is used: unsupported quantization formats are rejected.
            byte_sizes = {0: 4, 1: 2}
            if dtype not in byte_sizes:
                raise ValueError(f"Whisper type {dtype} requires an explicit block-size parser")
            tensors.append({"name": name, "shape": shape, "elements": count,
                            "type": GGML_TYPES[dtype]})
            f.seek(count * byte_sizes[dtype], 1)
    # OpenAI registers the sinusoidal encoder positional embedding as a buffer,
    # whereas decoder positional embeddings are learned parameters.
    return summarize(path, tensors, metadata, {"encoder.positional_embedding"})


def onnx_profile(path):
    import onnx
    model = onnx.load_model(str(path), load_external_data=False)
    initializers = {t.name: t for t in model.graph.initializer}
    candidates = set()
    slots = {"MatMul": [1], "Gemm": [1, 2], "Conv": [1, 2], "MatMulInteger": [1],
             "ConvInteger": [1], "QLinearMatMul": [3], "QLinearConv": [3, 8],
             "Gather": [0], "LayerNormalization": [1, 2], "BatchNormalization": [1, 2]}
    for node in model.graph.node:
        for index in slots.get(node.op_type, []):
            if index < len(node.input) and node.input[index] in initializers:
                candidates.add(node.input[index])
    tensors = [{"name": name, "shape": list(t.dims), "elements": math.prod(t.dims),
                "type": onnx.TensorProto.DataType.Name(t.data_type),
                "weight_candidate": name in candidates}
               for name, t in initializers.items()]
    result = summarize(path, tensors, {"format": "ONNX", "onnx_version": onnx.__version__})
    result["weight_candidate_elements"] = sum(t["elements"] for t in tensors if t["weight_candidate"])
    result["non_candidate_initializer_elements"] = result["stored_tensor_elements"] - result["weight_candidate_elements"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, default=MODEL_LIBRARY)
    parser.add_argument("--output", type=Path, default=ROOT / "results/model-parameters.json")
    args = parser.parse_args()
    onnx_available = importlib.util.find_spec("onnx") is not None
    official = {
        "whisperTiny": (39_000_000, "https://github.com/openai/whisper#available-models-and-languages"),
        "whisperBase": (74_000_000, "https://github.com/openai/whisper#available-models-and-languages"),
        "senseVoice": (234_000_000, "https://github.com/modelscope/FunASR#model-zoo"),
        "paraformer": (220_000_000, "https://github.com/modelscope/FunASR#model-zoo"),
        "nano": (800_000_000, "https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512"),
    }
    model_ids = ["zipformer", "whisperTiny", "whisperBase", "voskChinese", "voskEnglish",
                 "senseVoice", "paraformer", "nano"]
    entries = []
    for model_id in model_ids:
        value, source = official.get(model_id, (None, None))
        item = {"id": model_id, "official_approximate_parameters": value,
                "official_reference_source": source, "local_status": "unavailable",
                "exact_trainable_parameters": None, "components": [],
                "flops_status": "unavailable", "flops": None, "mips": None,
                "flops_reason": "未执行算子级剖析。FLOPs由输入长度、图结构及解码长度决定；不能由RTF或CPU耗时反推。MIPS还依赖指令计数和具体CPU。"}
        try:
            model_path = args.models / model_id
            if model_id.startswith("whisper"):
                file = model_path / ("ggml-tiny.bin" if model_id == "whisperTiny" else "ggml-base.bin")
                profile = whisper_profile(file)
                item["components"] = [profile]
                item["local_status"] = "exact_stored_tensor_elements"
                item["stored_asr_tensor_elements"] = profile["stored_tensor_elements"]
                item["known_fixed_buffer_elements"] = profile["known_fixed_buffer_elements"]
                item["note"] = "本地精确统计导出文件中的张量元素，不等同于训练参数总数；单列已知固定的编码器位置嵌入，mel滤波器及词表不计入。官方参数量为独立的取整参考。"
            elif model_id == "nano":
                for name, role in [("funasr-encoder-f16.gguf", "asr_encoder_adaptor"),
                                   ("qwen3-0.6b-q4km.gguf", "asr_decoder"),
                                   ("fsmn-vad.gguf", "external_vad")]:
                    component = gguf_profile(model_path / name)
                    component["role"] = role
                    item["components"].append(component)
                item["local_status"] = "exact_stored_tensor_elements"
                item["stored_asr_tensor_elements"] = sum(c["stored_tensor_elements"] for c in item["components"] if c["role"] != "external_vad")
                item["external_vad_tensor_elements"] = item["components"][-1]["stored_tensor_elements"]
                item["decoder_embedding_and_output_tensors"] = [t for t in item["components"][1]["tensors"] if t["name"] in ("token_embd.weight", "output.weight")]
                item["note"] = "GGUF张量逻辑维度元素数精确统计；Q4_K/Q6_K/F16只是存储格式，量化块中的scale及打包字节不作为额外参数。ASR编码器/适配器与解码器相加，外置VAD单列。当前解码器分别保存token_embd.weight与output.weight，各155582464个元素；未确认训练时的共享关系，因此不将985374304个导出张量元素宣称为训练时唯一参数数，也不擅自去重。官方800M另列。"
            elif model_id in ("zipformer", "senseVoice", "paraformer"):
                if onnx_available:
                    item["components"] = [onnx_profile(p) for p in sorted(model_path.glob("*.onnx"))]
                    item["local_status"] = "estimated_weight_candidate_elements"
                    item["estimated_weight_candidate_elements"] = sum(c["weight_candidate_elements"] for c in item["components"])
                    item["note"] = "仅按常见权重输入位置估算，导出图可能折叠、共享或重排权重。initializer总数含量化scale/zero-point和常量，不是训练参数；weight候选也不能当作精确参数量。"
                else:
                    item["note"] = "当前Python未安装onnx；按成本约束不新增依赖，未解析量化ONNX initializer。不能用文件字节数/INT8位宽反推参数量。"
            else:
                item["note"] = "未加载Kaldi组件解析器；声学网络、i-vector、语言模型及FST分别计数口径不同。官方未找到对应权重的参数数，不用包大小反推。"
        except (OSError, ValueError, struct.error) as error:
            item["local_status"] = "unavailable"
            item["error"] = str(error)
        entries.append(item)
    output = {"schema": 1, "method": "header-only tensor-dimension inventory",
              "definitions": {"official_approximate_parameters": "官方架构参数量，通常为取整；与本地导出张量量分别保留。",
                              "stored_tensor_elements": "对文件中每个张量的逻辑shape求积后求和，含持久化固定buffer，排除词表、mel滤波器、量化块打包scale、文件metadata；不是运行内存。",
                              "exact_trainable_parameters": "无法从导出文件无歧义确认训练参数、权重共享及固定buffer时保留null。",
                              "local_status": "exact_stored_tensor_elements、estimated_weight_candidate_elements或unavailable，明确统计口径。"},
              "source_definitions": ["https://github.com/ggml-org/whisper.cpp/blob/master/src/whisper.cpp",
                                     "https://github.com/openai/whisper/blob/main/whisper/model.py",
                                     "https://github.com/ggml-org/ggml/blob/master/docs/gguf.md"],
              "onnx_parser_available": onnx_available, "models": entries}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    for item in entries:
        print(item["id"], item["local_status"], item.get("stored_asr_tensor_elements", "—"))


if __name__ == "__main__":
    main()
