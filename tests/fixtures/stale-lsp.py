#!/usr/bin/env python3
"""Old LSP process for the installation/activation transport regression."""
import json
import sys

if len(sys.argv) > 1 and sys.argv[1] in ("--version", "--source-identity"):
    sys.exit(2)  # Pre-identity binary: source reconciliation must upgrade it.
while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line == b"\r\n":
            break
        name, value = line.decode().split(":", 1)
        headers[name.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    if message.get("method") == "exit":
        sys.exit(0)
    if "id" not in message:
        continue
    result = None
    if message.get("method") == "initialize":
        result = {"capabilities": {"textDocumentSync": 1,
                  "experimental": {"arkBuild": {"source_fingerprint": "old", "build_id": "old"}}}}
    data = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
    sys.stdout.buffer.flush()
