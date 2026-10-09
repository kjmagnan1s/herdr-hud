"""Fixed read-only event bridge. The HUD runs it locally or over SSH and reads
one JSON line per Herdr change, so the roster refreshes on events instead of
polling. It never sends input to a pane. The request arrives only on stdin.

stdout lines: {"type":"ready","agents":N}, {"type":"changed",...},
{"type":"heartbeat"}. It exits when stdin closes (the HUD quit or the SSH link
dropped), when Herdr's stream ends, or on any error; the HUD then reconnects
with backoff and polls slowly meanwhile.
"""
import json, os, selectors, signal, socket, subprocess, sys, time
LIMIT = 1024 * 1024
HEARTBEAT = 20
# Pane set changes need a fresh status subscription; renames only need a refresh.
STRUCTURE = {'workspace_created', 'workspace_closed', 'tab_created', 'tab_closed', 'pane_created',
             'pane_closed', 'pane_exited', 'pane_moved', 'pane_agent_detected'}
LIFECYCLE = sorted(STRUCTURE | {'workspace_renamed', 'tab_renamed'})

def status(binary, session):
    env = {k: v for k, v in os.environ.items() if not k.startswith('HERDR_')}
    p = subprocess.run([binary, '--session', session, 'status', 'server'], stdin=subprocess.DEVNULL,
                       capture_output=True, env=env, timeout=12, start_new_session=True)
    if p.returncode or len(p.stdout) > 65536: raise RuntimeError('Herdr status unavailable')
    return next(line[8:].strip() for line in p.stdout.decode().splitlines() if line.startswith('socket: '))

def readline(sock, buffer, deadline=None):
    while b'\n' not in buffer:
        if deadline is not None: sock.settimeout(max(.01, deadline - time.monotonic()))
        chunk = sock.recv(16384)
        if not chunk: raise EOFError('Herdr closed the event stream')
        buffer.extend(chunk)
        if len(buffer) > LIMIT: raise RuntimeError('Event line limit exceeded')
    line, _, rest = bytes(buffer).partition(b'\n')
    buffer[:] = rest
    return json.loads(line)

def rpc(path, method, params):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(12); s.connect(path)
        s.sendall((json.dumps({'id': 'hud-watch', 'method': method, 'params': params}) + '\n').encode())
        value = readline(s, bytearray(), time.monotonic() + 12)
    if value.get('id') != 'hud-watch' or 'error' in value or not isinstance(value.get('result'), dict):
        raise RuntimeError('Herdr rejected ' + method)
    return value['result']

def emit(value):
    sys.stdout.write(json.dumps(value, separators=(',', ':')) + '\n'); sys.stdout.flush()

def subscribe(path):
    """One stream: lifecycle events plus a status subscription per agent pane."""
    agents = rpc(path, 'session.snapshot', {}).get('snapshot', {}).get('agents', [])
    panes = sorted({a['pane_id'] for a in agents if isinstance(a, dict) and isinstance(a.get('pane_id'), str)})
    subscriptions = [{'type': kind.replace('_', '.', 1)} for kind in LIFECYCLE]
    subscriptions += [{'type': 'pane.agent_status_changed', 'pane_id': pane} for pane in panes]
    s = socket.socket(socket.AF_UNIX); s.settimeout(12); s.connect(path)
    s.sendall((json.dumps({'id': 'hud-events', 'method': 'events.subscribe', 'params': {'subscriptions': subscriptions}}) + '\n').encode())
    buffer = bytearray()
    ack = readline(s, buffer, time.monotonic() + 12)
    if ack.get('id') != 'hud-events' or (ack.get('result') or {}).get('type') != 'subscription_started':
        s.close(); raise RuntimeError('Herdr refused the event subscription')
    s.setblocking(False)
    return s, buffer, len(panes)

def forward(buffer):
    """Emits every complete line in buffer. True when the stream must be
    re-established: the pane set changed, or Herdr dropped history."""
    resubscribe = False
    while b'\n' in buffer:
        line, _, rest = bytes(buffer).partition(b'\n'); buffer[:] = rest
        value = json.loads(line)
        if 'error' in value:
            # events_lost: Herdr dropped history. Resync from a fresh snapshot.
            emit({'type': 'changed', 'event': 'resync'}); return True
        event = str(value.get('event', '')); data = value.get('data') if isinstance(value.get('data'), dict) else {}
        change = {'type': 'changed', 'event': event}
        for field in ['pane_id', 'agent_status']:
            if isinstance(data.get(field), str): change[field] = data[field]
        emit(change)
        resubscribe = resubscribe or event in STRUCTURE
    return resubscribe

def main():
    request = json.loads(sys.stdin.readline() or 'null')
    if not isinstance(request, dict) or not isinstance(request.get('session'), str): raise RuntimeError('Invalid request')
    binary = next((p for p in [os.path.expanduser('~/.local/bin/herdr'), '/opt/homebrew/bin/herdr', '/usr/local/bin/herdr'] if os.access(p, os.X_OK)), 'herdr')
    path = status(binary, request['session'])
    while True:
        stream, buffer, count = subscribe(path)
        emit({'type': 'ready', 'agents': count})
        # Events can arrive in the same read as the acknowledgement.
        resubscribe = forward(buffer)
        with selectors.DefaultSelector() as sel:
            sel.register(sys.stdin, selectors.EVENT_READ, 'stdin'); sel.register(stream, selectors.EVENT_READ, 'herdr')
            while not resubscribe:
                ready = sel.select(HEARTBEAT)
                if not ready: emit({'type': 'heartbeat'}); continue
                for key, _ in ready:
                    if key.data == 'stdin':
                        if not os.read(sys.stdin.fileno(), 4096): return
                        continue
                    chunk = stream.recv(16384)
                    if not chunk: raise EOFError('Herdr closed the event stream')
                    buffer.extend(chunk)
                    if len(buffer) > LIMIT: raise RuntimeError('Event line limit exceeded')
                    resubscribe = forward(buffer)
                    if resubscribe: break
        stream.close()

if __name__ == '__main__':
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try: main()
    except Exception as error:
        print('Herdr events unavailable: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
