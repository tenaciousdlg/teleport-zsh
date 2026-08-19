# tfenv — Teleport terraform-provider credentials without the MFA storm.
#
# `eval $(tctl terraform env)` creates an ephemeral bot + role + token on
# every run — three admin actions, which means three hardware-key taps on
# clusters that enforce admin-action MFA. tfenv instead re-certs a
# PERSISTENT Machine ID bot over its bound keypair (bots are exempt from
# admin MFA): silent, sub-second when the identity is still fresh, and the
# certificates stay short-lived.
#
#   tfenv               # bot for the active cluster (~/.tsh/current-profile)
#   tfenv acme          # bot for a specific cluster, by short name
#   TFENV_FORCE=1 tfenv # re-cert even if the current identity looks fresh
#
# One tbot config per cluster, named by the cluster's first DNS label:
#   ~/.config/tbot/<short-name>-terraform.yaml   (acme.example.com → acme)
#
# Cluster-side setup (once per cluster, needs an admin session):
#   1. Create a role for the bot (e.g. the terraform-provider preset).
#   2. Create the bot and a bound_keypair token — create them with tctl,
#      NOT via the Kubernetes operator: operator reconciles re-arm the
#      token's onboarding and silently invalidate the bot's binding.
#        tctl bots add terraform-local --roles=terraform-provider
#        # token: kind token, join_method bound_keypair, recovery
#        # mode standard with a limit sized to your restart cadence —
#        # every re-cert after identity expiry consumes one recovery.
#   3. Write the tbot config with a directory destination whose identity
#      output lands at <storage>/out/identity, and put the one-time
#      registration secret in it for the first bind.
#
# Recovery economics: with a 1h identity TTL, each tfenv run more than an
# hour after the last burns one bound-keypair recovery. The freshness skip
# below avoids pointless burns; size the token's recovery limit generously
# (a daily terraform user needs ~30/month).

tfenv() {
  emulate -L zsh
  zmodload zsh/stat zsh/datetime 2>/dev/null
  # Guard the freshness math: if EPOCHSECONDS is somehow unavailable the
  # comparison must fail OPEN (re-cert) — a stale skip is the worse failure.
  local now=${EPOCHSECONDS:-0}

  local name=$1
  if [[ -z $name && -r $HOME/.tsh/current-profile ]]; then
    name=$(<$HOME/.tsh/current-profile)
  fi
  if [[ -z $name ]]; then
    print -u2 "tfenv: no cluster — pass a name or tsh login first"
    return 1
  fi
  name=${name%%.*}   # acme.example.com → acme

  local cfg=$HOME/.config/tbot/${name}-terraform.yaml
  if [[ ! -r $cfg ]]; then
    print -u2 "tfenv: no tbot config for '${name}' ($cfg)"
    print -u2 "tfenv: cluster-side + config recipe: see the header of ${(%):-%x}"
    return 1
  fi

  local addr identity
  addr=$(awk '/^proxy_server:/ {print $2}' "$cfg")
  identity="$(awk '/outputs:/ {o=1} o && /path:/ {print $2; exit}' "$cfg")/identity"
  if [[ -z $addr || $identity == "/identity" ]]; then
    print -u2 "tfenv: could not parse proxy_server / output path from $cfg"
    return 1
  fi

  # Skip the re-cert when the identity is younger than TFENV_MAX_AGE seconds
  # (default 45m against the usual 1h TTL) — every post-expiry rejoin burns
  # one bound-keypair recovery, so don't spend them on fresh identities.
  local -a mt
  local age=999999
  if (( now > 0 )) && [[ -r $identity ]] && zstat -A mt +mtime -- "$identity" 2>/dev/null; then
    age=$(( now - mt[1] ))
  fi
  if [[ -n $TFENV_FORCE ]] || (( age > ${TFENV_MAX_AGE:-2700} )); then
    local out
    if ! out=$(command tbot start -c "$cfg" --oneshot 2>&1); then
      # First post-expiry rejoins occasionally blip; one retry mirrors what a
      # human would do before digging in.
      if ! out=$(command tbot start -c "$cfg" --oneshot 2>&1); then
        print -u2 "tfenv: tbot re-cert failed twice — last error:"
        print -u2 -- "${$(print -r -- $out | grep -E 'Original Error|ERRO' | grep -v 'ERROR REPORT' | head -2):-$(print -r -- $out | tail -2)}"
        print -u2 "tfenv: debug with: tbot start -c $cfg --oneshot"
        return 1
      fi
    fi
  fi

  local note=""
  (( age <= ${TFENV_MAX_AGE:-2700} )) && [[ -z $TFENV_FORCE ]] && note=", identity fresh — re-cert skipped"

  export TF_TELEPORT_ADDR=$addr
  export TF_TELEPORT_IDENTITY_FILE_PATH=$identity
  print -P "%F{2}tfenv:%f ${addr} via ${cfg:t} (no MFA${note})"
}
