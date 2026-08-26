# Destroy guard for terraform — born from a 2026-07-29 incident where a
# `terraform destroy` in the wrong directory took out a demo cluster's
# prod-access role. Before any destroy (or apply -destroy) it shows exactly what's in the
# blast radius — directory, workspace, backend, Teleport proxy if one is
# configured — and requires typing the target's name to proceed.
#
#   TF_DESTROY_GUARD=off terraform destroy ...   # bypass (also off when
#   non-interactive, so CI and scripts are never blocked)

terraform() {
  if [[ ! -o interactive || $TF_DESTROY_GUARD == off ]]; then
    command terraform "$@"; return
  fi
  local a destroyish=0 sub=""
  for a in "$@"; do
    [[ $a == -* ]] || { sub=$a; break }
  done
  [[ $sub == destroy ]] && destroyish=1
  if [[ $sub == apply ]]; then
    for a in "$@"; do [[ $a == -destroy ]] && destroyish=1; done
  fi
  if (( ! destroyish )); then
    command terraform "$@"; return
  fi

  local dir=${PWD/#$HOME/\~}
  local ws; ws=$(command terraform workspace show 2>/dev/null)
  local backend=""
  if [[ -r .terraform/terraform.tfstate ]]; then
    backend=$(python3 - <<'PY' 2>/dev/null
import json
try:
    b = json.load(open(".terraform/terraform.tfstate")).get("backend", {})
    cfg = b.get("config") or {}
    keep = {k: cfg[k] for k in ("bucket", "key", "path", "region") if cfg.get(k)}
    print(b.get("type", "?"), " ".join(f"{k}={v}" for k, v in keep.items()))
except Exception:
    pass
PY
    )
  fi
  # Teleport proxy this config talks to (blast radius), from tf files or env.
  local -a proxies tffiles
  tffiles=(*.tf(N) *.tfvars(N))
  (( $#tffiles )) && proxies=(${(f)"$(grep -rhoE '(proxy_address|addr)[[:space:]]*=[[:space:]]*"[^"]+"' -- $tffiles 2>/dev/null |
                   grep -oE '"[^"]+"' | tr -d '"' | sort -u)"})
  [[ -n $TF_VAR_proxy_address ]] && proxies+=("$TF_VAR_proxy_address (env)")

  local token=${${proxies[1]%%[.:]*}:-${PWD:t}}

  print -u2 ""
  print -u2 -P "%F{1}%B╳ DESTROY GUARD%b%f — terraform ${sub} in:"
  print -u2 -P "   %Bdir%b        $dir"
  [[ -n $ws ]]       && print -u2 -P "   %Bworkspace%b  $ws"
  [[ -n $backend ]]  && print -u2 -P "   %Bbackend%b    $backend"
  (( $#proxies ))    && print -u2 -P "   %F{1}%Bteleport%b   ${(j:, :)proxies}  ← blast radius%f"
  [[ -n $AWS_PROFILE ]] && print -u2 -P "   %Baws%b        AWS_PROFILE=$AWS_PROFILE"
  # With several live sessions, "wrong active cluster" is the easy mistake:
  # tctl/provider auth follows the ACTIVE profile, not the directory. Always
  # show the active session — infra layers (VPC/EKS) often host a cluster
  # without declaring a teleport provider, so the tf files alone can't name
  # the blast radius.
  local tpdir=${TELEPORT_HOME:-$HOME/.tsh} activeprof=""
  [[ -r $tpdir/current-profile ]] && activeprof=$(<$tpdir/current-profile)
  [[ -n $activeprof ]] && print -u2 -P "   %Btsh%b        active session: ${activeprof%%.*}"
  if [[ -n $activeprof ]] && (( $#proxies )) && [[ ${proxies[1]%%:*} != $activeprof ]]; then
    print -u2 -P "   %F{1}%B⚠ mismatch%b  active tsh session is ${activeprof%%.*}, this config targets ${${proxies[1]%%:*}%%.*}%f"
  fi
  if (( $#tffiles )) && grep -qsE 'teleport_operator|teleport-cluster' -- $tffiles 2>/dev/null; then
    print -u2 -P "   %F{3}hint: if destroy hangs on Teleport CRDs, strip finalizers:%f"
    print -u2 -P "   %F{3}kubectl get crds -o name | grep teleport | xargs -I{} kubectl patch {} -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge%f"
  fi
  local REPLY
  read -r "REPLY?Type '${token}' to proceed, anything else aborts: "
  if [[ $REPLY != $token ]]; then
    print -u2 -P "%F{1}aborted%f (nothing destroyed)"
    return 1
  fi
  command terraform "$@"
}
