# Nyx's ZDOTDIR shim: .zlogin -- see .zshenv for why these exist.
[[ -f ${NYX_USER_ZDOTDIR:-$HOME}/.zlogin ]] && source "${NYX_USER_ZDOTDIR:-$HOME}/.zlogin"
