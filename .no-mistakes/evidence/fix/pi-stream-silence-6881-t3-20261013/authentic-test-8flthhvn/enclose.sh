#!/usr/bin/env bash
set -euo pipefail
R="$EVID/root"
common=/home/art/.no-mistakes/repos/9f75ec418609.git
gd="$common/worktrees/01M4SVYM577RRP7SBS7M9Y8NFN"
mount --make-rprivate /
mount -t tmpfs -o uid=0,gid=0,nosuid,nodev tmpfs "$R"
bind_ro() {
 local src=$1 dst="$R$1"
 if [ -d "$src" ]; then mkdir -p "$dst"; else mkdir -p "$(dirname "$dst")"; touch "$dst"; fi
 mount --bind "$src" "$dst"
 mount -o remount,bind,ro,nosuid "$dst"
}
for x in /nix/store /bin /usr/bin /lib64 /run/current-system/sw "$WORK" /home/art/.npm-packages/lib/node_modules/@earendil-works/pi-coding-agent; do bind_ro "$x"; done
# Only assigned worktree metadata; no sibling directories or gate configuration.
for x in "$common/objects" "$common/config" "$gd/HEAD" "$gd/index" "$gd/commondir" "$gd/gitdir" "$gd/config.worktree" "$gd/refs"; do
 [ ! -e "$x" ] || bind_ro "$x"
done
mkdir -p "$R$common/refs" "$R$EVID" "$R"/{proc,dev,dev/pts,tmp,synthetic-home,tools/bin,etc,out}
for f in expected.json preflight.py run.sh cli.sh; do cp "$EVID/$f" "$R/$f"; done
mount --bind "$EVID" "$R/out"
mount -t proc -o nosuid,nodev,noexec proc "$R/proc"
mount -t tmpfs -o mode=755,uid=0,gid=0,nosuid tmpfs "$R/dev"
mkdir -p "$R/dev/pts"
mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "$R/dev/pts"
ln -s pts/ptmx "$R/dev/ptmx"
for x in null zero random urandom tty; do touch "$R/dev/$x"; mount --bind "/dev/$x" "$R/dev/$x"; mount -o remount,bind,dev "$R/dev/$x"; done
ln -s /proc/self/fd "$R/dev/fd"
for fd in 0 1 2; do ln -s "/proc/self/fd/$fd" "$R/dev/$(case $fd in 0) echo stdin;; 1) echo stdout;; 2) echo stderr;; esac)"; done
mount -t tmpfs -o uid=0,gid=0,nosuid,nodev tmpfs "$R/tmp"
mount -t tmpfs -o uid=0,gid=0,nosuid,nodev tmpfs "$R/synthetic-home"
mkdir -p "$R/tmp"/{runtime,tmux} "$R/synthetic-home"/{config,cache,state,pi}
chmod 1777 "$R/tmp"
chown -R 0:0 "$R/synthetic-home" "$R/tmp/runtime" "$R/tmp/tmux"
chmod 700 "$R/tmp/runtime" "$R/tmp/tmux"
printf 'root:x:0:0:Test:/synthetic-home:/bin/bash\nart:x:0:0:Test:/synthetic-home:/bin/bash\n' > "$R/etc/passwd"
printf 'root:x:0:\n' > "$R/etc/group"
printf '127.0.0.1 localhost\n' > "$R/etc/hosts"
ln -s /home/art/.npm-packages/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js "$R/tools/bin/pi"
cp "$EVID/node" "$R/tools/bin/node"
chmod +x "$R/tools/bin/node"
ip link set lo up
mount -o remount,bind,ro "$R"
cd /
exec chroot "$R" /run/current-system/sw/bin/setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all --no-new-privs /bin/bash /run.sh "$@"
