#!/usr/bin/env python3
"""Inventory stored ONNX initializer elements, without running inference.

Requires `onnx` in the invoking Python environment. Does not convert tensors to
NumPy, calculate file hashes, download weights, or estimate FLOPs from timing.
`storedWeightElements` is an export inventory, not an exact training-parameter
count: ONNX graph fusion/quantization can transform or duplicate weights.
"""
import argparse
import json
import math
import re
from collections import Counter, defaultdict
from pathlib import Path

try:
    import onnx
except ImportError as exc:
    raise SystemExit("This script requires onnx: install it in an isolated Python environment.") from exc

from project_paths import APP_ROOT, REPO_ROOT, MODEL_LIBRARY, DEMO_CORPUS, WHISPER_SOURCE, LLAMA_SOURCE, android_sdk, repo_relative

ROOT = APP_ROOT
FILES = {
    "zipformer": ["encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.onnx", "joiner-epoch-99-avg-1.int8.onnx"],
    "senseVoice": ["model.int8.onnx"],
    "paraformer": ["encoder.int8.onnx", "decoder.int8.onnx"],
}
NOMINAL = {"zipformer": None, "senseVoice": 234_000_000, "paraformer": 220_000_000}
SOURCES = {
    "zipformer": "https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t",
    "senseVoice": "https://arxiv.org/abs/2407.04051",
    "paraformer": "https://huggingface.co/funasr/paraformer-zh-streaming",
}
FLOAT_TYPES = {onnx.TensorProto.FLOAT, onnx.TensorProto.FLOAT16, onnx.TensorProto.DOUBLE, onnx.TensorProto.BFLOAT16}
WEIGHT_CATEGORIES = {"quantized_weight", "named_weight_or_bias", "operator_weight_or_bias"}


def consumer_role(op, index):
    if op in {"QuantizeLinear", "DequantizeLinear"}:
        if index == 1:
            return "quantization_scale"
        if index == 2:
            return "quantization_zero_point"
    if op == "MatMulInteger" and index in (2, 3):
        return "quantization_zero_point"
    if op in {"QLinearMatMul", "QLinearConv"}:
        if index in (1, 4):
            return "quantization_scale"
        if index in (2, 5, 7):
            return "quantization_zero_point"
        if index == 6:
            return "quantization_scale"
    if op in {"DynamicQuantizeLinear", "Shape", "Gather", "Reshape", "Expand", "Slice", "Range", "ConstantOfShape"}:
        return "constant_or_graph_control"
    return None


def classification(name, dtype, dims, consumers):
    roles = {consumer_role(c["op"], c["inputIndex"]) for c in consumers}
    roles.discard(None)
    # Explicit quantization operator positions take precedence over name hints.
    for category in ("quantization_scale", "quantization_zero_point"):
        if category in roles:
            return category, "quantization operator input position"
    lower = name.lower()
    if re.search(r"(?:_|\.|/)(?:zero_point|zeropoint)(?:$|[_./:\d])", lower):
        return "quantization_zero_point", "initializer name"
    if re.search(r"(?:_|\.|/)scale(?:$|[_./:\d])", lower) and not any(c["op"] == "LayerNormalization" for c in consumers):
        return "quantization_scale", "initializer name; exported quantization support"
    if re.search(r"quantized(?:$|[_./:\d])", lower) and math.prod(dims) > 1:
        return "quantized_weight", "quantized weight initializer name"
    if re.search(r"(?:^|[._/])(?:weight|bias|gamma|beta|embedding)(?:$|[._/])", lower):
        return "named_weight_or_bias", "weight/bias/normalization/embedding initializer name"
    for consumer in consumers:
        op, i = consumer["op"], consumer["inputIndex"]
        is_weight = ((op in {"Gemm", "Conv", "ConvTranspose"} and i in (1, 2)) or
                     (op in {"MatMul", "MatMulInteger"} and i in (0, 1)) or
                     (op == "QLinearMatMul" and i in (0, 3)) or
                     (op == "QLinearConv" and i in (0, 3, 8)) or
                     (op in {"LayerNormalization", "BatchNormalization", "InstanceNormalization"} and i in (1, 2)))
        if is_weight:
            return "operator_weight_or_bias", "initializer used as operator weight/bias; may be transformed or fused"
    if roles == {"constant_or_graph_control"} or dtype not in FLOAT_TYPES:
        return "constant_or_graph_control", "graph-control use or non-floating non-weight tensor"
    return "unclassified_initializer", "no defensible trainable-weight classification from export"


def graph_inventory(graph, path="main"):
    consumers = defaultdict(list)
    for node in graph.node:
        for index, name in enumerate(node.input):
            if name:
                consumers[name].append({"op": node.op_type, "domain": node.domain, "inputIndex": index, "node": node.name})
    tensors, constants = [], []
    for tensor in graph.initializer:
        dims = list(tensor.dims)
        category, basis = classification(tensor.name, tensor.data_type, dims, consumers[tensor.name])
        tensors.append({
            "graph": path, "name": tensor.name, "dtype": onnx.TensorProto.DataType.Name(tensor.data_type),
            "shape": dims, "elements": math.prod(dims), "category": category, "classificationBasis": basis,
            "countedInStoredWeightElements": category in WEIGHT_CATEGORIES,
            "rawPayloadBytes": len(tensor.raw_data), "externalData": {p.key: p.value for p in tensor.external_data},
            "consumers": consumers[tensor.name],
        })
    for index, tensor in enumerate(graph.sparse_initializer):
        dims = list(tensor.dims)
        # Dense logical size is not sparse storage parameter count; retain both.
        tensors.append({"graph": path, "name": tensor.values.name or "sparse_%s" % index,
                        "dtype": onnx.TensorProto.DataType.Name(tensor.values.data_type), "shape": dims,
                        "elements": math.prod(tensor.values.dims), "denseLogicalElements": math.prod(dims),
                        "category": "unclassified_sparse_initializer", "classificationBasis": "sparse stored values",
                        "countedInStoredWeightElements": False})
    for index, node in enumerate(graph.node):
        for attr in node.attribute:
            if attr.type == onnx.AttributeProto.GRAPH:
                child_tensors, child_constants = graph_inventory(attr.g, "%s/%s:%s" % (path, node.name or index, attr.name))
                tensors.extend(child_tensors)
                constants.extend(child_constants)
            elif attr.type == onnx.AttributeProto.GRAPHS:
                for child_index, child in enumerate(attr.graphs):
                    child_tensors, child_constants = graph_inventory(child, "%s/%s:%s:%s" % (path, node.name or index, attr.name, child_index))
                    tensors.extend(child_tensors)
                    constants.extend(child_constants)
            elif node.op_type == "Constant" and attr.type in (onnx.AttributeProto.TENSOR, onnx.AttributeProto.TENSORS):
                values = [attr.t] if attr.type == onnx.AttributeProto.TENSOR else attr.tensors
                for tensor in values:
                    constants.append({"graph": path, "node": node.name or str(index), "name": tensor.name,
                                      "dtype": onnx.TensorProto.DataType.Name(tensor.data_type), "shape": list(tensor.dims),
                                      "elements": math.prod(tensor.dims)})
    return tensors, constants


def inventory(file, model_root):
    # ONNX parser reads the protobuf once, but does not materialize tensor arrays
    # or load external tensor files. Only shapes/type/name/operator metadata used.
    model = onnx.load_model(str(file), load_external_data=False)
    tensors, constants = graph_inventory(model.graph)
    categories, dtypes = Counter(), Counter()
    for tensor in tensors:
        categories[tensor["category"]] += tensor["elements"]
        dtypes[tensor["dtype"]] += tensor["elements"]
    name_counts = Counter(t["name"] for t in tensors)
    return {"file": str(file.relative_to(model_root)), "fileBytes": file.stat().st_size,
            "irVersion": model.ir_version, "opsets": {op.domain or "ai.onnx": op.version for op in model.opset_import},
            "producer": model.producer_name, "producerVersion": model.producer_version,
            "metadata": {item.key: item.value for item in model.metadata_props},
            "initializerTensorCount": len(tensors), "storedInitializerElements": sum(t["elements"] for t in tensors),
            "storedWeightElements": sum(t["elements"] for t in tensors if t["countedInStoredWeightElements"]),
            "quantizationSupportElements": categories["quantization_scale"] + categories["quantization_zero_point"],
            "otherInitializerElements": sum(n for c, n in categories.items() if c not in WEIGHT_CATEGORIES and not c.startswith("quantization_")),
            "categoryElements": dict(categories), "dtypeElements": dict(dtypes),
            "nodeTensorConstantElements": sum(t["elements"] for t in constants),
            "duplicateInitializerNamesAcrossScopes": {n: count for n, count in name_counts.items() if count > 1},
            "tensors": tensors, "nodeTensorConstants": constants}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-root", type=Path, default=MODEL_LIBRARY)
    parser.add_argument("--output", type=Path, default=ROOT / "results/onnx-parameter-inventory.json")
    args = parser.parse_args()
    result = {"schemaVersion": 1, "onnxParserVersion": onnx.__version__,
              "definition": "Stored ONNX initializer element inventory; not exact training parameter count.",
              "classification": {"storedWeightElements": "quantized_weight + named_weight_or_bias + operator_weight_or_bias",
                                 "quantizationSupportElements": "quantization scales and zero points, excluded from storedWeightElements",
                                 "constants": "graph-control/unclassified initializers and Constant-node tensor attributes, separate from storedWeightElements"},
              "limitations": [
                  "ONNX export may fuse, transform, replicate, or remove trained tensors; no reverse reconstruction of original training parameters is attempted.",
                  "Initializer names and consuming operator roles are classification evidence, not proof of trainability; all per-tensor decisions retained for review.",
                  "Repeated tensors across component files/scopes are counted as stored; no content-based deduplication or file hashing is performed.",
                  "Quantization scale/zero-point elements and graph constants are not equated with trainable model weights.",
                  "Official nominal parameter counts are rounded architecture claims and kept separate from stored export inventory.",
                  "FLOPs/MIPS are not inferred from parameter count, file size, elapsed time, RTF, or CPU utilization. Dynamic graph cost requires a separate justified operator analysis.",
              ], "models": []}
    for model_id, names in FILES.items():
        parts = [inventory(args.model_root / model_id / name, args.model_root) for name in names]
        item = {"modelId": model_id, "officialNominalParameterCount": NOMINAL[model_id],
                "officialNominalSource": SOURCES[model_id], "exactTrainableParameterCount": None,
                "storedWeightElements": sum(p["storedWeightElements"] for p in parts),
                "storedInitializerElements": sum(p["storedInitializerElements"] for p in parts),
                "quantizationSupportElements": sum(p["quantizationSupportElements"] for p in parts),
                "otherInitializerElements": sum(p["otherInitializerElements"] for p in parts),
                "nodeTensorConstantElements": sum(p["nodeTensorConstantElements"] for p in parts), "files": parts}
        result["models"].append(item)
        print("%s: stored weights=%s; initializer elements=%s; quantization support=%s; other=%s" %
              (model_id, item["storedWeightElements"], item["storedInitializerElements"], item["quantizationSupportElements"], item["otherInitializerElements"]))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("Saved %s" % args.output)


if __name__ == "__main__":
    main()
