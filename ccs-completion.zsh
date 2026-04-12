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
        'list:Liệt kê tất cả profiles'
        'current:Hiển thị profile đang active'
        'edit:Mở provider.conf trong editor'
        'add:Thêm profile mới'
        'remove:Xóa profile'
        'test:Test API key/endpoint'
        'backup:Backup settings.json'
        'restore:Khôi phục từ backup'
        'update:Cập nhật CCS'
        'uninstall:Gỡ cài đặt CCS'
        'version:Hiển thị phiên bản'
        'help:Hiển thị hướng dẫn'
    )

    _arguments -C \
        '(-h --help)'{-h,--help}'[Hiển thị hướng dẫn]' \
        '(-v --version)'{-v,--version}'[Hiển thị phiên bản]' \
        '(-y --yes)'{-y,--yes}'[Bỏ qua confirm prompts]' \
        '--no-color[Tắt màu output]' \
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
