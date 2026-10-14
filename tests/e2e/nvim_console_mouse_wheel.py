#!/usr/bin/env python3
"""Exercise Ark's standalone console with real terminal mouse input."""

import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[2]
TMP = Path(os.environ["ARK_TEST_TMPDIR"]) if "ARK_TEST_TMPDIR" in os.environ else Path(
    tempfile.mkdtemp(prefix="ark-wheel-")
)
TMP.mkdir(parents=True, exist_ok=True)
STATE = TMP / "console-wheel-state.json"
FAKE_R = TMP / "fake-r"
CHILD = TMP / "console-wheel-child.lua"

FAKE_R.write_text(
    "#!/bin/sh\n"
    "i=1\n"
    "while [ \"$i\" -le 80 ]; do "
    "printf 'history line %03d\\n' \"$i\"; i=$((i + 1)); done\n"
    "printf '> '\n"
    "while IFS= read -r line; do printf 'saw: %s\\n> ' \"$line\"; done\n"
)
FAKE_R.chmod(0o755)
CHILD.write_text(
    f"""
vim.opt.rtp:prepend({json.dumps(str(ROOT))})
vim.g.ark_console_standalone = true
vim.api.nvim_create_autocmd("VimEnter", {{ once = true, callback = function()
  vim.schedule(function()
    local ark = require("ark")
    ark.setup({{
      auto_start_pane = false,
      auto_start_lsp = false,
      terminal = {{
        launcher = {json.dumps(str(FAKE_R))},
        startup_status_dir = {json.dumps(str(TMP / 'status'))},
        session_pkg_path = {json.dumps(str(TMP / 'bridge'))},
      }},
    }})
    local bufnr, err = ark.console()
    if not bufnr then error(err) end
    local timer = vim.uv.new_timer()
    timer:start(50, 50, vim.schedule_wrap(function()
      local view = vim.fn.winsaveview()
      vim.fn.writefile({{vim.json.encode({{
        mode = vim.api.nvim_get_mode().mode,
        topline = view.topline,
        line_count = vim.api.nvim_buf_line_count(bufnr),
        last_line = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1],
      }})}}, {json.dumps(str(STATE))})
    end))
  end)
end }})
"""
)


def read_state():
    try:
        return json.loads(STATE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def wait_for(label, predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = read_state()
        if state is not None and predicate(state):
            return state
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {label}: {read_state()}")


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
env = dict(os.environ, TERM="xterm-256color")
child = subprocess.Popen(
    [
        "nvim",
        "-u",
        os.environ.get("ARK_TEST_CONSOLE_INIT", "NONE"),
        "-i",
        "NONE",
        "-n",
        "-c",
        f"luafile {CHILD}",
    ],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    env=env,
)
os.close(slave)


def send(data):
    os.write(master, data)
    # Drain the PTY so the child can continue rendering after each input.
    time.sleep(0.15)
    while select.select([master], [], [], 0)[0]:
        try:
            os.read(master, 65536)
        except OSError:
            break


try:
    ready = wait_for(
        "standalone console input and long transcript",
        lambda state: state["mode"].startswith("i") and state["line_count"] >= 81,
    )
    send(b"abc")
    drafted = wait_for("draft text", lambda state: state["last_line"] == "abc")

    # At the bottom prompt, Insert-mode wheel-up must expose older transcript
    # lines rather than being pinned to the input cursor.
    send(b"\x1b[<64;10;10M")
    up = wait_for("mouse wheel up", lambda state: state["topline"] < drafted["topline"])
    send(b"\x1b[<65;10;10M")
    down = wait_for("mouse wheel down", lambda state: state["topline"] > up["topline"])
    send(b"i")
    restored = wait_for("return to input", lambda state: state["mode"].startswith("i"))
    assert restored["last_line"] == "abc", restored
    print(f"console wheel: {drafted['topline']} -> {up['topline']} -> {down['topline']}")
finally:
    child.terminate()
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
    os.close(master)
