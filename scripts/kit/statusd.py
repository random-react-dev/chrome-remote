#!/usr/bin/env python3
"""statusd.py — tiny status sidecar for context-engine (Mac B only).

Binds 127.0.0.1:<port> (default 9223). Serves:
  GET /status  -> {idle_secs, cdp_alive, tailscale_ip, hostname, time}
  GET /idle    -> idle seconds as plain text
TCC-free: reads HIDIdleTime via ioreg (public IOKit registry, no permissions).
Run under launchd KeepAlive (remote-agent.sh installs it).
"""
import json, os, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get('STATUS_PORT', 9223))
CDP_PORT = int(os.environ.get('CDP_PORT', 9222))

def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=8).stdout.strip()
    except Exception:
        return ''

def idle_secs():
    out = sh(['ioreg', '-c', 'IOHIDSystem'])
    for line in out.splitlines():
        if 'HIDIdleTime' in line:
            try:
                return int(line.split()[-1]) // 1000000000
            except Exception:
                pass
    return -1

def cdp_alive():
    import urllib.request
    try:
        json.load(urllib.request.urlopen('http://127.0.0.1:%d/json/version' % CDP_PORT, timeout=3))
        return True
    except Exception:
        return False

def tailscale_ip():
    return sh(['tailscale', 'ip', '-n']) or ''

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/idle':
            body = str(idle_secs()).encode()
            ctype = 'text/plain'
        else:
            body = json.dumps({
                'idle_secs': idle_secs(),
                'cdp_alive': cdp_alive(),
                'tailscale_ip': tailscale_ip(),
                'hostname': os.uname().nodename,
                'time': time.strftime('%Y-%m-%d %H:%M:%S'),
            }).encode()
            ctype = 'application/json'
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *a):
        # stderr -> ~/.context-engine-statusd.log (launchd KeepAlive captures it)
        sys.stderr.write('%s %s\n' % (time.strftime('%F %T'), fmt % a))
        sys.stderr.flush()

if __name__ == '__main__':
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
