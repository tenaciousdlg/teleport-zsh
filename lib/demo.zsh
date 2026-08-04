# Demo-beat helpers — the "join live, then lock" moment without fumbling
# tctl syntax on stage:
#
#   tlock bob          # lock bob out (default --ttl=5m, self-expiring)
#   tlock bob 30m      # longer hold
#   tunlock bob        # remove the lock(s) targeting bob early
#
# tlock kills all of the user's live sessions cluster-wide and blocks new
# access until the TTL lapses or tunlock. The TTL default means a demo can
# never leave a persona permanently locked (the preflight checks for stale
# locks). Real commands are pushed to history so the audience can see them.

tlock() {
  local user=$1 ttl=${2:-5m}
  if [[ -z $user ]]; then
    print -u2 "usage: tlock <user> [ttl=5m]"
    return 1
  fi
  print -s "tctl lock --user=${user} --ttl=${ttl}"
  command tctl lock --user=$user --message="Demo: suspicious activity — access suspended" --ttl=$ttl
}

tunlock() {
  local user=$1
  if [[ -z $user ]]; then
    print -u2 "usage: tunlock <user>"
    return 1
  fi
  local -a ids
  ids=(${(f)"$(command tctl get locks --format=json 2>/dev/null |
    python3 -c '
import json, sys
try:
    locks = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for l in locks if isinstance(locks, list) else []:
    if l.get("spec", {}).get("target", {}).get("user") == sys.argv[1]:
        print(l["metadata"]["name"])
' "$user")"})
  if (( ! $#ids )); then
    print -u2 "no lock found for user ${user}"
    return 1
  fi
  local id
  for id in $ids; do
    command tctl rm "lock/$id"
  done
}

# Complete demo persona names (override with TSH_DEMO_PERSONAS="bob alice ...").
_tpersonas() { compadd ${=TSH_DEMO_PERSONAS:-bob alice} }
if (( $+functions[compdef] )); then
  compdef _tpersonas tlock tunlock tpersona
fi
