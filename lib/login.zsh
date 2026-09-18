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
#   # 3. Optional convention: bare names resolve to <name>.$DOMAIN, which is
#   #    what makes dynamically created clusters work with zero config.
#   typeset -g TELEPORT_ZSH_CLUSTER_DOMAIN=acme.example.com
#
# Resolution order for `tlogin <target>`:
#   1. contains a dot          -> used verbatim as the proxy address
#   2. key in _CLUSTERS        -> that address
#   3. matches a known profile -> that profile's address (~/.tsh/*.yaml)
#   4. _CLUSTER_DOMAIN set     -> <target>.$DOMAIN
#   5. otherwise               -> error listing what is known
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

_teleport_resolve_cluster() {
  typeset -g _tp_addr=""
  local t=$1
  [[ -z $t ]] && return 1

  if [[ $t == *.* ]]; then
    _tp_addr=$t
  elif [[ -n ${TELEPORT_ZSH_CLUSTERS[$t]:-} ]]; then
    _tp_addr=${TELEPORT_ZSH_CLUSTERS[$t]}
  else
    _teleport_known_profiles
    local p
    for p in $_tp_profiles; do
      if [[ ${p%%.*} == $t ]]; then _tp_addr=$p; break; fi
    done
    if [[ -z $_tp_addr && -n ${TELEPORT_ZSH_CLUSTER_DOMAIN:-} ]]; then
      _tp_addr="${t}.${TELEPORT_ZSH_CLUSTER_DOMAIN}"
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
    [[ -n ${TELEPORT_ZSH_CLUSTER_DOMAIN:-} ]] &&
      print -u2 "  bare names also resolve to <name>.${TELEPORT_ZSH_CLUSTER_DOMAIN}"
    return 1
  fi

  if ! _teleport_resolve_cluster "$target"; then
    print -u2 "tlogin: can't resolve '$target' — pass a full proxy address, add it to"
    print -u2 "        TELEPORT_ZSH_CLUSTERS, or set TELEPORT_ZSH_CLUSTER_DOMAIN"
    return 1
  fi

  # Flags are looked up by the short name the user typed AND by the resolved
  # host's first label, so `tlogin events` and `tlogin events.acme.example.com`
  # pick up the same settings.
  local key=${target%%.*} extra=""
  extra=${TELEPORT_ZSH_LOGIN_ARGS[$target]:-${TELEPORT_ZSH_LOGIN_ARGS[$key]:-}}

  print -P "%F{8}tlogin:%f ${_tp_addr}${extra:+ ${extra}}"
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
