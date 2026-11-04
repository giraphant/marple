#!/usr/bin/env python3
"""Read-only static extraction for the Setapp Ulysses 42 (84473) sidebar, arm64.

Requires the user's installed app and Xcode tools. Never launches Ulysses or
reads its document library. Raw proprietary instructions stay outside the repo.

Same machinery as ../ulysses-list/inspect-ulysses-list.py, pinned to the Setapp
build of the same version (different hashes than the direct-download build) and
selecting the sidebar tree: ULContainerTable*/ULTree*/ULExtended* in the app
binary, ULContainer*/ULLibrary*/ULModelTree* in UlyssesCoreMac.
"""
import argparse
import bisect
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

HASHES = {
    'app': '2b22c34158288f1b752bb67ddb7f5549683335bbbb66d8ba8a0b96b47d372b37',
    'core': '355e41de3cace132f694bda21d7239650056f0fc520644d153f902aac31bdad0',
}


def extract(image, binary, output, class_pattern=None):
    data = binary.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != HASHES[image]:
        raise SystemExit(f'{image}: binary changed; revalidate metadata encoding first')
    output.mkdir(parents=True, exist_ok=True)
    metadata_path = output / f'{image}-objc.txt'
    assembly_path = output / f'{image}-disassembly.txt'
    for path, command in [
        (metadata_path, ['otool', '-arch', 'arm64', '-ov', str(binary)]),
        (assembly_path, ['xcrun', 'llvm-objdump', '--macho', '--arch=arm64',
                         '--disassemble', '--section=__TEXT,__objc_stubs', str(binary)]),
    ]:
        with path.open('wb') as handle:
            subprocess.run(command, stdout=handle, check=True)
    metadata = metadata_path.read_text(errors='replace')
    assembly = assembly_path.read_text(errors='replace')
    base = 0
    if data[:4] == b'\xca\xfe\xba\xbe':
        for index in range(struct.unpack_from('>I', data, 4)[0]):
            cpu, _, offset, _, _ = struct.unpack_from('>IIIII', data, 8 + index * 20)
            if cpu == 0x100000c:
                base = offset
                break
    assert struct.unpack_from('<I', data, base)[0] == 0xfeedfacf
    segments = []
    position = base + 32
    for _ in range(struct.unpack_from('<I', data, base + 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19:
            address, _, offset, length = struct.unpack_from('<QQQQ', data, position + 24)
            segments.append((address, length, base + offset))
        position += size

    def file_offset(address):
        for start, length, offset in segments:
            if start <= address < start + length:
                return offset + address - start
        raise ValueError(f'Unmapped address {address:#x}')

    methods = []
    if image == 'app':
        class_name = selector_name = None
        for line in metadata.splitlines():
            match = re.fullmatch(r'        name\s+0x[\da-f]+ (\w+)', line)
            if match:
                class_name = match[1]
            match = re.fullmatch(r'            name\s+0x[\da-f]+ \((0x[\da-f]+)\)', line)
            if match:
                pointer = struct.unpack_from('<Q', data, file_offset(int(match[1], 16)))[0]
                offset = file_offset(0x100000000 + (pointer & 0xfffffffff))
                selector_name = data[offset:data.index(b'\0', offset)].decode()
            match = re.fullmatch(r'            imp\s+0x[\da-f]+ \((0x[\da-f]+)\)', line)
            if match and selector_name:
                methods.append({'class': class_name, 'selector': selector_name, 'address': int(match[1], 16)})
    else:
        for match in re.finditer(r'\s+imp\s+0x[\da-f]+ \((0x[\da-f]+)\) [-+]\[([^ ]+) (.+)\]', metadata):
            methods.append({'class': match[2], 'selector': match[3], 'address': int(match[1], 16)})
    addresses = sorted({m['address'] for m in methods})
    instructions, stubs = {}, {}
    for line in assembly.splitlines():
        match = re.match(r'\s*([\da-f]+):.*Objc selector ref: (.*)', line)
        if match:
            stubs[int(match[1], 16) - 4] = match[2]
        match = re.match(r'\s*([\da-f]+):', line)
        if match:
            instructions[int(match[1], 16)] = line
    instruction_addresses = sorted(instructions)
    selected = []
    for method in methods:
        name = method['class']
        wanted = (name.startswith(('ULContainerTable', 'ULContainerTextCounter', 'ULTree', 'ULExtended'))
                  or name in ('ULQuickOpenOutlineView',)) if image == 'app' else (
                      name.startswith(('ULContainer', 'ULLibrary'))
                      or name in ('ULModelTreeController', 'ULModelTreeRootNode'))
        if class_pattern is not None:
            wanted = re.search(class_pattern, name) is not None
        if not wanted:
            continue
        start = method['address']
        next_index = bisect.bisect_right(addresses, start)
        if next_index == len(addresses):
            continue
        end = addresses[next_index]
        body = []
        for address in instruction_addresses[bisect.bisect_left(instruction_addresses, start):bisect.bisect_left(instruction_addresses, end)]:
            line = instructions[address]
            call = re.search(r'\b(?:bl|b)\s+0x([\da-f]+)', line)
            if call and int(call[1], 16) in stubs:
                line += ' ; selector: ' + stubs[int(call[1], 16)]
            body.append(line)
        selected.append({**method, 'address': hex(start), 'end': hex(end), 'instructions': body})
    return {'sha256': digest, 'binary': str(binary), 'methods': selected,
            'all_methods': [{**m, 'address': hex(m['address'])} for m in methods]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/Setapp/Ulysses.app'))
    parser.add_argument('--output', type=Path, default=Path('/tmp/marple-ulysses-sidebar-static'))
    parser.add_argument('--class-pattern', help='Optional class-name regex for another UI subsystem')
    args = parser.parse_args()
    images = {
        'app': args.app / 'Contents/MacOS/Ulysses',
        'core': args.app / 'Contents/Frameworks/UlyssesCoreMac.framework/UlyssesCoreMac',
    }
    result = {name: extract(name, path, args.output, args.class_pattern) for name, path in images.items()}
    result['range_note'] = 'Unslid arm64 virtual addresses, image-local. Next-IMP ranges can include helper blocks; verify call sites before attributing them.'
    (args.output / 'sidebar-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
    for name in images:
        print(f"{name}: {len(result[name]['methods'])} method ranges")
    print(args.output / 'sidebar-evidence.json')


if __name__ == '__main__':
    main()
