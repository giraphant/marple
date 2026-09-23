"""Exercise collection argument parsing and JSON transport against a temporary socket."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import uuid

binary = Path(sys.argv[1]).resolve()
key = str(uuid.uuid4()).upper()
cases = [
    (["collections", "list"], {"action": "list", "paths": [], "dryRun": False}),
    (["collections", "create", "维修资料", "--request-id", key], {"action": "create", "paths": [], "name": "维修资料", "dryRun": False, "requestID": key}),
    (["collections", "rename", "vault/archives/旧", "新", "--dry-run"], {"action": "rename", "paths": ["vault/archives/旧"], "name": "新", "dryRun": True}),
    (["collections", "move", "vault/archives/a", "vault/archives/b/archive.md", "--to", "vault/archives/新", "--dry-run"], {"action": "move", "paths": ["vault/archives/a", "vault/archives/b/archive.md"], "destination": "vault/archives/新", "dryRun": True}),
    (["collections", "status", key], {"action": "status", "paths": [], "dryRun": False, "requestID": key}),
]
with tempfile.TemporaryDirectory(prefix="collection-cli-", dir="/tmp") as home:
    address = Path(home) / "Library/Application Support/Marple/cli.sock"
    address.parent.mkdir(parents=True)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(address))
        server.listen(1)
        server.settimeout(5)
        for arguments, expected in cases:
            process = subprocess.Popen([str(binary), *arguments], env=dict(os.environ, CFFIXED_USER_HOME=home), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                connection, _ = server.accept()
                with connection:
                    with connection.makefile("rb") as stream:
                        actual = json.loads(stream.readline())
                    connection.sendall(b'{"ok":true}\n')
                stdout, stderr = process.communicate(timeout=5)
                assert actual == {"method": "collections", "collection": expected}, (arguments, actual)
                assert process.returncode == 0 and json.loads(stdout)["ok"], (stdout, stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
print(f"Passed {len(cases)} collection CLI socket cases.")
