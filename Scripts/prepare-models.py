#!/usr/bin/env python3
"""Prepare/verify ModelLibrary from ModelsManifest.json before building the app.
Xcode bundles this local ModelLibrary; the app itself never downloads models.
Build-time downloads use pinned sources and verified checksums.
Usage: python3 Scripts/prepare-models.py [--verify-only] [--model senseVoice]
"""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, tempfile, zipfile
ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'ModelLibrary'
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def safe_child(root, name):
    path=(root/name).resolve()
    if root.resolve() not in path.parents: raise ValueError(f'Unsafe relative path: {name}')
    return path
def valid(path, row):
    return path.is_file() and path.stat().st_size==row['bytes'] and digest(path)==row['sha256']
def download(url, destination):
    subprocess.run(['curl','--fail','--location','--retry','3','--output',str(destination),url],check=True)
def prepare(model, verify_only):
    folder=safe_child(LIBRARY, model['id'])
    missing=[row for row in model['files'] if not valid(safe_child(folder,row['path']),row)]
    if missing and verify_only: raise RuntimeError(f"{model['id']}: {len(missing)} absent or invalid files")
    if missing:
        folder.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='ASRtest-model-') as temp:
            temp=Path(temp)
            if model.get('archive_url'):
                archive=temp/'model.zip'; download(model['archive_url'],archive)
                if digest(archive)!=model['archive_sha256']: raise RuntimeError('Archive SHA256 mismatch')
                with zipfile.ZipFile(archive) as package:
                    for row in missing:
                        candidate=temp/'file.tmp'
                        with package.open(row['archive_path']) as src, candidate.open('wb') as dst: shutil.copyfileobj(src,dst)
                        if not valid(candidate,row): raise RuntimeError(f"SHA256 mismatch: {row['path']}")
                        destination=safe_child(folder,row['path']); destination.parent.mkdir(parents=True,exist_ok=True)
                        shutil.copyfile(candidate,destination)
            else:
                for row in missing:
                    candidate=temp/'file.tmp'; download(row['url'],candidate)
                    if not valid(candidate,row): raise RuntimeError(f"SHA256 mismatch: {row['path']}")
                    destination=safe_child(folder,row['path']); destination.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copyfile(candidate,destination)
    print(f"Verified {model['id']}: {len(model['files'])} files, {sum(row['bytes'] for row in model['files'])} bytes",flush=True)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-only',action='store_true')
    parser.add_argument('--model',action='append',default=[])
    args=parser.parse_args()
    manifest=json.loads((ROOT/'ModelsManifest.json').read_text())
    models=[m for m in manifest['models'] if not args.model or m['id'] in args.model]
    unknown=set(args.model)-{m['id'] for m in models}
    if unknown:parser.error('Unknown model IDs: '+', '.join(sorted(unknown)))
    for model in models:prepare(model,args.verify_only)
if __name__=='__main__':main()
