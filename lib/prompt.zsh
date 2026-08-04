# Teleport powerlevel10k segment — cluster ▸ identity + elevation + cert TTL.
#
#   ⛨ acme ▸ chris 7h32m           (green: >4h left on the TLS cert)
#   ⛨ acme ▸ bob ↑staging 5h02m    (an approved access request is assumed)
#   ⛨ acme ▸ bob 6h02m             (magenta: persona shell via TELEPORT_HOME)
#   ⛨ acme ▸ chris 43m             (yellow <1h, red <15m / expired)
#   ⛨ logged out                   (dim; only shown if the tsh dir exists)
#
# Zero network on the prompt path: reads ${TELEPORT_HOME:-~/.tsh} only.
# openssl runs once per new cert (memoized by mtime), never per prompt.
# Honors TELEPORT_HOME so persona terminals (TELEPORT_HOME=~/.tsh-bob)
# are visually unmistakable from the main identity.
#
# Elevation (↑role) works by snapshotting the cert's roles to
# ~/.cache/tsh-zsh/<profile>/baseline-roles whenever no access request is
# active; when the cert carries active requests (subject OID 1.3.9999.2.8,
# one per assumed request), the roles added relative to that baseline are
# shown (fallback: ↑<count>).
#
# Enable by adding `teleport` to POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS (or
# LEFT). Override the icon with TELEPORT_ZSH_ICON (default: Nerd Font
# shield ), and colors with POWERLEVEL9K_TELEPORT_<STATE>_FOREGROUND
# (states: OK WARN CRIT LOGGEDOUT PERSONA_OK PERSONA_WARN PERSONA_CRIT).

zmodload zsh/stat zsh/datetime 2>/dev/null

typeset -gA _tp_expiry_memo _tp_roles_memo _tp_req_memo _tp_base_memo

# Parse the cert once per mtime: notAfter → $_tp_expiry (epoch), roles →
# $_tp_roles (space-joined), active request count → $_tp_nreq. Sets globals
# instead of printing — a $(...) call would run in a subshell and lose the
# memo, forking openssl on every prompt.
_teleport_cert_meta() {
  local cert=$1 mtime out end exp
  zstat -A mtime +mtime -- "$cert" 2>/dev/null || return 1
  local key="$cert:$mtime"
  if [[ -z ${_tp_expiry_memo[$key]} ]]; then
    out=$(openssl x509 -noout -enddate -subject -nameopt multiline -in "$cert" 2>/dev/null) || return 1
    end=${${(M)${(f)out}:#notAfter=*}[1]#notAfter=}
    [[ -n $end ]] || return 1
    # BSD date (macOS) first, GNU date (Linux) fallback.
    exp=$(date -j -u -f '%b %e %H:%M:%S %Y %Z' "$end" +%s 2>/dev/null) ||
      exp=$(date -u -d "$end" +%s 2>/dev/null) || return 1
    _tp_expiry_memo[$key]=$exp
    # Teleport encodes roles as organizationName values in the cert subject,
    # and each assumed access request as an OID 1.3.9999.2.8 entry.
    _tp_roles_memo[$key]="$(print -r -- "$out" |
      grep -oE 'organizationName *= *[^+]+' |
      sed -E 's/organizationName *= *//; s/ +$//' | tr '\n' ' ')"
    _tp_req_memo[$key]=${#${(M)${(f)out}:#*1.3.9999.2.8*}}
  fi
  typeset -g _tp_expiry=${_tp_expiry_memo[$key]}
  typeset -g _tp_roles=${_tp_roles_memo[$key]}
  typeset -g _tp_nreq=${_tp_req_memo[$key]}
}

# Maintain the unelevated-roles baseline for a profile. Written only when no
# request is active and the roles actually changed; read from disk once per
# shell when starting out elevated.
_teleport_baseline_sync() {
  local prof=$1 nreq=$2 roles=$3
  local bfile=${XDG_CACHE_HOME:-$HOME/.cache}/tsh-zsh/$prof/baseline-roles
  if (( nreq == 0 )); then
    if [[ ${_tp_base_memo[$prof]} != $roles ]]; then
      command mkdir -p "${bfile:h}" 2>/dev/null
      print -r -- "$roles" > "$bfile" 2>/dev/null
      _tp_base_memo[$prof]=$roles
    fi
  elif [[ -z ${_tp_base_memo[$prof]} && -r $bfile ]]; then
    _tp_base_memo[$prof]=$(<$bfile)
  fi
}

prompt_teleport() {
  local tdir=${TELEPORT_HOME:-$HOME/.tsh}
  [[ -d $tdir ]] || return
  local icon=${TELEPORT_ZSH_ICON-$''}

  local persona=""
  [[ -n $TELEPORT_HOME && $TELEPORT_HOME != $HOME/.tsh ]] && persona="PERSONA_"

  local prof=""
  [[ -r $tdir/current-profile ]] && prof=$(<$tdir/current-profile)
  if [[ -z $prof ]]; then
    p10k segment -s LOGGEDOUT -f 8 -i "$icon" -t 'logged out'
    return
  fi

  # Identity = the TLS cert file name (keys/<proxy>/<user>.crt); its absence
  # after `tsh logout` is what flips the segment to "logged out".
  local -a certs
  certs=($tdir/keys/$prof/*.crt(N))
  if (( ! $#certs )); then
    p10k segment -s LOGGEDOUT -f 8 -i "$icon" -t 'logged out'
    return
  fi
  local user=${certs[1]:t:r}         # chris.delagarza@example.com
  user=${user%%@*}                   # chris.delagarza
  user=${user%%.*}                   # chris
  local cluster=${prof%%.*}          # acme

  local exp="" now left ttl state fg
  typeset -g _tp_nreq=0
  _teleport_cert_meta "${certs[1]}" && exp=$_tp_expiry
  _teleport_baseline_sync "$prof" "$_tp_nreq" "$_tp_roles"

  # Elevation marker: roles gained relative to the unelevated baseline.
  local elev=""
  if (( _tp_nreq > 0 )); then
    local -a cur=(${=_tp_roles}) base=(${=${_tp_base_memo[$prof]:-}}) added
    added=(${cur:|base})
    if (( $#added )); then
      elev=" ↑${(j:,:)${(@)added%-access}}"
      (( $#elev > 25 )) && elev="${elev[1,24]}…"
    else
      elev=" ↑$_tp_nreq"
    fi
  fi

  now=$EPOCHSECONDS
  if [[ -z $exp ]]; then
    ttl='?' state=WARN fg=3
  elif (( exp <= now )); then
    ttl='expired' state=CRIT fg=1
  else
    left=$(( exp - now ))
    if (( left >= 3600 )); then
      ttl="$(( left / 3600 ))h$(( (left % 3600) / 60 ))m"
    else
      ttl="$(( left / 60 ))m"
    fi
    if   (( left < 900 ));   then state=CRIT fg=1
    elif (( left < 3600 ));  then state=WARN fg=3
    else                          state=OK   fg=2
    fi
  fi

  # Other profiles tsh knows about (tsh status would list them) — shown as
  # a +N tail; `tprofiles` expands it. TELEPORT_ZSH_NO_OTHERS=1 hides it.
  local others=""
  if [[ -z $TELEPORT_ZSH_NO_OTHERS ]]; then
    local -a allprofs=($tdir/*.yaml(N))
    (( $#allprofs > 1 )) && others=" +$(( $#allprofs - 1 ))"
  fi

  # Persona shells stay magenta while healthy so bob/alice terminals are
  # unmistakable; low-TTL warning colors still win (safety over identity).
  [[ -n $persona && $state == OK ]] && fg=5
  p10k segment -s "${persona}${state}" -f $fg -i "$icon" -t "${cluster} ▸ ${user}${elev} ${ttl}${others}"
}

# Safe under p10k instant prompt: local files only, no side effects that matter.
instant_prompt_teleport() { prompt_teleport }

# One-shot expiry warnings: the prompt segment is passive; this taps you on
# the shoulder exactly once per cert when it crosses <15m, and once when it
# expires. A fresh login mints a new cert (new expiry) and re-arms both.
typeset -gA _tp_warned

_teleport_ttl_warn() {
  local tdir=${TELEPORT_HOME:-$HOME/.tsh} prof
  [[ -r $tdir/current-profile ]] || return 0
  prof=$(<$tdir/current-profile)
  [[ -n $prof ]] || return 0
  local -a certs
  certs=($tdir/keys/$prof/*.crt(N))
  (( $#certs )) || return 0
  _teleport_cert_meta "${certs[1]}" || return 0
  local left=$(( _tp_expiry - EPOCHSECONDS ))
  local key="${certs[1]}:${_tp_expiry}" short=${prof%%.*}
  if (( left <= 0 )); then
    [[ -n ${_tp_warned[${key}:expired]} ]] && return 0
    _tp_warned[${key}:expired]=1
    print -P "%F{1}⚠ teleport cert for ${short} has expired — tsh login%f"
  elif (( left < 900 )); then
    [[ -n ${_tp_warned[${key}:crit]} ]] && return 0
    _tp_warned[${key}:crit]=1
    print -P "%F{3}⚠ teleport cert for ${short} expires in $(( left / 60 ))m — finish up or re-login%f"
  fi
}

autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _teleport_ttl_warn
