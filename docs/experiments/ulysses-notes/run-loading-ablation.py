#!/usr/bin/env python3
"""Temporarily ablate only the Notes loading patch, test, and restore it.

Run from the same checkout after applying the fix. No installed app or vault is
used. A finally block restores AppModel.swift, including on test/build failure.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[3]
relative = 'apple/Sources/Marple/App/AppModel.swift'
source = root / relative
final = source.read_text()
head = json.loads((Path(__file__).parent / 'notes-loading-ablation.json').read_text())['baseline_commit']
baseline = subprocess.check_output(['git', 'show', f'{head}:{relative}'], cwd=root, text=True)

def replace_once(text, old, new):
    assert text.count(old) == 1, 'Source changed; review ablation anchors before running'
    return text.replace(old, new, 1)

no_dedup = replace_once(final, '''        if let task = inspectorNoteLoadTasks[path] {
            await task.value
            return
        }
''', '')
no_stale = replace_once(final, '                guard generation == inspectorNoteLoadGeneration, !Task.isCancelled else { return }\n', '')
no_stale = replace_once(no_stale, '''                guard generation == inspectorNoteLoadGeneration, !Task.isCancelled,
                      inspectorNoteDrafts[path] == nil else { return }
''', '                guard inspectorNoteDrafts[path] == nil else { return }\n')
no_draft = replace_once(final, '                guard inspectorNoteOriginals[path] == nil else { return }\n', '')
no_draft = replace_once(no_draft, '''                if let draft = inspectorNoteDrafts[path] {
                    // Preserve edits made while reading, including clearing the note.
                    if inspectorNoteStatuses[path] != .saving {
                        inspectorNoteStatuses[path] = draft == body ? .saved : .dirty
                        if draft != body { scheduleInspectorNoteSave(path: path) }
                    }
                } else {
                    inspectorNoteDrafts[path] = body
                    inspectorNoteStatuses[path] = .idle
                }
''', '''                inspectorNoteDrafts[path] = body
                inspectorNoteStatuses[path] = .idle
''')
variants = [('baseline', baseline), ('without_read_sharing', no_dedup),
            ('without_stale_result_guards', no_stale),
            ('without_draft_and_saved_baseline_preservation', no_draft), ('full_fix', final)]
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
assert (frameworks / 'Testing.framework/Testing').exists()
env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(frameworks))
command = ['swift', 'test', '--package-path', 'apple', '--build-system', 'native',
           '-Xlinker', str(frameworks / 'Testing.framework/Testing'),
           '--filter', 'InspectorNoteLoadingTests']
results = []
try:
    for name, text in variants:
        source.write_text(text)
        log_path = Path(f'/tmp/marple-notes-loading-{name}.log')
        with log_path.open('w') as log:
            result = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        log = log_path.read_text()
        assert 'Test run with' in log, f'{name}: build/runtime failed; inspect {log_path}'
        failed = re.findall(r'✘ Test (\w+\([^\n]*?\))(?: with \d+ test cases)? failed after', log)
        passed = re.findall(r'✔ Test (\w+\([^\n]*?\))(?: with \d+ test cases)? passed after', log)
        assert (result.returncode == 0) == (name == 'full_fix'), f'Unexpected result: {name}'
        results.append(dict(variant=name, exit_code=result.returncode,
                            passed=passed, failed=failed,
                            source_sha256=hashlib.sha256(text.encode()).hexdigest()))
        print(f'{name}: {len(passed)} passed, {len(failed)} failed', flush=True)
finally:
    source.write_text(final)
output = dict(baseline_commit=head, command=command,
              test_source_sha256=hashlib.sha256((root / 'apple/Tests/MarpleKitTests/InspectorNoteLoadingTests.swift').read_bytes()).hexdigest(),
              variants=results,
              limits=['Controlled stub I/O; no user files, real-disk latency, or full-app FPS.',
                      'Stale-result arm disables publication guards but retains task cancellation and cleanup.',
                      'Draft arm removes preservation of both local edits and a newer completed save.'])
(root / 'docs/experiments/ulysses-notes/notes-loading-ablation.json').write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
