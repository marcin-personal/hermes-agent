"""Windows regression coverage for the Desktop update hand-off stream pump."""

from __future__ import annotations

import shutil
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import psutil
import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
HANDOFF_SCRIPT = REPO_ROOT / "scripts" / "desktop-update.ps1"


def _powershell_literal(value: Path | str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _invoke_streamed_hermes_source() -> str:
    source = HANDOFF_SCRIPT.read_text(encoding="utf-8")
    start = source.index("function Invoke-StreamedHermes")
    end_marker = "\n}\n\n$finalCode"
    end = source.index(end_marker, start) + len("\n}")
    return source[start:end]


def _kill_if_alive(pid_path: Path) -> None:
    if not pid_path.exists():
        return
    pid = int(pid_path.read_text(encoding="ascii"))
    try:
        proc = psutil.Process(pid)
        for child in proc.children(recursive=True):
            child.kill()
        proc.kill()
        proc.wait(timeout=5)
    except (psutil.NoSuchProcess, psutil.TimeoutExpired):
        pass


@pytest.mark.skipif(sys.platform != "win32", reason="Windows pipe-handle inheritance regression")
def test_stream_pump_drains_stderr_and_ignores_descendant_held_handles(tmp_path: Path) -> None:
    """Direct-child exit bounds the hand-off and stderr cannot block that child."""
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        pytest.skip("Windows PowerShell is unavailable")

    sleeper_pid = tmp_path / "sleeper.pid"
    fake_hermes = tmp_path / "fake_hermes.py"
    fake_hermes.write_text(
        textwrap.dedent(
            f"""
            import subprocess
            import sys

            for _ in range(256):
                print("stderr payload " + ("x" * 1024), file=sys.stderr)
            print("stderr complete", file=sys.stderr, flush=True)
            child = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                close_fds=False,
            )
            with open({str(sleeper_pid)!r}, "w", encoding="ascii") as handle:
                handle.write(str(child.pid))
            print("direct child finished", flush=True)
            """
        ),
        encoding="utf-8",
    )

    harness = tmp_path / "invoke-streamed-hermes.ps1"
    harness.write_text(
        textwrap.dedent(
            f"""
            $ErrorActionPreference = 'Stop'
            $script:Ui = $false
            function Write-HandoffLog([string]$Message) {{}}

            {_invoke_streamed_hermes_source()}

            $result = Invoke-StreamedHermes `
                {_powershell_literal(sys.executable)} `
                @({_powershell_literal(fake_hermes)}) `
                'regression'
            Write-Output ("RESULT_CODE={{0}}" -f $result.Code)
            Write-Output ("RESULT_HAS_LINE={{0}}" -f $result.Output.Contains('direct child finished'))
            Write-Output ("RESULT_HAS_STDERR={{0}}" -f $result.Output.Contains('stderr complete'))
            if ($result.Code -ne 0) {{ exit 1 }}
            """
        ),
        encoding="utf-8",
    )

    console_log = tmp_path / "harness.log"
    started = time.monotonic()
    try:
        with console_log.open("wb") as console:
            try:
                completed = subprocess.run(
                    [
                        powershell,
                        "-NoLogo",
                        "-NoProfile",
                        "-NonInteractive",
                        "-ExecutionPolicy",
                        "Bypass",
                        "-File",
                        str(harness),
                    ],
                    cwd=REPO_ROOT,
                    stdout=console,
                    stderr=subprocess.STDOUT,
                    timeout=8,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                pytest.fail(
                    "Invoke-StreamedHermes waited for descendant-held pipe EOF after "
                    "the direct child exited"
                )
    finally:
        _kill_if_alive(sleeper_pid)

    elapsed = time.monotonic() - started
    console_text = console_log.read_text(encoding="utf-8", errors="replace")
    assert completed.returncode == 0, console_text
    assert "RESULT_CODE=0" in console_text
    assert "RESULT_HAS_LINE=True" in console_text
    assert "RESULT_HAS_STDERR=True" in console_text
    assert elapsed < 8
