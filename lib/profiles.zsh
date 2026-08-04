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
