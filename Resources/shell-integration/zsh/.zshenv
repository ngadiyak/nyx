# Nyx's ZDOTDIR shim: .zshenv
#
# Nyx points ZDOTDIR at this directory so it can add shell integration without editing anything in
# your home directory. The catch is that zsh then looks for *all* of its startup files here, so each
# one needs a shim that sources yours -- without this, ~/.zshenv would silently stop running, and
# for most people that is where PATH is set.
#
# ZDOTDIR stays pointed here until .zshrc has finished, so zsh keeps finding the rest of these
# shims; .zshrc puts it back the way you had it at the very end.

NYX_USER_ZDOTDIR=${NYX_ZDOTDIR:-$HOME}
[[ -f $NYX_USER_ZDOTDIR/.zshenv ]] && source "$NYX_USER_ZDOTDIR/.zshenv"
