#!/usr/bin/env bash
set -euo pipefail
WORK=/home/art/.no-mistakes/worktrees/9f75ec418609/01M4SVYM577RRP7SBS7M9Y8NFN
EVID=/home/art/.no-mistakes/evidence/01M4SVYM577RRP7SBS7M9Y8NFN
R="$WORK/.test-enclosure/root"
PI=/home/art/.npm-packages/lib/node_modules/@earendil-works/pi-coding-agent
mount --make-rprivate /
for p in /nix/store /bin /usr/bin /run/current-system/sw "$WORK" "$EVID" "$PI"; do
  mkdir -p "$R$p"
  mount --bind "$p" "$R$p"
  case "$p" in "$WORK"|"$EVID") ;; *) mount -o remount,bind,ro "$R$p" ;; esac
done
mkdir -p "$R"/{proc,dev,tmp,synthetic-home,tools/bin,etc}
# Supply disposable metadata without exposing or reading the gate bare repo.
mkdir -p "$R/fixture.git"
printf 'gitdir: /fixture.git\n' > "$R/worktree-dotgit"
mount --bind "$R/worktree-dotgit" "$R$WORK/.git"
mount -t proc proc "$R/proc"
mount -t tmpfs tmpfs "$R/tmp"
for p in null zero random urandom; do touch "$R/dev/$p"; mount --bind "/dev/$p" "$R/dev/$p"; done
ln -sfn /proc/self/fd "$R/dev/fd"
ln -sfn /proc/self/fd/0 "$R/dev/stdin"
ln -sfn /proc/self/fd/1 "$R/dev/stdout"
ln -sfn /proc/self/fd/2 "$R/dev/stderr"
ln -sfn "$PI/dist/bundle/cli.js" "$R/tools/bin/pi"
printf 'root:x:0:0:Test:/synthetic-home:/bin/bash\n' > "$R/etc/passwd"
printf 'root:x:0:\n' > "$R/etc/group"
cp "$EVID/inside.sh" "$R/inside-$1.sh"
exec chroot "$R" /usr/bin/env -i HOME=/synthetic-home PATH=/tools/bin:/run/current-system/sw/bin:/bin:/usr/bin TMPDIR=/tmp XDG_CONFIG_HOME=/synthetic-home/config XDG_CACHE_HOME=/synthetic-home/cache XDG_RUNTIME_DIR=/tmp/runtime WORK="$WORK" EVID="$EVID" /bin/bash "/inside-$1.sh" "$@"
