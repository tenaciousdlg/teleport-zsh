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
# One tbot config per cluster, named by the cluster's FIRST DNS LABEL:
#   ~/.config/tbot/<short-name>-terraform.yaml   (acme.example.com → acme)
#
# THE FIRST LABEL IS NOT ALWAYS DISTINCTIVE, AND THE FAILURE READS AS A
# BROKEN BOT. Two clusters at teleport.acme.example.com and
# teleport.acme.example.net both shorten to "teleport", so `tfenv teleport`
# silently picks whichever config owns that name — possibly a decommissioned
# cluster's. The error then surfaces as `dial tcp: lookup ...: no such host`,
# which looks like DNS or a dead bot rather than the wrong config file. Name
# the config after something that distinguishes the CLUSTER, not its service
# label, and pass that name explicitly.
#
# Each cluster also needs its OWN storage directory. bound_keypair join state
# (bkp_state, bkp_key_history.json) is per-cluster, so two clusters cannot
# share one storage dir even on the same workstation.
#
# Cluster-side setup (once per cluster, needs an admin session):
#   1. Create a role for the bot (e.g. the terraform-provider preset).
#   2. Create the bot and a bound_keypair token. EITHER tctl or the Kubernetes
#      operator works — see the onboarding note below, which is what decides
#      it.
#        tctl bots add terraform-local --roles=terraform-provider
#        # token: kind token, join_method bound_keypair, recovery
#        # mode standard with a limit sized to your restart cadence —
#        # every re-cert after identity expiry consumes one recovery.
#   3. ONBOARD WITH A PRE-REGISTERED PUBLIC KEY, NOT A REGISTRATION SECRET.
#      Generate the keypair on the workstation with `tbot keypair create`
#      into the storage dir, and put only its PUBLIC half on the token as
#      spec.bound_keypair.onboarding.initial_public_key. A public key is not
#      a secret, so the token is fully describable in a repo with nothing
#      gitignored. When initial_public_key is set, registration_secret is
#      ignored.
#
#      THIS IS ALSO WHAT MAKES AN OPERATOR-MANAGED TOKEN SURVIVABLE, and it
#      corrects an earlier version of this header that said to use tctl and
#      avoid the operator. An operator reconcile DOES wipe bound_public_key,
#      bound_bot_instance_id and recovery_count — but with the key
#      pre-registered the bot simply re-binds on its next join. A
#      registration_secret does NOT survive that, because the re-arm resets
#      the token to awaiting a secret the bot already consumed. So the old
#      "tctl only" advice was treating a symptom of the wrong onboarding
#      method as a property of the operator.
#   4. Write the tbot config with a directory destination whose identity
#      output lands at <storage>/out/identity.
#
# Provider-side, tfenv sets the two documented provider arguments:
# TF_TELEPORT_ADDR and TF_TELEPORT_IDENTITY_FILE_PATH. Note that Teleport's
# own local-auth guide recommends `tctl terraform env` instead; this exists
# because that path costs three admin actions, and therefore three MFA taps,
# on any cluster enforcing MFA for administrative actions.
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
