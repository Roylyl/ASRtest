#!/usr/bin/env python3
"""Compute edit-distance metrics from actual ASRtestAndroid benchmark JSON."""
import argparse
import csv
import json
import pathlib
import re
import unicodedata
from collections import defaultdict


def clean_text(text):
    # Match app Metrics.chars: lowercase and retain Unicode letters/digits.
    text = (text or "").lower()
    return "".join(c for c in text if c.isalpha() or unicodedata.category(c) == "Nd")


def english_tokens(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", (text or "").lower())


def edits(reference, hypothesis):
    """Return S/D/I via Levenshtein; ties prefer substitution, deletion, insertion."""
    previous = [(i, 0, i, 0) for i in range(len(reference) + 1)]
    for token in hypothesis:
        current = [(previous[0][0] + 1, 0, 0, previous[0][3] + 1)]
        for j, expected in enumerate(reference, 1):
            diagonal = previous[j - 1]
            if token == expected:
                current.append(diagonal)
                continue
            substitution = (diagonal[0] + 1, diagonal[1] + 1, diagonal[2], diagonal[3])
            deletion = (current[j - 1][0] + 1, current[j - 1][1], current[j - 1][2] + 1, current[j - 1][3])
            insertion = (previous[j][0] + 1, previous[j][1], previous[j][2], previous[j][3] + 1)
            current.append(min((substitution, deletion, insertion), key=lambda item: item[0]))
        previous = current
    _, substitutions, deletions, insertions = previous[-1]
    return substitutions, deletions, insertions


def metric(language, reference, hypothesis):
    if language == "zh":
        name, ref, hyp = "CER", list(clean_text(reference)), list(clean_text(hypothesis))
    elif language == "en":
        name, ref, hyp = "WER", english_tokens(reference), english_tokens(hypothesis)
    else:
        name, ref, hyp = "CER（混合字符）", list(clean_text(reference)), list(clean_text(hypothesis))
    s, d, i = edits(ref, hyp)
    return {"metric": name, "referenceUnits": len(ref), "substitutions": s, "deletions": d, "insertions": i, "errorRate": (s + d + i) / len(ref) if ref else None}


def md_cell(value):
    return str(value if value is not None else "未记录").replace("|", "\\|").replace("\n", "<br>")


def fmt(value, digits=3):
    return "未记录" if value is None else f"{value:.{digits}f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="+", type=pathlib.Path, help="Actual benchmark JSON files or result directories")
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("evaluation/report"))
    parser.add_argument("--corpus", type=pathlib.Path, default=pathlib.Path(__file__).parent / "demo/corpus.json")
    args = parser.parse_args()
    corpus = {entry["id"]: entry for entry in json.loads(args.corpus.read_text(encoding="utf-8"))}
    paths = []
    for path in args.results:
        paths.extend(sorted(path.rglob("*.json")) if path.is_dir() else [path])
    rows, seen, devices = [], set(), []
    for path in paths:
        group = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(group, dict) or group.get("kind") != "benchmark":
            continue
        for record in group.get("records", []):
            identity = (group.get("id"), record.get("id"))
            if identity in seen:
                continue
            seen.add(identity)
            if record.get("device") and record["device"] not in devices:
                devices.append(record["device"])
            source = corpus.get(record.get("corpusId"), {})
            reference = record.get("reference", source.get("reference", ""))
            language = record.get("language", source.get("language", "mixed"))
            status = record.get("status", "unknown")
            row = {"groupId": group.get("id"), "recordId": record.get("id"), "modelId": record.get("modelId", group.get("modelId")), "corpusId": record.get("corpusId"), "language": language, "isSynthetic": record.get("isSynthetic", source.get("isSynthetic")), "threads": group.get("threads"), "effectiveThreads": record.get("effectiveThreads"), "languageHint": record.get("languageHint"), "useITN": record.get("useITN"), "runIndex": record.get("runIndex"), "status": status, "reference": reference, "transcript": record.get("transcript", ""), "audioSeconds": record.get("audioSeconds"), "inferenceMS": record.get("inferenceMS"), "rtf": record.get("rtf"), "modelLoadMS": record.get("modelLoadMS"), "baselineRssKB": record.get("baselineRssKB"), "peakRssKB": record.get("peakRssKB"), "endPssKB": record.get("endPssKB"), "memoryDefinition": record.get("memoryDefinition"), "timingDefinition": record.get("timingDefinition"), "languageScope": record.get("languageScope", ""), "error": record.get("error", ""), "sourceFile": str(path)}
            if status == "completed":
                row.update(metric(language, reference, row["transcript"]))
                if row["audioSeconds"] and row["inferenceMS"] is not None:
                    row["rtfRecomputed"] = row["inferenceMS"] / 1000 / row["audioSeconds"]
            rows.append(row)
    args.output.mkdir(parents=True, exist_ok=True)
    if not rows:
        raise SystemExit("No actual benchmark records found; no report generated.")
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with (args.output / "records.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["modelId"], row["language"], row["threads"])].append(row)
    summary = []
    for (model, language, threads), items in sorted(grouped.items(), key=lambda item: tuple(str(x) for x in item[0])):
        completed = [row for row in items if row["status"] == "completed"]
        total_audio = sum(row["audioSeconds"] or 0 for row in completed)
        total_inference = sum(row["inferenceMS"] or 0 for row in completed)
        total_units = sum(row["referenceUnits"] for row in completed)
        total_errors = sum(row["substitutions"] + row["deletions"] + row["insertions"] for row in completed)
        peak_rss = [row["peakRssKB"] for row in completed if row["peakRssKB"] is not None]
        end_pss = [row["endPssKB"] for row in completed if row["endPssKB"] is not None]
        summary.append({"modelId": model, "language": language, "threads": threads, "completed": len(completed), "failed": sum(row["status"] == "failed" for row in items), "skipped": sum(row["status"] == "skipped" for row in items), "metric": completed[0]["metric"] if completed else None, "errorRate": total_errors / total_units if total_units else None, "audioSeconds": total_audio, "inferenceMS": total_inference, "rtf": total_inference / 1000 / total_audio if total_audio else None, "maxRssMiB": max(peak_rss) / 1024 if peak_rss else None, "maxEndPssMiB": max(end_pss) / 1024 if end_pss else None})
    with (args.output / "summary.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    lines = ["# Android端侧ASR演示音频测试记录", "本报告来自实际App结果JSON。当前语料为macOS本地合成语音，只用于跑通和初步对比，不能代表真实用户录音的识别效果。相同音频重复运行只观察运行波动，不增加独立语料数量。请求线程不等于各框架实际线程，具体effectiveThreads保留在records.csv。", "评分口径与App一致：中文采用CER；英文采用WER，按小写ASCII单词或数字分词；混合语音采用CER（混合字符），每个汉字、英文字母或数字各为一个单位。忽略大小写、标点和空白，不做数字读法、同义词或繁简转换。错误率=(替换+删除+插入)/参考单位数，可能超过100%。失败或跳过记录不计入错误率，另列数量。中文数字参考使用汉字，模型ITN若输出2300或123456，严格CER会把书写形式差异计为编辑错误，不等于数字语义识别错误，应同时查看完整转写。", "RTF=识别调用耗时总和/音频时长总和，模型加载另记。内存是App整个进程的RSS采样峰值和推理结束时PSS快照，PSS不是峰值；1MiB=1024KiB。RSS采样可能漏掉短暂峰值，不能当作模型权重大小。baseline在模型加载后采集。每次运行重新加载识别上下文；后续轮次仅可能受操作系统文件缓存影响，不称为已加载模型的热推理。同一模型的多条记录在同一个App进程中完成，分配器可能保留已释放页面，因此RSS不能作为模型独占内存。模型按固定顺序执行，发热和后台负载可能影响耗时。Vosk中文/英文模型只支持对应单语言，中英混合结果不代表完整双语能力。", "|模型|语言|请求线程|完成/失败/跳过|指标|错误率|RTF|峰值RSS(MiB)|结束PSS快照最大值(MiB)|", "|---|---|---:|---|---|---:|---:|---:|---:|"]
    device_descriptions = [f'{device.get("manufacturer", "")} {device.get("model", "")},Android{device.get("android", "未知")}/API{device.get("sdk", "未知")},硬件{device.get("hardware", "未知")}' for device in devices]
    if device_descriptions:
        lines.insert(2, "设备条件：" + "；".join(device_descriptions).replace("Xiaomi ", "Xiaomi") + "。")
    driver_paths = {((path if path.is_dir() else path.parent) / "driver.json") for path in args.results}
    for driver_path in sorted(driver_paths):
        if not driver_path.is_file():
            continue
        driver = json.loads(driver_path.read_text(encoding="utf-8"))
        before = re.search(r"temperature:\s*(\d+)", driver.get("deviceBefore", {}).get("battery", ""))
        after = re.search(r"temperature:\s*(\d+)", driver.get("deviceAfter", {}).get("battery", ""))
        if before and after:
            lines.insert(3, f'运行时间：{driver.get("startedAt", "未记录")}至{driver.get("endedAt", "未记录")}；电池传感器温度{int(before.group(1))/10:.1f}℃→{int(after.group(1))/10:.1f}℃。此温度不是CPU核心温度，USB充电也可能影响热状态。')
    for row in summary:
        lines.append("|" + "|".join(md_cell(value) for value in [row["modelId"], row["language"], row["threads"], f'{row["completed"]}/{row["failed"]}/{row["skipped"]}', row["metric"], f'{row["errorRate"] * 100:.2f}%' if row["errorRate"] is not None else "未记录", fmt(row["rtf"]), fmt(row["maxRssMiB"], 1), fmt(row["maxEndPssMiB"], 1)]) + "|")
    lines.extend(["## 各文件完整结果", "|模型|音频|轮次|状态|参考文字|识别文字|指标及错误率|错误|", "|---|---|---:|---|---|---|---|---|"])
    for row in rows:
        score = f'{row.get("metric", "")}={row["errorRate"] * 100:.2f}%' if row.get("errorRate") is not None else "未计分"
        lines.append("|" + "|".join(md_cell(value) for value in [row["modelId"], row["corpusId"], row["runIndex"], row["status"], row["reference"], row["transcript"], score, row["error"]]) + "|")
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(rows)} actual records to {args.output}")


if __name__ == "__main__":
    main()
