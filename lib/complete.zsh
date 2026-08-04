# Dynamic tab-completion for tsh — nodes, databases, apps, kube clusters,
# access-request IDs, session recordings, and common flags:
#
#   tsh ssh <TAB>            → ec2-user@ / ubuntu@ prefixes + node names (env=dev,team=platform)
#   tsh ssh --mfa-mode=<TAB> → auto cross-platform platform otp sso browser
#   tsh db connect <TAB>     → database names; --db-user=/--db-name= values too
#   tsh apps login <TAB>     → app names
#   tsh kube login <TAB>     → kube cluster names
#   tsh request review <TAB> → pending request IDs
#   tsh play <TAB>           → recording session IDs with kind/user/date
#
# Results are cached per-profile under ~/.cache/tsh-zsh/ (TTL 120s; 30s for
# requests). A stale cache is served instantly while a background refresh
# runs — only the very first TAB for a resource type pays a network round
# trip. The tsh wrapper at the bottom drops the cache after login/logout/
# request, so privilege changes show up on the very next TAB.
# SSH login prefixes come from the local SSH cert's principals (no network).

zmodload zsh/stat zsh/datetime 2>/dev/null

_tsh_current_profile() {
  local d=${TELEPORT_HOME:-$HOME/.tsh}
  [[ -r $d/current-profile ]] || return 1
  print -r -- "$(<$d/current-profile)"
}

# _tsh_cache <kind> <ttl-seconds> <cmd...>  → prints path to a usable cache file
_tsh_cache() {
  local kind=$1 ttl=$2; shift 2
  local prof; prof=$(_tsh_current_profile) || return 1
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/tsh-zsh/$prof
  local f=$dir/$kind.json mt
  mkdir -p "$dir" 2>/dev/null
  if [[ -s $f ]]; then
    zstat -A mt +mtime -- "$f" 2>/dev/null
    if (( EPOCHSECONDS - ${mt:-0} > ttl )); then
      ( "$@" > "$f.tmp" 2>/dev/null && command mv "$f.tmp" "$f" ) &>/dev/null &!
    fi
    print -r -- "$f"
  else
    "$@" > "$f.tmp" 2>/dev/null && command mv "$f.tmp" "$f" || return 1
    print -r -- "$f"
  fi
}

# Emit "name<TAB>description" lines from a tsh -f json cache file.
_tsh_parse() {  # $1 = kind, $2 = json file
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
kind, path = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
def labels_of(item):
    meta = item.get("metadata", {})
    lbls = dict(meta.get("labels") or {})
    for k, v in (item.get("spec", {}).get("cmd_labels") or {}).items():
        lbls[k] = v.get("result", "") if isinstance(v, dict) else v
    # skip internal labels and long dynamic values (uptime strings etc.)
    return {k: v for k, v in lbls.items()
            if not k.startswith("teleport.") and len(str(v)) <= 20}
def fit(pairs, limit=60):
    # accumulate whole key=value tokens; never cut one mid-way
    out = []
    for k, v in sorted(pairs.items()):
        if not v:
            continue
        tok = f"{k}={v}"
        if out and len(",".join(out)) + 1 + len(tok) > limit:
            break
        out.append(tok)
    return ",".join(out)
for it in data:
    spec, meta = it.get("spec", {}), it.get("metadata", {})
    if kind == "nodes":
        name, desc = spec.get("hostname") or meta.get("name"), labels_of(it)
    elif kind == "dbs":
        name = meta.get("name")
        desc = {"protocol": spec.get("protocol", "")}
        desc.update({k: v for k, v in labels_of(it).items() if k in ("env", "team")})
    elif kind == "apps":
        name, desc = meta.get("name"), {k: v for k, v in labels_of(it).items() if k in ("env", "team")}
    elif kind == "kube":
        name, desc = it.get("kube_cluster_name") or meta.get("name"), it.get("labels") or {}
    elif kind == "requests":
        name = it.get("id") or meta.get("name") or it.get("name")
        s = it.get("spec", it)
        desc = {"roles": ",".join(s.get("roles", [])), "user": s.get("user", "")}
    elif kind == "recordings":
        name = it.get("sid")
        ev = it.get("event", "").replace(".session.end", "")
        target = it.get("server_hostname") or it.get("db_service") or it.get("windows_desktop_service") or ""
        desc = {"1kind": ev, "2on": target,
                "3user": (it.get("user") or "").split("@")[0],
                "4at": (it.get("time") or "")[:10]}
        print(f"{name}\t{' '.join(v for _, v in sorted(desc.items()) if v)}")
        continue
    else:
        continue
    if not name:
        continue
    print(f"{name}\t{fit(desc)}")
PY
}

# compadd names (+ descriptions) for a resource kind; extra compadd args pass through.
_tsh_add() {  # $1 kind, $2 ttl, $3... fetch cmd -- remaining args go to compadd
  local kind=$1 ttl=$2; shift 2
  local -a fetch=() extra=()
  while (( $# )) && [[ $1 != -- ]]; do fetch+=("$1"); shift; done
  [[ $1 == -- ]] && shift && extra=("$@")
  local f; f=$(_tsh_cache "$kind" "$ttl" "${fetch[@]}") || return 1
  local -a names=() disp=()
  local n d
  while IFS=$'\t' read -r n d; do
    names+=("$n"); disp+=("${n}${d:+  ${d}}")
  done < <(_tsh_parse "$kind" "$f")
  (( $#names )) || return 1
  compadd "${extra[@]}" -ld disp -a names
}

# SSH login principals from the local cert (no network), filtered of internals.
_tsh_logins() {
  local tdir=${TELEPORT_HOME:-$HOME/.tsh}
  local prof; prof=$(_tsh_current_profile) || return 1
  local -a certs; certs=($tdir/keys/$prof/*-ssh/*-cert.pub(N))
  (( $#certs )) || return 1
  ssh-keygen -L -f "${certs[1]}" 2>/dev/null |
    sed -n '/Principals:/,/Critical Options:/p' |
    awk 'NR>1 && !/Critical/ {gsub(/^[ \t]+/,""); if ($0 !~ /^-/) print}'
}

_tsh_ssh_target() {
  local cur=${words[CURRENT]}
  if [[ $cur == *@* ]]; then
    local login=${cur%%@*}
    _tsh_add nodes 120 command tsh ls -f json -- -P "${login}@"
  else
    local -a logins; logins=(${(f)"$(_tsh_logins)"})
    (( $#logins )) && compadd -S '@' -q -a logins
    _tsh_add nodes 120 command tsh ls -f json --
  fi
}

# Value completion for --flag=value style words; returns 0 if it handled one.
_tsh_flag_value() {
  local cur=${words[CURRENT]}
  case $cur in
    --mfa-mode=*)
      compadd -P '--mfa-mode=' auto cross-platform platform otp sso browser; return 0 ;;
    --db-user=*)
      compadd -P '--db-user=' ${=TSH_DB_USERS:-writer reader}; return 0 ;;
    --db-name=*)
      compadd -P '--db-name=' ${=TSH_DB_NAMES:-postgres}; return 0 ;;
    --auth=*)
      compadd -P '--auth=' okta local passwordless; return 0 ;;
    --login=*)
      local -a logins; logins=(${(f)"$(_tsh_logins)"})
      (( $#logins )) && compadd -P '--login=' -a logins; return 0 ;;
    --reason=*)
      compadd -P '--reason=' 'authorized job'; return 0 ;;
  esac
  return 1
}

_tsh() {
  (( $+commands[tsh] )) || return 1
  local sub=${words[2]} action=${words[3]}
  _tsh_flag_value && return
  # Only add smarts once a subcommand is chosen; otherwise offer subcommands.
  if (( CURRENT == 2 )); then
    local -a subs=(
      'ssh:SSH to a node' 'ls:list nodes' 'login:log in to a cluster'
      'logout:log out' 'status:show profile' 'apps:application access'
      'db:database access' 'kube:kubernetes access' 'mcp:MCP server access'
      'request:access requests' 'aws:AWS CLI via app access'
      'proxy:local proxies' 'play:replay a session' 'recordings:list recordings'
      'clusters:list clusters' 'sessions:active sessions' 'scp:secure copy'
      'env:print profile env vars' 'version:client/server version'
    )
    _describe -t subcommands 'tsh subcommand' subs
    return
  fi
  # Curated flags per subcommand when the word starts with a dash.
  if [[ ${words[CURRENT]} == -* ]]; then
    case $sub in
      ssh)     compadd -S '' -- -l --login= --mfa-mode= --request-reason --tty ;;
      db|dbs)  compadd -S '' -- --db-user= --db-name= --mfa-mode= ;;
      login)   compadd -S '' -- --proxy= --user= --auth= ;;
      request) compadd -S '' -- --roles= --reason= --reviewers= ;;
      *)       compadd -S '' -- --mfa-mode= ;;
    esac
    return
  fi
  case $sub in
    ssh)
      _tsh_ssh_target ;;
    play)
      _tsh_add recordings 60 command tsh recordings ls -f json -- ;;
    db|dbs)
      case $action in
        connect|login|logout|config) (( CURRENT >= 4 )) && _tsh_add dbs 120 command tsh db ls -f json -- ;;
        *) (( CURRENT == 3 )) && compadd ls connect login logout config ;;
      esac ;;
    apps|app)
      case $action in
        login|logout|config) (( CURRENT >= 4 )) && _tsh_add apps 120 command tsh apps ls -f json -- ;;
        *) (( CURRENT == 3 )) && compadd ls login logout config ;;
      esac ;;
    kube)
      case $action in
        login) (( CURRENT >= 4 )) && _tsh_add kube 120 command tsh kube ls -f json -- ;;
        *) (( CURRENT == 3 )) && compadd ls login sessions exec ;;
      esac ;;
    request|requests)
      case $action in
        review|show) (( CURRENT >= 4 )) && _tsh_add requests 30 command tsh request ls -f json -- ;;
        *) (( CURRENT == 3 )) && compadd ls create review show search drop ;;
      esac ;;
    mcp)
      (( CURRENT == 3 )) && compadd ls config connect ;;
  esac
}

(( $+functions[compdef] )) && compdef _tsh tsh


# Wrapper: drop completion caches whenever privileges may have changed, so
# the next TAB reflects reality (e.g. prod nodes right after an approved
# request). The prompt's role baseline is deliberately left alone.
tsh() {
  command tsh "$@"
  local rc=$?
  case ${1:-} in
    login|logout|request|requests)
      local d=${XDG_CACHE_HOME:-$HOME/.cache}/tsh-zsh
      [[ -d $d ]] && command rm -f -- $d/*/*.json(N) $d/*/*.json.tmp(N)
      ;;
  esac
  return $rc
}
