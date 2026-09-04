# Nyx shell integration for bash.
#
# bash has no ZDOTDIR equivalent and its startup-file rules differ between login and interactive
# shells, so this one is sourced by hand. Add the line Nyx shows you in Settings to your ~/.bashrc.

case $- in *i*) ;; *) return 0 ;; esac
[[ -n $NYX_INTEGRATION_LOADED ]] && return 0
NYX_INTEGRATION_LOADED=1

_nyx_report_cwd() {
  local encoded="" i char
  local LC_ALL=C
  for (( i = 0; i < ${#PWD}; i++ )); do
    char=${PWD:i:1}
    case $char in
      [A-Za-z0-9/._~-]) encoded+=$char ;;
      *) encoded+=$(printf '%%%02X' "'$char") ;;
    esac
  done
  printf '\e]7;file://%s%s\a' "${HOSTNAME}" "$encoded"
}

# Runs before each prompt. The exit status must be read on the first line, before anything else can
# overwrite it.
_nyx_prompt() {
  local exit_status=$?
  if [[ -n $_nyx_command_running ]]; then
    printf '\e]133;D;%s\a' "$exit_status"
    unset _nyx_command_running
  fi
  _nyx_report_cwd
  printf '\e]133;A\a'
}

# bash has no preexec, but the DEBUG trap fires before each command. It must not fire for the prompt
# command itself, hence the guard.
_nyx_preexec() {
  [[ -n $COMP_LINE ]] && return
  [[ $BASH_COMMAND == _nyx_prompt* ]] && return
  [[ -n $_nyx_command_running ]] && return
  _nyx_command_running=1
  printf '\e]133;C\a'
}

PROMPT_COMMAND="_nyx_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
trap '_nyx_preexec' DEBUG

# `B` marks the end of the prompt. \[...\] tells readline the sequence occupies no columns, without
# which the prompt is mismeasured and line editing corrupts the display.
if [[ $PS1 != *'133;B'* ]]; then
  PS1="${PS1}\[\e]133;B\a\]"
fi
