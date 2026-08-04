# teleport-zsh — shell integration for Teleport (https://goteleport.com)
#
# Prompt segment (powerlevel10k), dynamic tsh tab-completion, fzf pickers,
# persona shells, demo helpers, and a terraform destroy guard.
# See README.md for installation and configuration.

0=${(%):-%N}
typeset -g TELEPORT_ZSH_DIR=${0:A:h}

source "$TELEPORT_ZSH_DIR/lib/prompt.zsh"
source "$TELEPORT_ZSH_DIR/lib/profiles.zsh"   # tprofiles (uses prompt.zsh cert helpers)
source "$TELEPORT_ZSH_DIR/lib/complete.zsh"   # must load before fzf.zsh (shared cache helpers)
source "$TELEPORT_ZSH_DIR/lib/fzf.zsh"
source "$TELEPORT_ZSH_DIR/lib/persona.zsh"
source "$TELEPORT_ZSH_DIR/lib/demo.zsh"

# The destroy guard wraps `terraform`; opt out with TELEPORT_ZSH_NO_GUARD=1.
[[ -n $TELEPORT_ZSH_NO_GUARD ]] || source "$TELEPORT_ZSH_DIR/lib/terraform-guard.zsh"
