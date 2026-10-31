#!/bin/sh
# Report phone-lockbox worktrees and build caches. Read-only: prints sizes and
# suggested cleanup commands; it never deletes anything itself.
set -eu
REPO=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
CACHE=/Users/nishantroy/code/.build-cache/phone-lockbox

echo "== Worktrees (size, commits not in r5-relay, uncommitted files)"
git -C "$REPO" worktree list --porcelain | awk '/^worktree/{w=$2} /^branch/{print w" "$2} /^detached/{print w" (detached)"}' |
while read -r w b; do
  [ "$w" = "$REPO" ] && continue
  if [ ! -d "$w" ]; then echo "missing  $w  -> git worktree prune"; continue; fi
  br=${b#refs/heads/}
  un=$(git -C "$REPO" rev-list --count "r5-relay..$br" 2>/dev/null || echo "?")
  dirty=$(git -C "$w" status --porcelain | wc -l | tr -d ' ')
  printf '%6s  unmerged=%s dirty=%s  %s  %s\n' "$(du -sh "$w" | cut -f1)" "$un" "$dirty" "$w" "$br"
done

echo "== Build cache folders under $CACHE"
if [ -d "$CACHE" ]; then
  for d in "$CACHE"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if git -C "$REPO" worktree list | grep -q "/$name "; then state=active; else state="ORPHANED -> rm -rf $d"; fi
    printf '%6s  %s  %s\n' "$(du -sh "$d" | cut -f1)" "$name" "$state"
  done
else
  echo "(none yet)"
fi
echo "Remove a merged worktree: git worktree remove --force <path>   (branch is kept)"
