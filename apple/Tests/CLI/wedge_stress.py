"""Real-app write/CLI stress. Never uses the user's vault or default CLI socket.

Run with --app /path/to/Marple.app --out /tmp/unique-run. Each invocation starts
and stops its own process. A nonzero exit distinguishes startup failure (2),
persistent CLI failure (3), process exit (4), and incomplete indexing (5).
Samples and raw per-command measurements are retained, including passing runs.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--cli', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--seed', type=int, default=1000)
    parser.add_argument('--papers', type=int, default=120)
    parser.add_argument('--books', type=int, default=3)
    parser.add_argument('--chapters', type=int, default=24)
    parser.add_argument('--interval', type=float, default=.2)
    parser.add_argument('--burst-every', type=int, default=8)
    parser.add_argument('--burst-gap', type=float, default=.7)
    parser.add_argument('--settle', type=float, default=60)
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--tabs', type=int, default=100)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root, user = out / 'workspace', out / 'home'
    vault = root / 'vault'
    vault.mkdir(parents=True)
    user.mkdir()
    address = user / 'Library/Application Support/Marple/cli.sock'
    if len(str(address).encode()) >= 104:
        raise ValueError('Choose a shorter --out path: Unix sockets allow 103 bytes')
    app = args.app.resolve()
    binary = app / 'Contents/MacOS/Marple'
    cli = args.cli.resolve() if args.cli else app / 'Contents/MacOS/marple-cli'
    with (app / 'Contents/Info.plist').open('rb') as f:
        bundle_id = plistlib.load(f)['CFBundleIdentifier']
    if bundle_id == 'com.marple.app':
        raise ValueError('Use an isolated test bundle ID, not com.marple.app')
    # Use only the environment needed by the launched programs; no agent tokens.
    env = {k: os.environ[k] for k in ('PATH', 'TMPDIR', 'LANG') if k in os.environ}
    env.update(CFFIXED_USER_HOME=str(user), MARPLE_MEMORY_WATCHDOG='1',
               TSAN_OPTIONS=f'log_path={out}/tsan:halt_on_error=0')
    records, lock, stop = [], threading.Lock(), threading.Event()
    log = (out / 'requests.jsonl').open('w')
    sampled = threading.Event()
    started = time.monotonic()
    process = None
    tab_ids = []

    def record(data):
        data['t'] = round(time.monotonic() - started, 3)
        with lock:
            records.append(data)
            log.write(json.dumps(data, ensure_ascii=False) + '\n')
            log.flush()

    def call(command):
        begin = time.monotonic()
        try:
            result = subprocess.run([str(cli), *command], env=env,
                                    capture_output=True, text=True, timeout=12)
            response = json.loads(result.stdout)
            ok = result.returncode == 0 and response.get('ok') is True
            record(dict(command=command, elapsed=round(time.monotonic()-begin, 4),
                        ok=ok, exit=result.returncode, error=response.get('error')))
            return response if ok else None
        except (subprocess.TimeoutExpired, ValueError, OSError) as exc:
            record(dict(command=command, elapsed=round(time.monotonic()-begin, 4),
                        ok=False, error=str(exc)))
            return None

    def document(relative, number, kind='paper', book=None):
        path = vault / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        metadata = (f'---\ntype: {kind}\ntitle: "压力测试 文献 {number}"\n'
                    f'author: "Author {number % 31}"\nyear: 2026\n')
        if book:
            metadata += f'book: "{book}"\nchapter: {number}\n'
        text = metadata + '---\n\n' + (
            f'Critical reading {number}: social theory, evidence, language, interpretation. '
            '知识与权力，文献研究，历史解释。\n' * 18)
        temporary = path.with_suffix('.pending')
        temporary.write_text(text)
        temporary.replace(path)

    def sample(reason):
        if sampled.is_set() or process.poll() is not None:
            return
        sampled.set()
        record(dict(event='sample', reason=reason))
        subprocess.run(['/usr/bin/sample', str(process.pid), '3', '1', '-file',
                        str(out / 'wedge.sample')], capture_output=True, timeout=15)
        result = subprocess.run(['/bin/ps', '-p', str(process.pid), '-o',
                                 'pid,state,%cpu,rss,time,command'], capture_output=True, text=True)
        (out / 'process.txt').write_text(result.stdout + result.stderr)

    def read_loop(command):
        failures = 0
        while not stop.is_set():
            failures = 0 if call(command) else failures + 1
            if failures >= 3:
                sample('three consecutive failures: ' + ' '.join(command))
            stop.wait(.08)

    def folders(worker):
        number = 0
        while not stop.is_set():
            title = f'Stress {worker}-{number}'
            items = tab_ids[worker * 4:(worker + 1) * 4]
            created = call(['folders', 'create', title] + (['--items', *items] if items else []))
            if created:
                folder = created.get('data', {}).get('createdID')
                if folder:
                    call(['folders', 'dissolve', folder])
            number += 1
            stop.wait(.08)

    def count_entries():
        try:
            db = sqlite3.connect(f'file:{root}/.marple/index.sqlite?mode=ro', uri=True, timeout=1)
            with db:
                count = db.execute('SELECT count(*) FROM entries').fetchone()[0]
            db.close()
            return count
        except sqlite3.Error:
            return None

    for i in range(args.seed):
        document(f'papers/seed-{i:05}.md', i)
    document('notes/start.md', 0, 'note')
    manifest = {**vars(args), 'app': str(app), 'cli': str(cli), 'out': str(out),
                'bundle_id': bundle_id, 'expected': args.seed + 1 + args.papers + args.books * (args.chapters + 1)}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2, default=str))
    launch_log = (out / 'launch.log').open('w')
    try:
        process = subprocess.Popen([str(binary), '-marple.workspaceRoot', str(root),
                                    '-marple.cliServerEnabled', 'YES', '-marple.backupEnabled', 'NO'],
                                   env=env, cwd=out, stdout=launch_log, stderr=launch_log)
        (out / 'pid').write_text(str(process.pid))
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and process.poll() is None:
            if address.exists() and call(['ping']):
                break
            time.sleep(.5)
        else:
            record(dict(event='startup_failed', exit=process.poll()))
            return 2
        # Prove CLI isolation with a read-only request before any mutations.
        if not address.is_socket():
            raise RuntimeError('isolated socket missing')
        call(['open', 'vault/notes/start.md'])
        for i in range(min(args.tabs, args.seed)):
            if not call(['open', f'vault/papers/seed-{i:05}.md']):
                raise RuntimeError('failed to prepare tabs')
        initial_tree = call(['tabs', 'list'])
        if not initial_tree:
            raise RuntimeError('failed to read initial tab IDs')
        tab_ids = [node['id'] for node in initial_tree.get('data', {}).get('tree', [])
                   if node.get('kind') == 'tab']
        with ThreadPoolExecutor(max_workers=args.workers + 2) as pool:
            tasks = [pool.submit(read_loop, ['ping']), pool.submit(read_loop, ['tabs', 'list'])]
            tasks += [pool.submit(folders, worker) for worker in range(args.workers)]
            for i in range(max(args.papers, args.books * (args.chapters + 1))):
                if process.poll() is not None:
                    break
                if i < args.papers:
                    document(f'papers/new-{i:05}.md', i + args.seed)
                if i < args.books * (args.chapters + 1):
                    book, chapter = divmod(i, args.chapters + 1)
                    document(f'books/book-{book}/' + ('index.md' if chapter == 0 else f'{chapter:02}.md'),
                             chapter, 'book' if chapter == 0 else 'chapter', f'Book {book}')
                if i % 20 == 0:
                    record(dict(event='write_progress', iteration=i, indexed=count_entries()))
                time.sleep(args.interval)
                if args.burst_every and (i + 1) % args.burst_every == 0:
                    time.sleep(args.burst_gap)
            deadline = time.monotonic() + args.settle
            while time.monotonic() < deadline and process.poll() is None:
                record(dict(event='settle', indexed=count_entries()))
                time.sleep(5)
            stop.set()
            for future in tasks:
                future.result()
        # Persistent means failures still occur after writes and the drain period.
        final = [bool(call(['ping'])) and bool(call(['tabs', 'list'])) for _ in range(3)]
        count = count_entries()
        code = 4 if process.poll() is not None else 3 if not any(final) else 5 if count != manifest['expected'] else 0
        if code:
            sample('final check failed')
        summary = dict(exit=code, indexed=count, expected=manifest['expected'],
                       final_health=final, commands=sum('command' in x for x in records),
                       failures=sum(x.get('ok') is False for x in records),
                       duration=round(time.monotonic()-started, 2))
        (out / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary), flush=True)
        return code
    finally:
        stop.set()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        log.close()
        launch_log.close()


if __name__ == '__main__':
    raise SystemExit(main())
