"""Check the built CLI's argument-to-wire mapping using an isolated local socket."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import uuid


binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / ".build/debug/marple-cli"
first = "11111111-1111-1111-1111-111111111111"
second = "22222222-2222-2222-2222-222222222222"
folder = "33333333-3333-3333-3333-333333333333"
cases = [
    (["tabs", "list"], {"method": "tabs.list"}),
    (["tabs", "rename", first, "读书笔记"], {"method": "tabs.rename", "id": first, "title": "读书笔记", "reset": False}),
    (["tabs", "rename", first, "--reset"], {"method": "tabs.rename", "id": first, "reset": True}),
    (["tabs", "move", second, first, "--after", folder], {"method": "tabs.move", "ids": [second, first], "after": folder, "root": False}),
    (["tabs", "move", first, "--before", second], {"method": "tabs.move", "ids": [first], "before": second, "root": False}),
    (["tabs", "move", first, "--parent", folder], {"method": "tabs.move", "ids": [first], "parent": folder, "root": False}),
    (["tabs", "move", first, "--root"], {"method": "tabs.move", "ids": [first], "root": True}),
    (["folders", "create", "空文件夹"], {"method": "folders.create", "title": "空文件夹", "ids": []}),
    (["folders", "create", "Research", "--items", second, first, "--parent", folder], {"method": "folders.create", "title": "Research", "ids": [second, first], "parent": folder}),
    (["folders", "rename", folder, "Sources"], {"method": "folders.rename", "id": folder, "title": "Sources"}),
    (["folders", "move", folder, "--parent", second], {"method": "folders.move", "ids": [folder], "parent": second, "root": False}),
    (["folders", "move", folder, first, "--before", second], {"method": "folders.move", "ids": [folder, first], "before": second, "root": False}),
    (["folders", "move", folder, "--root"], {"method": "folders.move", "ids": [folder], "root": True}),
    (["folders", "dissolve", folder], {"method": "folders.dissolve", "id": folder}),
]

with tempfile.TemporaryDirectory(prefix="cli-home-", dir="/tmp") as home:
    address = Path(home) / "Library/Application Support/Marple/cli.sock"
    address.parent.mkdir(parents=True)
    env = dict(os.environ, CFFIXED_USER_HOME=home)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(address))
        server.listen(1)
        server.settimeout(5)

        def exchange(arguments, expected, response):
            process = subprocess.Popen([str(binary), *arguments], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(5)
                    with connection.makefile("rb") as stream:
                        actual = json.loads(stream.readline())
                    if expected["method"] not in ("ping", "tabs.list"):
                        key = actual.get("requestID")
                        assert key and str(uuid.UUID(key)).upper() == key, actual
                        expected = {**expected, "method": "mutate", "operation": expected["method"],
                                    "requestID": key, "retryOnly": False}
                        response = {**response, "requestID": key}
                    connection.sendall(json.dumps(response).encode() + b"\n")
                stdout, stderr = process.communicate(timeout=5)
                assert actual == expected, (arguments, actual, expected)
                assert json.loads(stdout) == response, (arguments, stdout, stderr)
                assert process.returncode == (0 if response["ok"] else 1), (arguments, process.returncode)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

        # Prove the binary uses this isolated home before sending any mutations.
        exchange(["ping"], {"method": "ping"}, {"ok": True, "data": {"pong": "isolated-smoke"}})
        for arguments, expected in cases:
            exchange(arguments, expected, {"ok": True})
        exchange(["tabs", "move", first], {"method": "tabs.move", "ids": [first], "root": False},
                 {"ok": False, "error": {"code": "bad_request", "message": "missing destination"}})
print(f"Passed {len(cases) + 2} CLI socket smoke cases.")
