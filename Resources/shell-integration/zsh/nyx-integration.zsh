# Nyx shell integration for zsh.
#
# Emits the OSC 133 marks that tell the terminal where a prompt begins, where the user's typing
# begins, where a command's output begins and how the command ended. Without these, jumping between
# commands, the status gutter, "copy the last command's output" and the completion notification have
# nothing to work from.
#
# Sourced automatically through ZDOTDIR; nothing in your home directory is modified.

# Only interactive shells have a prompt to mark.
[[ -o interactive ]] || return 0
# Guard against being sourced twice -- once automatically and once from a hand-edited rc file.
[[ -n $NYX_INTEGRATION_LOADED ]] && return 0
NYX_INTEGRATION_LOADED=1

autoload -Uz add-zsh-hook

# OSC 7: tells the terminal the working directory, which is how a new pane or tab opens where you
# already are. The path is percent-encoded because it is a URL, and paths contain spaces.
_nyx_report_cwd() {
  local encoded="" char
  local LC_ALL=C
  for (( i = 1; i <= ${#PWD}; i++ )); do
    char=${PWD[i]}
    case $char in
      [A-Za-z0-9/._~-]) encoded+=$char ;;
      *) encoded+=$(printf '%%%02X' "'$char") ;;
    esac
  done
  printf '\e]7;file://%s%s\a' "${HOST}" "$encoded"
}

# Runs before each prompt. The exit status has to be captured on the very first line: anything else
# here would overwrite $?.
_nyx_precmd() {
  # `status` is read-only in zsh -- a synonym for `$?` -- so naming it that makes the hook fail
  # on its first line and silently disables every mark. Kept the same name in bash for symmetry.
  local exit_status=$?
  if [[ -n $_nyx_command_running ]]; then
    printf '\e]133;D;%s\a' "$exit_status"
    unset _nyx_command_running
  fi
  _nyx_report_cwd
  printf '\e]133;A\a'
}

# Runs when a command is about to execute.
_nyx_preexec() {
  _nyx_command_running=1
  printf '\e]133;C\a'
}

add-zsh-hook precmd _nyx_precmd
add-zsh-hook preexec _nyx_preexec

# `B` marks the end of the prompt, so it belongs at the end of PS1 rather than in a hook. The
# %{...%} wrapper tells zsh the sequence prints nothing, without which every prompt would be
# mismeasured and line editing would corrupt the display.
if [[ $PS1 != *'133;B'* ]]; then
  PS1="${PS1}"$'%{\e]133;B\a%}'
fi
