#compdef ccs
# CCS - Claude Code Switch - Zsh Completion
# Source this file in ~/.zshrc: source ~/.ccs/ccs-completion.zsh

_ccs() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    local provider_conf="${HOME}/.ccs/provider.conf"
    local profiles=()

    # Get profile names from provider.conf
    if [[ -f "$provider_conf" ]]; then
        profiles=(${(f)"$(grep '^\[' "$provider_conf" 2>/dev/null | tr -d '[]')"})
    fi

    local commands=(
        'list:List all profiles'
        'current:Show active profile'
        'clear:Remove project provider config (requires -p)'
        'edit:Open provider.conf in editor'
        'add:Add new profile'
        'remove:Remove profile'
        'test:Test API key/endpoint'
        'backup:Backup settings.json'
        'restore:Restore from backup'
        'update:Update CCS'
        'uninstall:Uninstall CCS'
        'clear:Remove project provider config (requires -p)'
        'version:Show version'
        'help:Show help'
    )

    _arguments -C \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '(-y --yes)'{-y,--yes}'[Skip confirm prompts]' \
        '(-p --project)'{-p,--project}'[Use project-level settings]' \
        '--no-color[Disable colored output]' \
        '1: :->command' \
        '*: :->args' \
        && return 0

    case "$state" in
        command)
            # Combine profiles and commands
            local -a all_options
            all_options=("${profiles[@]}" "${commands[@]}")
            _describe -t commands 'ccs commands' all_options
            ;;
        args)
            case "$line[1]" in
                remove|test)
                    if [[ "$line[1]" == "test" && "$line[CURRENT-1]" == --* ]]; then
                        _arguments '--all[Test all profiles]'
                    else
                        _describe -t profiles 'profiles' profiles
                    fi
                    ;;
                help)
                    _describe -t commands 'commands' commands
                    ;;
                *)
                    _files
                    ;;
            esac
            ;;
    esac
}

_ccs "$@"
