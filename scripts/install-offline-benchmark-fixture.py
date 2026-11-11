#!/usr/bin/env python3
"""Install an already-downloaded bare repository for simulator benchmarks. Never fetches."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('repository', type=Path, help='Existing local bare repository; no URL accepted')
parser.add_argument('--device', required=True, help='Booted simulator UDID')
args = parser.parse_args()
source = args.repository.resolve()
if not source.is_dir():
    parser.error('A local repository directory is required; this script never downloads one.')

def git(*arguments):
    return subprocess.check_output(['git', '--git-dir', str(source), *arguments], text=True).strip()

if git('rev-parse', '--is-bare-repository') != 'true':
    parser.error('The source must be a bare repository.')
if git('remote'):
    parser.error('Remove remotes from the benchmark source before installing it.')
if (source / 'shallow').exists():
    parser.error('A complete history is required, not a shallow clone.')
head = git('symbolic-ref', '--short', 'HEAD')
branches = git('for-each-ref', '--format=%(refname:short)', 'refs/heads').splitlines()
comparisons = []
for branch in branches:
    if branch == head:
        continue
    comparisons.append({
        'branch': branch,
        'commits': int(git('rev-list', '--count', branch)),
        'changedPaths': len(git('diff', '--name-only', '-z', head, branch).split('\0')) - 1,
    })
comparisons.sort(key=lambda row: (row['changedPaths'], row['commits']))
nonempty = [row for row in comparisons if row['changedPaths'] > 0]
targets = []
if nonempty:
    targets.append(nonempty[0])
    if nonempty[-1]['branch'] != nonempty[0]['branch']:
        targets.append(nonempty[-1])
manifest = {
    'version': 1,
    'head': head,
    'headOID': git('rev-parse', 'HEAD'),
    'headCommits': int(git('rev-list', '--count', 'HEAD')),
    'allCommits': int(git('rev-list', '--branches', '--count')),
    'branchCount': len(branches),
    'trackedFiles': len(git('ls-tree', '-r', '--name-only', '-z', 'HEAD').split('\0')) - 1,
    'targets': targets,
}
environment = os.environ.copy()
environment.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
container = Path(subprocess.check_output([
    'xcrun', 'simctl', 'get_app_container', args.device,
    'com.maneeshacooray.gitling.ios', 'data',
], text=True, env=environment).strip())
directory = container / 'Documents' / 'OfflineBenchmarks'
directory.mkdir(parents=True, exist_ok=True)
# Replace only our fixture, never the application's repositories directory.
destination = directory / 'fixture.git'
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination)
(directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
print('Installed local-only benchmark fixture:', directory)
