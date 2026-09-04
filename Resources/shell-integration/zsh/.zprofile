# Nyx's ZDOTDIR shim: .zprofile -- see .zshenv for why these exist.
[[ -f ${NYX_USER_ZDOTDIR:-$HOME}/.zprofile ]] && source "${NYX_USER_ZDOTDIR:-$HOME}/.zprofile"
