#!/usr/bin/env bash
# Option A - deploy fork main @ aaddfe7 to john using the host's existing release convention.
# NOT RUN BY THIS TASK: staged for the captain's go-ahead (see RECORD.md, "Decision").
# Reversible: rerun with the rollback release name. Nothing here forces, stashes, discards, or
# touches /opt/sparkDash, its 18 dirty files, its stash, or the feat/llm-proxy-auth branch.
#
# DRY RUN BY DEFAULT. Set APPLY=1 to execute on john.
#   bash option-A-release-swap.sh                       # print what would happen
#   APPLY=1 bash option-A-release-swap.sh               # cut the release, do not touch the unit
#   APPLY=1 SWAP_UNIT=1 bash option-A-release-swap.sh   # also repoint sparkdash-boot.service
set -euo pipefail

RELEASE="${RELEASE:-mac-node-$(date +%Y%m%d)}"
JOHN="${JOHN:-john}"
FROM_REF="${FROM_REF:-origin/main}"                       # == aaddfe7 (Mac-node merge)
BASE_RELEASE="${BASE_RELEASE:-mama-live-rates-20260930}"  # currently serving = rollback target
UNIT="${UNIT:-sparkdash-boot.service}"
APPLY="${APPLY:-0}"
SWAP_UNIT="${SWAP_UNIT:-0}"

echo "release=${RELEASE} from=${FROM_REF} rollback=${BASE_RELEASE} unit=${UNIT} apply=${APPLY} swap_unit=${SWAP_UNIT}"

# Guard: the ref we deploy must actually contain the Mac-node merge. Note that ssh rejoins its
# command arguments on the remote side, so the ref is interpolated rather than passed positionally.
if ! ssh "$JOHN" "cd /opt/sparkDash && git merge-base --is-ancestor aaddfe7 ${FROM_REF}"; then
  echo "$FROM_REF does not contain aaddfe7 - refusing to deploy" >&2
  exit 1
fi

if [[ "$APPLY" != "1" ]]; then
  echo "would: cp -a $BASE_RELEASE -> $RELEASE, git checkout --detach $FROM_REF inside it"
  echo "would: keep the untracked docker-compose.live.yml (container_name sparkDash-opencode-e2e,"
  echo "       ports 100.120.26.16:5556:5556, ~/.ssh bind) so sparkdash-boot's expectations hold"
  if [[ "$SWAP_UNIT" == "1" ]]; then
    echo "would: keep $UNIT.bak-<ts>, sed the single ExecStart path $BASE_RELEASE -> $RELEASE,"
    echo "       systemctl daemon-reload && systemctl restart $UNIT"
  else
    echo "would NOT touch the systemd unit (release cut only; verify, then swap separately)"
  fi
  echo "dry run complete (nothing changed)"
  exit 0
fi

ssh "$JOHN" bash -s <<REMOTE
set -eu
RELEASE="$RELEASE"
BASE_RELEASE="$BASE_RELEASE"
FROM_REF="$FROM_REF"
SWAP_UNIT="$SWAP_UNIT"
UNIT="$UNIT"
root=/home/kesslerio/sparkDash-releases
test -d "\$root/\$BASE_RELEASE" || { echo "missing base release" >&2; exit 1; }
if [ ! -e "\$root/\$RELEASE" ]; then
  cp -a "\$root/\$BASE_RELEASE" "\$root/\$RELEASE"   # preserves the untracked compose.live.yml
  ( cd "\$root/\$RELEASE" && git fetch origin main && git checkout --detach "\$FROM_REF" )
fi
cd "\$root/\$RELEASE"
git log --oneline -1
git merge-base --is-ancestor aaddfe7 HEAD && echo "release contains aaddfe7"
[ -f docker-compose.live.yml ] || { echo "release has no docker-compose.live.yml" >&2; exit 1; }
docker compose -f docker-compose.live.yml config -q && echo "compose file valid"
if [ "\$SWAP_UNIT" = "1" ]; then
  unit="/etc/systemd/system/\$UNIT"
  sudo cp -a "\$unit" "\$unit.bak-\$(date +%Y%m%d%H%M%S)"
  sudo sed -i "s|sparkDash-releases/\$BASE_RELEASE|sparkDash-releases/\$RELEASE|g" "\$unit"
  sudo systemctl daemon-reload
  sudo systemctl restart "\$UNIT"
  sleep 5
  systemctl is-active "\$UNIT" || true
fi
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -i sparkdash || true
curl -sS -m 8 http://100.120.26.16:5556/api/sparks | head -c 200; echo
REMOTE

echo "applied; rollback = point $UNIT back to $BASE_RELEASE (unit .bak kept beside the unit)"
