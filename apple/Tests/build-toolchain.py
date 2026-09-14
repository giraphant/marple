#!/usr/bin/env python3
"""Check release SDK validation without compiling or touching an app bundle."""
import os
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / "build-app.sh"
with tempfile.TemporaryDirectory(prefix="marple-toolchain-test-") as temporary:
    root = Path(temporary)
    developer = root / "Xcode.app/Contents/Developer"
    compiler = developer / "usr/bin/xcstringstool"
    compiler.parent.mkdir(parents=True)
    compiler.write_text("#!/bin/sh\nexit 0\n")
    compiler.chmod(0o755)
    binaries = root / "bin"
    binaries.mkdir()
    marker = root / "swift-invoked"
    for name, source in {
        "xcrun": '''#!/bin/sh
if [ "$1" = "--sdk" ] && [ "$2" = "macosx" ]; then
    export SDKROOT="$TEST_SDKROOT"
    shift 2
fi
if [ "$1" = "swift" ]; then shift; exec swift "$@"; fi
printf "%s\\n" "$TEST_SDK"
''',
        "swift": '#!/bin/sh\nprintf "%s\\n%s" "$DEVELOPER_DIR" "$SDKROOT" > "$TEST_MARKER"\nexit 42\n',
    }.items():
        path = binaries / name
        path.write_text(source)
        path.chmod(0o755)
    environment = dict(os.environ, CONFIG="release", VERSION="test", BUILD="test",
                       APP_DIR=str(root / "Unused.app"), DEVELOPER_DIR=str(developer),
                       PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                       TEST_MARKER=str(marker), SDKROOT=str(root / "Old.sdk"),
                       TEST_SDKROOT=str(developer / "MacOSX.sdk"))
    for sdk in ("15.5", "26.5"):
        marker.unlink(missing_ok=True)
        result = subprocess.run([str(script)], env=dict(environment, TEST_SDK=sdk),
                                capture_output=True, text=True)
        if sdk == "15.5":
            assert result.returncode != 0 and not marker.exists(), result.stdout + result.stderr
            assert "26" in result.stderr, result.stderr
        else:
            assert result.returncode == 42, result.stdout + result.stderr
            assert marker.read_text().splitlines() == [str(developer), environment["TEST_SDKROOT"]]
    marker.unlink(missing_ok=True)
    result = subprocess.run([str(script)], env=dict(environment, DEVELOPER_DIR=str(root / "Missing"),
                                                    TEST_SDK="26.5"), capture_output=True, text=True)
    assert result.returncode != 0 and not marker.exists(), result.stdout + result.stderr
print("Release rejects old/missing SDKs and passes the chosen Xcode to Swift.")
