# Teleport powerlevel10k segment — cluster ▸ identity + elevation + cert TTL.
#
#   ⛨ acme ▸ sam 7h32m           (green: >4h left on the TLS cert)
#   ⛨ acme ▸ bob ↑staging 5h02m    (an approved access request is assumed)
#   ⛨ acme ▸ bob 6h02m             (magenta: persona shell via TELEPORT_HOME)
#   ⛨ acme ▸ sam 43m             (yellow <1h, red <15m / expired)
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
  local user=${certs[1]:t:r}         # sam.jones@acme.example.com
  user=${user%%@*}                   # sam.jones
  user=${user%%.*}                   # sam
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
    # Long-expired = you're not working Teleport right now; that's inventory,
    # not exposure — drop out of the prompt instead of nagging in red for days.
    # Fresh expiry (default <24h, override TELEPORT_ZSH_STALE_AFTER) stays loud.
    (( now - exp > ${TELEPORT_ZSH_STALE_AFTER:-86400} )) && return
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

  # Other clusters you hold LIVE credentials on right now — expired or
  # logged-out profiles never show (they're inventory, not exposure; see
  # tprofiles for the full list). Shown by name (+staging) while short,
  # falling back to a count (+3) when names would crowd the prompt.
  # TELEPORT_ZSH_OTHERS=count forces the count; =off hides the tail.
  # Safe to reuse _teleport_cert_meta here: the active cert's values were
  # captured into locals above.
  local others=""
  if [[ $TELEPORT_ZSH_OTHERS != off ]]; then
    local op names
    local -a ocerts oyams live
    oyams=($tdir/*.yaml(N))
    for op in ${(@)oyams:t:r}; do
      [[ $op == $prof ]] && continue
      ocerts=($tdir/keys/$op/*.crt(N))
      (( $#ocerts )) || continue
      _teleport_cert_meta "${ocerts[1]}" || continue
      (( _tp_expiry > EPOCHSECONDS )) && live+=(${op%%.*})
    done
    if (( $#live )); then
      names="${(j:,:)live}"
      if [[ $TELEPORT_ZSH_OTHERS != count ]] && (( $#names <= 16 )); then
        others=" +$names"
      else
        others=" +$#live"
      fi
    fi
  fi

  # Reviewer badge: pending access requests on this cluster (cache-only
  # read; lib/requests.zsh owns the background refresh).
  local pend=""
  if (( $+functions[_teleport_pending_count] )); then
    _teleport_pending_count "$prof"
    (( _tp_pendingreq > 0 )) && pend=" ✉$_tp_pendingreq"
  fi

  # Cluster color accents: TELEPORT_ZSH_CLUSTER_COLORS=(pattern color ...)
  # e.g. ('prod-*' 1 '*.teleport.sh' 208) — anything prod-shaped reads hot
  # even when healthy. Warning/persona colors still take precedence.
  if [[ $state == OK && -z $persona ]] && (( $#TELEPORT_ZSH_CLUSTER_COLORS )); then
    local _i _pat
    for (( _i=1; _i + 1 <= $#TELEPORT_ZSH_CLUSTER_COLORS; _i+=2 )); do
      _pat=${TELEPORT_ZSH_CLUSTER_COLORS[_i]}
      if [[ $prof == ${~_pat} || $cluster == ${~_pat} ]]; then
        fg=${TELEPORT_ZSH_CLUSTER_COLORS[_i+1]}
        break
      fi
    done
  fi

  # Persona shells stay magenta while healthy so bob/alice terminals are
  # unmistakable; low-TTL warning colors still win (safety over identity).
  [[ -n $persona && $state == OK ]] && fg=5
  p10k segment -s "${persona}${state}" -f $fg -i "$icon" -t "${cluster} ▸ ${user}${pend}${elev} ${ttl}${others}"
}

# Safe under p10k instant prompt: local files only, no side effects that matter.
instant_prompt_teleport() { prompt_teleport }

# One-shot expiry warnings: the prompt segment is passive; this taps you on
# the shoulder exactly once per cert when it crosses <15m, and once when it
# expires. A fresh login mints a new cert (new expiry) and re-arms both.
# Non-active sessions get a transition notice too: if a cluster was seen
# LIVE earlier in this shell and its cert expires, one line says so —
# otherwise the +name tail just silently vanishes.
typeset -gA _tp_warned _tp_seen_live

_teleport_ttl_warn() {
  # p10k instant-prompt safety: the first precmd of a shell fires inside the
  # instant-prompt capture window, and printing there trips its console-output
  # warning. Skip that one prompt; the shoulder-tap can arrive one prompt late.
  if [[ -z $_tp_warn_armed ]]; then
    typeset -g _tp_warn_armed=1
    return 0
  fi
  local tdir=${TELEPORT_HOME:-$HOME/.tsh} prof
  [[ -r $tdir/current-profile ]] || return 0
  prof=$(<$tdir/current-profile)
  [[ -n $prof ]] || return 0
  local -a certs
  certs=($tdir/keys/$prof/*.crt(N))
  (( $#certs )) || return 0
  _teleport_cert_meta "${certs[1]}" || return 0
  (( $+functions[_teleport_stall_warn] )) && _teleport_stall_warn "$prof"
  local left=$(( _tp_expiry - EPOCHSECONDS ))
  local key="${certs[1]}:${_tp_expiry}" short=${prof%%.*}
  if (( left <= 0 )); then
    # Same staleness rule as the prompt segment: warn only while the expiry
    # is fresh; a cert that's been dead for a day isn't news in every shell.
    (( -left > ${TELEPORT_ZSH_STALE_AFTER:-86400} )) && return 0
    if [[ -z ${_tp_warned[${key}:expired]} ]]; then
      _tp_warned[${key}:expired]=1
      print -P "%F{1}⚠ teleport cert for ${short} has expired — tsh login%f"
    fi
  elif (( left < 900 )); then
    if [[ -z ${_tp_warned[${key}:crit]} ]]; then
      _tp_warned[${key}:crit]=1
      print -P "%F{3}⚠ teleport cert for ${short} expires in $(( left / 60 ))m — finish up or re-login%f"
    fi
  fi

  # live→expired transitions on the OTHER profiles
  local -a oyams=($tdir/*.yaml(N)) ocerts
  local op
  for op in ${(@)oyams:t:r}; do
    [[ $op == $prof ]] && continue
    ocerts=($tdir/keys/$op/*.crt(N))
    (( $#ocerts )) || continue
    _teleport_cert_meta "${ocerts[1]}" || continue
    if (( _tp_expiry > EPOCHSECONDS )); then
      _tp_seen_live[$op]=1
    elif [[ -n ${_tp_seen_live[$op]} && -z ${_tp_warned[other:$op:$_tp_expiry]} ]]; then
      _tp_warned[other:$op:$_tp_expiry]=1
      print -P "%F{3}⚠ teleport session on ${op%%.*} expired (was in your +tail)%f"
    fi
  done
}

autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _teleport_ttl_warn
