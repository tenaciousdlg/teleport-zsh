# Reviewer badge — pending access requests visible from the prompt:
#
#   ⛨ acme ▸ chris ✉1 7h32m +beta     ← someone's waiting on a review
#
# Prompt-safe by construction: the segment only ever reads a cache file
# (~/.cache/tsh-zsh/<profile>/requests.json). When the cache is older than
# TELEPORT_ZSH_REQ_TTL (default 60s) a background `tsh request ls` refresh
# is spawned — the network never runs on the prompt path, so a slow or dead
# cluster can't freeze your shell; the badge is at most one prompt late.
# Counting only PENDING requests (state 1 / "PENDING") keeps it exposure:
# a request needing action now, not request history.
#
# The tsh wrapper (complete.zsh) drops this cache after login/logout/request,
# so approvals and drops reflect on the next prompt. TELEPORT_ZSH_REQUESTS=off
# disables the badge entirely.

zmodload zsh/stat zsh/datetime 2>/dev/null

typeset -gA _tp_pending_memo
typeset -g _tp_stall_warned

# Spawn one cache refresh with a watchdog. A wedged tsh (classic cause: a
# wedged system ssh-agent) would otherwise hang forever and accumulate
# one zombie per refresh window — instead the attempt is killed after
# TELEPORT_ZSH_REQ_TIMEOUT (default 10s) and the miss is recorded in
# <dir>/refresh-stalled so the stall can be surfaced once (see
# _teleport_stall_warn), rather than the badge silently going stale.
# A successful refresh clears the marker.
_teleport_refresh_requests() {  # $1 = cache file, $2 = cache dir
  (
    command tsh request ls -f json > "$1.tmp" 2>/dev/null &
    local tpid=$! wpid rc
    ( command sleep "${TELEPORT_ZSH_REQ_TIMEOUT:-10}"; kill -9 $tpid 2>/dev/null ) &
    wpid=$!
    wait $tpid 2>/dev/null; rc=$?
    kill $wpid 2>/dev/null
    if (( rc == 0 )); then
      command mv "$1.tmp" "$1"
      command rm -f "$2/refresh-stalled"
    else
      command rm -f "$1.tmp"
      # >=128 means the watchdog killed it (a stall); anything else is a
      # normal failure (logged out, no permission) and not worth alarms.
      (( rc >= 128 )) && print -n 1 >> "$2/refresh-stalled" 2>/dev/null
    fi
  ) &>/dev/null &!
}

_teleport_pending_count() {  # $1 = profile → sets $_tp_pendingreq
  typeset -g _tp_pendingreq=0
  [[ $TELEPORT_ZSH_REQUESTS == off ]] && return 0
  local prof=$1
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/tsh-zsh/$prof
  local f=$dir/requests.json ttl=${TELEPORT_ZSH_REQ_TTL:-60} mt
  if [[ -e $f ]]; then
    zstat -A mt +mtime -- "$f" 2>/dev/null
    if (( EPOCHSECONDS - ${mt:-0} > ttl )); then
      command touch "$f" 2>/dev/null   # claim the refresh slot: no spawn storms
      _teleport_refresh_requests "$f" "$dir"
    fi
  else
    command mkdir -p "$dir" 2>/dev/null
    : > "$f"
    _teleport_refresh_requests "$f" "$dir"
  fi
  [[ -s $f ]] || return 0
  zstat -A mt +mtime -- "$f" 2>/dev/null
  local key="$prof:$mt"
  if [[ -z ${_tp_pending_memo[$key]} ]]; then
    local n
    n=$(command python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(0); raise SystemExit
n = 0
for r in (d if isinstance(d, list) else []):
    s = (r.get("spec") or {}).get("state", r.get("state"))
    if s == 1 or str(s).upper() == "PENDING":
        n += 1
print(n)' "$f" 2>/dev/null)
    _tp_pending_memo[$key]=${n:-0}
  fi
  _tp_pendingreq=${_tp_pending_memo[$key]}
}

# One-shot notice when refreshes keep getting killed by the watchdog (two or
# more consecutive stalls). Called from the precmd hook in prompt.zsh — safe
# to print there; never print from the segment itself. The marker persists
# until a refresh succeeds, so each new shell warns once while the condition
# lasts. `tunwedge` (lib/doctor.zsh) clears the usual cause.
_teleport_stall_warn() {
  [[ -n $_tp_stall_warned ]] && return 0
  local prof=$1 sz
  local marker=${XDG_CACHE_HOME:-$HOME/.cache}/tsh-zsh/$prof/refresh-stalled
  [[ -s $marker ]] || return 0
  zstat -A sz +size -- "$marker" 2>/dev/null
  if (( ${sz:-0} >= 2 )); then
    _tp_stall_warned=1
    print -P "%F{3}⚠ teleport-zsh: request refresh keeps timing out — tsh looks wedged (often a wedged system ssh-agent). Try: tunwedge%f"
  fi
}
