#!/usr/bin/env python3
"""cdp.py — minimal Chrome DevTools Protocol client (stdlib only).

Used by both sides of context-engine:
  Mac A (steer.sh) drives the Mac B browser through it;
  Mac B (remote-agent.sh) uses it for preflight/verification.

Usage: cdp.py <host> <port> <cmd> [args...]

Commands:
  version
  tabs
  new <url>                 open a BACKGROUND tab (never brings it to front)
  close <targetId>
  activate <targetId>
  nav <targetId> <url>
  title <targetId>
  url <targetId>
  eval <targetId> <js>      Runtime.evaluate, returnByValue (NO Runtime.enable — avoids the CDP leak)
  read <targetId> <css>     innerText of first match
  text <targetId> [n]       body innerText, truncated
  shot <targetId> <path>    Page.captureScreenshot -> png file
  click <targetId> <css>    human-ish mouse: approach, press, release (jitter + delays)
  type <targetId> <css> <text>   focus + per-key typing (random 40-140ms/key)

Rules baked in:
  - NEVER send Runtime.enable (the console.debug serialization leak anti-bots key on).
  - Human-like timing/jitter on Input events (behavioral biometrics is the weak spot).
"""
import json, os, random, socket, base64, struct, sys, time, urllib.request

HOST, PORT = sys.argv[1], int(sys.argv[2])
CMD = sys.argv[3]
A = sys.argv[4:]

# ---------------- websocket (proven in clone-sync/cdp_verify.py) ----------------
def ws(path, timeout=25):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: ' + HOST + ':' + str(PORT) + '\r\nUpgrade: websocket\r\n'
               'Connection: Upgrade\r\nSec-WebSocket-Key: ' + key +
               '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
    buf = b''
    while b'\r\n\r\n' not in buf:
        buf += s.recv(4096)
    return s, buf.split(b'\r\n\r\n', 1)[1]

def ws_send(s, obj):
    data = json.dumps(obj).encode(); n = len(data); m = os.urandom(4)
    if n < 126: h = b'\x81' + bytes([0x80 | n])
    elif n < 65536: h = b'\x81' + bytes([0x80 | 126]) + struct.pack('>H', n)
    else: h = b'\x81' + bytes([0x80 | 127]) + struct.pack('>Q', n)
    s.sendall(h + m + bytes(b ^ m[i % 4] for i, b in enumerate(data)))

def ws_recv(pending, s):
    while True:
        hdr, ln = 0, 0
        if len(pending) >= 2:
            l = pending[1] & 0x7F
            if l < 126: hdr, ln = 2, l
            elif l == 126 and len(pending) >= 4: hdr, ln = 4, struct.unpack('>H', pending[2:4])[0]
            elif l == 127 and len(pending) >= 10: hdr, ln = 10, struct.unpack('>Q', pending[2:10])[0]
        if hdr and len(pending) >= hdr + ln:
            op = pending[0] & 0x0F; p = pending[hdr:hdr+ln]
            return op, p, pending[hdr+ln:]
        chunk = s.recv(262144)
        if not chunk: raise Exception('WS closed')
        pending += chunk

_cid = [0]
def call(s, pending, method, params=None):
    _cid[0] += 1
    ws_send(s, {'id': _cid[0], 'method': method, 'params': params or {}})
    while True:
        op, payload, pending = ws_recv(pending, s)
        if op == 8: raise Exception('WS close frame')
        if op != 1: continue
        msg = json.loads(payload.decode())
        if msg.get('id') == _cid[0]:
            if 'error' in msg: raise Exception(method + ': ' + json.dumps(msg['error'])[:300])
            return msg.get('result', {}), pending

def ws_path(url):
    # Chrome fills webSocketDebuggerUrl with its OWN bind address (ws://127.0.0.1:PORT/...)
    # even when we reach it via the tailnet/VM — keep only the path, connect to HOST.
    return '/' + url.split('://', 1)[1].split('/', 1)[1]

def browser_ws():
    ver = json.load(urllib.request.urlopen('http://%s:%d/json/version' % (HOST, PORT), timeout=5))
    return ws(ws_path(ver['webSocketDebuggerUrl']))

def target_ws(target_id):
    tabs = json.load(urllib.request.urlopen('http://%s:%d/json' % (HOST, PORT), timeout=5))
    for t in tabs:
        if t['id'] == target_id and t.get('webSocketDebuggerUrl'):
            return ws(ws_path(t['webSocketDebuggerUrl']))
    raise Exception('no ws for target ' + target_id)

def eval_js(s, pending, js, await_promise=False):
    r, pending = call(s, pending, 'Runtime.evaluate',
                      {'expression': js, 'returnByValue': True, 'awaitPromise': await_promise})
    if r.get('exceptionDetails'):
        raise Exception('JS exception: ' + json.dumps(r['exceptionDetails'])[:300])
    return r.get('result', {}).get('value'), pending

# ---------------- http helpers ----------------
def http_json(method, path):
    req = urllib.request.Request('http://%s:%d%s' % (HOST, PORT, path), method=method)
    return json.load(urllib.request.urlopen(req, timeout=8))

def pages():
    return [x for x in http_json('GET', '/json') if x.get('type') == 'page']

def die(msg, code=2):
    print('RESULT: FAIL cmd=' + CMD + ' reason=' + msg)
    sys.exit(code)

# ---------------- commands ----------------
def cmd_version():
    v = http_json('GET', '/json/version')
    print(v.get('Browser', '?') + ' | ' + v.get('User-Agent', '')[:80])

def cmd_tabs():
    for t in pages():
        print('%s\t%s\t%s' % (t['id'], (t.get('url') or '')[:120], (t.get('title') or '')[:60]))

def cmd_new():
    url = A[0] if A else 'about:blank'
    # PUT /json/new?about:blank — Chrome 111+ requires PUT. Opens a background tab.
    try:
        r = http_json('PUT', '/json/new?' + urllib.request.quote(url, safe=':/?&='))
    except Exception as e:
        # fallback: WS Target.createTarget (newWindow:false = tab in last focused window)
        s, p = browser_ws()
        r, p = call(s, p, 'Target.createTarget', {'url': url, 'newWindow': False})
        s.close()
    print(r['id'])

def cmd_close():
    # /json/close returns plain text ("Target is closing"), not JSON — don't parse it
    urllib.request.urlopen('http://%s:%d/json/close/%s' % (HOST, PORT, A[0]), timeout=8)
    print('closed')

def cmd_activate():
    http_json('GET', '/json/activate/' + A[0])
    print('activated')

def cmd_nav():
    s, p = target_ws(A[0])
    call(s, p, 'Page.enable')
    r, p = call(s, p, 'Page.navigate', {'url': A[1]})
    s.close()
    print('navigated')

def cmd_title():
    s, p = target_ws(A[0])
    v, p = eval_js(s, p, 'document.title')
    s.close()
    print(v or '')

def cmd_url():
    for t in pages():
        if t['id'] == A[0]:
            print(t.get('url', '')); return
    die('no such tab')

def cmd_eval():
    s, p = target_ws(A[0])
    v, p = eval_js(s, p, A[1])
    s.close()
    print(json.dumps(v) if isinstance(v, (dict, list)) else (v if v is not None else 'null'))

def cmd_read():
    js = ('(function(){var el=document.querySelector(%s);'
          'return el ? (el.innerText||el.textContent||"").trim().slice(0,20000) : null;}())' % json.dumps(A[1]))
    s, p = target_ws(A[0])
    v, p = eval_js(s, p, js)
    s.close()
    print(v if v is not None else 'NO_MATCH')

def cmd_text():
    n = int(A[1]) if len(A) > 1 else 4000
    js = '(function(){var t=document.body?document.body.innerText:"";return t.slice(0,%d);})()' % n
    s, p = target_ws(A[0])
    v, p = eval_js(s, p, js)
    s.close()
    print(v or '')

def cmd_shot():
    s, p = target_ws(A[0])
    r, p = call(s, p, 'Page.captureScreenshot', {'format': 'png'})
    s.close()
    open(A[1], 'wb').write(base64.b64decode(r['data']))
    print('saved ' + A[1])

def center_of(s, p, css):
    js = ('(function(){var el=document.querySelector(%s);'
          'if(!el) return null; el.scrollIntoView({block:"center"});'
          'var r=el.getBoundingClientRect();'
          'return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2,w:r.width,h:r.height});})()') % json.dumps(css)
    v, p = eval_js(s, p, js)
    if not v: return None, p
    return json.loads(v), p

def cmd_click():
    s, p = target_ws(A[0])
    box, p = center_of(s, p, A[1])
    if not box:
        s.close(); die('NO_MATCH:' + A[1])
    x = box['x'] + random.uniform(-box['w'] * 0.1, box['w'] * 0.1)
    y = box['y'] + random.uniform(-box['h'] * 0.1, box['h'] * 0.1)
    x, y = int(x), int(y)
    # approach in a few steps (mouse entropy), then click
    for frac in (0.3, 0.6, 0.85, 1.0):
        call(s, p, 'Input.dispatchMouseEvent',
             {'type': 'mouseMoved', 'x': int(x * frac), 'y': int(y * frac)})
        time.sleep(random.uniform(0.02, 0.07))
    time.sleep(random.uniform(0.05, 0.2))
    call(s, p, 'Input.dispatchMouseEvent', {'type': 'mousePressed', 'x': x, 'y': y, 'button': 'left', 'clickCount': 1})
    time.sleep(random.uniform(0.04, 0.14))
    call(s, p, 'Input.dispatchMouseEvent', {'type': 'mouseReleased', 'x': x, 'y': y, 'button': 'left', 'clickCount': 1})
    s.close()
    print('clicked ' + A[1])

def cmd_type():
    text = A[2]
    s, p = target_ws(A[0])
    js = ('(function(){var el=document.querySelector(%s);'
          'if(!el) return false; el.focus();'
          'if(el.select) { try { el.select(); } catch(e){} }'
          'return true;})()') % json.dumps(A[1])
    ok, p = eval_js(s, p, js)
    if not ok:
        s.close(); die('NO_MATCH:' + A[1])
    time.sleep(random.uniform(0.15, 0.4))
    for ch in text:
        # keyDown carries NO text (that alone makes Blink insert a char); the char event inserts.
        vk = ord(ch.upper()) if ch.isalpha() else (32 if ch == ' ' else (ord(ch) if ch.isprintable() else 0))
        call(s, p, 'Input.dispatchKeyEvent', {'type': 'keyDown', 'key': ch, 'windowsVirtualKeyCode': vk})
        call(s, p, 'Input.dispatchKeyEvent', {'type': 'char', 'text': ch})
        call(s, p, 'Input.dispatchKeyEvent', {'type': 'keyUp', 'key': ch})
        time.sleep(random.uniform(0.04, 0.14))
    s.close()
    print('typed %d chars' % len(text))

CMDS = {
    'version': cmd_version, 'tabs': cmd_tabs, 'new': cmd_new, 'close': cmd_close,
    'activate': cmd_activate, 'nav': cmd_nav, 'title': cmd_title, 'url': cmd_url,
    'eval': cmd_eval, 'read': cmd_read, 'text': cmd_text, 'shot': cmd_shot,
    'click': cmd_click, 'type': cmd_type,
}

def main():
    if CMD not in CMDS:
        die('unknown cmd ' + CMD)
    try:
        CMDS[CMD]()
        print('RESULT: OK cmd=' + CMD)
    except SystemExit:
        raise
    except Exception as e:
        die(str(e)[:200])

if __name__ == '__main__':
    main()
