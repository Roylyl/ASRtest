#!/usr/bin/env python3
"""Attempt ONNX operator cost from actual CPU-forward execution shapes.

This deliberately reports only covered matrix/convolution MAC core operations,
never a full ASR FLOPs value. Audio frontend, stream/CIF search, quantization
corrections, bias, activations, normalization, softmax, and model-dependent call
counts are not equated with zero. No parameter/timing-based cost extrapolation.
Requires onnx, onnxruntime, numpy in an isolated Python environment.
"""
import argparse
import json
import math
import platform
import time
import traceback
from collections import Counter
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort

from project_paths import APP_ROOT, REPO_ROOT, MODEL_LIBRARY, DEMO_CORPUS, WHISPER_SOURCE, LLAMA_SOURCE, android_sdk, repo_relative

ROOT = APP_ROOT
CASES = [
    ("zipformer", "encoder-epoch-99-avg-1.int8.onnx", {"N": 1},
     "One encoder block: x[1,39,80], 32 new 10ms fbank frames; all cache states initially zero."),
    ("zipformer", "decoder-epoch-99-avg-1.onnx", {"N": 1},
     "One prediction-network call: blank-token history y[1,2]. Number of calls depends on transcription/search."),
    ("zipformer", "joiner-epoch-99-avg-1.int8.onnx", {"N": 1},
     "One joiner call for one encoder and decoder vector [1,512]; not all steps for an utterance."),
    ("senseVoice", "model.int8.onnx", {"N": 1, "T": 167},
     "One offline forward: 167 LFR feature frames×560, LFR window7/shift6. Nominal ~10s feature sequence; no waveform frontend included."),
    ("paraformer", "encoder.int8.onnx", {"batch_size": 1, "feats_length": 18},
     "One streaming encoder call:61 raw frames→10 LFR frames plus5 left/3 right cached frames =18 frames×560."),
    ("paraformer", "decoder.int8.onnx", {"batch_size": 1, "enc_length": 18, "token_length": 1},
     "One decoder call with encoder18 frames, explicitly fixed1 acoustic token,16 zero caches[1,512,10]. Real token count comes from CIF and audio."),
]
MATRIX_OPS = {"MatMul", "MatMulInteger", "Gemm", "Conv", "ConvTranspose", "QLinearConv", "QLinearMatMul"}


def shape_of(value):
    return [d.dim_value if d.HasField("dim_value") else d.dim_param or None
            for d in value.type.tensor_type.shape.dim]


def attrs(node):
    return {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}


def static_inventory(model):
    original = {v.name: shape_of(v) for v in list(model.graph.input) + list(model.graph.output) + list(model.graph.value_info)}
    try:
        inferred = onnx.shape_inference.infer_shapes(model, strict_mode=False, data_prop=False)
        shapes = {v.name: shape_of(v) for v in list(inferred.graph.input) + list(inferred.graph.output) + list(inferred.graph.value_info)}
        result = {"status": "completed", "declaredShapeCount": len(original), "inferredShapeCount": len(shapes),
                  "fullyStaticShapeCount": sum(all(isinstance(d, int) and d > 0 for d in s) for s in shapes.values()),
                  "shapes": shapes}
        del inferred
        return result
    except Exception as exc:
        return {"status": "failed", "error": str(exc), "shapes": original}


def input_array(value, symbols, meta):
    shape = [d if isinstance(d, int) else symbols[d] for d in shape_of(value)]
    dtype = onnx.helper.tensor_dtype_to_np_dtype(value.type.tensor_type.elem_type)
    out = np.zeros(shape, dtype=dtype)
    if value.name in {"x_length", "speech_lengths", "enc_len"}:
        out.fill(symbols.get("T", symbols.get("feats_length", symbols.get("enc_length", 0))))
    elif value.name == "acoustic_embeds_len":
        out.fill(symbols["token_length"])
    elif value.name == "language":
        out.fill(int(meta["lang_auto"]))
    elif value.name == "text_norm":
        out.fill(int(meta["with_itn"]))
    return out


def profile_shapes(entries):
    shapes = []
    dtypes = []
    for entry in entries or []:
        if isinstance(entry, dict) and len(entry) == 1:
            dtype, shape = next(iter(entry.items()))
            shapes.append(shape)
            dtypes.append(dtype)
        else:
            shapes.append(None)
            dtypes.append(None)
    return shapes, dtypes


def numel(shape):
    if shape is None or not all(isinstance(d, int) and d >= 0 for d in shape):
        raise ValueError("unresolved execution shape")
    return math.prod(shape)


def core_ops(op, inputs, outputs, attributes):
    if not outputs:
        raise ValueError("no execution output shapes")
    if op in {"MatMul", "MatMulInteger", "QLinearMatMul"}:
        a = inputs[0]
        if not a:
            raise ValueError("missing left matrix operand shape")
        k = a[-1]
        if not isinstance(k, int) or k < 0:
            raise ValueError("unresolved matrix reduction dimension")
        # ORT profiling omits prepacked B tensors and compresses the remaining
        # input-shape list. A[-1] and the actual output element count are already
        # sufficient for the standard matrix-core arithmetic formula; no guessed
        # weight dimension or transcript length is required.
        return 2 * numel(outputs[0]) * k, "2×actual_output_elements×actual_A[-1]; sufficient even when ORT omits prepacked B shape; core only"
    if op == "Gemm":
        a = inputs[0]
        if a is None or len(a) != 2:
            raise ValueError("Gemm operand is not rank2")
        k = a[0] if attributes.get("transA", 0) else a[1]
        return 2 * numel(outputs[0]) * k, "2×M×N×K; alpha/beta/bias excluded"
    if op in {"Conv", "QLinearConv"}:
        weight = inputs[3] if op == "QLinearConv" else inputs[1]
        if weight is None or len(weight) < 3:
            raise ValueError("missing convolution filter shape")
        return 2 * numel(outputs[0]) * math.prod(weight[1:]), "2×output_elements×Cin_per_group×kernel_volume; bias excluded"
    raise ValueError("operator core not covered by this conservative attempt")


def analyze_profile(profile_path, model):
    events = json.loads(profile_path.read_text())
    original = {node.name: node for node in model.graph.node if node.name}
    counted, unresolved, executed = [], [], Counter()
    non_core = Counter()
    for event in events:
        args = event.get("args", {})
        if event.get("cat") != "Node" or not event.get("name", "").endswith("_kernel_time"):
            continue
        op = args.get("op_name", "unknown")
        executed[op] += 1
        if op not in MATRIX_OPS:
            non_core[op] += 1
            continue
        name = event["name"][:-len("_kernel_time")]
        inputs, types = profile_shapes(args.get("input_type_shape"))
        outputs, output_types = profile_shapes(args.get("output_type_shape"))
        node = original.get(name)
        record = {"node": name, "op": op, "inputShapes": inputs, "inputTypes": types,
                  "outputShapes": outputs, "outputTypes": output_types}
        try:
            if op == "Gemm" and node is None:
                raise ValueError("original Gemm attributes not located")
            count, definition = core_ops(op, inputs, outputs, attrs(node) if node is not None else {})
            record.update({"coreArithmeticOperations": count, "definition": definition,
                           "arithmeticClass": "integer_matrix_core" if op in {"MatMulInteger", "QLinearMatMul", "QLinearConv"} else "floating_matrix_core"})
            counted.append(record)
        except Exception as exc:
            record["reason"] = str(exc)
            unresolved.append(record)
    by_op, by_class = Counter(), Counter()
    for node in counted:
        by_op[node["op"]] += node["coreArithmeticOperations"]
        by_class[node["arithmeticClass"]] += node["coreArithmeticOperations"]
    return {"status": "partial_operator_count", "completeAsrFlops": None, "completeAsrGops": None,
            "knownMatrixConvolutionCoreOperations": sum(by_op.values()),
            "knownMatrixConvolutionCoreGops": sum(by_op.values()) / 1e9,
            "coreOperationsByOperator": dict(by_op), "coreOperationsByArithmeticClass": dict(by_class),
            "executedNodeCountsByOperator": dict(executed), "excludedNonCoreNodeCountsByOperator": dict(non_core),
            "countedCoreNodeCount": len(counted), "unresolvedCoreNodeCount": len(unresolved),
            "countedNodes": counted, "unresolvedCoreNodes": unresolved,
            "excludedExplanation": "All non-core nodes remain uncounted, not zero-cost; matrix/conv quantization corrections and biases also excluded."}


def attempt(model_root, out, case):
    model_id, name, symbols, meaning = case
    case_id = "%s-%s" % (model_id, name.replace(".onnx", ""))
    model_file = model_root / model_id / name
    log = out / (case_id + ".log")
    result = {"caseId": case_id, "modelFile": repo_relative(model_file), "caseDefinition": meaning,
              "symbolicInputs": symbols, "fullAsrValueAvailable": False}
    def note(message):
        print(message, flush=True)
        with log.open("a") as f:
            f.write(message + "\n")
    note("CASE %s\n%s" % (case_id, meaning))
    session = None
    try:
        model = onnx.load_model(str(model_file), load_external_data=False)
        meta = {p.key: p.value for p in model.metadata_props}
        result["graphNodeCounts"] = dict(Counter((n.domain + ":" + n.op_type) for n in model.graph.node))
        result["inputDeclarations"] = {v.name: shape_of(v) for v in model.graph.input}
        result["staticShapeInference"] = static_inventory(model)
        note("static inference %s; static shapes=%s" %
             (result["staticShapeInference"]["status"], result["staticShapeInference"].get("fullyStaticShapeCount", 0)))
        inputs = {v.name: input_array(v, symbols, meta) for v in model.graph.input}
        result["actualInputs"] = {name: {"shape": list(value.shape), "dtype": str(value.dtype),
                                        "fill": "metadata language/ITN ID or length" if name in {"language", "text_norm", "x_length", "speech_lengths", "enc_len", "acoustic_embeds_len"} else "zero"}
                                  for name, value in inputs.items()}
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        options.enable_profiling = True
        options.profile_file_prefix = str(out / case_id)
        options.log_severity_level = 3
        session = ort.InferenceSession(str(model_file), options, providers=["CPUExecutionProvider"])
        begin = time.perf_counter()
        values = session.run(None, inputs)
        result["desktopForwardSecondsDiagnosticOnly"] = time.perf_counter() - begin
        result["actualOutputs"] = {decl.name: {"shape": list(value.shape), "dtype": str(value.dtype)}
                                   for decl, value in zip(session.get_outputs(), values)}
        profile = Path(session.end_profiling())
        result["runtimeProfile"] = repo_relative(profile)
        result["execution"] = "forward_completed"
        result["operatorCount"] = analyze_profile(profile, model)
        note("forward completed; partial matrix/conv core=%s GOP; unresolved core nodes=%s" %
             (result["operatorCount"]["knownMatrixConvolutionCoreGops"], result["operatorCount"]["unresolvedCoreNodeCount"]))
    except Exception as exc:
        result["execution"] = "blocked"
        result["error"] = {"class": type(exc).__name__, "message": str(exc), "traceback": traceback.format_exc()}
        note("BLOCKED %s: %s\n%s" % (type(exc).__name__, exc, result["error"]["traceback"]))
        if session is not None:
            try:
                result["runtimeProfile"] = repo_relative(Path(session.end_profiling()))
            except Exception:
                pass
    (out / (case_id + "-analysis.json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-root", type=Path, default=MODEL_LIBRARY)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "results/flops-attempt")
    parser.add_argument("--reanalyze-existing", action="store_true", help="Reanalyze saved core-node shapes without any new model load or forward")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    summary = {"schemaVersion": 1, "onnx": onnx.__version__, "onnxruntime": ort.__version__,
               "numpy": np.__version__, "host": platform.platform(), "executionProvider": "CPUExecutionProvider",
               "graphOptimization": "ORT_DISABLE_ALL", "threads": 1,
               "operationConvention": "One multiplication plus accumulation =2 arithmetic operations; only covered matrix/convolution cores counted.",
               "fullAsrFlopsAvailable": False, "fullAsrGopsAvailable": False, "mipsAvailable": False,
               "limitations": [
                   "The actual forwards run on Mac CPU with synthetic feature tensors, not Android performance measurement or actual waveform transcription.",
                   "Input feature extraction, LFR/CMVN outside ONNX, CTC/transducer search, Paraformer CIF, and variable decoder-call counts are outside this trace.",
                   "Bias, normalization, nonlinear activations, softmax, dynamic quantization/scaling/zero-point correction, layout and control work are excluded, not assumed free.",
                   "Shape inference cannot resolve all symbolic dimensions; actual runtime profiles are used only for executed core operators with resolved operand shapes.",
                   "One unit-call GOP subtotal cannot be multiplied by an arbitrary utterance duration/token count and called full ASR FLOPs.",
                   "MIPS requires an instruction-level definition/instrumentation for the target compiled code; ONNX arithmetic counts are not machine instructions.",
               ], "cases": []}
    for case in CASES:
        if args.reanalyze_existing:
            model_id, name, _, _ = case
            case_id = "%s-%s" % (model_id, name.replace(".onnx", ""))
            result_path = args.output_dir / (case_id + "-analysis.json")
            result = json.loads(result_path.read_text())
            count = result.get("operatorCount", {})
            if count:
                previous = count["unresolvedCoreNodeCount"]
                remaining = []
                for node in count["unresolvedCoreNodes"]:
                    if node["op"] in {"MatMul", "MatMulInteger", "QLinearMatMul"}:
                        try:
                            ops, definition = core_ops(node["op"], node["inputShapes"], node["outputShapes"], {})
                            node.pop("reason", None)
                            node.update({"coreArithmeticOperations": ops, "definition": definition,
                                         "arithmeticClass": "integer_matrix_core" if node["op"] != "MatMul" else "floating_matrix_core"})
                            count["countedNodes"].append(node)
                        except Exception as exc:
                            node["reason"] = str(exc)
                            remaining.append(node)
                    else:
                        remaining.append(node)
                count["unresolvedCoreNodes"] = remaining
                count["unresolvedCoreNodeCount"] = len(remaining)
                count["countedCoreNodeCount"] = len(count["countedNodes"])
                by_op, by_class = Counter(), Counter()
                for node in count["countedNodes"]:
                    by_op[node["op"]] += node["coreArithmeticOperations"]
                    by_class[node["arithmeticClass"]] += node["coreArithmeticOperations"]
                count["coreOperationsByOperator"] = dict(by_op)
                count["coreOperationsByArithmeticClass"] = dict(by_class)
                count["knownMatrixConvolutionCoreOperations"] = sum(by_op.values())
                count["knownMatrixConvolutionCoreGops"] = sum(by_op.values()) / 1e9
                result["profileShapeRecovery"] = {"previousUnresolvedCoreNodeCount": previous,
                    "method": "ORT omitted prepacked B shapes. Reanalysis used saved actual A reduction dimension and actual output element count, sufficient for matrix-core formula. No model reread or forward rerun."}
                result_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
                message = "REANALYSIS %s: previous missing-shape core nodes=%s, unresolved now=%s, partial core GOP=%s; no inference rerun." % (case_id, previous, len(remaining), count["knownMatrixConvolutionCoreGops"])
                print(message)
                with (args.output_dir / (case_id + ".log")).open("a") as log:
                    log.write(message + "\n")
        else:
            result = attempt(args.model_root, args.output_dir, case)
        count = result.get("operatorCount", {})
        summary["cases"].append({k: result[k] for k in ["caseId", "caseDefinition", "execution", "fullAsrValueAvailable"]})
        summary["cases"][-1].update({"knownMatrixConvolutionCoreGops": count.get("knownMatrixConvolutionCoreGops"),
                                     "countedCoreNodeCount": count.get("countedCoreNodeCount"),
                                     "unresolvedCoreNodeCount": count.get("unresolvedCoreNodeCount"),
                                     "error": result.get("error", {}).get("message"),
                                     "analysis": repo_relative(args.output_dir / (result["caseId"] + "-analysis.json"))})
    (args.output_dir / "onnx-attempt-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print("No defensible complete ASR FLOPs/GOPs/MIPS total obtained; unit-forward coverage and blockers recorded.")


if __name__ == "__main__":
    main()
