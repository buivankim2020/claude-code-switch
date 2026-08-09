#!/usr/bin/env bash
#
# CCS Install Script
# Install or uninstall Claude Code Switch
#
# Version: 1.4.7
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/user/claude-code-switch/main/install.sh | bash
#   bash install.sh --uninstall

set -e

# Configuration
# Derive version from VERSION file shipped alongside this script
_get_ccs_version() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    local version_file="${script_dir}/VERSION"
    if [[ -f "$version_file" ]]; then
        head -1 "$version_file"
    else
        echo "unknown"
    fi
}
readonly CCS_VERSION="$(_get_ccs_version)"
readonly REPO_URL="https://raw.githubusercontent.com/buivankim2020/claude-code-switch/main"
readonly CCS_DIR="${HOME}/.ccs"

# Colors
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
bold() { echo -e "\033[1m$1\033[0m"; }

info() { echo "→ $1"; }
success() { echo "$(green "✓") $1"; }
warn() { echo "$(yellow "⚠") $1"; }
error() { echo "$(red "✗") $1" >&2; }

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        echo
        echo "Install:"

        local platform
        platform=$(detect_platform)

        case "$platform" in
            linux|wsl)
                echo "  sudo apt update && sudo apt install -y ${missing[*]}"
                ;;
            macos)
                echo "  brew install ${missing[*]}"
                ;;
            *)
                echo "  Please install: ${missing[*]}"
                ;;
        esac
        exit 1
    fi
}

# Ensure ~/.local/bin is in PATH via shell rc
ensure_path() {
    local local_bin="${HOME}/.local/bin"
    case ":${PATH}:" in
        *":${local_bin}:"*) return ;;  # already in PATH
    esac

    local shell_rc=""
    if [[ "${SHELL##*/}" == "zsh" ]]; then
        shell_rc="${HOME}/.zshrc"
    else
        shell_rc="${HOME}/.bashrc"
    fi

    if [[ -f "$shell_rc" ]] && ! grep -q 'export PATH=.*\.local/bin' "$shell_rc" 2>/dev/null; then
        echo >> "$shell_rc"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_rc"
        info "Added ~/.local/bin to PATH in ${shell_rc##*/}"
        warn "Run 'source ~/${shell_rc##*/}' or open a new terminal"
    fi
}

# Get install path for symlink
get_install_path() {
    if [[ -w "/usr/local/bin" ]]; then
        echo "/usr/local/bin/ccs"
    else
        mkdir -p "${HOME}/.local/bin"
        echo "${HOME}/.local/bin/ccs"
    fi
}

# Download file from GitHub
download_file() {
    local filename="$1"
    local dest="$2"

    local url="${REPO_URL}/${filename}"

    if ! curl -fsSL --max-time 60 "$url" -o "$dest" 2>/dev/null; then
        error "Cannot download ${filename}"
        return 1
    fi

    return 0
}

# Install CCS
install_ccs() {
    echo "$(bold "=== CCS Install ===")"
    echo

    # Check dependencies
    check_dependencies

    # Create directories
    mkdir -p "$CCS_DIR"
    mkdir -p "${CCS_DIR}/backups"
    mkdir -p "${CCS_DIR}/custom-model"

    info "Downloading CCS..."

    # Download files
    download_file "ccs.sh" "${CCS_DIR}/ccs.sh"
    download_file "VERSION" "${CCS_DIR}/VERSION"
    download_file "provider.conf.example" "${CCS_DIR}/provider.conf.example"
    download_file "ccs-completion.bash" "${CCS_DIR}/ccs-completion.bash"
    download_file "ccs-completion.zsh" "${CCS_DIR}/ccs-completion.zsh"

    # Optional custom prompt body (repo is source of truth; non-fatal if missing)
    local prompt_dest="${CCS_DIR}/custom-model/gpt-custom-prompt.md"
    if ! download_file "custom-model/gpt-custom-prompt.md" "$prompt_dest" \
        || [[ ! -s "$prompt_dest" ]]; then
        rm -f "$prompt_dest"
        warn "CCS installed without the optional custom prompt file"
    fi

    # Make executable
    chmod +x "${CCS_DIR}/ccs.sh"
    chmod +x "${CCS_DIR}/ccs-completion.bash"
    chmod +x "${CCS_DIR}/ccs-completion.zsh"

    # Create symlink
    local install_path
    install_path=$(get_install_path)

    if [[ -L "$install_path" ]]; then
        rm "$install_path"
    fi

    ln -sf "${CCS_DIR}/ccs.sh" "$install_path"

    success "CCS installed at: $install_path"
    info "Config directory: ${CCS_DIR}"

    # Ensure ~/.local/bin is in PATH
    if [[ "$install_path" == "${HOME}/.local/bin/ccs" ]]; then
        ensure_path
    fi

    # Setup shell completion
    setup_completion

    # Show reload hint if ~/.local/bin was not in PATH
    if [[ "$install_path" == "${HOME}/.local/bin/ccs" ]]; then
        case ":${PATH}:" in
            *":${HOME}/.local/bin:"*) ;;
            *)
                echo
                warn "Run this first to activate ccs:"
                echo
                echo "  source ~/.bashrc"
                echo
                ;;
        esac
    fi

    echo
    echo "$(bold "Next steps:")"
    echo "  1. Run 'ccs' to create provider.conf from template"
    echo "  2. Fill in API keys in provider.conf"
    echo "  3. Run 'ccs <profile>' to switch"
    echo
    echo "$(bold "Help:")"
    echo "  ccs help           # Show help"
    echo "  ccs list           # List profiles"
}

# Setup shell completion
setup_completion() {
    local shell_rc=""

    # Detect shell
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "${SHELL##*/}" == "zsh" ]]; then
        # Zsh
        shell_rc="${HOME}/.zshrc"
        if [[ -f "$shell_rc" ]]; then
            if ! grep -q "ccs-completion.zsh" "$shell_rc" 2>/dev/null; then
                echo >> "$shell_rc"
                echo "# CCS Tab Completion" >> "$shell_rc"
                echo "[[ -f ~/.ccs/ccs-completion.zsh ]] && source ~/.ccs/ccs-completion.zsh" >> "$shell_rc"
                info "Added tab completion to ~/.zshrc"
            fi
        fi
    elif [[ -n "${BASH_VERSION:-}" ]] || [[ "${SHELL##*/}" == "bash" ]]; then
        # Bash
        shell_rc="${HOME}/.bashrc"
        if [[ -f "$shell_rc" ]]; then
            if ! grep -q "ccs-completion.bash" "$shell_rc" 2>/dev/null; then
                echo >> "$shell_rc"
                echo "# CCS Tab Completion" >> "$shell_rc"
                echo "[[ -f ~/.ccs/ccs-completion.bash ]] && source ~/.ccs/ccs-completion.bash" >> "$shell_rc"
                info "Added tab completion to ~/.bashrc"
            fi
        fi
    fi
}

# Uninstall CCS
uninstall_ccs() {
    echo "$(bold "=== CCS Uninstall ===")"
    echo

    local install_path
    install_path=$(get_install_path)

    # Find actual symlink
    local actual_symlink=""
    for path in "/usr/local/bin/ccs" "${HOME}/.local/bin/ccs"; do
        if [[ -L "$path" ]]; then
            actual_symlink="$path"
            break
        fi
    done

    echo "This will:"
    echo "  1. Remove directory ${CCS_DIR}/"
    [[ -n "$actual_symlink" ]] && echo "  2. Remove symlink ${actual_symlink}"
    echo

    read -r -p "Confirm CCS uninstall? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

    # Remove symlink
    if [[ -n "$actual_symlink" ]]; then
        rm "$actual_symlink"
        info "Removed ${actual_symlink}"
    fi

    # Remove directory
    if [[ -d "$CCS_DIR" ]]; then
        rm -rf "$CCS_DIR"
        info "Removed ${CCS_DIR}/"
    fi

    # Remove completion lines from shell rc
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        if [[ -f "$rc" ]]; then
            sed -i.bak '/ccs-completion/d' "$rc" 2>/dev/null || true
            rm -f "${rc}.bak"
        fi
    done

    success "CCS has been completely uninstalled."
}

# Main
main() {
    case "${1:-}" in
        --uninstall|-u)
            uninstall_ccs
            ;;
        --help|-h)
            echo "CCS Install Script"
            echo
            echo "Usage:"
            echo "  bash install.sh           # Install CCS"
            echo "  bash install.sh --uninstall  # Remove CCS"
            ;;
        *)
            install_ccs
            ;;
    esac
}

main "$@"
