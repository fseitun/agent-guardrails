#!/usr/bin/env bash
# Remove git worktrees whose work is finished. Claude Code only cleans up worktrees
# it made itself; worktrees that agents (or you) add by hand with `git worktree add`
# pile up, and nothing else ever removes them.
#
#   reap-worktrees.sh REPO...                  dry run: print a verdict per worktree
#   reap-worktrees.sh --apply REPO...          remove the REAP ones (never --force)
#   reap-worktrees.sh --apply --throttle 6 REPO...   skip if it ran in the last 6 hours
#
# REPO is the path of a main checkout whose origin is on GitHub (needs `gh` signed in).
# Linked worktrees of that repo are checked; the main checkout itself never is.
#
# A worktree is REAP only when ALL of these hold:
#   - its branch's PR is MERGED and HEAD is the PR's head commit or an ancestor of it,
#     or HEAD is detached on a commit already in origin/<default branch>. Squash merges
#     make `git branch --merged` useless, so the PR is the authority.
#   - no modified or untracked files, and it is not locked
#   - no live process has its cwd inside it
#   - its reflog has been quiet for IDLE_HOURS (default 24): a session can own a
#     worktree without its cwd being inside it
set -u

IDLE_HOURS="${IDLE_HOURS:-24}"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/reap-worktrees"
APPLY=0
THROTTLE=0
REPOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --throttle) THROTTLE="$2"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) REPOS+=("$1") ;;
  esac
  shift
done
[ "${#REPOS[@]}" -gt 0 ] || { echo "usage: reap-worktrees.sh [--apply] [--throttle H] REPO..." >&2; exit 2; }

mkdir -p "$LOG_DIR"
exec 9>"$LOG_DIR/.lock"
flock -n 9 || exit 0
if [ "$THROTTLE" -gt 0 ] && [ -e "$LOG_DIR/.last-run" ]; then
  age=$(( ($(date +%s) - $(stat -c %Y "$LOG_DIR/.last-run")) / 3600 ))
  [ "$age" -lt "$THROTTLE" ] && exit 0
fi
[ "$APPLY" = 1 ] && touch "$LOG_DIR/.last-run"

now=$(date +%s)
live=$(for p in /proc/[0-9]*; do readlink "$p/cwd" 2>/dev/null; done | sort -u)
removed=0

for repo in "${REPOS[@]}"; do
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || { echo "skip $repo: not a git checkout" >&2; continue; }
  git -C "$top" fetch -q --prune origin 2>/dev/null || { echo "skip $top: fetch failed" >&2; continue; }
  base=$(git -C "$top" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); base=${base#origin/}
  [ -n "$base" ] || base=main
  slug=$( (cd "$top" && gh repo view --json nameWithOwner -q .nameWithOwner) 2>/dev/null) || { echo "skip $top: not a GitHub repo gh can read" >&2; continue; }
  prs=$(gh pr list -R "$slug" --state all --limit 1000 --json state,number,headRefName,headRefOid 2>/dev/null) || continue

  path=""; head=""; branch=detached; locked=no
  verdict() {
    [ -n "$path" ] && [ "$path" != "$top" ] && [ -d "$path" ] || return 0
    local why="" st num oid gd m
    if [ "$branch" = detached ]; then
      git -C "$top" merge-base --is-ancestor "$head" "origin/$base" 2>/dev/null || why="detached, not in $base"
    else
      st=$(jq -r --arg b "$branch" '[.[] | select(.headRefName == $b)] | sort_by(.number) | last
        | if . == null then "none" else "\(.state) \(.number) \(.headRefOid)" end' <<<"$prs")
      read -r st num oid <<<"$st"
      if [ "$st" != MERGED ]; then
        why="PR $st"
      elif [ "$oid" != "$head" ]; then
        # Behind the merged head is fine; ahead of it means commits the merge never saw.
        git -C "$top" fetch -q origin "pull/$num/head" 2>/dev/null
        git -C "$top" merge-base --is-ancestor "$head" "$oid" 2>/dev/null || why="commits the merge never saw"
      fi
    fi
    [ -z "$why" ] && [ "$locked" = yes ] && why="locked"
    [ -z "$why" ] && [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && why="uncommitted files"
    [ -z "$why" ] && grep -qE "^$path(/|$)" <<<"$live" && why="live process inside"
    if [ -z "$why" ]; then
      gd=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)
      m=$(stat -c %Y "$gd/logs/HEAD" 2>/dev/null || stat -c %Y "$gd/HEAD" 2>/dev/null || echo "$now")
      [ $(( (now - m) / 3600 )) -lt "$IDLE_HOURS" ] && why="active in the last ${IDLE_HOURS}h"
    fi
    if [ -n "$why" ]; then
      [ "$APPLY" = 1 ] || printf 'KEEP  %-60s %s\n' "$path" "$why"
      return 0
    fi
    if [ "$APPLY" = 0 ]; then
      printf 'REAP  %-60s %s\n' "$path" "$branch"
      return 0
    fi
    local note="git refused"
    if git -C "$top" worktree remove "$path" 2>/dev/null; then
      note=removed
      if [ "$branch" != detached ] && [ "$(git -C "$top" rev-parse "refs/heads/$branch" 2>/dev/null)" = "$head" ]; then
        git -C "$top" branch -D "$branch" >/dev/null 2>&1 && note="removed, branch deleted"
      fi
      removed=$((removed + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$slug" "$branch" "$path" "$note" >>"$LOG_DIR/$(date +%Y-%m).tsv"
  }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) verdict; path=${line#worktree }; head=""; branch=detached; locked=no ;;
      "HEAD "*) head=${line#HEAD } ;;
      "branch "*) branch=${line#branch refs/heads/} ;;
      locked*) locked=yes ;;
    esac
  done < <(git -C "$top" worktree list --porcelain)
  verdict
  [ "$APPLY" = 1 ] && git -C "$top" worktree prune 2>/dev/null
done

[ "$APPLY" = 1 ] && echo "reap-worktrees: removed $removed"
exit 0
