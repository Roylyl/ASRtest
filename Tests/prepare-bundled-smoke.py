#!/usr/bin/env python3
"""Copy physical model resources into a disposable test bundle; never use App Support."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
if not app.is_relative_to((root / 'Tests').resolve()) or app.suffix != '.app':
    raise SystemExit('Test bundle must be a .app inside project Tests')
source = Path(os.environ.get('BUNDLED_MODELS_ROOT', str(root / 'ModelLibrary'))).absolute()
if not source.is_dir() or source.is_symlink():
    raise SystemExit(f'Model source must be a physical directory: {source}')
manifest = source.parent / 'ModelsManifest.json'
if not manifest.is_file():
    raise SystemExit(f'The model source must have a sibling ModelsManifest.json: {manifest}')
value = json.loads(manifest.read_text())
expected = {'zipformer','whisperTiny','whisperBase','voskChinese','voskEnglish','senseVoice','paraformer','nano'}
if {model['id'] for model in value['models']} != expected:
    raise SystemExit('Source manifest must contain exactly the eight model configurations')
for model in value['models']:
    if not (source / model['id']).is_dir() or (source / model['id']).is_symlink():
        raise SystemExit(f"Missing physical model folder: {model['id']}")
app.mkdir(parents=True, exist_ok=True)
# Delete only this helper's known generated resources, including the old linked
# StarterModels resource from earlier test builds, so stale files cannot pass.
for name in ['ModelLibrary', 'StarterModels']:
    old = app / name
    if old.is_symlink():
        old.unlink()
    elif old.exists():
        shutil.rmtree(old)
shutil.copyfile(manifest, app / 'ModelsManifest.json')
subprocess.run(['/bin/cp', '-cR', str(source), str(app / 'ModelLibrary')], check=True)
report = {
    'prepared_at': datetime.datetime.now().astimezone().isoformat(),
    'source_models': str(source),
    'source_manifest': str(manifest),
    'source_is_app_bundle': source.parent.suffix == '.app',
    'explicit_source_override': 'BUNDLED_MODELS_ROOT' in os.environ,
    'source_manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
    'destination_bundle': str(app),
    'resource_directory': 'ModelLibrary',
    'copy': 'physical APFS clone, not symbolic link',
    'models': [model['id'] for model in value['models']],
    'manifest_model_bytes': sum(file['bytes'] for model in value['models'] for file in model['files'])
}
(app.parent / 'bundle-source.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f"Physical bundle models prepared from: {source}")
