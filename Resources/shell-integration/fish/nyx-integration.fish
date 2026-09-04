# Nyx shell integration for fish.
#
# Sourced by hand: add the line Nyx shows you in Settings to your fish config.

status is-interactive; or exit 0
set -q NYX_INTEGRATION_LOADED; and exit 0
set -g NYX_INTEGRATION_LOADED 1

function _nyx_report_cwd --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url -- $PWD | string replace -a '%2F' '/')
end

function _nyx_prompt --on-event fish_prompt
    printf '\e]133;A\a'
end

function _nyx_preexec --on-event fish_preexec
    printf '\e]133;C\a'
end

function _nyx_postexec --on-event fish_postexec
    printf '\e]133;D;%s\a' $status
end

# `B` marks the end of the prompt, so it is appended to whatever prompt function is in use.
functions --copy fish_prompt _nyx_original_prompt
function fish_prompt
    _nyx_original_prompt
    printf '\e]133;B\a'
end

_nyx_report_cwd
