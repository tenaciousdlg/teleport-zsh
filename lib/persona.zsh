# Persona shell launcher for demo stations — codifies the two-identity
# pattern (TELEPORT_HOME=~/.tsh-<persona>) so a persona terminal is one
# command:
#
#   tpersona bob                       # bob on your current cluster
#   tpersona alice other.example.com   # explicit proxy
#
# Sets the terminal tab title (BOB — acme), tints the window background
# via OSC 11 (works in iTerm2, Ghostty, Warp; harmlessly ignored elsewhere),
# adds an iTerm2 badge when available, logs in with --auth=local if the
# persona has no live cert, and drops into a subshell where the teleport
# prompt segment renders in persona magenta. Exit the subshell to return to
# your own identity; title/tint/badge are restored.
#
# Proxy resolution: explicit arg → TELEPORT_PERSONA_PROXY → the cluster
# your main identity (~/.tsh) is currently logged into.
# Disable tinting with TPERSONA_TINT=off, or set TPERSONA_TINT=#rrggbb.

# Pick a dark, readable tint deterministically from the persona name so
# bob and alice stations differ at a glance.
_tpersona_tint_color() {
  local name=$1 sum=0 i c
  local -a palette=('#2b1b2f' '#0e2a2a' '#14203a' '#33200f')  # plum teal navy rust
  for (( i=1; i <= $#name; i++ )); do c=$name[i]; (( sum += #c )); done
  print -r -- ${palette[$(( sum % $#palette + 1 ))]}
}

tpersona() {
  emulate -L zsh
  local name=$1
  if [[ -z $name ]]; then
    print -u2 "usage: tpersona <name> [proxy]"
    return 1
  fi
  local proxy=${2:-${TELEPORT_PERSONA_PROXY:-}}
  if [[ -z $proxy && -r $HOME/.tsh/current-profile ]]; then
    proxy=$(<$HOME/.tsh/current-profile)
  fi
  if [[ -z $proxy ]]; then
    print -u2 "tpersona: no proxy — pass one, set TELEPORT_PERSONA_PROXY, or tsh login first"
    return 1
  fi
  local phome=$HOME/.tsh-$name
  mkdir -p "$phome"

  local tint=${TPERSONA_TINT:-$(_tpersona_tint_color $name)}
  print -n "\e]0;${(U)name} — ${proxy%%.*}\a"
  [[ $tint != off ]] && print -n "\e]11;${tint}\a"
  [[ $TERM_PROGRAM == iTerm.app ]] &&
    print -n "\e]1337;SetBadgeFormat=$(print -n "${(U)name}" | base64)\a"

  if ! TELEPORT_HOME=$phome command tsh status &>/dev/null; then
    print -P "%F{5}logging in as ${name}@${proxy} (local auth)...%f"
    if ! TELEPORT_HOME=$phome command tsh login --proxy=${proxy}:443 $proxy --auth=local --user=$name; then
      print -n "\e]0;\a"
      [[ $tint != off ]] && print -n "\e]111;\a"
      [[ $TERM_PROGRAM == iTerm.app ]] && print -n "\e]1337;SetBadgeFormat=\a"
      return 1
    fi
  fi
  TELEPORT_HOME=$phome zsh
  print -n "\e]0;\a"
  [[ $tint != off ]] && print -n "\e]111;\a"          # OSC 111: reset background
  [[ $TERM_PROGRAM == iTerm.app ]] && print -n "\e]1337;SetBadgeFormat=\a"
}
