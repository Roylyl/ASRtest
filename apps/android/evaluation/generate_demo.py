#!/usr/bin/env python3
"""Recreate the bundled synthetic smoke corpus with macOS local voices."""
import json
import pathlib
import subprocess
import tempfile
import wave

APP_ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = APP_ROOT.parents[1]
DEMO = REPO_ROOT / "shared/assets/evaluation/demo"
SAMPLES = [
    ("zh_short", "zh", "今天下午三点，请提醒我参加项目会议。", [("Tingting", "今天下午三点，请提醒我参加项目会议。")]),
    ("zh_numbers", "zh", "这台手机售价两千三百元，订单编号是一二三四五六。", [("Tingting", "这台手机售价两千三百元，订单编号是一二三四五六。")]),
    ("en_short", "en", "Please remind me to attend the project meeting at three this afternoon.", [("Samantha", "Please remind me to attend the project meeting at three this afternoon.")]),
    ("mixed_short", "mixed", "请打开蓝牙，连接我的Bluetooth speaker，然后播放音乐。", [("Tingting", "请打开蓝牙，连接我的"), ("Samantha", "Bluetooth speaker"), ("Tingting", "然后播放音乐。")]),
]


def main():
    DEMO.mkdir(parents=True, exist_ok=True)
    corpus = []
    with tempfile.TemporaryDirectory(prefix="asrtest-demo-") as temp:
        for sample_id, language, reference, segments in SAMPLES:
            frames = bytearray(b"\0" * 16000)  # 0.5 seconds of leading silence.
            for index, (voice, sentence) in enumerate(segments):
                part = pathlib.Path(temp) / f"{sample_id}-{index}.wav"
                subprocess.run(["/usr/bin/say", "-v", voice, "-r", "180", "-o", str(part), "--file-format=WAVE", "--data-format=LEI16@16000", sentence], check=True)
                with wave.open(str(part), "rb") as audio:
                    if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                        raise RuntimeError(f"Unexpected audio format: {part}")
                    frames.extend(audio.readframes(audio.getnframes()))
                if index + 1 < len(segments):
                    frames.extend(b"\0" * 4800)  # 0.15 seconds between language segments.
            frames.extend(b"\0" * 16000)
            filename = f"{sample_id}.wav"
            with wave.open(str(DEMO / filename), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16000)
                audio.writeframes(frames)
            corpus.append({"id": sample_id, "file": filename, "reference": reference, "language": language, "source": "macOS say local synthesized speech; " + "+".join(voice for voice, _ in segments), "isSynthetic": True, "sampleRate": 16000, "channels": 1, "durationSeconds": len(frames) / 32000})
    (DEMO / "corpus.json").write_text(json.dumps(corpus, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(corpus, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
