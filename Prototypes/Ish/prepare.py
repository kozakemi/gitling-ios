#!/usr/bin/env python3
"""Fetch pinned runtime artifacts once; subsequent prototype runs are offline."""
import hashlib
import io
import json
import zlib
from pathlib import Path
import tarfile
import urllib.request
import zipfile
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'build/ish-prototype'

def kernel_source_path():
    cached = CACHE / 'IshEmbed/third_party/ish'
    return cached if (cached / 'kernel/task.c').exists() else CACHE / 'kernel-source'

def prepare_kernel_source(row):
    source = kernel_source_path()
    if not (source / 'kernel/task.c').exists():
        source.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git','init','-q',str(source)], check=True)
        subprocess.run(['git','-C',str(source),'fetch','--depth','1','--no-tags',row['url'],row['revision']], check=True)
        subprocess.run(['git','-C',str(source),'checkout','--detach','-q','FETCH_HEAD'], check=True)
    revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    if revision != row['revision']:
        raise ValueError('Pinned kernel source revision mismatch')

def safe_path(root, name):
    target = (root / name).resolve()
    if target != root.resolve() and root.resolve() not in target.parents:
        raise ValueError('Archive path escapes cache: ' + name)
    return target

def gzip_streams(data):
    pos = 0
    streams = []
    while pos < len(data) and data[pos:pos + 2] == b'\x1f\x8b':
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        payload = decoder.decompress(data[pos:]) + decoder.flush()
        pos += len(data) - pos - len(decoder.unused_data)
        streams.append(payload)
    return streams

def terminfo_entry(data, name):
    # The package hardlinks one entry, which this filesystem rejects. Extract the
    # regular xterm-256color description and install that file directly.
    payload = gzip_streams(data)[2]
    archive = tarfile.open(fileobj=io.BytesIO(payload), mode='r:')
    return archive.extractfile(name).read()

def download(row, path):
    if not path.exists():
        data = urllib.request.urlopen(row['url'], timeout=60).read()
        if hashlib.sha256(data).hexdigest() != row['sha256']:
            raise ValueError('Checksum mismatch: ' + row['url'])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    if hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
        raise ValueError('Cached checksum mismatch: ' + str(path))

def main():
    manifest = json.loads((ROOT / 'Prototypes/Ish/dependencies.json').read_text())
    prepare_kernel_source(manifest['kernelSource'])
    CACHE.mkdir(parents=True, exist_ok=True)
    download(manifest['kernel'], CACHE / 'kernel.zip')
    download(manifest['rootfs'], CACHE / 'fs.tar.gz')
    for package in manifest['packages']:
        download(package, CACHE / 'packages' / package['name'])
    allowed = {r['name'] for r in manifest['packages']}
    extra = {p.name for p in (CACHE / 'packages').glob('*.apk')} - allowed
    if extra:
        raise ValueError('Unpinned APK files in cache: ' + str(extra))
    terminfo = manifest['terminfo']
    download(terminfo, CACHE / 'terminfo-source.apk')
    entry = terminfo_entry((CACHE / 'terminfo-source.apk').read_bytes(), terminfo['entry'])
    if hashlib.sha256(entry).hexdigest() != terminfo['fileSha256']:
        raise ValueError('Terminfo entry checksum mismatch')
    (CACHE / terminfo['name']).write_bytes(entry)
    kernel = CACHE / 'kernel'
    with zipfile.ZipFile(CACHE / 'kernel.zip') as archive:
        for info in archive.infolist():
            safe_path(kernel, info.filename)
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('Archive symlink: ' + info.filename)
        archive.extractall(kernel)
    rootfs = CACHE / 'rootfs-original'
    if not rootfs.exists():
        with tarfile.open(CACHE / 'fs.tar.gz') as archive:
            for member in archive.getmembers():
                safe_path(rootfs, member.name)
                # fakefs represents Linux symlinks in metadata; this artifact
                # needs only regular files and directories on the host.
                if not (member.isfile() or member.isdir()):
                    raise ValueError('Unexpected archive member: ' + member.name)
            archive.extractall(rootfs)
    print('Pinned runtime, rootfs and offline packages verified.')

if __name__ == '__main__':
    main()
