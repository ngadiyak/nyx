# Nyx's ZDOTDIR shim: .zshrc -- see .zshenv for why these exist.
#
# ZDOTDIR is put back FIRST, before anything else runs. That ordering is load-bearing.
#
# macOS's own /etc/zshrc contains `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history`, and it runs before
# this file. With ZDOTDIR still pointing at the shim, every command the user typed would be written
# into the application bundle: lost on the next upgrade, shared with everyone else on the machine,
# and their real ~/.zsh_history would quietly stop growing. So the variable goes back, HISTFILE is
# repaired if it was aimed at us, and only then is the user's configuration sourced -- which leaves
# them free to set HISTFILE to whatever they like, as they could without Nyx in the picture.

_nyx_shim_dir=${ZDOTDIR:-$HOME}
_nyx_user_dir=${NYX_USER_ZDOTDIR:-$HOME}

if [[ -n $NYX_ZDOTDIR ]]; then
  ZDOTDIR=$NYX_ZDOTDIR
else
  unset ZDOTDIR
fi
unset NYX_ZDOTDIR NYX_USER_ZDOTDIR

# Only if it points inside the shim: a user who set it themselves keeps their choice.
if [[ $HISTFILE == $_nyx_shim_dir/* ]]; then
  HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history
fi

[[ -f ${_nyx_user_dir}/.zshrc ]] && source "${_nyx_user_dir}/.zshrc"

# The marks go on last, so they append to whatever prompt the user ended up with.
[[ -f $_nyx_shim_dir/nyx-integration.zsh ]] && source "$_nyx_shim_dir/nyx-integration.zsh"
unset _nyx_shim_dir _nyx_user_dir
