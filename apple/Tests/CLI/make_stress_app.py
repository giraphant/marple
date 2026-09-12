"""Assemble a separately identified test app without installing or changing PATH."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--resources-from', type=Path, required=True)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.output.exists():
    parser.error('--output must not already exist')
shutil.copytree(args.resources_from, args.output)
contents = args.output / 'Contents'
for source, name in ((args.binary, 'Marple'), (args.cli, 'marple-cli')):
    shutil.copy2(source, contents / 'MacOS' / name)
plist = contents / 'Info.plist'
with plist.open('rb') as stream:
    info = plistlib.load(stream)
info['CFBundleIdentifier'] = 'com.marple.stress.' + uuid.uuid4().hex
info.pop('CFBundleURLTypes', None)
with plist.open('wb') as stream:
    plistlib.dump(info, stream)
# Non-Mach-O Metal library signatures are xattrs and may be lost during copying.
for name in ('mlx.metallib', 'marple-cli'):
    item = contents / 'MacOS' / name
    if item.exists():
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(item)], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(args.output)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(args.output)], check=True)
print(args.output.resolve())
