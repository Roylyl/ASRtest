"""Shared monorepo paths for Android tools; independent of the caller's cwd."""
from pathlib import Path
import os

APP_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = APP_ROOT.parents[1]
SHARED_ASSETS = REPO_ROOT / 'shared/assets'
MODEL_LIBRARY = SHARED_ASSETS / 'ModelLibrary'
DEMO_CORPUS = SHARED_ASSETS / 'evaluation/demo'
WHISPER_SOURCE = REPO_ROOT / 'Vendor/whisper.cpp'
LLAMA_SOURCE = REPO_ROOT / 'Vendor/Fun-ASR/third_party/llama.cpp'


def repo_relative(path):
    try:
        return str(Path(path).resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(Path(path).resolve())


def android_sdk():
    for name in ('ANDROID_SDK_ROOT', 'ANDROID_HOME'):
        if os.environ.get(name):
            return Path(os.environ[name]).expanduser()
    local = APP_ROOT / 'local.properties'
    if local.is_file():
        for line in local.read_text().splitlines():
            if line.startswith('sdk.dir='):
                return Path(line.split('=', 1)[1].replace('\\:', ':').replace('\\\\', '\\'))
    candidates = [Path.home() / 'Library/Android/sdk', Path.home() / 'Android/Sdk']
    if os.environ.get('LOCALAPPDATA'):
        candidates.append(Path(os.environ['LOCALAPPDATA']) / 'Android/Sdk')
    return next((path for path in candidates if path.is_dir()), candidates[0])
