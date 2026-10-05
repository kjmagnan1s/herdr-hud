"""Event bridge tests against a fake Herdr socket server, plus an opt-in run
against a real, isolated Herdr (set HERDR_BIN). No user agent is touched: the
real test starts its own headless server in a temporary home."""
import json, os, pathlib, select, shutil, socket, subprocess, sys, tempfile, threading, time, unittest
BRIDGE = pathlib.Path(__file__).resolve().parents[1] / 'Sources/HerdrHUD/Resources/watch.py'

class FakeHerdr:
    """NDJSON over a Unix socket. Each events.subscribe connection plays the
    next script: a list of lines to push, then 'hold' (stay open) or 'close'."""
    def __init__(self, root, agents, scripts):
        self.path = str(root / 's'); self.agents = agents; self.scripts = list(scripts)
        self.methods = []; self.subscriptions = []; self.failures = []
        self.listener = socket.socket(socket.AF_UNIX); self.listener.bind(self.path); self.listener.listen(); self.listener.settimeout(.2)
        self.running = True; self.connections = []
        self.thread = threading.Thread(target=self.serve, daemon=True); self.thread.start()
    def serve(self):
        while self.running:
            try: con, _ = self.listener.accept()
            except socket.timeout: continue
            except OSError: return
            threading.Thread(target=self.handle, args=(con,), daemon=True).start()
    def handle(self, con):
        try:
            request = json.loads(con.makefile('rb').readline()); method = request['method']; self.methods.append(method)
            if method == 'session.snapshot':
                con.sendall((json.dumps({'id': request['id'], 'result': {'type': 'session_snapshot', 'snapshot': {'agents': [dict(a) for a in self.agents]}}}) + '\n').encode()); con.close(); return
            if method != 'events.subscribe': self.failures.append('unexpected ' + method); con.close(); return
            self.subscriptions.append(request['params']['subscriptions'])
            con.sendall((json.dumps({'id': request['id'], 'result': {'type': 'subscription_started'}}) + '\n').encode())
            script = self.scripts.pop(0) if self.scripts else ['hold']
            for line in script:
                if line == 'hold': self.connections.append(con); return
                if line == 'close': con.close(); return
                if callable(line): line()
                else: con.sendall((json.dumps(line) + '\n').encode()); time.sleep(.02)
        except Exception as error: self.failures.append(repr(error))
    def close(self):
        self.running = False; self.listener.close()
        for con in self.connections:
            try: con.close()
            except OSError: pass

class Bridge:
    def __init__(self, home, socket_path=None, binary_dir=None, env=None):
        if socket_path:
            binary = home / '.local/bin/herdr'; binary.parent.mkdir(parents=True)
            binary.write_text('#!' + sys.executable + '\nprint(' + repr('socket: ' + socket_path) + ')\n'); binary.chmod(0o700)
        environment = {**os.environ, 'HOME': str(home), **(env or {})}
        if binary_dir: environment['PATH'] = str(binary_dir) + os.pathsep + environment['PATH']
        self.process = subprocess.Popen([sys.executable, str(BRIDGE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        self.process.stdin.write(b'{"session":"default"}\n'); self.process.stdin.flush()
        self.buffer = b''
    def line(self, timeout=5):
        end = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            left = end - time.monotonic()
            if left <= 0 or not select.select([self.process.stdout], [], [], left)[0]: raise AssertionError('no line from bridge')
            chunk = os.read(self.process.stdout.fileno(), 4096)
            if not chunk: raise AssertionError('bridge exited: ' + self.process.stderr.read().decode())
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b'\n')
        return json.loads(line)
    def until(self, kind, timeout=5):
        while True:
            value = self.line(timeout)
            if value['type'] == kind: return value
    def stop(self):
        if self.process.poll() is None: self.process.kill()
        self.process.wait(5)
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            try: stream.close()
            except OSError: pass

AGENT = {'pane_id': 'w1:p1', 'terminal_id': 't1', 'workspace_id': 'w1', 'agent': 'claude', 'agent_status': 'working'}
def status_event(status, pane='w1:p1'): return {'event': 'pane.agent_status_changed', 'data': {'pane_id': pane, 'workspace_id': 'w1', 'agent_status': status}}

class FakeServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.root = pathlib.Path(self.directory.name)
    def tearDown(self):
        for item in [getattr(self, 'bridge', None), getattr(self, 'herdr', None)]:
            if item: (item.stop if isinstance(item, Bridge) else item.close)()
        self.directory.cleanup()
    def start(self, agents, scripts):
        self.herdr = FakeHerdr(self.root, agents, scripts); self.bridge = Bridge(self.root, self.herdr.path)
        return self.herdr, self.bridge

    def test_subscribes_per_agent_pane_and_forwards_status(self):
        herdr, bridge = self.start([AGENT, {**AGENT, 'pane_id': 'w2:p3'}], [[status_event('blocked'), 'hold']])
        self.assertEqual(bridge.line(), {'type': 'ready', 'agents': 2})
        self.assertEqual(bridge.line(), {'type': 'changed', 'event': 'pane.agent_status_changed', 'pane_id': 'w1:p1', 'agent_status': 'blocked'})
        kinds = [s['type'] for s in herdr.subscriptions[0]]
        self.assertIn('pane.created', kinds); self.assertIn('tab.renamed', kinds); self.assertNotIn('pane.updated', kinds)
        self.assertEqual(sorted(s['pane_id'] for s in herdr.subscriptions[0] if s['type'] == 'pane.agent_status_changed'), ['w1:p1', 'w2:p3'])

    def test_new_agent_pane_resubscribes_with_it(self):
        agents = [AGENT]
        def detect(): agents.append({**AGENT, 'pane_id': 'w1:p2'})
        herdr, bridge = self.start(agents, [[detect, {'event': 'pane_agent_detected', 'data': {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'agent': 'codex'}}, 'hold']])
        self.assertEqual(bridge.line()['agents'], 1)
        self.assertEqual(bridge.line(), {'type': 'changed', 'event': 'pane_agent_detected', 'pane_id': 'w1:p2'})
        self.assertEqual(bridge.line(), {'type': 'ready', 'agents': 2})
        self.assertEqual(len(herdr.subscriptions), 2)

    def test_renames_refresh_without_resubscribing(self):
        herdr, bridge = self.start([AGENT], [[{'event': 'tab_renamed', 'data': {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'label': 'x'}}, status_event('done'), 'hold']])
        bridge.until('ready'); self.assertEqual(bridge.line()['event'], 'tab_renamed'); self.assertEqual(bridge.line()['agent_status'], 'done')
        self.assertEqual(len(herdr.subscriptions), 1)

    def test_events_lost_resyncs_from_a_fresh_snapshot(self):
        herdr, bridge = self.start([AGENT], [[{'id': 'hud-events', 'error': {'code': 'events_lost', 'message': 'resubscribe'}}, 'close'], ['hold']])
        bridge.until('ready'); self.assertEqual(bridge.line(), {'type': 'changed', 'event': 'resync'})
        self.assertEqual(bridge.line()['type'], 'ready')
        self.assertEqual(herdr.methods, ['session.snapshot', 'events.subscribe', 'session.snapshot', 'events.subscribe'])

    def test_herdr_closing_the_stream_ends_the_bridge_with_an_error(self):
        _, bridge = self.start([AGENT], [['close']])
        bridge.until('ready'); self.assertNotEqual(bridge.process.wait(5), 0)

    def test_stdin_closing_ends_the_bridge_quietly(self):
        _, bridge = self.start([AGENT], [['hold']])
        bridge.until('ready'); bridge.process.stdin.close(); self.assertEqual(bridge.process.wait(5), 0)

    def test_refused_subscription_fails_without_retrying_in_a_loop(self):
        self.herdr = FakeHerdr(self.root, [AGENT], []); self.herdr.handle_orig = self.herdr.handle
        def refuse(con):
            request = json.loads(con.makefile('rb').readline()); self.herdr.methods.append(request['method'])
            reply = {'id': request['id'], 'result': {'type': 'session_snapshot', 'snapshot': {'agents': [AGENT]}}} if request['method'] == 'session.snapshot' else {'id': request['id'], 'error': {'code': 'not_found', 'message': 'pane not found'}}
            con.sendall((json.dumps(reply) + '\n').encode()); con.close()
        self.herdr.handle = refuse
        self.bridge = Bridge(self.root, self.herdr.path)
        self.assertNotEqual(self.bridge.process.wait(5), 0); self.assertEqual(self.herdr.methods, ['session.snapshot', 'events.subscribe'])

    def test_only_reads_herdr_and_takes_the_session_from_stdin(self):
        herdr, bridge = self.start([AGENT], [[status_event('idle'), 'hold']])
        bridge.until('changed')
        self.assertEqual(set(herdr.methods), {'session.snapshot', 'events.subscribe'}); self.assertFalse(herdr.failures)
        source = BRIDGE.read_text()
        for writer in ['agent.prompt', 'send_text', 'send_keys', 'send_input', 'pane.close']: self.assertNotIn(writer, source)

@unittest.skipUnless(os.environ.get('HERDR_BIN'), 'set HERDR_BIN to run against a real, isolated Herdr')
class RealHerdrTests(unittest.TestCase):
    def test_status_and_lifecycle_events_from_a_real_server(self):
        # Short path: Unix socket paths are limited to about 100 bytes.
        home = pathlib.Path(tempfile.mkdtemp(prefix='hh', dir='/tmp')); bindir = home / 'bin'; bindir.mkdir()
        shutil.copy(os.environ['HERDR_BIN'], bindir / 'herdr'); (bindir / 'herdr').chmod(0o755)
        env = {**{k: v for k, v in os.environ.items() if not k.startswith('HERDR_')}, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config'), 'PATH': str(bindir) + os.pathsep + os.environ['PATH']}
        server = subprocess.Popen([str(bindir / 'herdr'), 'server'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        bridge = None
        try:
            run = lambda *args: subprocess.run([str(bindir / 'herdr'), *args], env=env, capture_output=True, text=True, timeout=10)
            for _ in range(100):
                if run('status', 'server').returncode == 0: break
                time.sleep(.1)
            path = next(l[8:].strip() for l in run('status', 'server').stdout.splitlines() if l.startswith('socket: '))
            def rpc(method, params):
                with socket.socket(socket.AF_UNIX) as s:
                    s.connect(path); s.sendall((json.dumps({'id': 't', 'method': method, 'params': params}) + '\n').encode())
                    return json.loads(s.makefile().readline())
            pane = rpc('workspace.create', {})['result']['root_pane']['pane_id']
            # A reported agent stands in for Claude or Codex; nothing is typed anywhere.
            rpc('pane.report_agent', {'pane_id': pane, 'source': 'custom:hud-test', 'agent': 'codex', 'state': 'idle'})
            bridge = Bridge(home, binary_dir=bindir, env={'XDG_CONFIG_HOME': str(home / '.config')})
            self.assertEqual(bridge.until('ready', 15)['agents'], 1)
            rpc('pane.report_agent', {'pane_id': pane, 'source': 'custom:hud-test', 'agent': 'codex', 'state': 'working'})
            change = bridge.until('changed')
            self.assertEqual((change['event'], change['pane_id'], change['agent_status']), ('pane.agent_status_changed', pane, 'working'))
            rpc('tab.create', {'workspace_id': pane.split(':')[0]})
            events = {bridge.line()['event'] for _ in range(2)}
            self.assertIn('tab_created', events); self.assertEqual(bridge.until('ready')['agents'], 1)
        finally:
            if bridge: bridge.stop()
            run('server', 'stop'); server.wait(10); shutil.rmtree(home, ignore_errors=True)

if __name__ == '__main__': unittest.main()
