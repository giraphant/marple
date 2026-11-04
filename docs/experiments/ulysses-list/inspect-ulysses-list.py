#!/usr/bin/env python3
"""Read-only static extraction for Ulysses 42 (84473), arm64.

Requires the user's installed app and Xcode tools. Never launches Ulysses or
reads its document library. Raw proprietary instructions stay outside the repo.
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
    'app': '8cae5b764483e9c1fe6baabd786125669a1ce5f972a1d459cdf2f07bd07f0b88',
    'core': '72c6fec1e2c634e69a3e06b5478e43dcce68b8d97e436be2a4fd95a4a073240b',
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
        wanted = (name.startswith(('ULSheetTable', 'ULSheetHandleTable', 'ULSheetMatchTable', 'ULSheetMatchPlaceholder'))
                  or name in ('ULStorageTableViewController', 'ULTreeController', 'ULTreeNode', 'ULExtendedOutlineView')) if image == 'app' else (
                      name.startswith(('ULSheetHandle', 'ULSheetIndex', 'ULSearchIndex', 'ULSheetMatchNode'))
                      or name in ('ULModelTreeController', 'ULModelTreeRootNode', 'ULImageEntityPreviewCache',
                                  'ULImagePreviewCacheEntry', 'ULSearchResult', 'ULSearchQuery'))
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
    parser.add_argument('--app', type=Path, default=Path('/Applications/UlyssesMac.app'))
    parser.add_argument('--output', type=Path, default=Path('/tmp/marple-ulysses-list-static'))
    parser.add_argument('--class-pattern', help='Optional class-name regex for another UI subsystem')
    args = parser.parse_args()
    images = {
        'app': args.app / 'Contents/MacOS/UlyssesMac',
        'core': args.app / 'Contents/Frameworks/UlyssesCoreMac.framework/UlyssesCoreMac',
    }
    result = {name: extract(name, path, args.output, args.class_pattern) for name, path in images.items()}
    result['range_note'] = 'Unslid arm64 virtual addresses, image-local. Next-IMP ranges can include helper blocks; verify call sites before attributing them.'
    (args.output / 'list-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
    for name in images:
        print(f"{name}: {len(result[name]['methods'])} method ranges")
    print(args.output / 'list-evidence.json')


if __name__ == '__main__':
    main()
