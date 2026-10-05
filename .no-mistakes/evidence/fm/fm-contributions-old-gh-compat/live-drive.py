#!/usr/bin/env python3
"""Drive real Firstmate and real gh 2.45 against a disposable HTTPS API.

The fixture replaces the remote forge only. Firstmate, gh pagination, jq
assembly, deadlines, persistence, wake publication and acknowledgment are real.
No operator credentials, config, fleet, or remote mutation are used.
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import time
import urllib.parse

ROOT = Path.cwd()
SCRATCH = ROOT / '.test-scratch'
EVIDENCE = Path(__file__).parent
HEAD = 'a' * 40
OTHER_HEAD = 'b' * 40
NOW = '2026-10-05T23:00:00Z'
requests = []
mode = 'normal'
lock = threading.Lock()
results = []
transcript = []
old_cli = True
product = ROOT/'bin/fm-contributions.sh'

def event(id, kind='comment', association='OWNER', author='maintainer'):
    return dict(id=id, user=dict(login=author), author_association=association,
                body='Please clarify the compatibility contract',
                html_url=f'https://github.com/o/r/pull/8#signal-{id}',
                updated_at=NOW, submitted_at=NOW, commit_id=HEAD,
                state='CHANGES_REQUESTED')

def check(id, name):
    return dict(id=id, name=name, status='completed', conclusion='success', started_at=NOW)

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, value, link=None, raw=False):
        data = value.encode() if raw else json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        if link:
            self.send_header('Link', f'<https://api.github.com{link}>; rel="next"')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ssl.SSLError, ConnectionResetError):
            pass

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        page = int(urllib.parse.parse_qs(parsed.query).get('page', ['1'])[0])
        path = parsed.path
        with lock:
            requests.append(dict(method='GET', path=self.path, mode=mode))
        if path == '/repos/o/r/pulls/8':
            return self.respond(dict(state='open', user=dict(login='author'),
                                     head=dict(sha=HEAD), draft=False, mergeable=True, merged_at=None))
        if path == '/repos/o/r/issues/9':
            return self.respond(dict(state='open', user=dict(login='author'), labels=[],
                                     html_url='https://github.com/o/r/issues/9'))
        if path == '/repos/o/r':
            return self.respond(dict(permissions=dict(push=False)))
        is_comments = path.endswith('/issues/8/comments')
        if is_comments and page == 2 and mode == 'malformed':
            return self.respond('{broken JSON', raw=True)
        if is_comments and page == 2 and mode == 'slow':
            time.sleep(8)
        if path.endswith('/issues/8/comments'):
            pages = [[event(11, association='NONE', author='passerby'), event(10, author='author')], [event(12)]]
        elif path.endswith('/pulls/8/reviews'):
            pages = [[event(20, association='NONE', author='passerby')], [event(21, association='MEMBER')]]
        elif path.endswith('/pulls/8/comments'):
            pages = [[event(30, association='NONE', author='passerby')], [event(31, association='COLLABORATOR')]]
        elif path.endswith('/check-runs'):
            pages = [dict(total_count=2, check_runs=[check(1, 'portable-serial-1')]),
                     dict(total_count=2, check_runs=[check(2, 'portable-serial-2')])]
        elif path.endswith('/statuses'):
            pages = [[dict(id=3, context='legacy-status-1', state='success', created_at=NOW)],
                     [dict(id=4, context='legacy-status-2', state='success', created_at=NOW)]]
        elif path.endswith('/issues/9/comments'):
            pages = [[event(40, association='NONE', author='passerby')], [event(41)]]
        elif path.endswith('/issues/9/events'):
            pages = [[dict(id=87, event='unlabeled', label=dict(name='other-label'))], [dict(id=88, event='labeled', label=dict(name='ready-for-pr'))]]
        else:
            self.send_error(404, f'Unexpected fixture path: {path}')
            return
        next_link = self.path + '&page=2' if page == 1 else None
        self.respond(pages[page-1], next_link)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path == '/graphql', self.path
        assert 'mutation' not in body['query'].lower(), body
        with lock:
            requests.append(dict(method='POST', path=self.path, query=body['query'], mode=mode))
        self.respond(dict(data=dict(repository=dict(pullRequest=dict(
            headRefOid=OTHER_HEAD if mode == 'changed-head' else HEAD,
            reviewDecision='CHANGES_REQUESTED')))))

tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(SCRATCH/'cert.pem', SCRATCH/'key.pem')

class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_CONNECT(self):
        assert self.path in ('api.github.com:443', 'github.com:443'), self.path
        self.send_response(200, 'Connection established')
        self.end_headers()
        try:
            conn = tls.wrap_socket(self.connection, server_side=True)
            API(conn, self.client_address, self.server)
            conn.close()
        except (ssl.SSLError, ConnectionResetError):
            pass
        self.close_connection = True

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()

def environment(home):
    cli_prefix = f'{SCRATCH}/gh_2.45.0_linux_amd64/bin:' if old_cli else ''
    return dict(PATH=cli_prefix + os.environ['PATH'],
                HOME=str(home), LANG='C.UTF-8', TMPDIR=str(SCRATCH/'tmp'),
                GH_CONFIG_DIR=str(home/'gh-config'), GH_TOKEN='disposable-test-token',
                GH_PROMPT_DISABLED='1', GH_NO_UPDATE_NOTIFIER='1',
                HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',
                HTTP_PROXY=f'http://127.0.0.1:{server.server_port}', NO_PROXY='',
                SSL_CERT_FILE=str(SCRATCH/'cert.pem'),
                GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home/'root'),
                FM_STATE_OVERRIDE=str(home/'state'), FM_DATA_OVERRIDE=str(home/'data'),
                FM_CONFIG_OVERRIDE=str(home/'config'), FM_PROJECTS_OVERRIDE=str(home/'projects'),
                FM_CONTRIBUTIONS_NOW=NOW, FM_CONTRIBUTIONS_BUDGET='20')

def home(name, kind='pr'):
    h = SCRATCH/name
    for directory in ('data', 'state', 'config', 'projects', 'root', 'gh-config'):
        (h/directory).mkdir(parents=True, exist_ok=True)
    url = 'https://github.com/o/r/pull/8' if kind == 'pr' else 'https://github.com/o/r/issues/9'
    (h/'data/backlog.md').write_text(f'# Backlog\n\n## Queued\n- [ ] delivery - Compatibility {url} (repo: sample) (kind: ship)\n')
    return h, url

def run(h, *args, gh=False, budget=None):
    env = environment(h)
    if budget:
        env['FM_CONTRIBUTIONS_BUDGET'] = str(budget)
    cmd = ['gh'] + list(args) if gh else ['bash', str(product)] + list(args)
    start = time.monotonic()
    p = subprocess.run(cmd, env=env, cwd=ROOT, capture_output=True, text=True, timeout=45)
    elapsed = time.monotonic()-start
    transcript.append(f'$ {" ".join(cmd)}\nexit={p.returncode}; elapsed={elapsed:.3f}s\n{p.stdout}{p.stderr}')
    assert p.returncode == 0, transcript[-1]
    return p.stdout, elapsed

def record(h):
    return json.loads((h/'data/delivery/contributions.json').read_text())['records'][0]

def capture(h, name):
    data = dict(record=record(h), wake_queue=(h/'state/.wake-queue').read_text() if (h/'state/.wake-queue').exists() else '')
    (EVIDENCE/f'{name}.json').write_text(json.dumps(data, indent=2)+'\n')

def success(name, evidence):
    results.append(dict(name=name, result='pass', live=True, evidence=evidence, reason=''))

try:
    h, url = home('live-pr')
    version, _ = run(h, '--version', gh=True)
    assert '2.45.0' in version
    baseline_dir = SCRATCH/'baseline-bin'
    baseline_dir.mkdir(exist_ok=True)
    for source in (ROOT/'bin').iterdir():
        if source.name != 'fm-contributions.sh':
            link = baseline_dir/source.name
            if not link.exists():
                link.symlink_to(source)
    baseline_script = baseline_dir/'fm-contributions.sh'
    baseline_script.write_bytes(subprocess.check_output(['git', 'show', '70f2ed3d0ce66d481a105a9b79877c861ec9552e:bin/fm-contributions.sh'], cwd=ROOT))
    baseline, _ = home('live-baseline')
    product = baseline_script
    output, _ = run(baseline, 'poll')
    assert 'observation unavailable' in output
    assert record(baseline)['error'] is not None
    assert record(baseline)['observation'] is None
    capture(baseline, 'baseline-old-gh-refused')
    product = ROOT/'bin/fm-contributions.sh'
    run(h, 'pr', 'view', url, '--json', 'headRefOid,reviewDecision', gh=True)
    run(h, 'api', 'repos/o/r/issues/8/comments?per_page=100', '--paginate', gh=True)
    for endpoint in ('repos/o/r/pulls/8/reviews?per_page=100', 'repos/o/r/pulls/8/comments?per_page=100', f'repos/o/r/commits/{HEAD}/check-runs?filter=all&per_page=100', f'repos/o/r/commits/{HEAD}/statuses?per_page=100'):
        run(h, 'api', endpoint, '--paginate', gh=True)
    output, _ = run(h, 'poll')
    r = record(h)
    assert r['error'] is None
    assert r['observation']['head'] == HEAD
    assert r['observation']['can_merge'] is False
    assert len(r['observation']['checks']) == 4
    assert len(r['pending']) == 3
    assert {x['type'] for x in r['pending']} == {'comment', 'review', 'review-comment'}
    assert all(x['author'] == 'maintainer' for x in r['pending'])
    assert output.count('contribution-wake:') == 3
    capture(h, 'pr-pagination')
    success('Poll an owned PR with gh 2.45: later-page comments, reviews, inline feedback, checks and statuses are measured', 'pr-pagination.json; api-requests.json; live-transcript.log')

    prior_queue = (h/'state/.wake-queue').read_bytes()
    output, _ = run(h, 'poll')
    assert not output.strip()
    assert (h/'state/.wake-queue').read_bytes() == prior_queue
    pending, _ = run(h, 'pending')
    token = json.loads(pending)[0]['token']
    run(h, 'ack', 'delivery', url, token)
    assert len(record(h)['pending']) == 2
    output, _ = run(h, 'poll')
    assert not output.strip()
    assert len(record(h)['pending']) == 2
    assert (h/'state/.wake-queue').read_bytes() == prior_queue
    capture(h, 'ack-and-repoll')
    success('Re-poll and acknowledge one captured signal: no duplicate wakes and only that token is removed', 'ack-and-repoll.json; live-transcript.log')

    issue, issue_url = home('live-issue', 'issue')
    output, _ = run(issue, 'poll')
    ir = record(issue)
    assert ir['error'] is None
    assert {x['type'] for x in ir['pending']} == {'comment', 'ready-for-pr'}
    assert len(ir['pending']) == 2
    assert output.count('contribution-wake:') == 2
    capture(issue, 'issue-pagination')
    success('Poll a filed issue with gh 2.45: later-page maintainer feedback and a ready-label timeline event survive filtering', 'issue-pagination.json; api-requests.json; live-transcript.log')

    mode = 'slow'
    prior = (h/'data/delivery/contributions.json').read_bytes()
    prior_queue = (h/'state/.wake-queue').read_bytes()
    output, elapsed = run(h, 'poll', budget=5)
    assert elapsed < 10, elapsed
    assert not output.strip(), output
    assert (h/'data/delivery/contributions.json').read_bytes() == prior
    assert (h/'state/.wake-queue').read_bytes() == prior_queue
    capture(h, 'slow-read-preserved')
    mode = 'normal'
    run(h, 'poll')
    assert record(h)['error'] is None
    success('A slow later page reaches the read deadline: prior evidence and wakes stay unchanged and a later normal poll recovers', 'slow-read-preserved.json; live-transcript.log')

    mode = 'malformed'
    prior_observation = record(h)['observation']
    output, _ = run(h, 'poll')
    assert 'observation unavailable' in output, output
    assert record(h)['error'] is not None
    assert record(h)['observation'] == prior_observation
    output, _ = run(h, 'poll')
    assert 'observation unavailable' not in output
    capture(h, 'malformed-page')
    mode = 'normal'
    run(h, 'poll')
    assert record(h)['error'] is None
    capture(h, 'recovered-page')
    success('A malformed later page records one unavailable episode, preserves the last observation, and clears the error after recovery', 'malformed-page.json; recovered-page.json; live-transcript.log')

    mode = 'changed-head'
    before = record(h)['observation']
    output, _ = run(h, 'poll')
    assert 'observation unavailable' in output
    assert record(h)['error'] is not None
    assert record(h)['observation'] == before
    capture(h, 'changed-head-refused')
    success('A PR head changes between opening and closing reads: mixed-head evidence is refused', 'changed-head-refused.json; live-transcript.log')

    mode = 'normal'
    old_cli = False
    current, _ = home('live-current')
    run(current, '--version', gh=True)
    output, _ = run(current, 'poll')
    assert record(current)['error'] is None
    assert len(record(current)['observation']['checks']) == 4
    assert len(record(current)['pending']) == 3
    assert output.count('contribution-wake:') == 3
    capture(current, 'current-gh-pagination')
    success('Poll the same paginated PR with the installed current gh CLI: compatibility and complete measurement are retained', 'current-gh-pagination.json; live-transcript.log')
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
    (EVIDENCE/'api-requests.json').write_text(json.dumps(requests, indent=2)+'\n')
    (EVIDENCE/'live-transcript.log').write_text('\n'.join(transcript)+'\n')
    (EVIDENCE/'live-results.json').write_text(json.dumps(results, indent=2)+'\n')
    for name in ('live-pr', 'live-issue', 'live-baseline', 'live-current'):
        shutil.rmtree(SCRATCH/name, ignore_errors=True)
print(json.dumps(results, indent=2))
