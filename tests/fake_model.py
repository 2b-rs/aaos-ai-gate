#!/usr/bin/env python3
"""Local stand-in for an OpenAI-compatible gate endpoint. No outbound traffic."""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        state = self.server.state
        with state["lock"]:
            count = int(state["count"]) + 1
            state["count"] = count
            with open(state["count_file"], "w", encoding="utf-8") as handle:
                handle.write(str(count))
            with open(state["body_file"], "wb") as handle:
                handle.write(body)
            model = ""
            try:
                model = json.loads(body.decode("utf-8")).get("model", "")
            except (UnicodeError, json.JSONDecodeError, AttributeError):
                model = ""
            meta = {
                "auth": self.headers.get("Authorization", ""),
                "model": model if isinstance(model, str) else "",
                "count": count,
            }
            with open(state["meta_file"], "w", encoding="utf-8") as handle:
                json.dump(meta, handle)
        delay = 0.0
        try:
            delay = float(open(state["delay_file"], encoding="utf-8").read().strip() or "0")
        except (OSError, ValueError):
            delay = 0.0
        if delay > 0:
            time.sleep(delay)
        try:
            verdict = open(state["verdict_file"], encoding="utf-8").read()
        except OSError:
            verdict = ""
        if not verdict.strip():
            verdict = (
                '{"compile":"ok","runtime":"ok","effect":"likely",'
                '"ask":false,"question":"","reason":"ok"}'
            )
        payload = json.dumps(
            {"choices": [{"message": {"content": verdict}}]},
            ensure_ascii=False,
        ).encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def log_message(self, fmt, *args):
        return


def main():
    root = os.environ["FAKE_MODEL_DIR"]
    os.makedirs(root, exist_ok=True)
    state = {
        "lock": threading.Lock(),
        "count": 0,
        "count_file": os.path.join(root, "count"),
        "body_file": os.path.join(root, "last_body"),
        "meta_file": os.path.join(root, "last_meta.json"),
        "delay_file": os.path.join(root, "delay"),
        "verdict_file": os.path.join(root, "verdict.txt"),
    }
    with open(state["count_file"], "w", encoding="utf-8") as handle:
        handle.write("0")
    if not os.path.exists(state["delay_file"]):
        with open(state["delay_file"], "w", encoding="utf-8") as handle:
            handle.write("0")
    if not os.path.exists(state["verdict_file"]):
        with open(state["verdict_file"], "w", encoding="utf-8") as handle:
            handle.write(
                '{"compile":"ok","runtime":"ok","effect":"likely",'
                '"ask":false,"question":"","reason":"ok"}\n'
            )
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.state = state
    port = server.server_address[1]
    with open(os.path.join(root, "port"), "w", encoding="utf-8") as handle:
        handle.write(str(port))
    server.serve_forever()


if __name__ == "__main__":
    main()
