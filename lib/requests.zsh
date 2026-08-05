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
      ( command tsh request ls -f json > "$f.tmp" 2>/dev/null &&
        command mv "$f.tmp" "$f" ) &>/dev/null &!
    fi
  else
    command mkdir -p "$dir" 2>/dev/null
    : > "$f"
    ( command tsh request ls -f json > "$f.tmp" 2>/dev/null &&
      command mv "$f.tmp" "$f" ) &>/dev/null &!
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
