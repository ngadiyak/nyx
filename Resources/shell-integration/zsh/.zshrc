# Nyx's ZDOTDIR shim: .zshrc -- see .zshenv for why these exist.
#
# Order matters here. The user's configuration is sourced first so that the integration appends its
# end-of-prompt mark to the prompt they actually ended up with; then ZDOTDIR is put back, so a zsh
# started from inside this one sees the value the user set rather than ours.

_nyx_shim_dir=${ZDOTDIR:-$HOME}
_nyx_user_dir=${NYX_USER_ZDOTDIR:-$HOME}

[[ -f $_nyx_user_dir/.zshrc ]] && source "$_nyx_user_dir/.zshrc"

if [[ -n $NYX_ZDOTDIR ]]; then
  ZDOTDIR=$NYX_ZDOTDIR
else
  unset ZDOTDIR
fi
unset NYX_ZDOTDIR NYX_USER_ZDOTDIR

[[ -f $_nyx_shim_dir/nyx-integration.zsh ]] && source "$_nyx_shim_dir/nyx-integration.zsh"
unset _nyx_shim_dir _nyx_user_dir
