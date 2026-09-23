"""Run all 8 source ablations in a disposable package copy (macOS).

The input package must contain the completed resilience changes. Reverse patches
remove one mechanism at a time. The metadata injection seam, mutate envelope,
and client SIGPIPE protection remain in all variants so identical behavior tests
compile and reach the bug. The replay bit toggles server admission/cache.
000 is therefore a diagnostic control, not the pristine pre-change app.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

GROUPS = {
    'metadata': {'stalledPathTimesOutWhileHealthyPathsProgress',
                 'repeatedStalledPathDoesNotConsumeAnotherWorker',
                 'saturatedReaderSkipsInsteadOfSpawningUnboundedWorkers',
                 'unavailableMetadataRetainsExistingRowAndIndexesHealthyFile'},
    'ping': {'pingDoesNotCrossMainActorFromAcceptQueue'},
    'replay': {'replaySurvivesLostResponseAndRejectsChangedPayload',
               'concurrentMutationDuplicatesCreateOneFolder',
               'absentRecoveryNeverExecutesAnotherWrite',
               'dissolveReplaysOriginalSuccessAndValidationErrorsAreCached',
               'invalidKeysAndUnsupportedOperationsDoNotExecute'},
}
TEST_FILTER = '|'.join(sorted(set.union(*GROUPS.values()))) + '|fullRebuildKeepsReadableFilesWhenMetadataIsUnavailable'


def hashes(source):
    return {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(source.rglob('*.swift'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--out', type=Path, required=True, help='New disposable directory')
    parser.add_argument('--resources-from', type=Path, help='Also assemble single-fix and combined apps')
    parser.add_argument('--prepare-only', action='store_true', help='Verify all patches/hashes without compiling')
    args = parser.parse_args()
    original, out = args.package.resolve(), args.out.resolve()
    if out.is_relative_to(original):
        parser.error('--out must be outside the input package')
    out.mkdir(parents=True, exist_ok=False)
    package, fixed = out / 'package', out / 'fixed'
    shutil.copytree(original, package, ignore=shutil.ignore_patterns('.build*', '.git', '__pycache__', 'DerivedData'))
    shutil.copytree(package / 'Sources', fixed)
    if not args.prepare_only:
        (package / '.build').mkdir()
        for name in ('checkouts', 'repositories', 'workspace-state.json'):
            cached = original / '.build' / name
            if cached.exists():
                subprocess.run(['/bin/cp', '-cR', str(cached), str(package / '.build' / name)], check=True)
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
               DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'),
               CLANG_MODULE_CACHE_PATH=str(out / 'clang-cache'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(out / 'module-cache'))
    source = package / 'Sources'
    patches = Path(__file__).resolve().parent / 'ablation'
    summary = []
    try:
        for bits in itertools.product((False, True), repeat=3):
            shutil.copytree(fixed, source, dirs_exist_ok=True)
            flags = dict(zip(GROUPS, bits))
            name = ''.join('1' if value else '0' for value in bits)
            for group, enabled in flags.items():
                if not enabled:
                    command = ['/usr/bin/git', 'apply', str(patches / (group + '.patch'))]
                    subprocess.run(command[:2] + ['--check'] + command[2:], cwd=package, env=env, check=True)
                    subprocess.run(command, cwd=package, env=env, check=True)
            (out / (name + '-sources.json')).write_text(json.dumps(hashes(source), indent=2))
            if args.prepare_only:
                continue
            expected = sorted(set.union(*(GROUPS[k] for k, enabled in flags.items() if not enabled), set()))
            log_path = out / (name + '.log')
            command = ['/usr/bin/xcrun', 'swift', 'test', '--disable-sandbox', '--skip-update',
                       '-j', '8', '--filter', TEST_FILTER]
            with log_path.open('w') as log:
                completed = subprocess.run(command, cwd=package, env=env, stdout=log,
                                           stderr=subprocess.STDOUT, timeout=900)
            text = log_path.read_text()
            failed = sorted(set(re.findall(r'^✘ Test (\w+)\(', text, re.MULTILINE)))
            valid = ('Build complete!' in text and 'Test run with 11 tests' in text
                     and failed == expected and ((completed.returncode == 0) == (not expected)))
            row = dict(variant=name, enabled=flags, exit=completed.returncode,
                       expected_failures=expected, actual_failures=failed, matched=valid)
            summary.append(row)
            (out / 'results.json').write_text(json.dumps(summary, indent=2))
            print(json.dumps(row), flush=True)
            if not valid:
                raise RuntimeError(f'{name}: unexpected test or build result; inspect {log_path}')
            if args.resources_from and name in {'100', '010', '001', '111'}:
                subprocess.run(['/usr/bin/python3', str(package / 'Tests/CLI/make_stress_app.py'),
                    '--resources-from', str(args.resources_from.resolve()),
                    '--binary', str(package / '.build/debug/Marple'),
                    '--cli', str(package / '.build/debug/marple-cli'),
                    '--output', str(out / (name + '.app'))], env=env, check=True)
    finally:
        shutil.copytree(fixed, source, dirs_exist_ok=True)
    print('All eight source variants verified.' if args.prepare_only else
          'All eight ablations matched the expected independent failures.', flush=True)


if __name__ == '__main__':
    main()
