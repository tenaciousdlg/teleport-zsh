# tlogin — log into a Teleport cluster by short name, clean-slate.
#
# `tsh logout --proxy=X` runs first because a stale expired profile makes the
# next login render blank roles / EXPIRED even when the server-side SSO
# succeeded. Logging out ONE proxy leaves your other clusters alone.
#
# Built for estates where clusters come and go: nothing is hardcoded here, and
# a cluster you have logged into once is offered by completion from then on,
# so a freshly spun-up tenant needs no config at all.
#
# Configure in ~/.zshrc.local (keep real cluster names out of this repo):
#
#   # 1. Optional short-name aliases, for names that don't follow the domain
#   #    convention or that need a specific address.
#   typeset -gA TELEPORT_ZSH_CLUSTERS=(
#     dev     dev.acme.example.com
#     lab     lab.example.net:3080
#   )
#
#   # 2. Optional per-cluster login flags.
#   typeset -gA TELEPORT_ZSH_LOGIN_ARGS=(
#     dev     '--auth=okta'
#     lab     '--user=sam@acme.example.com --auth=local'
#   )
#
#   # 3. Optional convention: bare names resolve to <name>.<domain>, which is
#   #    what makes dynamically created clusters work with zero config. List
#   #    every domain you spin clusters up under.
#   typeset -ga TELEPORT_ZSH_CLUSTER_DOMAINS=(acme.example.com lab.example.net)
#
# Resolution order for `tlogin <target>`:
#   1. contains a dot          -> used verbatim as the proxy address
#   2. key in _CLUSTERS        -> that address
#   3. matches a known profile -> that profile's address (~/.tsh/*.yaml)
#   4. <target>.<domain> for each configured domain, narrowed by DNS
#   5. otherwise               -> error listing what is known
#
# Step 4 is the one that can surprise you, so it never guesses silently: with
# more than one domain configured, only candidates that actually resolve in DNS
# are considered, an ambiguous result is an error listing the candidates, and a
# convention hit is always labelled "(by convention)" in the echoed line. Pin
# anything stable in _CLUSTERS and it never reaches step 4 at all.
#
# ":443" is appended when no port is given. Only --proxy is passed; a trailing
# positional cluster name selects a LEAF cluster and is not needed for a root
# login.

typeset -gA TELEPORT_ZSH_CLUSTERS TELEPORT_ZSH_LOGIN_ARGS

# Short names of every cluster with a profile on disk, live or expired. Used
# for completion and as a resolution source, so anything logged into once is
# reachable by its short name afterwards.
_teleport_known_profiles() {
  typeset -ga _tp_profiles=()
  local tdir=${TELEPORT_HOME:-$HOME/.tsh}
  local -a yams=($tdir/*.yaml(N))
  (( $#yams )) && _tp_profiles=(${(@)yams:t:r})
}

# Does this hostname resolve? Used to disambiguate convention candidates
# across several domains. Falls back to "assume yes" when no resolver tool is
# present, so a missing `host`/`dig` degrades to the old behaviour instead of
# blocking a login.
_teleport_host_resolves() {
  if (( $+commands[host] )); then
    host -W 1 -t A "$1" >/dev/null 2>&1 && return 0
    host -W 1 -t CNAME "$1" >/dev/null 2>&1 && return 0
    return 1
  elif (( $+commands[dig] )); then
    [[ -n $(dig +short +time=1 +tries=1 "$1" 2>/dev/null) ]]
  else
    return 0
  fi
}

_teleport_resolve_cluster() {
  typeset -g _tp_addr="" _tp_via=""
  local t=$1
  [[ -z $t ]] && return 1

  # Back-compat: a scalar TELEPORT_ZSH_CLUSTER_DOMAIN still works.
  local -a domains=(${TELEPORT_ZSH_CLUSTER_DOMAINS[@]:-})
  (( $#domains )) || domains=(${TELEPORT_ZSH_CLUSTER_DOMAIN:+$TELEPORT_ZSH_CLUSTER_DOMAIN})

  if [[ $t == *.* ]]; then
    _tp_addr=$t _tp_via=literal
  elif [[ -n ${TELEPORT_ZSH_CLUSTERS[$t]:-} ]]; then
    _tp_addr=${TELEPORT_ZSH_CLUSTERS[$t]} _tp_via=alias
  else
    _teleport_known_profiles
    local p
    for p in $_tp_profiles; do
      if [[ ${p%%.*} == $t ]]; then _tp_addr=$p _tp_via=profile; break; fi
    done

    if [[ -z $_tp_addr ]] && (( $#domains )); then
      local -a cands=(${^domains:#}) hits=()
      cands=("${t}."${^domains})
      if (( $#cands == 1 )); then
        hits=($cands)                      # single domain: no DNS probe needed
      else
        local c
        for c in $cands; do
          _teleport_host_resolves "$c" && hits+=($c)
        done
      fi
      case $#hits in
        1) _tp_addr=${hits[1]} _tp_via=convention ;;
        0) typeset -g _tp_cands="${(j: :)cands}"; return 1 ;;
        *) typeset -g _tp_cands="${(j: :)hits}";  return 2 ;;
      esac
    fi
  fi

  [[ -n $_tp_addr ]] || return 1
  # Append the default port unless one is already present. Guard against IPv6
  # literals, where colons are part of the address.
  [[ $_tp_addr != *:* || $_tp_addr == \[*\]* ]] && _tp_addr="${_tp_addr}:443"
  return 0
}

tlogin() {
  emulate -L zsh
  local target=$1

  if [[ -z $target || $target == -h || $target == --help ]]; then
    _teleport_known_profiles
    print -u2 "usage: tlogin <short-name|proxy.address>"
    (( $#TELEPORT_ZSH_CLUSTERS )) &&
      print -u2 "  aliases : ${(ko)TELEPORT_ZSH_CLUSTERS}"
    (( $#_tp_profiles )) &&
      print -u2 "  known   : ${(j: :)${(@)_tp_profiles%%.*}}"
    local -a d=(${TELEPORT_ZSH_CLUSTER_DOMAINS[@]:-})
    (( $#d )) || d=(${TELEPORT_ZSH_CLUSTER_DOMAIN:+$TELEPORT_ZSH_CLUSTER_DOMAIN})
    (( $#d )) && print -u2 "  domains : ${(j: :)d}"
    return 1
  fi

  _teleport_resolve_cluster "$target"
  case $? in
    2) print -u2 "tlogin: '$target' is ambiguous — it resolves under more than one domain:"
       print -u2 "        ${_tp_cands}"
       print -u2 "        pass the full address, or pin it in TELEPORT_ZSH_CLUSTERS"
       return 1 ;;
    1) print -u2 "tlogin: can't resolve '$target' — pass a full proxy address, add it to"
       print -u2 "        TELEPORT_ZSH_CLUSTERS, or add a domain to TELEPORT_ZSH_CLUSTER_DOMAINS"
       [[ -n ${_tp_cands:-} ]] &&
         print -u2 "        (tried, none resolved: ${_tp_cands})"
       return 1 ;;
  esac

  # Flags are looked up by the short name the user typed AND by the resolved
  # host's first label, so `tlogin events` and `tlogin events.acme.example.com`
  # pick up the same settings.
  local key=${target%%.*} extra=""
  extra=${TELEPORT_ZSH_LOGIN_ARGS[$target]:-${TELEPORT_ZSH_LOGIN_ARGS[$key]:-}}

  # Label convention hits so a guessed domain is never silent.
  local note=""
  [[ $_tp_via == convention ]] && note=" %F{3}(by convention)%f"
  print -P "%F{8}tlogin:%f ${_tp_addr}${extra:+ ${extra}}${note}"
  command tsh logout --proxy=$_tp_addr 2>/dev/null
  command tsh login --proxy=$_tp_addr ${=extra}
}

_tlogin() {
  _teleport_known_profiles
  local -a opts
  opts=(${(ko)TELEPORT_ZSH_CLUSTERS} ${(@)_tp_profiles%%.*})
  compadd -- ${(u)opts}
}
(( $+functions[compdef] )) && compdef _tlogin tlogin
