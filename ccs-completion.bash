#!/usr/bin/env bash
# CCS - Claude Code Switch - Bash Completion
# Source this file in ~/.bashrc: source ~/.ccs/ccs-completion.bash

_ccs_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local commands="list current edit add remove test backup restore update uninstall version help clear"
    local provider_conf="${HOME}/.ccs/provider.conf"

    # Get profile names from provider.conf
    local profiles=""
    if [[ -f "$provider_conf" ]]; then
        profiles=$(grep '^\[' "$provider_conf" 2>/dev/null | tr -d '[]' | tr '\n' ' ')
    fi

    # First argument - flags, commands or profile names
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        local flags="-p --project -y --yes -h --help -v --version --no-color"
        COMPREPLY=($(compgen -W "$flags $commands $profiles" -- "$cur"))
        return
    fi

    # Second+ argument - depends on first command
    local first_cmd="${COMP_WORDS[1]}"

    case "$first_cmd" in
        remove|test|help)
            # These commands take a profile name (or --all for test)
            if [[ "$first_cmd" == "test" && "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "--all" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
            fi
            ;;
        add)
            # add takes a new profile name - no completion
            COMPREPLY=()
            ;;
        *)
            # Other commands don't take arguments
            COMPREPLY=()
            ;;
    esac
}

complete -F _ccs_completions ccs
