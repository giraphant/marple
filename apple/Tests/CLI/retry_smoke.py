"""Exercise the real CLI's lost-response recovery contract on an isolated socket."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import uuid

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='cli-retry-', dir='/tmp') as home:
    address = Path(home) / 'Library/Application Support/Marple/cli.sock'
    address.parent.mkdir(parents=True)
    env = dict(os.environ, CFFIXED_USER_HOME=home)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(address))
        server.listen(8)
        server.settimeout(5)

        def exchange(arguments, reply):
            process = subprocess.Popen([str(binary), *arguments], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(5)
                    with connection.makefile('rb') as stream:
                        request = json.loads(stream.readline())
                    if reply is not None:
                        connection.sendall(json.dumps(reply(request)).encode() + b'\n')
                stdout, stderr = process.communicate(timeout=5)
                return request, json.loads(stdout), process.returncode
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

        request, output, code = exchange(['folders', 'create', 'Retry'], None)
        assert request['method'] == 'mutate', request
        assert request['operation'] == 'folders.create', request
        key = request['requestID']
        assert str(uuid.UUID(key)).upper() == key, request
        assert request['retryOnly'] is False, request
        assert code == 1 and output['requestID'] == key, output
        assert f'--retry-request {key}' in output['error']['message'], output

        reply = lambda req: {'ok': True, 'requestID': req['requestID'], 'data': {'createdID': key}}
        retried, output, code = exchange(['folders', 'create', 'Retry', '--retry-request', key], reply)
        assert retried == {**request, 'retryOnly': True}, retried
        assert code == 0 and output['requestID'] == key, output

        old_reply = lambda req: {'ok': False, 'error': {'code': 'bad_request', 'message': 'unknown method: mutate'}}
        old_request, output, code = exchange(['folders', 'create', 'Old server'], old_reply)
        assert old_request['method'] == 'mutate' and code == 1, (old_request, output)
        assert output['error']['code'] == 'bad_request', output

        # A peer may close while the request is still being sent. This must
        # return structured recovery information, not terminate on SIGPIPE.
        for _ in range(5):
            process = subprocess.Popen([str(binary), 'folders', 'create', 'x' * 200000],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                connection, _ = server.accept()
                connection.close()
                stdout, stderr = process.communicate(timeout=5)
                assert process.returncode == 1, (process.returncode, stderr)
                output = json.loads(stdout)
                key = output['requestID']
                assert str(uuid.UUID(key)).upper() == key, output
                assert f'--retry-request {key}' in output['error']['message'], output
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

        malformed = subprocess.run([str(binary), 'folders', 'create', 'Invalid', '--retry-request', 'not-a-uuid'],
                                   env=env, capture_output=True, text=True, timeout=5)
        assert malformed.returncode != 0, malformed.stdout
        server.settimeout(.1)
        try:
            unexpected, _ = server.accept()
            unexpected.close()
            raise AssertionError('invalid retry UUID reached the socket')
        except socket.timeout:
            pass
print('Passed lost-response, keyed-retry, early-close, old-server, and invalid-key CLI contracts.')
