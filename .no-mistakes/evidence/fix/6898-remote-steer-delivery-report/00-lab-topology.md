# Lab topology: real loopback SSH hop for fm-send remote-steer delivery

Date: 2026-11-09T00:51:25Z
Product under test: {run-worktree} (branch fix/6898-remote-steer-delivery-report, HEAD 2342080f0)

The sending CLI and the far-side control-plane leg are the real product
scripts. The transport is a real OpenSSH client talking to a real sshd on
127.0.0.1 (lab host key, lab authorized_keys, real public-key auth). The only
replaced piece is fm-remote-entrypoint.sh's job-staging step, which writes
under the account home; a lab launcher decodes the same protocol envelope and
execs the same real remote command with the same env contract.

## ssh client config (lab)
Host rsm-lab
  HostName 127.0.0.1
  Port 20491
  User art
  IdentityFile /tmp/fmlab/lab1/ckey
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking no
  UserKnownHostsFile /tmp/fmlab/lab1/known_hosts
  LogLevel ERROR

## sshd config (lab)
Port 20491
ListenAddress 127.0.0.1
HostKey /tmp/fmlab/lab1/hostkey
PidFile /tmp/fmlab/lab1/sshd.pid
AuthorizedKeysFile /tmp/fmlab/lab1/authorized_keys
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitUserEnvironment no
LogLevel VERBOSE
ForceCommand /tmp/fmlab/lab1/rbin/launcher.sh

## remote-side launcher (lab stand-in for fm-remote-entrypoint.sh job staging)
#!/usr/bin/env bash
# Lab stand-in for fm-remote-entrypoint.sh's job-staging step: decode the same
# protocol envelope and exec the real remote command with the same environment
# contract (stdout/stderr separate, stdin forwarded, exit status preserved).
set -u
LAB=/tmp/fmlab/lab1
cmdstr=${SSH_ORIGINAL_COMMAND:-}
[ -n "$cmdstr" ] || { echo "launcher: no original command" >&2; exit 64; }
# shellcheck disable=SC2086
set -- $cmdstr
[ "$#" -eq 5 ] || { echo "launcher: unexpected envelope arity $#" >&2; exit 64; }
[ "$1" = fm-remote-entrypoint.sh ] || { echo "launcher: unexpected entrypoint $1" >&2; exit 64; }
[ "$2" = 1 ] || { echo "launcher: bad protocol $2" >&2; exit 64; }
root=$(printf '%s' "$3" | base64 -d)
home=$(printf '%s' "$4" | base64 -d)
tmp=$(mktemp "$LAB/argv.XXXXXX")
printf '%s' "$5" | base64 -d > "$tmp"
args=()
while IFS= read -r -d '' a; do args+=("$a"); done < "$tmp"
rm -f "$tmp"
[ "${#args[@]}" -ge 1 ] || { echo "launcher: empty argv" >&2; exit 64; }
cmd=${args[0]}
exec env -i \
  PATH="$LAB/rpath:/run/current-system/sw/bin:/usr/bin:/bin" \
  HOME="$LAB/remote-account-home" \
  LANG=C.UTF-8 \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
  "$root/bin/$cmd" "${args[@]:1}"

## proof the hop is a real ssh session (sshd log)
Accepted publickey for art from 127.0.0.1 port 49164 ssh2: ED25519 SHA256:q+AvDEt1TTi12Levj1GgJJnSeJTurbQTM5FMCtLYPOM
Starting session: forced-command (config) '/tmp/fmlab/lab1/rbin/launcher.sh' for art from 127.0.0.1 port 49164 id 0
Accepted publickey for art from 127.0.0.1 port 58888 ssh2: ED25519 SHA256:q+AvDEt1TTi12Levj1GgJJnSeJTurbQTM5FMCtLYPOM
Starting session: forced-command (config) '/tmp/fmlab/lab1/rbin/launcher.sh' for art from 127.0.0.1 port 58888 id 0
Accepted publickey for art from 127.0.0.1 port 47570 ssh2: ED25519 SHA256:q+AvDEt1TTi12Levj1GgJJnSeJTurbQTM5FMCtLYPOM
Starting session: forced-command (config) '/tmp/fmlab/lab1/rbin/launcher.sh' for art from 127.0.0.1 port 47570 id 0
Accepted publickey for art from 127.0.0.1 port 47582 ssh2: ED25519 SHA256:q+AvDEt1TTi12Levj1GgJJnSeJTurbQTM5FMCtLYPOM
Starting session: forced-command (config) '/tmp/fmlab/lab1/rbin/launcher.sh' for art from 127.0.0.1 port 47582 id 0
