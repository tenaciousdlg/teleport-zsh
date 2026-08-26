# tctl target banner — tctl mutates whatever cluster is ACTIVE, and with
# tcycle making profile switches cheap, the easy mistake is running an
# admin command against the wrong one. Before any mutating subcommand, a
# dim one-liner names the target:
#
#   ❯ tctl rm roles/dev-access
#   tctl → acme.example.com
#
# Read-only subcommands (get, status, acl, ...) stay silent. Disable the
# wrapper entirely with TELEPORT_ZSH_NO_TCTL=1 (set before the plugin loads).

if [[ -z $TELEPORT_ZSH_NO_TCTL ]]; then
  tctl() {
    case ${1:-} in
      rm|create|edit|users|lock|tokens|bots|nodes|auth|request|requests|plugins)
        local tdir=${TELEPORT_HOME:-$HOME/.tsh} prof=""
        [[ -r $tdir/current-profile ]] && prof=$(<$tdir/current-profile)
        [[ -n $prof ]] && print -u2 -P "%F{8}tctl → %B${prof}%b%f"
        ;;
    esac
    command tctl "$@"
  }
fi
