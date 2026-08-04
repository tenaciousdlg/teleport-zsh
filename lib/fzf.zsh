# fzf pickers over Teleport resources — fuzzy-find with labels visible,
# hit Enter, connected. Reuses teleport-complete.zsh's per-profile cache
# (sourced after it by teleport.plugin.zsh).
#
#   tss   → pick a node (+ login if the cert has several) → tsh ssh
#   tdb   → pick a database → tsh db connect (db-user/db-name prompted,
#           defaults writer/postgres, override via TSH_DB_USER/TSH_DB_NAME)
#   tapp  → pick an app → tsh apps login + config
#
# Each picker pushes the real tsh command onto shell history, so the
# audience sees a replayable command, not a magic function.

_tsh_fzf_pick() {  # $1 kind, $2 ttl, $3 prompt, rest = fetch cmd → picked name
  (( $+commands[fzf] )) || { print -u2 "fzf not installed (brew install fzf)"; return 1 }
  local kind=$1 ttl=$2 fprompt=$3; shift 3
  local f; f=$(_tsh_cache "$kind" "$ttl" "$@") || { print -u2 "not logged in? (tsh status)"; return 1 }
  local line
  line=$(_tsh_parse "$kind" "$f" | column -t -s$'\t' |
         fzf --height=40% --reverse --prompt="$fprompt ❯ ") || return 1
  print -r -- "${line%% *}"
}

tss() {
  local host login
  host=$(_tsh_fzf_pick nodes 120 node command tsh ls -f json) || return
  local -a logins; logins=(${(f)"$(_tsh_logins)"})
  if (( $#logins > 1 )); then
    login=$(print -l -- $logins | fzf --height=20% --reverse --prompt='login ❯ ') || return
  else
    login=${logins[1]:-$USER}
  fi
  print -s "tsh ssh ${login}@${host}"
  command tsh ssh ${login}@${host}
}

tdb() {
  local db u n
  db=$(_tsh_fzf_pick dbs 120 db command tsh db ls -f json) || return
  read "u?db-user [${TSH_DB_USER:-writer}]: "
  read "n?db-name [${TSH_DB_NAME:-postgres}]: "
  u=${u:-${TSH_DB_USER:-writer}} n=${n:-${TSH_DB_NAME:-postgres}}
  print -s "tsh db connect ${db} --db-user=${u} --db-name=${n}"
  command tsh db connect ${db} --db-user=${u} --db-name=${n}
}

tapp() {
  local app
  app=$(_tsh_fzf_pick apps 120 app command tsh apps ls -f json) || return
  print -s "tsh apps login ${app}"
  command tsh apps login ${app} && command tsh apps config ${app}
}

trec() {  # pick a session recording → tsh play (desktop recordings need the web UI)
  local sid
  sid=$(_tsh_fzf_pick recordings 60 recording command tsh recordings ls -f json) || return
  print -s "tsh play ${sid}"
  command tsh play ${sid}
}
