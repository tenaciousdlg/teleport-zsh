# tprofiles — every cluster tsh knows about, at a glance. A compact,
# color-coded answer to "what am I actually logged into right now?":
#
#   ▸ presales.teleportdemo.com   dlg    18m       ← active, yellow TTL
#     blackhat.teleportdemo.com   chris  EXPIRED   ← known but dead
#
# Reads the same local files as the prompt segment (profile YAMLs +
# certs under ${TELEPORT_HOME:-~/.tsh}); no network. The prompt segment
# shows `+N` when N other profiles exist — tprofiles is the expansion.
# Switch with `tsh login --proxy=<TAB>` (completion offers known profiles;
# a still-valid cert switches instantly without re-auth).

# tcycle — switch the active profile to the next cluster you hold live
# credentials on. `tsh login --proxy=<cluster>` with a valid cert switches
# instantly (no re-auth), so this is a free rotation through your live
# sessions. `tcycle -n` prints the target without switching.
#
# A ZLE widget is included for key-driven cycling; opt in by setting
# TELEPORT_ZSH_CYCLE_KEY before the plugin loads, e.g.:
#   TELEPORT_ZSH_CYCLE_KEY='^[t'   # Alt-T cycles cluster, prompt updates live
tcycle() {
  emulate -L zsh
  setopt local_options null_glob
  local dry=""
  [[ $1 == -n ]] && dry=1
  local tdir=${TELEPORT_HOME:-$HOME/.tsh}
  local active=""
  [[ -r $tdir/current-profile ]] && active=$(<$tdir/current-profile)
  local -a yams=($tdir/*.yaml) live
  local p
  for p in ${(@)yams:t:r}; do
    local -a c=($tdir/keys/$p/*.crt)
    (( $#c )) || continue
    _teleport_cert_meta "${c[1]}" || continue
    (( _tp_expiry > EPOCHSECONDS )) && live+=($p)
  done
  if (( ! $#live )); then
    print -u2 "tcycle: no live profiles — tsh login first (see tprofiles)"
    return 1
  fi
  if (( $#live == 1 )) && [[ ${live[1]} == $active ]]; then
    print "tcycle: only one live profile ($active)"
    return 0
  fi
  local idx=${live[(Ie)$active]}          # 0 when active isn't live → picks first
  local next=${live[$(( idx % $#live + 1 ))]}
  if [[ -n $dry ]]; then
    print -r -- "$next"
    return 0
  fi
  # Use the profile's exact web_proxy_addr — a bare hostname makes tsh's
  # already-logged-in fast path print status without switching. And even the
  # right form can decline to move the pointer, so verify and set it
  # directly if needed (current-profile is a one-line client-side pointer
  # to a profile whose cert we just checked is live).
  local addr
  addr=$(command grep -m1 '^web_proxy_addr:' "$tdir/$next.yaml" 2>/dev/null | command awk '{print $2}')
  [[ -z $addr ]] && addr=$next:443
  command tsh login --proxy=$addr >/dev/null 2>&1
  if [[ "$(<$tdir/current-profile)" != $next ]]; then
    print -r -- "$next" > "$tdir/current-profile"
  fi
  tprofiles
}

teleport-cycle-profile() {
  tcycle >/dev/null 2>&1
  zle && zle reset-prompt
}
if (( $+functions[zle] )) || zmodload -e zsh/zle 2>/dev/null; then
  zle -N teleport-cycle-profile 2>/dev/null
  [[ -n $TELEPORT_ZSH_CYCLE_KEY ]] && bindkey "$TELEPORT_ZSH_CYCLE_KEY" teleport-cycle-profile
fi

tprofiles() {
  emulate -L zsh
  setopt local_options null_glob
  local tdir=${TELEPORT_HOME:-$HOME/.tsh}
  local -a yams=($tdir/*.yaml)
  if (( ! $#yams )); then
    print "no Teleport profiles in ${tdir/#$HOME/~} — tsh login to get started"
    return 0
  fi
  local active=""
  [[ -r $tdir/current-profile ]] && active=$(<$tdir/current-profile)

  local y prof user state color mark elev
  local -a rows
  local now=$EPOCHSECONDS
  for y in $yams; do
    prof=${y:t:r}
    local -a certs=($tdir/keys/$prof/*.crt)
    elev=""
    if (( ! $#certs )); then
      user="-" state="logged out" color=8
    else
      user=${${certs[1]:t:r}%%@*}
      if _teleport_cert_meta "${certs[1]}"; then
        _teleport_baseline_sync "$prof" "$_tp_nreq" "$_tp_roles"
        if (( _tp_nreq > 0 )); then
          local -a cur=(${=_tp_roles}) base=(${=${_tp_base_memo[$prof]:-}}) added
          added=(${cur:|base})
          (( $#added )) && elev=" ↑${(j:,:)${(@)added%-access}}" || elev=" ↑$_tp_nreq"
        fi
        local left=$(( _tp_expiry - now ))
        if (( left <= 0 )); then
          state="EXPIRED" color=1
        elif (( left < 3600 )); then
          state="$(( left / 60 ))m" color=3
        else
          state="$(( left / 3600 ))h$(( (left % 3600) / 60 ))m" color=2
        fi
      else
        state="?" color=3
      fi
    fi
    mark=" "
    [[ $prof == $active ]] && mark="▸"
    rows+=("$mark|$prof|$user$elev|$color|$state")
  done

  local w1=0 w2=0 r
  local -a f
  for r in $rows; do
    f=(${(s:|:)r})
    (( $#f[2] > w1 )) && w1=$#f[2]
    (( $#f[3] > w2 )) && w2=$#f[3]
  done
  for r in $rows; do
    f=(${(s:|:)r})
    print -P -- "%B${f[1]}%b ${(r:$w1:)f[2]}  ${(r:$w2:)f[3]}  %F{${f[4]}}${f[5]}%f"
  done
}
