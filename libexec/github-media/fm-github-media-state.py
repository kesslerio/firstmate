#!/usr/bin/env python3
"""fm-github-media.sh - approved native attachments with durable reconciliation.

Usage:
  FM_HOME=<home> FM_TASK_ID=<task> fm-github-media.sh prepare [--resume] --manifest FILE -- FILE...
  FM_HOME=<home> FM_TASK_ID=<task> fm-github-media.sh inspect --operation ID
  FM_HOME=<home> FM_TASK_ID=<task> fm-github-media.sh publish --operation ID
    --dependencies FILE [--disposition FILE]
  FM_HOME=<home> FM_TASK_ID=<task> fm-github-media.sh edit-body --operation ID
    --dependencies FILE --approval FILE
  FM_HOME=<home> FM_TASK_ID=<task> fm-github-media.sh complete --operation ID
    --dependencies FILE --review FILE

The supervisor supplies a JSON manifest (schema 1):
  home: absolute physical FM_HOME; task: existing data/<task> directory name;
  operation: unique safe ID; attempt: positive integer;
  authority: {explicit: true, approved_by: nonempty text, provenance: nonempty text};
  target: {host: "github.com", repository: "owner/name", repository_id: node ID,
           object_id: node ID, kind: "pr"|"issue", number: positive integer};
  actor: expected login;
  source: {repository_id: node ID, head: 40-hex SHA, ref: nonempty text} for PRs;
  files: ordered nonempty array of {path: absolute physical regular-file path,
         sha256: lowercase hex digest, size: bytes, media_type: MIME, label: text}.
Unknown/missing fields and duplicate JSON keys refuse; issue source is omitted.
Authority records an existing explicit approval, not a natural-language parser
or a sandbox against a hostile same-UID process. Labels are 1-200 ASCII letters,
numbers, spaces, underscores, periods, commas or hyphens, without edge spaces.
Labels must not contain any planned snapshot filename, even for another item.
CLI file arguments must exactly equal the approved paths in approved order.

PNG, JPEG and GIF are accepted with matching extension and signature, up to
10 MiB inclusive. MP4 is accepted only with an ISO MP4 ftyp brand, up to 10 MiB;
other video containers and higher limits refuse pending qualification (native
CLI maximum is 100 MiB). Container recognition does not prove codec/playback.
No transformation is performed. Files are opened without following any symlink,
streamed into exclusive private snapshots and hashed there; subsequent source
changes cannot substitute staged bytes. Hard-linked/duplicate bytes refuse.

Records live in FM_HOME/data/<task>/github-media/<operation>/operation.json.
The host-global registry is passwd-home/.local/state/firstmate-github-media,
independent of FM_HOME, HOME and XDG overrides, shared by homes of the same OS
user. Different OS users are outside this cooperative writer domain.
FM_TEST_SEAM=1 permits FM_GITHUB_MEDIA_TEST_ROOT for synthetic test roots only.
Directories/files owned here are 0700/0600; existing unsafe paths refuse.
The immutable host/repository_id/object_id hashes to a stable registry key.
A persistent <key>.lock inode has a nonblocking flock lease (busy exit 75).
A durable <key>.json claims the operation before snapshots or remote reads.
It is NEVER removed or treated as stale based on PID/lock freedom.
Unresolved claims refuse a new prepare, including the same operation ID.
prepare --resume explicitly continues only the current owner's preparing record
with the identical approved manifest and CLI files, settled read-only command
history and no mutation/attempt/dependency/body history. It retains the failed
record as preparation-<id>.json and every command/snapshot, revalidates existing
snapshots, stages only missing unrecorded files, then performs fresh actor,
repository, object and source/head preflight after operator renewal. Legacy
empty item lists may adopt exact approved staged bytes. Partial/corrupt snapshots,
missing recorded snapshots, malformed/unknown journals and changed approvals
hold without reset; no retirement, claim deletion or guessed PID kill exists.
Missing unrecorded source files can be supplied only as originally approved.
Crash before the claim's operation receipt exists still requires reconciliation.
Only delivery-complete permits a successor prepare under the same lease with
fresh target/actor/source/body checks. All prior claim owners, sealed reviews,
confirmed receipts, snapshots and command journals remain retained and checked.
Any requested digest already confirmed in that history refuses with guidance
to inspect/reuse its URLs. New disjoint bytes may proceed; no asset catalog or
automatic reupload exists. At 100 predecessors, further handoff holds.
Old operations remain inspectable but cannot mutate after ownership handoff.
Atomic JSON replacement and directory fsync bound writes; partial snapshots and
preparing records survive failure for inspection, without being publishable.

Record schema 1 stores manifest, operation_dir, target_key, state (preparing,
prepared, publishing, held, published-confirmed or delivery-complete), ordered items and, when prepared,
baseline_body_sha256 and preflight observations (actor, repository, object).
Prepared only means bytes and GET preflight matched, not publication authority
for a future changed head, upload success, hygiene approval or rendered proof.
inspect checks owner, registry, receipt and every snapshot under the target
lease without remote reads; it never grants permission to replay an attempt.
publish continuously holds the lease across actor/target/source/head/byte/body
revalidation, all-input hygiene, one native edit per item and fresh readback.
Each item is unattempted, unknown or published-confirmed. Its attempts array
stores id/command_id, private pre_body/pre_body_sha256 and state before launch.
A confirmed attempt adds url, post_body_sha256 and its limited assurance.
expected_body_sha256 chains confirmed appends. Confirmed entries are reused.
Reconciliation accepts only one fresh UUID user-attachment URL in the exact
native image/standalone-video append form, permitting only native trailing
space/tab/CR/LF trimming. No URLs are fetched or followed. CLI stdout is not
asset evidence. Nonzero can confirm; unchanged body after attempt is UNKNOWN.
Missing command completion, readback or receipt leaves a hold, never replay.
No rollback, orphan enumeration, asset-byte proof, server CAS or exactly-once
guarantee exists. The external human-write race of a full-body native edit
remains; observed divergence holds without stale restoration.

New execution dependencies JSON: {schema:2, native:{path,sha256}, read:{path,sha256},
validator:{path,sha256}, parser:{path,sha256}}.
Retained schema 1 bindings remain inspectable, but cannot execute. Only wholly
unattempted provisional records may adopt schema 2; mutative history cannot upgrade.
All paths are explicit absolute physical files, and reviewed digests are rechecked.
The first durable attempt binds this document.
Before any attempt or attach/body-edit history, dependencies remain provisional,
including legacy bindings, only while all items remain unattempted and command
ownership is settled. Any retained mutative attempt freezes the binding,
including a body edit journaled but never launched.
Native must be the qualified /nix/store/<hash>-github-media-gh/bin/github-media-gh
entrypoint, version 2.102.0 with --attach; ordinary reads remain reviewed gh-axi.
Parser must be the executable immutable /nix/store/<hash>-cmark-gfm-0.29.0.gfm.13/bin/cmark-gfm.
Validator and parser pins are rechecked before every hygiene invocation.
The validator is invoked as python3 <path> --validate-attachment-body --repo
OWNER/REPO --target-kind pr|issue --body-file FILE --cmark PATH
--cmark-sha256 HEX [--media-label TEXT ...].
Exit 0 must also return exactly protocol=attachment-body/v1, valid=true, repo,
target_kind, body_sha256 and labels_sha256. Labels use UTF-8 compact JSON with
ensure_ascii=false, preserving order. Missing/legacy/silent/malformed receipts
refuse. Existing body, all labels and cumulative predictions are validated
before upload, and actual readback after each. Production requires a separately
qualified stable reviewed pr-body-lint artifact implementing this exact mode.
No no-op default, PR_LINT_SKIP or marker exemption exists. Repository-local
template conflicts hold until target guidance and validator applicability are
reviewed; this interface does not override templates or add issue-create shapes.
Append placement accepts balanced Markdown, attribute-free closed details with one leading summary, nested disclosures, same-line inline code and complete HTML comments.
Multiline inline-code spans conservatively refuse, including across blank
paragraphs; an unmatched tick cannot hide a following HTML block/comment.
Markdown fences inside disclosures require a blank line before opening and cannot start inside summary or HTML code.
Nonblank lines indented four columns (including tabs) outside fences refuse, even with a later unindented disclosure close.
Backslashes in prose refuse; literal backslashes in code spans, fenced/HTML code and complete comments are preserved.
Other HTML, malformed structures and unclosed Markdown conservatively refuse.
This structural subset does not replace the validator's content policy.
Existing snapshot references refuse native rewriting. Image labels use #alt; videos
cannot take alt text. Approved video labels remain in the manifest for the
final body author's caption handoff, not a claim that captions were appended.

Body approval JSON: {schema:1,id,home,task,operation,target,actor,source,authority,
purpose:"repair"|"final",before_body_sha256,draft:{path,sha256},prose_offset,
retire_media_owed?:TEXT,reviewed_cleanup?:{before_body_sha256,draft_sha256,provenance}}.
Context exactly matches the immutable manifest; source
is null for issues. Authority has the manifest authority shape and records the
body owner's reviewed exact bytes/provenance. This is trusted task approval,
not inferred authorization or protection against a hostile same-UID writer.
Draft bytes are UTF-8, nofollow-read, digest-verified and privately snapshotted.
Repair defaults to a reviewed suffix addition retaining every existing body
byte. A separate reviewed_cleanup allowance explicitly authorizes the exact
clean draft, including deletions/replacements, and must repeat the approval's
before hash and draft hash with nonempty cleanup-review provenance. It is a
trusted owner assertion, never inferred from media approval or private-text
classification. Both repair forms require all files unattempted with no native
attempt history; unknown body edits hold. The whole cleaned draft AND all
cumulative predicted appends must pass hygiene before any body edit or upload.
Final supports ONLY moving the complete ordered confirmed media block into
the original pre-upload prose at prose_offset (a Unicode-character offset at
0, end, or immediately after LF); both prose slices must independently pass
the closed append-context predicate, so insertion inside a fence or open HTML
structure refuses. Each image retains exact approved alt text;
each video is preceded by its approved label and two LF. Blocks are separated
by two LF. The exact draft is prose[:offset] + two LF + blocks + two LF +
prose[offset:]. Prose is the first upload pre_body. Optional retire_media_owed is one exact existing
LF-terminated line explicitly designated by the owner for removal ONLY after
all uploads confirm; match it against the untrimmed pre_body, then apply native
trailing space/tab/CR/LF trimming. Offset addresses that retained prose. The designation
is a trusted review assertion, not semantic classification. All other prose
bytes are compared exactly; hashing arbitrary supplied prose is insufficient.
Intermediate/unknown uploads hold. No generic editor/Markdown diff is exposed.

edit-body uses ONLY fixed argv: reviewed gh-axi pr|issue edit NUMBER --repo
OWNER/REPO --body-file PRIVATE_SNAPSHOT. No native prose fallback, arbitrary
flags, shell evaluation or asset upload. Ordered body_edits store approval,
snapshot, pre_body, command_id and unknown/confirmed state. Repairs precede
upload hashes; final edits follow them. Journal and dependency freeze precede
launch. Fresh readback, including after nonzero/cancellation, decides whether
exact approved bytes landed with proved command launch. Unknown holds, even
if body is unchanged. Repeating the same approval reconciles/reuses; it never
reissues the edit. Changed/reused approval ids, source/body/actor drift, missing
ownership proof and live descendants hold. No old-body restoration or CAS.

Completion review JSON: {schema:1,home,task,operation,target,actor,source,authority,
body_sha256,reviewer,independent:true,provenance,media:[{ordinal,sha256,url,label,
rendered:true,playback:BOOLEAN,artifact:{path,sha256}}]}. Media exactly follows
confirmed manifest order; playback must be true for video, false for images.
Reviewer is an independently supplied identity distinct from the final body
approver. Evidence/provenance must come from actual independent rendered-image
and video-playback review, bound to this final body, items and URLs. The helper
never creates approval or reviewer evidence, nor judges artifact semantics.
Evidence is nofollow-read, digest-bound and snapshotted privately (10 MiB each).
Candidate review metadata and snapshots use the complete review's content hash,
including body and artifact bindings. Declined candidates remain retained;
fresh independent review can follow a refusal or later approved final placement.
All artifact inputs are checked before copying evidence. Later context/hygiene
refusals do not seal those candidate slots. Successful completion seals its
snapshot prefix; prior ordinal-only sealed reviews remain readable.
Synthetic attestations prove only offline behavior, never real UI acceptance.
complete requires settled ownership, all confirmed uploads, confirmed final
body edit, exact review bindings, hygiene and fresh readback before sealing
delivery-complete. Repeating the same review is idempotent; changed evidence
holds. Completion does not delete a claim/history or roll back server state.

Retry disposition JSON: {schema:1,id,authority,target,operation,ordinal,sha256,
prior_attempt,action:"retry-unknown"}. Authority has the manifest authority
shape; target must equal the complete immutable target. It binds the latest
unknown attempt and unchanged pre-body, after command ownership is settled.
Its unique id is consumed durably in consumed_dispositions in the same write
as the new attempt. Wrong, absent or reused dispositions refuse. Retained
attempts keep earlier uncertainty visible; dispositions do not prove no asset.

Linux /proc, subreaper and Python pidfd support are required for this optional
command. The private lifecycle module owns ephemeral command guardians.
Each guardian inherits the lease, watches parent EOF even after SIGKILL,
and kills/reaps only its children and adopted descendants through pidfds.
command-<id>.json records starting/running/stopped; stopped is written only
after ECHILD proves no owned descendants remain. Interrupted guardians or
unknown liveness refuse replacement even after reboot; no saved PID is killed.
Caught pipe/fork OSError before a guardian exists instead records stopped with
guardian=null, child_started=false, reason=spawn-failed, returncode=null,
output="" and descendants_reaped=true. Only that exact no-child receipt settles;
failure to persist it still holds, as does an interrupted starting record.
No daemon, listener, arbitrary command gateway or takeover command is exposed.
Synthetic tests require FM_TEST_SEAM=1, FM_GITHUB_MEDIA_TEST_ROOT and an explicit
FM_GITHUB_MEDIA_TEST_READ; only this seam admits fake native dependencies and
FM_GITHUB_MEDIA_TEST_TIMEOUT (0.5-120 seconds for attachment/body-edit deadline tests).

published-confirmed means attributable body readback, not completion.
rendered_qa stays pending-independent-review. Independent image rendering,
video playback, final captions and final-body hygiene remain separate gates
until complete records the independently supplied review after edit-body.

Reads use only gh-axi api GET <path> --jq @base64 --full --hostname github.com.
The qualified wire shape is exactly:
  api_response:
    body: <unquoted base64 JSON object>
    truncated: false
Unexpected/truncated output refuses; there is no native read fallback.
Only repository-push writers are currently qualified.
Author-only issue/PR body permissions are not qualified yet.
After operator recovery, an intact nonmutating preparing record can use
prepare --resume; all other unresolved states require their own reconciliation.
Reads/validator/runtime probes have 30-second deadlines; attachment/body edit has 120.
Authentication failures
hold for operator login/SSO/permission recovery; no credentials are logged.
Exit 0: prepared/inspected/confirmed/completed JSON; 1: actionable refusal, including dependency qualification;
2: usage or launcher failure;
75: target busy. Errors never echo transport output or manifest values.
"""
import argparse
import base64
import contextlib
import fcntl
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import stat
import sys
import tempfile
import uuid
from urllib.parse import unquote

from fm_github_media_lifecycle import Lifetime

LIMIT = 10 * 1024 * 1024
SLUG = r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}'
NODE = r'[A-Za-z0-9_-]{1,128}'


class Refusal(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def exact(obj, keys, name):
    require(isinstance(obj, dict) and set(obj) == set(keys.split()),
            name + ': missing or unknown fields; consult --help')


def matches(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def text(value):
    return isinstance(value, str) and 0 < len(value) <= 2000 and all(ord(c) >= 32 for c in value)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON field; provide an unambiguous manifest/record')
        result[key] = value
    return result


def physical(path):
    require(isinstance(path, str) and path.startswith('/') and
            str(Path(path)) == path and '..' not in Path(path).parts,
            'path must be absolute and normalized without symlinks')
    return Path(path)


@contextlib.contextmanager
def opened(path, flags=os.O_RDONLY, mode=0o600):
    """Walk directory descriptors so parent and leaf symlinks cannot be followed."""
    path = physical(str(path))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        leaf = os.open(path.name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, mode, dir_fd=fd)
        try:
            yield leaf
        finally:
            os.close(leaf)
    finally:
        os.close(fd)


def regular(fd, private=False):
    s = os.fstat(fd)
    require(stat.S_ISREG(s.st_mode), 'input/state must be a regular file without symlinks')
    require(s.st_mode & 0o444, 'input/state must be readable')
    if private:
        require(s.st_uid == os.getuid() and s.st_mode & 0o077 == 0 and s.st_nlink == 1,
                'unsafe private state ownership or permissions; reconcile without takeover')
    return s


def read_json(path, private=False):
    with opened(path) as fd:
        s = regular(fd, private)
        require(s.st_size <= 2 * 1024 * 1024, 'JSON record exceeds bounded size')
        with os.fdopen(os.dup(fd), 'r') as stream:
            return json.load(stream, object_pairs_hook=unique_pairs)


def sync_dir(path):
    with opened(path, os.O_RDONLY | os.O_DIRECTORY) as fd:
        os.fsync(fd)


def private_dir(path, create=True):
    if create and not path.exists():
        try:
            path.mkdir(mode=0o700)
            sync_dir(path.parent)
        except FileExistsError:
            pass
    with opened(path, os.O_RDONLY | os.O_DIRECTORY) as fd:
        s = os.fstat(fd)
        require(s.st_uid == os.getuid() and s.st_mode & 0o077 == 0,
                'state directory must be private and owned; do not take over existing state')


def atomic_json(path, value):
    payload = json.dumps(value, sort_keys=True) + '\n'
    require(len(payload.encode('utf-8')) <= 2 * 1024 * 1024,
            'state journal exceeds bounded size; operation held before further command launch')
    fd, tmp = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def owner():
    home = physical(os.environ.get('FM_HOME', ''))
    task = os.environ.get('FM_TASK_ID', '')
    require(matches(task, SLUG) and task not in ('.', '..'), 'task requires explicit safe FM_TASK_ID')
    task_dir = home / 'data' / task
    with opened(task_dir, os.O_RDONLY | os.O_DIRECTORY) as fd:
        s = os.fstat(fd)
        require(s.st_uid == os.getuid() and s.st_mode & 0o022 == 0,
                'task directory ownership/permissions are unsafe; refuse operation')
    return home, task, task_dir


def validate(m, home, task, paths):
    require(isinstance(m, dict) and isinstance(m.get('authority'), dict), 'authority is required')
    keys = 'schema home task operation attempt authority target actor files'
    kind = m.get('target', {}).get('kind') if isinstance(m.get('target'), dict) else None
    exact(m, keys + (' source' if kind == 'pr' else ''), 'manifest')
    require(type(m['schema']) is int and m['schema'] == 1, 'unsupported manifest schema')
    require(m['home'] == str(home), 'home does not match explicit FM_HOME')
    require(m['task'] == task, 'task does not match explicit FM_TASK_ID')
    require(matches(m['operation'], SLUG), 'operation requires a safe unique ID')
    require(type(m['attempt']) is int and m['attempt'] > 0, 'attempt must be a positive integer')
    a = m['authority']
    exact(a, 'explicit approved_by provenance', 'authority')
    require(a['explicit'] is True and text(a['approved_by']) and text(a['provenance']),
            'authority requires prior explicit approval and provenance')
    t = m['target']
    exact(t, 'host repository repository_id object_id kind number', 'target')
    require(t['host'] == 'github.com' and t['kind'] in ('pr', 'issue') and
            matches(t['repository'], r'[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+') and
            all(matches(t[k], NODE) for k in ('repository_id', 'object_id')) and
            type(t['number']) is int and t['number'] > 0, 'target has unsupported or invalid bindings')
    require(matches(m['actor'], r'[A-Za-z0-9][A-Za-z0-9-]{0,38}'), 'actor requires a GitHub login')
    if kind == 'pr':
        exact(m['source'], 'repository_id head ref', 'source/head')
        require(matches(m['source']['head'], r'[0-9a-f]{40}') and
                matches(m['source']['repository_id'], NODE) and text(m['source']['ref']),
                'source/head context must be explicit')
    require(isinstance(m['files'], list) and 0 < len(m['files']) <= 100,
            'files must be a nonempty bounded approved list')
    seen_paths, seen_hashes = set(), set()
    for item in m['files']:
        exact(item, 'path sha256 size media_type label', 'file')
        physical(item['path'])
        require(item['path'] not in seen_paths and item['sha256'] not in seen_hashes,
                'duplicate approved file or digest')
        require(matches(item['sha256'], r'[0-9a-f]{64}'), 'digest must be a SHA256 hex string')
        require(type(item['size']) is int and item['size'] > 0, 'empty or invalid approved size')
        require(item['size'] <= LIMIT, 'approved media exceeds 10 MiB limit')
        require(item['media_type'] in ('image/png', 'image/jpeg', 'image/gif', 'video/mp4'),
                'unsupported media type; no transformation is authorized')
        require(matches(item['label'], r'[A-Za-z0-9][A-Za-z0-9 _.,-]{0,199}') and
                item['label'].strip() == item['label'], 'label must be safe plain text')
        seen_paths.add(item['path'])
        seen_hashes.add(item['sha256'])
    require(paths == [f['path'] for f in m['files']], 'CLI inputs must equal listed approved files in order')


def target_key(target):
    identity = [target[k] for k in ('host', 'repository_id', 'object_id')]
    return hashlib.sha256(json.dumps(identity, separators=(',', ':')).encode()).hexdigest()


def registry_root():
    override = os.environ.get('FM_GITHUB_MEDIA_TEST_ROOT')
    if override:
        require(os.environ.get('FM_TEST_SEAM') == '1', 'registry override requires synthetic test seam')
        root = physical(override)
    else:
        root = Path(pwd.getpwuid(os.getuid()).pw_dir) / '.local/state/firstmate-github-media'
    # Existing ancestors need not be private, but must be real directories.
    missing = []
    p = root
    while not p.exists():
        missing.append(p)
        p = p.parent
    with opened(p, os.O_RDONLY | os.O_DIRECTORY):
        pass
    for p in reversed(missing):
        try:
            p.mkdir(mode=0o700)
            sync_dir(p.parent)
        except FileExistsError:
            pass
    private_dir(root)
    return root


@contextlib.contextmanager
def target_lease(root, key):
    with opened(root / (key + '.lock'), os.O_RDWR | os.O_CREAT) as fd:
        regular(fd, True)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refusal('busy: target lease is held by another cooperating writer')
        yield fd


def signature(header, item):
    mime = item['media_type']
    suffix = Path(item['path']).suffix.lower()
    valid = ((mime == 'image/png' and suffix == '.png' and header.startswith(b'\x89PNG\r\n\x1a\n')) or
             (mime == 'image/jpeg' and suffix in ('.jpg', '.jpeg') and header.startswith(b'\xff\xd8\xff')) or
             (mime == 'image/gif' and suffix == '.gif' and header[:6] in (b'GIF87a', b'GIF89a')))
    if mime == 'video/mp4' and suffix == '.mp4' and len(header) >= 20:
        length = int.from_bytes(header[:4], 'big')
        brands = [header[8:12]] + [header[n:n+4] for n in range(16, min(length, len(header)), 4)]
        valid = (header[4:8] == b'ftyp' and 20 <= length <= len(header) and
                 length % 4 == 0 and any(b in (b'isom', b'iso2', b'mp41', b'mp42', b'avc1') for b in brands))
    require(valid, 'signature/extension does not match supported media; do not transform silently')


def stage(item, dest, seen_inodes):
    try:
        with opened(item['path']) as src:
            before = regular(src)
            require(before.st_size > 0, 'empty media input')
            require(before.st_size <= LIMIT, 'media exceeds 10 MiB limit')
            require(before.st_size == item['size'], 'size changed from approved bytes')
            inode = (before.st_dev, before.st_ino)
            require(inode not in seen_inodes, 'duplicate source inode')
            seen_inodes.add(inode)
            with opened(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL) as out:
                digest = hashlib.sha256()
                total, header = 0, b''
                while True:
                    chunk = os.read(src, 65536)
                    if not chunk:
                        break
                    total += len(chunk)
                    require(total <= LIMIT, 'media grew beyond limit while staging')
                    if len(header) < 4096:
                        header += chunk[:4096-len(header)]
                    digest.update(chunk)
                    view = memoryview(chunk)
                    while view:
                        view = view[os.write(out, view):]
                after = os.fstat(src)
                require(total == item['size'] and digest.hexdigest() == item['sha256'],
                        'digest/size mismatch in staged bytes; obtain approval for changed input')
                require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                        (after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                        'source changed while staging; obtain stable approved bytes')
                signature(header, item)
                os.fsync(out)
    except OSError:
        raise Refusal('media must be readable regular files without symlink components') from None


def command_env():
    env = dict(os.environ, GH_HOST='github.com', GH_PROMPT_DISABLED='1')
    env.pop('GH_REPO', None)
    env['GH_PAGER'] = 'cat'
    env['GH_NO_UPDATE_NOTIFIER'] = '1'
    return env


def read_runtime():
    if os.environ.get('FM_TEST_SEAM') == '1':
        path = os.environ.get('FM_GITHUB_MEDIA_TEST_READ')
    else:
        path = shutil.which('gh-axi')
    require(path and Path(path).is_file(), 'gh-axi dependency unavailable; no native read fallback')
    return str(Path(path).resolve())


def remote_get(path, lifetime, runtime):
    result = lifetime.run([runtime, 'api', 'GET', path, '--jq', '@base64', '--full',
                           '--hostname', 'github.com'], command_env(), 'read')
    require(result['returncode'] == 0 and result['reason'] == 'exited',
            'gh-axi target read failed; operator must resolve authentication/SSO/permission')
    output = base64.b64decode(result['output'], validate=True)
    match = re.fullmatch(rb'api_response:\n  body: ([A-Za-z0-9+/]+={0,2})\n  truncated: false\n?', output)
    require(match is not None, 'unsupported gh-axi response; qualify wrapper compatibility, no native fallback')
    try:
        value = json.loads(base64.b64decode(match[1], validate=True), object_pairs_hook=unique_pairs)
    except (ValueError, UnicodeError):
        raise Refusal('invalid gh-axi response encoding; operation held') from None
    require(isinstance(value, dict), 'invalid gh-axi response object')
    return value


def preflight(m, lifetime, runtime, check_source=True):
    t = m['target']
    actor = remote_get('/user', lifetime, runtime)
    require(actor.get('login') == m['actor'], 'actor mismatch; operator must select the approved existing identity')
    repo = remote_get('/repos/' + t['repository'], lifetime, runtime)
    require(repo.get('node_id') == t['repository_id'] and repo.get('full_name') == t['repository'],
            'target repository identity/name mismatch')
    require(isinstance(repo.get('permissions'), dict) and repo['permissions'].get('push') is True,
            'writer capability is outside the qualified repository-push subset; reconcile the retained operation instead of retrying prepare')
    obj = remote_get('/repos/' + t['repository'] + ('/pulls/' if t['kind'] == 'pr' else '/issues/') + str(t['number']), lifetime, runtime)
    require(obj.get('node_id') == t['object_id'] and obj.get('number') == t['number'] and
            (t['kind'] != 'issue' or 'pull_request' not in obj), 'target object identity/kind/number mismatch')
    if t['kind'] == 'pr' and check_source:
        head = obj.get('head') or {}
        require(isinstance(head, dict) and head.get('sha') == m['source']['head'] and
                head.get('ref') == m['source']['ref'] and isinstance(head.get('repo'), dict) and
                head['repo'].get('node_id') == m['source']['repository_id'], 'source/head drift; new approval required')
    body = obj.get('body')
    require('body' in obj and (body is None or isinstance(body, str)), 'target body read is invalid')
    return {'actor': actor['login'], 'repository': repo['node_id'], 'object': obj['node_id']}, body or ''


def prepare(args):
    home, task, task_dir = owner()
    m = read_json(physical(args.manifest))
    validate(m, home, task, args.files)
    snapshots = [str(i) + Path(f['path']).suffix.lower() for i, f in enumerate(m['files'])]
    for item in m['files']:
        no_snapshot_references(item['label'], snapshots)
    root = registry_root()
    key = target_key(m['target'])
    with target_lease(root, key) as lease:
        claim = root / (key + '.json')
        if args.resume:
            op = task_dir/'github-media'/m['operation']
            private_dir(op, create=False)
            record = read_json(op/'operation.json', True)
            exact(record, 'schema manifest operation_dir target_key state items', 'preparing receipt')
            require(type(record['schema']) is int and record['schema'] == 1 and
                    record['state'] == 'preparing', 'resume requires a preparing operation without mutation history')
            require(record['manifest'] == m and record['operation_dir'] == str(op) and
                    record['target_key'] == key, 'preparation approval/context changed; original manifest required')
            active_owner(record)
            lifetime = Lifetime(op, lease, atomic_json, read_json, require)
            lifetime.settled()
            require(all(read_json(p, True)['phase'] == 'read' for p in op.glob('command-*.json')),
                    'preparation has non-read command history; hold without reset')
            expected = [dict(ordinal=i, snapshot=str(i)+Path(f['path']).suffix.lower(), state='unattempted')
                        for i, f in enumerate(m['files'])]
            require(isinstance(record['items'], list) and len(record['items']) <= len(expected) and
                    record['items'] == expected[:len(record['items'])],
                    'preparation has uncertain item/attempt history; hold without reset')
            allowed = {'operation.json'} | {i['snapshot'] for i in expected}
            require(all(p.name in allowed or re.fullmatch(r'(command|preparation)-[0-9a-f]{32}\.json', p.name)
                        for p in op.iterdir()), 'unrecognized preparation evidence; hold without reset')
            # Old preparing receipts may have items=[] even after all snapshots
            # were staged. Only exact approved bytes can be adopted, never reset.
            for item, approved in zip(expected, m['files']):
                path = op/item['snapshot']
                require(item not in record['items'] or os.path.lexists(path),
                        'recorded preparation snapshot missing; hold without reset')
                if os.path.lexists(path):
                    data = snapshot_bytes(dict(path=str(path), sha256=approved['sha256']), True)
                    require(len(data) == approved['size'], 'snapshot size changed; hold operation')
                    signature(data[:4096], approved)
            save_snapshot(op/('preparation-'+uuid.uuid4().hex+'.json'),
                          (json.dumps(record, sort_keys=True)+'\n').encode())
            return finish_preparation(record, op, lifetime)
        history = []
        if os.path.lexists(claim):
            try:
                previous = read_json(claim, True)
                require(isinstance(previous, dict), 'invalid claim')
                history = previous.get('history', []) + [{k: v for k, v in previous.items() if k != 'history'}]
            except (OSError, ValueError, KeyError, TypeError, Refusal):
                raise Refusal('unresolved target registry claim; inspect unreadable ownership without takeover') from None
            require(len(history) <= 100, 'retained target history limit; reuse known receipts, no automatic pruning')
            for prior in history:
                try:
                    old_op = physical(prior['operation_dir'])
                    private_dir(old_op, create=False)
                    old = read_json(old_op/'operation.json', True)
                except (OSError, ValueError, KeyError, TypeError, Refusal):
                    raise Refusal('unresolved target registry claim; inspect unreadable ownership without takeover') from None
                require(prior == claim_owner(old) and target_key(prior['target']) == key and
                        old['state'] == 'delivery-complete',
                        'unresolved target registry claim; reconcile existing operation, never replay')
                verify_snapshots(old, old_op)
                validate_attempts(old, old_op)
                validate_completion(old, old_op)
                Lifetime(old_op, lease, atomic_json, read_json, require).settled()
                require(not {f['sha256'] for f in m['files']} & {f['sha256'] for f in old['manifest']['files']},
                        'known confirmed receipts already cover requested bytes; inspect retained operation history and reuse URLs, never reupload')
            _, fresh = preflight(m, Lifetime(old_op, lease, atomic_json, read_json, require), read_runtime())
            require(sha(fresh) == old['expected_body_sha256'],
                    'terminal body drift; owner must reconcile retained history before handoff')
        parent = task_dir / 'github-media'
        private_dir(parent)
        op = parent / m['operation']
        require(not os.path.lexists(op), 'operation already exists; inspect and reconcile it')
        op.mkdir(mode=0o700)
        sync_dir(parent)
        record = dict(schema=1, manifest=m, operation_dir=str(op), target_key=key, state='preparing', items=[])
        next_claim = claim_owner(record)
        if history:
            next_claim['history'] = history
        atomic_json(claim, next_claim)
        atomic_json(op/'operation.json', record)
        return finish_preparation(record, op, Lifetime(op, lease, atomic_json, read_json, require))


def finish_preparation(record, op, lifetime):
    m = record['manifest']
    inodes = set()
    for ordinal, item in enumerate(m['files']):
        name = str(ordinal) + Path(item['path']).suffix.lower()
        if not os.path.lexists(op/name):
            stage(item, op/name, inodes)
        if ordinal >= len(record['items']):
            record['items'].append(dict(ordinal=ordinal, snapshot=name, state='unattempted'))
            atomic_json(op/'operation.json', record)
    sync_dir(op)
    verify_snapshots(record, op)
    observations, body = preflight(m, lifetime, read_runtime())
    verify_snapshots(record, op)
    record.update(state='prepared', preflight=observations, baseline_body_sha256=sha(body))
    atomic_json(op/'operation.json', record)
    return record


def verify_snapshots(record, op):
    m = record['manifest']
    require(len(record['items']) == len(m['files']), 'unresolved item list; reconciliation required')
    for ordinal, (item, approved) in enumerate(zip(record['items'], m['files'])):
        require(isinstance(item, dict) and item.get('ordinal') == ordinal and
                item.get('snapshot') == str(ordinal)+Path(approved['path']).suffix.lower() and
                item.get('state') in ('unattempted', 'unknown', 'published-confirmed'),
                'unresolved item receipt; reconciliation required')
        with opened(op/item['snapshot']) as fd:
            s = regular(fd, True)
            require(s.st_size == approved['size'], 'snapshot size changed; hold operation')
            with os.fdopen(os.dup(fd), 'rb') as stream:
                digest = hashlib.sha256(stream.read(LIMIT+1)).hexdigest()
            require(digest == approved['sha256'], 'snapshot digest changed; hold operation')


def claim_owner(record):
    m = record['manifest']
    return dict(schema=1, home=m['home'], task=m['task'], operation=m['operation'],
                operation_dir=record['operation_dir'], target=m['target'])


def active_owner(record):
    claim = read_json(registry_root()/(record['target_key']+'.json'), True)
    require({k: v for k, v in claim.items() if k != 'history'} == claim_owner(record),
            'historical operation is read-only; current owner holds target lease')


@contextlib.contextmanager
def operation(args):
    home, task, task_dir = owner()
    require(matches(args.operation, SLUG), 'operation requires a safe ID')
    op = task_dir/'github-media'/args.operation
    private_dir(op, create=False)
    record = read_json(op/'operation.json', True)
    m = record['manifest']
    validate(m, home, task, [f['path'] for f in m['files']])
    key = target_key(m['target'])
    root = registry_root()
    with target_lease(root, key) as lease:
        # Reread under the lease rather than trusting a pre-lease receipt.
        require(read_json(op/'operation.json', True) == record, 'receipt changed; reconcile before continuing')
        claim = read_json(root/(key+'.json'), True)
        owners = [{k: v for k, v in claim.items() if k != 'history'}] + claim.get('history', [])
        require(claim_owner(record) in owners and
                record['operation_dir'] == str(op) and record['target_key'] == key and
                m['operation'] == args.operation, 'uncertain operation ownership; refuse takeover')
        require(record['schema'] == 1 and record['state'] in ('prepared', 'publishing', 'held', 'published-confirmed', 'delivery-complete') and
                record.get('preflight') == dict(actor=m['actor'], repository=m['target']['repository_id'],
                                                object=m['target']['object_id']) and
                matches(record.get('baseline_body_sha256'), r'[0-9a-f]{64}'),
                'unresolved operation receipt; reconciliation required')
        verify_snapshots(record, op)
        validate_attempts(record, op)
        if record['state'] == 'delivery-complete':
            validate_completion(record, op)
        lifetime = Lifetime(op, lease, atomic_json, read_json, require)
        lifetime.settled()
        yield record, op, lifetime


def inspect(args):
    with operation(args) as (record, _, _):
        return record


def sha(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def append_media(body, approved, url):
    addition = url if approved['media_type'] == 'video/mp4' else '![' + approved['label'] + '](' + url + ')'
    before = body.rstrip(' \t\r\n')
    return before + ('\n\n' if before else '') + addition


ASSET_URL = r'https://github\.com/user-attachments/assets/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
PROBE_URL = 'https://github.com/user-attachments/assets/00000000-0000-0000-0000-000000000000'


def validate_attempts(record, op):
    expected = record['baseline_body_sha256']
    edits = record.get('body_edits', [])
    require(isinstance(edits, list), 'invalid body edit journal; hold')
    repairs = [e for e in edits if e['approval']['purpose'] == 'repair']
    finals = [e for e in edits if e['approval']['purpose'] == 'final']
    require(edits == repairs + finals, 'invalid body edit phase order; hold')
    expected = validate_body_chain(repairs, record, op, expected)
    require(not any(e['state'] == 'unknown' for e in repairs) or
            all(i['state'] == 'unattempted' and not i.get('attempts') for i in record['items']),
            'unknown repair before upload history; hold')
    consumed = record.get('consumed_dispositions', [])
    require(isinstance(consumed, list) and all(matches(i, SLUG) for i in consumed) and
            len(set(consumed)) == len(consumed), 'invalid disposition consumption journal; hold')
    identities = set()
    pending = False
    for item, approved in zip(record['items'], record['manifest']['files']):
        attempts = item.get('attempts', [])
        require(isinstance(attempts, list), 'invalid attempt journal; hold')
        require((item['state'] == 'unattempted') == (not attempts), 'missing attempt journal; hold')
        for attempt in attempts:
            require(isinstance(attempt, dict) and matches(attempt.get('id'), r'[0-9a-f]{32}') and
                    attempt['id'] not in identities and
                    attempt.get('command_id') == attempt['id'] and
                    isinstance(attempt.get('pre_body'), str) and
                    sha(attempt['pre_body']) == attempt.get('pre_body_sha256') and
                    attempt.get('state') in ('unknown', 'published-confirmed'),
                    'invalid attempt binding; hold')
            identities.add(attempt['id'])
        if attempts:
            latest = attempts[-1]
            require(not pending and item['state'] == latest['state'] and
                    latest['pre_body_sha256'] == expected, 'invalid ordered receipt chain; hold')
            if item['state'] == 'published-confirmed':
                url = latest.get('url')
                require(matches(url, ASSET_URL) and url not in latest['pre_body'] and
                        sha(append_media(latest['pre_body'], approved, url)) == latest.get('post_body_sha256'),
                        'invalid confirmed append receipt; hold')
                expected = latest['post_body_sha256']
            else:
                pending = True
        else:
            pending = True
    require(not finals or all(i['state'] == 'published-confirmed' for i in record['items']),
            'final body edit requires complete confirmation; hold')
    expected = validate_body_chain(finals, record, op, expected)
    require(record.get('expected_body_sha256', expected) == expected, 'invalid expected body receipt; hold')


def dependency_file(spec):
    exact(spec, 'path sha256', 'dependency')
    path = physical(spec['path'])
    with opened(path) as fd:
        regular(fd)
        with os.fdopen(os.dup(fd), 'rb') as stream:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: stream.read(65536), b''):
                hasher.update(chunk)
            digest = hasher.hexdigest()
    require(matches(spec['sha256'], r'[0-9a-f]{64}') and digest == spec['sha256'],
            'reviewed dependency digest changed; operator review required')
    return str(path)


def dependencies(path):
    try:
        value = read_json(physical(path))
        exact(value, 'schema native read validator parser', 'dependencies')
        require(type(value['schema']) is int and value['schema'] == 2, 'unsupported execution dependencies schema; schema 2 required')
        for spec in (value['native'], value['read'], value['validator'], value['parser']):
            dependency_file(spec)
        require(os.access(value['parser']['path'], os.X_OK), 'reviewed parser must be executable')
        if os.environ.get('FM_TEST_SEAM') == '1':
            require(os.environ.get('FM_GITHUB_MEDIA_TEST_ROOT') and
                    value['read']['path'] == read_runtime(), 'synthetic dependencies must be explicit')
        else:
            require(matches(value['native']['path'], r'/nix/store/[a-z0-9]{32}-github-media-gh/bin/github-media-gh'),
                    'native dependency must be the qualified immutable github-media-gh store entrypoint')
            require(value['read']['path'] == read_runtime(), 'read dependency must resolve to the reviewed gh-axi')
            require(matches(value['parser']['path'], r'/nix/store/[a-z0-9]{32}-cmark-gfm-0\.29\.0\.gfm\.13/bin/cmark-gfm'),
                    'parser dependency must be the immutable cmark-gfm 0.29.0.gfm.13 store executable')
        return value
    except OSError:
        raise Refusal('reviewed dependency missing/unreadable; publication held') from None


class AppendHTML(HTMLParser):
    """Recognize a closed disclosure subset without rendering or rewriting it."""

    def __init__(self, source):
        super().__init__(convert_charrefs=False)
        self.source = source
        # HTMLParser counts LF line breaks; offsets stay in the original text for CRLF positions.
        self.line_starts = [0]
        self.line_starts.extend(index + 1 for index, char in enumerate(source) if char == '\n')
        self.stack = []
        self.markdown = []
        self.code_span = None

    def admit(self, condition):
        require(condition, 'unsafe HTML append context; unsupported or unclosed structure')

    def remaining(self):
        line, column = self.getpos()
        # Fence masking can exceed the source's LF rows; retain the old empty suffix.
        if line > len(self.line_starts):
            return ''
        return self.source[self.line_starts[line - 1] + column:]

    def literal_markup(self, raw):
        if self.code_span:
            self.admit(not self.stack)
            self.markdown.append(raw)
            return True
        return False

    def handle_starttag(self, tag, attrs):
        if self.literal_markup(self.get_starttag_text()):
            return
        self.admit(tag in ('details', 'summary', 'code') and not attrs and
                   re.fullmatch(r'<' + tag + r'\s*>', self.get_starttag_text(), re.I))
        parent = self.stack[-1] if self.stack else None
        self.admit(parent is None or parent['tag'] != 'code')
        if tag == 'summary':
            self.admit(parent is not None and parent['tag'] == 'details' and not parent['summary'])
            parent['summary'] = True
        elif parent and parent['tag'] == 'details':
            self.admit(parent['summary'])
        if tag == 'details':
            self.admit(parent is None or parent['tag'] == 'details')
        self.stack.append(dict(tag=tag, summary=False))

    def handle_endtag(self, tag):
        if self.literal_markup(self.remaining().split('>', 1)[0] + '>'):
            return
        self.admit(re.match(r'</' + re.escape(tag) + r'\s*>', self.remaining(), re.I) and
                   self.stack and self.stack[-1]['tag'] == tag)
        frame = self.stack.pop()
        self.admit(tag != 'details' or frame['summary'])

    def handle_startendtag(self, tag, attrs):
        self.admit(self.literal_markup(self.get_starttag_text()))

    def handle_data(self, data):
        parent = self.stack[-1] if self.stack else None
        if parent and parent['tag'] == 'code':
            self.admit(not re.search(r'<[!/?A-Za-z]', data))
            return
        if parent and parent['tag'] == 'details' and not parent['summary']:
            self.admit(not data.strip())
        # HTML code/comments do not contribute Markdown delimiters, and
        # balanced Markdown code spans make contained HTML syntax literal.
        for part in re.split(r'(`+)', data):
            if part.startswith('`'):
                if self.code_span is None:
                    self.code_span = len(part)
                elif len(part) == self.code_span:
                    self.code_span = None
            elif not self.code_span:
                # Escapes are Markdown-context dependent. Do not rewrite HTML
                # or guess at escaped delimiters in this conservative subset.
                self.admit('\\' not in part)
                self.admit(not re.search(r'<[!/?A-Za-z]', part))
        self.markdown.append(data)

    def handle_comment(self, data):
        if self.literal_markup('<!--' + data + '-->'):
            return
        self.admit(self.remaining().startswith('<!--' + data + '-->') and '--' not in data and
                   (not self.stack or self.stack[-1]['tag'] != 'code'))

    def handle_decl(self, decl):
        self.admit(False)

    def unknown_decl(self, data):
        self.admit(False)

    def handle_pi(self, data):
        self.admit(False)


def safe_append(body):
    # Only append placement is decided here; hygiene remains the validator's.
    inline = body + '\n'
    structure = AppendHTML(inline)
    fence = None
    previous_blank = True
    for line in inline.splitlines(keepends=True):
        found = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if found:
            marker, tail = found.groups()
            if fence is None:
                require(not structure.stack or (previous_blank and all(f['tag'] == 'details' for f in structure.stack)),
                        'unsafe Markdown fence in HTML context; separate disclosure content with a blank line')
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence) and not tail.strip():
                fence = None
            structure.feed('\n')
        elif fence is None:
            # Indented Markdown code can contain literal closing HTML tags.
            # Refuse this interaction rather than letting it change the stack.
            require(not line.strip() or not line.expandtabs(4).startswith('    '),
                    'unsafe unsupported indented content; use a separated fenced code block')
            structure.feed(line)
            require(structure.code_span is None,
                    'unsafe unsupported multiline inline code span; use same-line code or a separated fenced block')
        else:
            structure.feed('\n')
        previous_blank = not line.strip()
    require(fence is None, 'unsafe unclosed Markdown fence; body author must resolve before upload')
    structure.close()
    structure.admit(not structure.stack)
    inline = ''.join(structure.markdown)
    inline = re.sub(r'(`+)(?!`)([^\r\n]*?)(?<!`)\1(?!`)', '', inline)
    require('`' not in inline, 'unsafe unclosed Markdown code span; body author must resolve before upload')
    for opening, closing in [('(', ')'), ('[', ']')]:
        depth = 0
        for char in inline:
            if char == opening:
                depth += 1
            elif char == closing:
                depth -= 1
            require(depth >= 0, 'unsupported Markdown delimiter context; resolve before upload')
        require(depth == 0, 'unsafe unclosed Markdown delimiter; resolve before upload')
    # Avoid native reference substitution: even encoded/escaped snapshot
    # filenames cannot enter an append-only operation from existing prose.
    require('\x00' not in body, 'invalid body append context')


def hygiene(body, record, op, lifetime, deps):
    safe_append(body)
    labels = [f['label'] for f in record['manifest']['files']]
    target = record['manifest']['target']
    spec = deps['validator']
    dependency_file(spec)
    parser = deps['parser']
    dependency_file(parser)
    require(os.access(parser['path'], os.X_OK), 'reviewed parser must be executable')
    fd, name = tempfile.mkstemp(prefix='body-', dir=op)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(body.encode('utf-8'))
        args = [sys.executable, spec['path'], '--validate-attachment-body', '--repo', target['repository'],
                '--target-kind', target['kind'], '--body-file', name,
                '--cmark', parser['path'], '--cmark-sha256', parser['sha256']]
        for label in labels:
            args += ['--media-label', label]
        result = lifetime.run(args, command_env(), 'hygiene')
        require(result['returncode'] == 0 and result['reason'] == 'exited',
                'attachment-body validator refused/unavailable; publication held')
        try:
            receipt = json.loads(base64.b64decode(result['output'], validate=True), object_pairs_hook=unique_pairs)
        except (ValueError, UnicodeError):
            raise Refusal('attachment-body validator receipt missing/malformed; publication held') from None
        expected = dict(protocol='attachment-body/v1', valid=True, repo=target['repository'], target_kind=target['kind'],
                        body_sha256=sha(body), labels_sha256=sha(json.dumps(labels, ensure_ascii=False, separators=(',', ':'))))
        require(receipt == expected and receipt.get('valid') is True,
                'attachment-body validator receipt mismatch; publication held')
    finally:
        os.unlink(name)


def no_snapshot_references(body, snapshots):
    decoded = unquote(re.sub(r'\\([!"#$%&\'()*+,\-./:;<=>?@\[\]\\^_`{|}~])', r'\1', body))
    for snapshot in snapshots:
        require(snapshot not in decoded, 'body or label may reference snapshot; append-only operation refused')


def prevalidate(body, record, op, lifetime, deps):
    snapshots = [item['snapshot'] for item in record['items']]
    no_snapshot_references(body, snapshots)
    hygiene(body, record, op, lifetime, deps)
    predicted = body
    for item, approved in zip(record['items'], record['manifest']['files']):
        if item['state'] != 'published-confirmed':
            predicted = append_media(predicted, approved, PROBE_URL)
            no_snapshot_references(predicted, snapshots)
            hygiene(predicted, record, op, lifetime, deps)


def qualify_native(record, lifetime, deps):
    native = dependency_file(deps['native'])
    result = lifetime.run([native, '--version'], command_env(), 'runtime')
    require(result['returncode'] == 0 and result['reason'] == 'exited' and
            re.match(rb'gh version 2\.102\.0(?:[ \n]|$)', base64.b64decode(result['output'])),
            'unsupported native runtime; operator must supply qualified 2.102.0')
    kind = record['manifest']['target']['kind']
    result = lifetime.run([native, kind, 'edit', '--help'], command_env(), 'runtime')
    require(result['returncode'] == 0 and result['reason'] == 'exited' and
            b'--attach' in base64.b64decode(result['output']), 'native attachment capability unavailable')


def reconcile_item(body, item, approved):
    attempt = item['attempts'][-1]
    before = attempt['pre_body']
    prefix = before.rstrip(' \t\r\n')
    prefix += '\n\n' if prefix else ''
    if not body.startswith(prefix):
        return False
    addition = body[len(prefix):]
    pattern = ASSET_URL if approved['media_type'] == 'video/mp4' else r'!\[' + re.escape(approved['label']) + r'\]\((' + ASSET_URL + r')\)'
    match = re.fullmatch(pattern, addition)
    if match is None:
        return False
    url = addition if approved['media_type'] == 'video/mp4' else match[1]
    if url in before:
        return False
    attempt.update(state='published-confirmed', url=url, post_body_sha256=sha(body),
                   assurance='attributable-native-append-readback; asset-bytes-and-rendering-unverified')
    item['state'] = 'published-confirmed'
    return True


def native_started(op, item):
    path = op/('command-' + item['attempts'][-1]['command_id'] + '.json')
    if not path.exists():
        return False
    command = read_json(path, True)
    return command.get('phase') == 'attach' and type(command.get('child_pid')) is int and command['child_pid'] > 0


def disposition(path, record, item):
    require(path, 'unknown upload outcome; explicit item-bound operator disposition required, never blind replay')
    value = read_json(physical(path))
    exact(value, 'schema id authority target operation ordinal sha256 prior_attempt action', 'disposition')
    m = record['manifest']
    require(value['schema'] == 1 and matches(value['id'], SLUG) and value['action'] == 'retry-unknown' and
            value['target'] == m['target'] and value['operation'] == m['operation'] and
            type(value['ordinal']) is int and value['ordinal'] == item['ordinal'] and
            value['sha256'] == m['files'][item['ordinal']]['sha256'] and
            value['prior_attempt'] == item['attempts'][-1]['id'], 'disposition binding mismatch; hold')
    exact(value['authority'], 'explicit approved_by provenance', 'disposition authority')
    require(value['authority']['explicit'] is True and text(value['authority']['approved_by']) and
            text(value['authority']['provenance']), 'disposition requires explicit operator authority')
    require(value['id'] not in record.get('consumed_dispositions', []), 'disposition already consumed; hold')
    return value


def approved_context(value, record):
    m = record['manifest']
    require(all(value[k] == m[k] for k in ('home', 'task', 'operation', 'target', 'actor')) and
            value['source'] == m.get('source'), 'approval owner/target/actor/source binding mismatch; hold')
    a = value['authority']
    exact(a, 'explicit approved_by provenance', 'body owner authority')
    require(a['explicit'] is True and text(a['approved_by']) and text(a['provenance']),
            'body owner requires explicit reviewed approval and provenance')


def snapshot_bytes(spec, private=False):
    exact(spec, 'path sha256', 'snapshot input')
    with opened(physical(spec['path'])) as fd:
        s = regular(fd, private)
        require(s.st_size <= LIMIT, 'snapshot input exceeds bounded size')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            data = stream.read(LIMIT+1)
        after = os.fstat(fd)
        require(len(data) <= LIMIT and hashlib.sha256(data).hexdigest() == spec['sha256'] and
                (s.st_size, s.st_mtime_ns, s.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                'approved snapshot digest changed; obtain fresh review')
        return data


def save_snapshot(path, data):
    # An interrupted pre-journal snapshot is reusable only for these exact bytes.
    if os.path.lexists(path):
        snapshot_bytes(dict(path=str(path), sha256=hashlib.sha256(data).hexdigest()), True)
        return
    with opened(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL) as fd:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    sync_dir(path.parent)


def body_request(value, record):
    keys = 'schema id home task operation target actor source authority purpose before_body_sha256 draft prose_offset'
    keys += ''.join(' '+k for k in ('retire_media_owed', 'reviewed_cleanup') if k in value)
    exact(value, keys, 'body approval')
    approved_context(value, record)
    require(type(value['schema']) is int and value['schema'] == 1 and matches(value['id'], SLUG) and
            value['purpose'] in ('repair', 'final') and matches(value['before_body_sha256'], r'[0-9a-f]{64}') and
            type(value['prose_offset']) is int and value['prose_offset'] >= 0,
            'invalid body approval fields; hold')
    exact(value['draft'], 'path sha256', 'approved draft')
    if 'reviewed_cleanup' in value:
        cleanup = value['reviewed_cleanup']
        exact(cleanup, 'before_body_sha256 draft_sha256 provenance', 'reviewed cleanup allowance')
        require(value['purpose'] == 'repair' and cleanup['before_body_sha256'] == value['before_body_sha256'] and
                cleanup['draft_sha256'] == value['draft']['sha256'] and text(cleanup['provenance']),
                'cleanup requires explicit review bound to exact before/draft bytes')


def body_shape(approval, before, draft, record):
    if approval['purpose'] == 'repair':
        require(not approval.get('retire_media_owed') and approval['prose_offset'] == 0 and draft != before and
                (draft.startswith(before) or 'reviewed_cleanup' in approval),
                'repair needs offset zero and a changed draft; without reviewed_cleanup retain every existing prose byte')
    else:
        # U3's exact append chain identifies the original prose without parsing
        # arbitrary Markdown. Only one ordered block may move, at a line boundary.
        prose = record['items'][0]['attempts'][-1]['pre_body']
        retired = approval.get('retire_media_owed')
        if retired is not None:
            require(isinstance(retired, str) and retired.endswith('\n') and retired.strip() and
                    '\n' not in retired[:-1] and prose.count(retired) == 1 and
                    (prose.startswith(retired) or '\n'+retired in prose),
                    'retired media-owed text must be one explicitly reviewed complete existing line')
            prose = prose.replace(retired, '', 1)
        prose = prose.rstrip(' \t\r\n')
        blocks = []
        for item, approved in zip(record['items'], record['manifest']['files']):
            url = item['attempts'][-1]['url']
            blocks.append(approved['label']+'\n\n'+url if approved['media_type'] == 'video/mp4'
                          else append_media('', approved, url))
        offset = approval['prose_offset']
        require(offset <= len(prose) and (offset in (0, len(prose)) or prose[offset-1] == '\n'),
                'media placement requires a retained-prose line boundary')
        safe_append(prose[:offset])
        safe_append(prose[offset:])
        expected = prose[:offset]+'\n\n'+'\n\n'.join(blocks)+'\n\n'+prose[offset:]
        require(draft == expected, 'approved draft must preserve exact unrelated prose and all confirmed media/order/labels')


def validate_body_chain(edits, record, op, expected):
    pending = False
    ids = set()
    for edit in edits:
        a = edit['approval']
        body_request(a, record)
        require(not pending and a['id'] not in ids and matches(edit['command_id'], r'[0-9a-f]{32}') and
                edit['state'] in ('unknown', 'confirmed') and sha(edit['pre_body']) == expected and
                a['before_body_sha256'] == expected and edit['snapshot'] == 'draft-'+a['id']+'.md',
                'invalid ordered body edit journal; hold')
        ids.add(a['id'])
        draft = snapshot_bytes(dict(path=str(op/edit['snapshot']), sha256=a['draft']['sha256']), True).decode('utf-8')
        body_shape(a, edit['pre_body'], draft, record)
        if edit['state'] == 'confirmed':
            require(edit['post_body_sha256'] == sha(draft), 'invalid confirmed body edit receipt')
            expected = sha(draft)
        else:
            pending = True
    return expected


def bind_dependencies(record, op, deps):
    provisional = (all(i['state'] == 'unattempted' and not i.get('attempts') for i in record['items']) and
                   not record.get('body_edits') and not record.get('consumed_dispositions') and
                   not any(read_json(p, True)['phase'] in ('attach', 'body-edit') for p in op.glob('command-*.json')))
    if provisional:
        record.pop('dependencies', None)
    else:
        require(record.get('dependencies') == deps, 'reviewed dependency binding changed; hold')


def settled_body(record):
    require(not any(e['state'] == 'unknown' for e in record.get('body_edits', [])),
            'unknown body edit outcome; reconcile the same approved edit, never replay or restore old body')


def reconcile_body(edit, body, op):
    path = op/('command-'+edit['command_id']+'.json')
    if path.exists():
        command = read_json(path, True)
        if (command.get('phase') == 'body-edit' and type(command.get('child_pid')) is int and
                command['child_pid'] > 0 and sha(body) == edit['approval']['draft']['sha256']):
            edit.update(state='confirmed', post_body_sha256=sha(body))
            return True
    return False


def edit_body(args):
    deps = dependencies(args.dependencies)
    with operation(args) as (record, op, lifetime):
        active_owner(record)
        require(record['state'] != 'delivery-complete', 'delivery-complete operation is sealed; inspect retained receipts')
        bind_dependencies(record, op, deps)
        approval = read_json(physical(args.approval))
        body_request(approval, record)
        data = snapshot_bytes(approval['draft'])
        draft = data.decode('utf-8')
        m = record['manifest']
        try:
            prior = next((e for e in record.get('body_edits', []) if e['approval']['id'] == approval['id']), None)
            _, body = preflight(m, lifetime, dependency_file(deps['read']))
            if prior:
                require(prior['approval'] == approval, 'approved body edit identity reused with changed input; hold')
                recovered = prior['state'] == 'unknown' and reconcile_body(prior, body, op)
                if recovered:
                    record['expected_body_sha256'] = sha(body)
                    atomic_json(op/'operation.json', record)
                require(prior['state'] == 'confirmed', 'unknown body edit outcome; no blind replay')
                require(sha(body) == record['expected_body_sha256'], 'body drift after confirmed edit; hold')
                hygiene(body, record, op, lifetime, deps)
                if recovered:
                    record['state'] = 'prepared' if approval['purpose'] == 'repair' else 'published-confirmed'
                    record.pop('hold', None)
                    atomic_json(op/'operation.json', record)
                return record
            settled_body(record)
            state = 'unattempted' if approval['purpose'] == 'repair' else 'published-confirmed'
            require(all(i['state'] == state and (state != 'unattempted' or not i.get('attempts')) for i in record['items']),
                    'body edit phase requires all-unattempted repair or all-confirmed final handoff; reconcile intermediate uploads')
            if state == 'unattempted':
                require(not any(read_json(p, True)['phase'] == 'attach' for p in op.glob('command-*.json')),
                        'repair refuses retained native attempt history')
            require(sha(body) == record.get('expected_body_sha256', record['baseline_body_sha256']) == approval['before_body_sha256'],
                    'body drift or stale draft approval; hold without restoration')
            body_shape(approval, body, draft, record)
            prevalidate(draft, record, op, lifetime, deps)
            name = 'draft-'+approval['id']+'.md'
            save_snapshot(op/name, data)
            # Fresh context after validator subprocesses, immediately before journal/effect.
            _, fresh = preflight(m, lifetime, dependency_file(deps['read']))
            require(fresh == body, 'body drift before body edit; hold')
            edit = dict(approval=approval, snapshot=name, pre_body=body, command_id=uuid.uuid4().hex, state='unknown')
            record.setdefault('body_edits', []).append(edit)
            record.update(dependencies=deps, state='held')
            atomic_json(op/'operation.json', record)
            snapshot_bytes(dict(path=str(op/name), sha256=approval['draft']['sha256']), True)
            interrupted = False
            try:
                t = m['target']
                result = lifetime.run([dependency_file(deps['read']), t['kind'], 'edit', str(t['number']),
                                       '--repo', t['repository'], '--body-file', str(op/name)],
                                      command_env(), 'body-edit', timeout=120, command_id=edit['command_id'])
                edit['command_outcome'] = {k: result[k] for k in ('returncode', 'reason')}
                interrupted = result['reason'] != 'exited'
            except (Refusal, KeyboardInterrupt):
                interrupted = True
            lifetime.settled()
            _, after = preflight(m, lifetime, dependency_file(deps['read']), check_source=False)
            landed = reconcile_body(edit, after, op)
            if landed:
                record['expected_body_sha256'] = sha(after)
            atomic_json(op/'operation.json', record)
            require(landed, 'unknown body edit outcome; no blind replay or old-body restoration')
            hygiene(after, record, op, lifetime, deps)
            _, fresh = preflight(m, lifetime, dependency_file(deps['read']))
            require(fresh == after, 'body drift after body edit; hold')
            require(not interrupted, 'body edit reconciled after cancellation; owner review required')
            record['state'] = 'prepared' if approval['purpose'] == 'repair' else 'published-confirmed'
            record.pop('hold', None)
            atomic_json(op/'operation.json', record)
            return record
        except (Refusal, OSError, ValueError, KeyboardInterrupt) as exc:
            record['state'] = 'held'
            record['hold'] = str(exc) if isinstance(exc, Refusal) else 'body edit input/state failure; reconcile before continuing'
            atomic_json(op/'operation.json', record)
            raise Refusal(record['hold']) from None


def review_binding(review, record):
    exact(review, 'schema home task operation target actor source authority body_sha256 reviewer independent provenance media', 'completion review')
    approved_context(review, record)
    settled_body(record)
    finals = [e for e in record.get('body_edits', []) if e['approval']['purpose'] == 'final']
    require(finals and all(i['state'] == 'published-confirmed' for i in record['items']),
            'completion requires final approved body and fully confirmed uploads')
    require(type(review['schema']) is int and review['schema'] == 1 and review['independent'] is True and
            text(review['reviewer']) and review['reviewer'] != finals[-1]['approval']['authority']['approved_by'] and
            text(review['provenance']) and review['body_sha256'] == record['expected_body_sha256'],
            'independent review must bind the final body and independent reviewer/provenance')
    require(isinstance(review['media'], list) and len(review['media']) == len(record['items']),
            'independent review must cover every confirmed item')
    for evidence, item, approved in zip(review['media'], record['items'], record['manifest']['files']):
        exact(evidence, 'ordinal sha256 url label rendered playback artifact', 'media review')
        require(type(evidence['ordinal']) is int and evidence['ordinal'] == item['ordinal'] and
                evidence['sha256'] == approved['sha256'] and evidence['url'] == item['attempts'][-1]['url'] and
                evidence['label'] == approved['label'] and evidence['rendered'] is True and
                evidence['playback'] is (approved['media_type'] == 'video/mp4'),
                'independent media review binding/rendering/playback mismatch')
        exact(evidence['artifact'], 'path sha256', 'review artifact')


def validate_completion(record, op):
    review = record['completion_review']
    review_binding(review, record)
    prefix = record.get('completion_snapshot_prefix', 'review-')
    require(prefix in ('review-', review_prefix(review)), 'invalid sealed review snapshot binding')
    for item in review['media']:
        snapshot_bytes(dict(path=str(op/(prefix+str(item['ordinal']))), sha256=item['artifact']['sha256']), True)


def review_prefix(review):
    return 'review-'+sha(json.dumps(review, sort_keys=True, ensure_ascii=False, separators=(',', ':')))+'-'


def complete(args):
    deps = dependencies(args.dependencies)
    with operation(args) as (record, op, lifetime):
        active_owner(record)
        bind_dependencies(record, op, deps)
        review = read_json(physical(args.review))
        review_binding(review, record)
        if record.get('completion_review'):
            require(record['completion_review'] == review, 'completion review is sealed; inspect retained evidence')
        prefix = record.get('completion_snapshot_prefix', 'review-') if record.get('completion_review') else review_prefix(review)
        # Declined candidates are retained without sealing their ordinal slots.
        # The identity includes final-body and artifact bindings, so fresh review
        # can never accidentally inherit evidence for an earlier placement.
        save_snapshot(op/(review_prefix(review)+'candidate.json'),
                      (json.dumps(review, sort_keys=True)+'\n').encode())
        for item in review['media']:
            snapshot_bytes(item['artifact'])
        for item in review['media']:
            save_snapshot(op/(prefix+str(item['ordinal'])), snapshot_bytes(item['artifact']))
        _, body = preflight(record['manifest'], lifetime, dependency_file(deps['read']))
        require(sha(body) == review['body_sha256'], 'body drift before terminal handoff; claim retained')
        hygiene(body, record, op, lifetime, deps)
        _, fresh = preflight(record['manifest'], lifetime, dependency_file(deps['read']))
        require(fresh == body, 'body drift during terminal handoff; claim retained')
        record.update(state='delivery-complete', completion_review=review, rendered_qa='independent-review-recorded')
        if prefix != 'review-':
            record['completion_snapshot_prefix'] = prefix
        record.pop('hold', None)
        atomic_json(op/'operation.json', record)
        return record


def publish(args):
    deps = dependencies(args.dependencies)
    with operation(args) as (record, op, lifetime):
        m = record['manifest']
        active_owner(record)
        require(record['state'] != 'delivery-complete', 'delivery-complete operation is sealed; inspect retained receipts')
        bind_dependencies(record, op, deps)
        settled_body(record)
        record['rendered_qa'] = 'pending-independent-review'
        disposition_path = args.disposition
        try:
            # A restart reconciles the last attempted item before considering
            # any new upload or a changed PR head. GETs remain target-bound.
            _, body = preflight(m, lifetime, dependency_file(deps['read']), check_source=False)
            for item, approved in zip(record['items'], m['files']):
                if item['state'] == 'unknown' and native_started(op, item) and reconcile_item(body, item, approved):
                    record['expected_body_sha256'] = sha(body)
                    atomic_json(op/'operation.json', record)
            expected = record.get('expected_body_sha256', record['baseline_body_sha256'])
            require(sha(body) == expected, 'body drift or unknown append; hold without restoring earlier prose')
            prevalidate(body, record, op, lifetime, deps)
            if all(i['state'] == 'published-confirmed' for i in record['items']):
                require(not disposition_path, 'disposition has no unresolved item; refuse reuse')
            else:
                qualify_native(record, lifetime, deps)
            for item, approved in zip(record['items'], m['files']):
                if item['state'] == 'published-confirmed':
                    continue
                retry = disposition(disposition_path, record, item) if item['state'] == 'unknown' else None
                require(not disposition_path or retry is not None, 'disposition does not bind an unresolved item')
                _, body = preflight(m, lifetime, dependency_file(deps['read']))
                require(sha(body) == record.get('expected_body_sha256', record['baseline_body_sha256']),
                        'body drift before upload; hold without restoring earlier prose')
                verify_snapshots(record, op)
                prevalidate(body, record, op, lifetime, deps)
                native = dependency_file(deps['native'])
                # Validation can be slow. Refuse any drift observed after it,
                # before consuming retry authority or journaling a new attempt.
                _, fresh = preflight(m, lifetime, dependency_file(deps['read']))
                require(fresh == body, 'body drift during validation; hold before upload')
                attempt_id = uuid.uuid4().hex
                attempt = dict(id=attempt_id, command_id=attempt_id, state='unknown',
                               pre_body=body, pre_body_sha256=sha(body))
                if retry:
                    attempt['disposition'] = retry
                    record.setdefault('consumed_dispositions', []).append(retry['id'])
                    disposition_path = None
                item.setdefault('attempts', []).append(attempt)
                item['state'] = 'unknown'
                record['state'] = 'publishing'
                record['dependencies'] = deps
                atomic_json(op/'operation.json', record)
                attachment = str(op/item['snapshot'])
                if approved['media_type'].startswith('image/'):
                    attachment += '#' + approved['label']
                target = m['target']
                selector = 'https://github.com/' + target['repository'] + ('/pull/' if target['kind'] == 'pr' else '/issues/') + str(target['number'])
                interrupted = False
                try:
                    result = lifetime.run([native, target['kind'], 'edit', selector, '--repo',
                                           'github.com/' + target['repository'], '--attach', attachment],
                                          command_env(), 'attach', timeout=120, command_id=attempt_id)
                    attempt['command_outcome'] = {k: result[k] for k in ('returncode', 'reason')}
                    interrupted = result['reason'] != 'exited'
                except (Refusal, KeyboardInterrupt):
                    interrupted = True
                # A stopped process and nonzero status prove neither that an
                # asset was absent nor that it landed. Readback decides first.
                lifetime.settled()
                _, after = preflight(m, lifetime, dependency_file(deps['read']), check_source=False)
                landed = native_started(op, item) and reconcile_item(after, item, approved)
                if landed:
                    record['expected_body_sha256'] = sha(after)
                atomic_json(op/'operation.json', record)
                hygiene(after, record, op, lifetime, deps)
                require(landed, 'unknown upload outcome; unchanged body is not safe retry authority')
                require(not interrupted, 'publication reconciled after cancellation; remaining items held')
            # Confirmation is separate from fresh source validity and R13 QA.
            _, fresh = preflight(m, lifetime, dependency_file(deps['read']))
            require(sha(fresh) == record.get('expected_body_sha256', record['baseline_body_sha256']),
                    'body drift during final readback; hold without restoration')
            hygiene(fresh, record, op, lifetime, deps)
            record['state'] = 'published-confirmed'
            record.pop('hold', None)
            atomic_json(op/'operation.json', record)
            return record
        except (Refusal, OSError, ValueError, KeyboardInterrupt) as exc:
            record['state'] = 'held'
            record['hold'] = str(exc) if isinstance(exc, Refusal) else 'input/state write or cancellation failure; reconcile before continuing'
            atomic_json(op/'operation.json', record)
            raise Refusal(record['hold']) from None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare')
    prep.add_argument('--resume', action='store_true')
    prep.add_argument('--manifest', required=True)
    prep.add_argument('files', nargs='+')
    show = commands.add_parser('inspect')
    show.add_argument('--operation', required=True)
    pub = commands.add_parser('publish')
    pub.add_argument('--operation', required=True)
    pub.add_argument('--dependencies', required=True)
    pub.add_argument('--disposition')
    for name, flag in [('edit-body', '--approval'), ('complete', '--review')]:
        sub = commands.add_parser(name)
        sub.add_argument('--operation', required=True)
        sub.add_argument('--dependencies', required=True)
        sub.add_argument(flag, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    def interrupted(signum, frame):
        # InterruptedError is retried by selectors, so use a distinct exception.
        raise Refusal('operation interrupted; inspect durable state before continuing')
    signal.signal(signal.SIGTERM, interrupted)
    try:
        result = {'prepare': prepare, 'inspect': inspect, 'publish': publish,
                  'edit-body': edit_body, 'complete': complete}[args.command](args)
        print(json.dumps(result, sort_keys=True))
    except Refusal as exc:
        print('fm-github-media: '+str(exc), file=sys.stderr)
        return 75 if str(exc).startswith('busy:') else 1
    except (OSError, ValueError, KeyError, TypeError, KeyboardInterrupt):
        print('fm-github-media: unreadable/invalid input or state; inspect ownership and records, never take over', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
