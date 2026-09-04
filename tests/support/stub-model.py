#!/usr/bin/env python3
"""A minimal OpenAI-completions server, so the agent path can be tested end
to end without a credential or a network.

mesthiri's whole reason to exist is driving a real coding agent, and until
this existed nothing had ever spawned one: every test injected a fake runner,
which proves the callers and not the thing being called. This is a real pi
process, talking a real protocol, over a real socket — the only fiction is
what the model says back.

Two modes, because the two failures that matter are different:

  serve    answer immediately; the run settles
  hang     accept the connection and never answer; the deadline must fire

Prints its port on stdout as `PORT <n>` and then serves until killed.
"""
import json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "serve"
REPLY = sys.argv[2] if len(sys.argv) > 2 else "hello from the stub"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        if MODE == "hang":
            # Never respond. pi waits; mesthiri's deadline is the only way out.
            threading.Event().wait()
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            def chunk(d):
                self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n")
                self.wfile.flush()
            chunk({"id": "1", "object": "chat.completion.chunk",
                   "model": body.get("model", "stub"),
                   "choices": [{"index": 0, "delta": {"role": "assistant",
                                                      "content": REPLY}}]})
            chunk({"id": "1", "object": "chat.completion.chunk",
                   "model": body.get("model", "stub"),
                   "choices": [{"index": 0, "delta": {},
                                "finish_reason": "stop"}],
                   "usage": {"prompt_tokens": 11, "completion_tokens": 7,
                             "total_tokens": 18}})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        out = json.dumps({
            "id": "1", "object": "chat.completion",
            "model": body.get("model", "stub"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": REPLY}}],
            "usage": {"prompt_tokens": 11, "completion_tokens": 7,
                      "total_tokens": 18},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

srv = HTTPServer(("127.0.0.1", 0), H)
print("PORT %d" % srv.server_address[1], flush=True)
srv.serve_forever()
