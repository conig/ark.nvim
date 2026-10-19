#!/usr/bin/env python3
"""The default runner must own unresponsive embedded editors launched via tmux."""
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


def alive(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except FileNotFoundError:
        return False


class TmuxCleanupTests(unittest.TestCase):
    def exercise(self, outcome):
        with tempfile.TemporaryDirectory(prefix="ark-cleanup-regression-") as temporary:
            root = Path(temporary)
            marker = root / "embedded.pid"
            child_script = root / "busy.lua"
            child_script.write_text(
                "vim.fn.writefile({tostring(vim.fn.getpid())}, " + json.dumps(str(marker)) + ")\n"
                # An event-loop-stuck core must not outlive its test runner.
                "while true do end\n"
            )
            script = root / "test.lua"
            ending = {"success": "", "failure": 'error("intentional cleanup failure")',
                      "timeout": "vim.wait(60000, function() return false end)"}[outcome]
            script.write_text(
                'local socket = assert(vim.env.ARK_TMUX_SOCKET)\n'
                'local cmd = "/usr/bin/nvim --clean -i NONE -n -c " .. vim.fn.shellescape("luafile " .. '
                + json.dumps(str(child_script)) + ')\n'
                'local output = vim.fn.system({"tmux", "-S", socket, "new-session", "-d", "-s", "cleanup-child", cmd})\n'
                'assert(vim.v.shell_error == 0, output)\n'
                'assert(vim.wait(3000, function() return vim.fn.filereadable('
                + json.dumps(str(marker)) + ') == 1 end, 20), "child never started")\n'
                'vim.fn.writefile({vim.env.ARK_TEST_TMPDIR}, '
                + json.dumps(str(root / "run-dir")) + ')\n' + ending + '\n'
            )
            env = dict(os.environ, ARK_CLEANUP_PROBE=str(root))
            # Pre-exporting these masks the regression: tmux would inherit them.
            env.pop("ARK_TEST_RUN_ID", None)
            env.pop("ARK_TEST_TMPDIR", None)
            process = None
            try:
                with (root / "runner.log").open("w+") as output:
                    process = subprocess.Popen(
                        [str(REPO / "scripts/run-e2e-test.sh"), "--timeout", "5",
                         "--kill-after", "1", str(script)],
                        cwd=REPO, env=env, stdout=output, stderr=output,
                        start_new_session=True,
                    )
                    code = process.wait(timeout=20)
                    output.seek(0)
                    log = output.read()
                self.assertTrue(marker.exists(), log)
                pid = int(marker.read_text().strip())
                self.assertEqual(code, 0 if outcome == "success" else 1 if outcome == "failure" else 124, log)
                self.assertFalse(alive(pid), f"{outcome}: runner leaked embedded Neovim {pid}")
            finally:
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                # Independent ownership tag: a red or interrupted test must
                # never reproduce the original days-long leak, even if the
                # runner dies before its cleanup trap or PID marker executes.
                expected = f"ARK_CLEANUP_PROBE={root}".encode()
                for proc in Path("/proc").iterdir():
                    if not proc.name.isdecimal():
                        continue
                    try:
                        if proc.stat().st_uid == os.getuid() and expected in (proc / "environ").read_bytes().split(b"\0"):
                            os.kill(int(proc.name), signal.SIGKILL)
                    except (FileNotFoundError, PermissionError, ProcessLookupError):
                        pass
                run_dir = root / "run-dir"
                if run_dir.exists():
                    shutil.rmtree(run_dir.read_text().strip(), ignore_errors=True)

    def test_normal_completion_reaps_embedded_tmux_editor(self):
        self.exercise("success")

    def test_assertion_failure_reaps_embedded_tmux_editor(self):
        self.exercise("failure")

    def test_timeout_reaps_embedded_tmux_editor(self):
        self.exercise("timeout")


if __name__ == "__main__":
    def interrupted(_sig, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    unittest.main()
