# tunwedge — clear wedged tsh processes and diagnose silent tsh hangs.
#
# ROOT CAUSE (proven 2026-08-18): tsh dials the SYSTEM ssh-agent at
# SSH_AUTH_SOCK during client init (--add-keys-to-agent defaults to auto)
# with no timeout. A wedged agent silently hangs every tsh command before
# any output, and hung calls pile up (one per prompt refresh, one per retry).
# The agent wedge also hangs plain ssh/git — it is not a Teleport bug alone.
# Immunize tsh permanently with: export TELEPORT_ADD_KEYS_TO_AGENT=no
#
#   tunwedge            kill stuck tsh CLI processes (>2m old), then probe
#                       the base client and the system ssh-agent
#   tunwedge --connect  also restart the Teleport Connect app; use only when
#                       the base-client probe itself still stalls
#
# Daemons (Connect's tshd, vnet) are never touched without --connect.
tunwedge() {
  emulate -L zsh
  local line et rest verdict
  local -a parts wpids wdesc

  # Stuck = argv0 basename is tsh, not a daemon, older than ~2 minutes.
  # etime formats: SS, MM:SS, HH:MM:SS, DD-HH:MM:SS.
  for line in ${(f)"$(command ps -axo pid=,etime=,command= 2>/dev/null)"}; do
    parts=(${(z)line})
    (( $#parts >= 3 )) || continue
    [[ ${parts[3]:t} == tsh ]] || continue
    et=$parts[2] rest="${(j: :)parts[3,-1]}"
    [[ $rest == *" daemon "* || $rest == *vnet-daemon* ]] && continue
    parts=(${(s.:.)${et//-/:}})
    (( $#parts >= 3 || ($#parts == 2 && parts[1] >= 2) )) || continue
    wpids+=(${line[(w)1]})
    wdesc+=("  ${line[(w)1]}  $et  ${rest[1,70]}")
  done

  if (( $#wpids )); then
    print -P "%F{3}tunwedge:%f killing $#wpids stuck tsh process(es):"
    print -rl -- $wdesc
    kill -9 $wpids 2>/dev/null
  else
    print "tunwedge: no stuck tsh CLI processes found"
  fi

  if [[ $1 == --connect ]]; then
    if command pgrep -qf 'MacOS/Teleport Connect$'; then
      print "tunwedge: restarting Teleport Connect…"
      command osascript -e 'quit app "Teleport Connect"' &>/dev/null
      command sleep 3
      command pkill -9 -f 'MacOS/Teleport Connect$' 2>/dev/null
      command pkill -9 -f 'tsh daemon start' 2>/dev/null
      command sleep 1
      command open -a 'Teleport Connect'
    else
      print "tunwedge: Teleport Connect is not running; nothing to restart"
    fi
  fi

  # Probe 1: base client (pure local; 5s watchdog, subshell keeps
  # job-control noise out of the interactive shell)
  verdict=$(
    command tsh version --client &>/dev/null &
    tpid=$!
    ( sleep 5; kill -9 $tpid 2>/dev/null ) &
    wpid=$!
    wait $tpid 2>/dev/null && print ok || print stall
    kill $wpid 2>/dev/null
  )

  # Probe 2: the system ssh-agent — the proven wedge source. ssh-add exits
  # immediately when the agent is healthy (0=keys, 1=empty, 2=no agent);
  # only a wedged agent makes it hang until the watchdog kills it.
  if [[ $verdict == ok && -n ${SSH_AUTH_SOCK:-} ]]; then
    verdict=$(
      command ssh-add -l &>/dev/null &
      tpid=$!
      ( sleep 5; kill -9 $tpid 2>/dev/null ) &
      wpid=$!
      wait $tpid 2>/dev/null
      rc=$?
      kill $wpid 2>/dev/null
      (( rc >= 128 )) && print agent-stall || print ok
    )
  fi

  if [[ $verdict == ok ]]; then
    print -P "%F{2}tunwedge: tsh and the system ssh-agent respond — healthy%f"
    command rm -f ${XDG_CACHE_HOME:-$HOME/.cache}/tsh-zsh/*/refresh-stalled(N) 2>/dev/null
  elif [[ $verdict == agent-stall ]]; then
    print -P "%F{1}tunwedge: the SYSTEM ssh-agent is wedged (plain ssh/git will hang too) — fix: pkill -9 ssh-agent (launchd respawns it)%f"
    if [[ ${TELEPORT_ADD_KEYS_TO_AGENT:-} != no ]]; then
      print -P "%F{3}tunwedge: tsh dials this agent on every command — immunize it: export TELEPORT_ADD_KEYS_TO_AGENT=no (put it in ~/.zshenv)%f"
    fi
    return 1
  else
    if [[ $1 == --connect ]]; then
      print -P "%F{1}tunwedge: base tsh still stalls after a Connect restart — check the proxy/network, or reboot%f"
    else
      print -P "%F{1}tunwedge: base tsh itself stalls — try: tunwedge --connect%f"
    fi
    return 1
  fi
}
