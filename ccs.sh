#!/usr/bin/env bash
#
# CCS - Claude Code Switch
# Quick switch between multiple AI provider profiles for Claude Code
#
# Version: 1.0.4
# License: MIT

set -euo pipefail

#==============================================================================
# Constants
#==============================================================================
readonly CCS_VERSION="1.0.4"
readonly CCS_DIR="${HOME}/.ccs"
readonly CONFIG_FILE="${CCS_DIR}/config.env"
readonly PROVIDER_CONF="${CCS_DIR}/provider.conf"
readonly PROVIDER_EXAMPLE="${CCS_DIR}/provider.conf.example"
readonly BACKUP_DIR="${CCS_DIR}/backups"
readonly UPDATE_CHECK_FILE="${CCS_DIR}/.update_check"
readonly REPO_URL="https://raw.githubusercontent.com/buivankim2020/claude-code-switch/main"

# Required keys for each profile
readonly REQUIRED_KEYS=(
    "ANTHROPIC_AUTH_TOKEN"
    "ANTHROPIC_BASE_URL"
    "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    "ANTHROPIC_DEFAULT_OPUS_MODEL"
    "ANTHROPIC_DEFAULT_SONNET_MODEL"
)

# Available commands
readonly COMMANDS="list current edit add remove test backup restore update uninstall version help"

#==============================================================================
# Platform Detection
#==============================================================================
detect_platform() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

get_settings_path() {
    # Check for user override first
    if [[ -n "${CCS_SETTINGS_PATH:-}" ]]; then
        echo "$CCS_SETTINGS_PATH"
        return
    fi

    local platform
    platform="$(detect_platform)"

    case "$platform" in
        wsl)
            # Check if running in WSL native mode
            if [[ -f "${HOME}/.claude/settings.json" ]]; then
                echo "${HOME}/.claude/settings.json"
            else
                # Windows-side Claude Code
                local win_user
                win_user=$(cmd.exe /C "echo %USERNAME%" 2>/dev/null | tr -d '\r' || echo "")
                if [[ -n "$win_user" ]]; then
                    echo "/mnt/c/Users/${win_user}/.claude/settings.json"
                else
                    echo "${HOME}/.claude/settings.json"
                fi
            fi
            ;;
        linux|macos|*)
            echo "${HOME}/.claude/settings.json"
            ;;
    esac
}

#==============================================================================
# Color & Output Helpers
#==============================================================================
_use_color=true

# Auto-disable colors when piping
if [[ ! -t 1 ]]; then
    _use_color=false
fi

red() { if $_use_color; then echo -e "\033[31m$1\033[0m"; else echo "$1"; fi; }
green() { if $_use_color; then echo -e "\033[32m$1\033[0m"; else echo "$1"; fi; }
yellow() { if $_use_color; then echo -e "\033[33m$1\033[0m"; else echo "$1"; fi; }
bold() { if $_use_color; then echo -e "\033[1m$1\033[0m"; else echo "$1"; fi; }

error() { echo "$(red "✗") $1" >&2; }
success() { echo "$(green "✓") $1"; }
warn() { echo "$(yellow "⚠") $1"; }
info() { echo "→ $1"; }

#==============================================================================
# Input & Confirmation
#==============================================================================
_auto_yes=false

confirm() {
    local prompt="$1"
    if $_auto_yes; then
        return 0
    fi
    read -r -p "$prompt (y/n): " response
    [[ "$response" =~ ^[Yy]$ ]]
}

#==============================================================================
# Profile Config Management
#==============================================================================
get_active_profile() {
    if [[ -f "$CONFIG_FILE" ]]; then
        grep "^ACTIVE_PROFILE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo ""
    else
        echo ""
    fi
}

set_active_profile() {
    local profile="$1"
    mkdir -p "$CCS_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        if grep -q "^ACTIVE_PROFILE=" "$CONFIG_FILE"; then
            sed -i.bak "s/^ACTIVE_PROFILE=.*/ACTIVE_PROFILE=${profile}/" "$CONFIG_FILE"
            rm -f "${CONFIG_FILE}.bak"
        else
            echo "ACTIVE_PROFILE=${profile}" >> "$CONFIG_FILE"
        fi
    else
        echo "ACTIVE_PROFILE=${profile}" > "$CONFIG_FILE"
    fi
}

list_profiles() {
    if [[ ! -f "$PROVIDER_CONF" ]]; then
        return
    fi
    grep '^\[' "$PROVIDER_CONF" | tr -d '[]' | sort
}

read_profile() {
    local profile="$1"
    local in_section=false
    local key value

    if [[ ! -f "$PROVIDER_CONF" ]]; then
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Check for section
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            section="${BASH_REMATCH[1]}"
            if [[ "$section" == "$profile" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi

        # Read key=value if in target section
        if $in_section && [[ "$line" =~ ^([A-Z_]+)=(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Trim trailing comment
            value="${value%%#*}"
            # Trim whitespace
            value="${value%% }"
            value="${value## }"
            echo "${key}=${value}"
        fi
    done < "$PROVIDER_CONF"
}

validate_conf() {
    local errors=()
    local in_section=false
    local section=""
    local -a sections=()
    local -a current_keys=()

    if [[ ! -f "$PROVIDER_CONF" ]]; then
        error "Not found: ${PROVIDER_CONF}"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            # Validate previous section if exists
            if [[ -n "$section" ]]; then
                for key in "${REQUIRED_KEYS[@]}"; do
                    if ! echo "${current_keys[*]}" | grep -qw "$key"; then
                        errors+=("[$section]: Missing $key")
                    fi
                done
            fi

            section="${BASH_REMATCH[1]}"
            if echo "${sections[*]}" | grep -qw "$section"; then
                errors+=("Duplicate section: [$section]")
            fi
            sections+=("$section")
            current_keys=()
            continue
        fi

        if [[ -n "$section" && "$line" =~ ^([A-Z_]+)= ]]; then
            key="${BASH_REMATCH[1]}"
            # Check for typos
            local valid=false
            for req in "${REQUIRED_KEYS[@]}"; do
                if [[ "$key" == "$req" ]]; then
                    valid=true
                    break
                fi
            done
            if ! $valid; then
                # Check similar keys
                if [[ "$key" == "ANTHROPIC_BASE_URLS" ]]; then
                    errors+=("[$section]: Invalid key: $key (did you mean ANTHROPIC_BASE_URL?)")
                else
                    errors+=("[$section]: Invalid key: $key")
                fi
            else
                current_keys+=("$key")
            fi
        fi
    done < "$PROVIDER_CONF"

    # Validate last section
    if [[ -n "$section" ]]; then
        for key in "${REQUIRED_KEYS[@]}"; do
            if ! echo "${current_keys[*]}" | grep -qw "$key"; then
                errors+=("[$section]: Missing $key")
            fi
        done
    fi

    # Check if any sections exist
    if [[ ${#sections[@]} -eq 0 ]]; then
        errors+=("No profiles found")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        error "Errors in ${PROVIDER_CONF}:"
        for err in "${errors[@]}"; do
            echo "  - $err" >&2
        done
        return 1
    fi

    return 0
}

#==============================================================================
# Backup Management
#==============================================================================
backup_settings() {
    local settings_path
    settings_path="$(get_settings_path)"

    mkdir -p "$BACKUP_DIR"

    if [[ -f "$settings_path" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        cp "$settings_path" "${BACKUP_DIR}/settings.backup.${timestamp}.json"
        info "Backup settings.json"
        cleanup_backups
    fi
}

cleanup_backups() {
    local max_backups=10
    local count

    count=$(ls -1 "${BACKUP_DIR}/"*.json 2>/dev/null | wc -l)

    if [[ $count -gt $max_backups ]]; then
        ls -1t "${BACKUP_DIR}/"*.json | tail -n +$((max_backups + 1)) | xargs rm -f
    fi
}

cmd_restore() {
    local backups
    backups=$(ls -1 "${BACKUP_DIR}/"*.json 2>/dev/null | sort -r)

    if [[ -z "$backups" ]]; then
        error "No backups found"
        return 1
    fi

    echo "Available backups:"
    local i=1
    local backup_array=()
    while IFS= read -r backup; do
        local name
        name=$(basename "$backup")
        echo "  $i. $name"
        backup_array+=("$backup")
        ((i++))
    done <<< "$backups"

    read -r -p "Select backup (number): " choice
    if [[ -z "${backup_array[$((choice-1))]:-}" ]]; then
        error "Invalid selection"
        return 1
    fi

    local selected
    selected="${backup_array[$((choice-1))]}"
    local settings_path
    settings_path="$(get_settings_path)"

    if confirm "Restore from $(basename "$selected")?"; then
        mkdir -p "$(dirname "$settings_path")"
        cp "$selected" "$settings_path"
        success "Restored settings.json"
    fi
}

#==============================================================================
# Settings.json Management
#==============================================================================
ensure_settings_exists() {
    local settings_path
    settings_path="$(get_settings_path)"

    if [[ ! -f "$settings_path" ]]; then
        if confirm "settings.json not found. Create at: $settings_path?"; then
            mkdir -p "$(dirname "$settings_path")"
            echo '{}' > "$settings_path"
            info "Created $settings_path"
        else
            return 1
        fi
    fi
}

update_settings_json() {
    local token="$1"
    local url="$2"
    local haiku="$3"
    local opus="$4"
    local sonnet="$5"
    local settings_path
    settings_path="$(get_settings_path)"

    # Create temp file
    local tmpfile
    tmpfile=$(mktemp)

    # Use jq to update only the 5 env keys
    jq --arg token "$token" \
       --arg url "$url" \
       --arg haiku "$haiku" \
       --arg opus "$opus" \
       --arg sonnet "$sonnet" \
       '.env = (.env // {}) |
        .env.ANTHROPIC_AUTH_TOKEN = $token |
        .env.ANTHROPIC_BASE_URL = $url |
        .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $haiku |
        .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $opus |
        .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet' \
       "$settings_path" > "$tmpfile"

    mv "$tmpfile" "$settings_path"
    info "Updated settings.json"
}

#==============================================================================
# Commands
#==============================================================================
cmd_switch() {
    local profile="$1"

    # Check if profile exists
    local found=false
    local p
    for p in $(list_profiles); do
        if [[ "$p" == "$profile" ]]; then
            found=true
            break
        fi
    done

    if ! $found; then
        error "Profile \"$profile\" does not exist"
        local available
        available=$(list_profiles | tr '\n' ', ' | sed 's/, $//')
        [[ -n "$available" ]] && echo "  Available profiles: $available" >&2
        return 1
    fi

    # Read profile values
    local config
    config=$(read_profile "$profile")
    if [[ -z "$config" ]]; then
        error "Cannot read profile \"$profile\""
        return 1
    fi

    # Parse values
    local token url haiku opus sonnet
    while IFS='=' read -r key value; do
        case "$key" in
            ANTHROPIC_AUTH_TOKEN) token="$value" ;;
            ANTHROPIC_BASE_URL) url="$value" ;;
            ANTHROPIC_DEFAULT_HAIKU_MODEL) haiku="$value" ;;
            ANTHROPIC_DEFAULT_OPUS_MODEL) opus="$value" ;;
            ANTHROPIC_DEFAULT_SONNET_MODEL) sonnet="$value" ;;
        esac
    done <<< "$config"

    # Validate all required keys present
    if [[ -z "${token:-}" || -z "${url:-}" || -z "${haiku:-}" || -z "${opus:-}" || -z "${sonnet:-}" ]]; then
        error "Profile \"$profile\" is missing required fields"
        return 1
    fi

    # Ensure settings.json exists
    if ! ensure_settings_exists; then
        return 1
    fi

    # Backup first
    backup_settings

    # Update settings
    update_settings_json "$token" "$url" "$haiku" "$opus" "$sonnet"

    # Save active profile
    set_active_profile "$profile"

    # Ask to reload VSCode
    if confirm "Reload VSCode to apply?"; then
        # Try to reload VSCode
        if command -v code &>/dev/null; then
            # Check if running in VSCode terminal
            if [[ -n "${VSCODE_PID:-}" ]] || [[ -n "${TERM_PROGRAM:-}" ]]; then
                info "Please reload VSCode: Ctrl+Shift+P → Reload Window"
            else
                info "Please reload VSCode: Ctrl+Shift+P → Reload Window"
            fi
        else
            info "Please reload VSCode: Ctrl+Shift+P → Reload Window"
        fi
    fi

    success "Switched to profile: $profile"
    echo "  Base URL: $url"
    echo "  Haiku:    $haiku"
    echo "  Opus:     $opus"
    echo "  Sonnet:   $sonnet"
}

cmd_list() {
    local active
    active="$(get_active_profile)"

    echo "$(bold "Available profiles:")"
    local profile
    for profile in $(list_profiles); do
        if [[ "$profile" == "$active" ]]; then
            echo "  $(green "●") $profile $(green "(active)")"
        else
            echo "  ○ $profile"
        fi
    done
}

cmd_current() {
    local active
    active="$(get_active_profile)"

    if [[ -n "$active" ]]; then
        echo "Active profile: $(bold "$active")"
    else
        warn "No profile is currently active"
    fi
}

cmd_edit() {
    local editor="${EDITOR:-vi}"

    if [[ ! -f "$PROVIDER_CONF" ]]; then
        warn "No provider.conf found."
        info "Run \"ccs add <name>\" to create your first profile."
        return 1
    fi

    # Save original checksum
    local original_checksum
    original_checksum=$(md5sum "$PROVIDER_CONF" 2>/dev/null || echo "")

    # Open editor
    $editor "$PROVIDER_CONF"

    # Validate after edit
    local new_checksum
    new_checksum=$(md5sum "$PROVIDER_CONF" 2>/dev/null || echo "")

    if [[ "$original_checksum" != "$new_checksum" ]]; then
        info "Validating provider.conf..."
        if validate_conf; then
            success "provider.conf is valid"
            local count
            count=$(list_profiles | wc -l)
            info "Found $count profiles"
        else
            if confirm "Reopen editor to fix?"; then
                cmd_edit
            fi
        fi
    fi
}

cmd_add() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        read -r -p "Profile name: " name
    fi

    if [[ -z "$name" ]]; then
        error "Profile name cannot be empty"
        return 1
    fi

    # Check if exists
    if list_profiles | grep -qx "$name"; then
        error "Profile \"$name\" already exists"
        return 1
    fi

    echo "=== Add profile: $name ==="
    echo

    local token url haiku opus sonnet
    read -r -p "ANTHROPIC_AUTH_TOKEN: " token
    read -r -p "ANTHROPIC_BASE_URL: " url
    read -r -p "ANTHROPIC_DEFAULT_HAIKU_MODEL: " haiku
    read -r -p "ANTHROPIC_DEFAULT_OPUS_MODEL: " opus
    read -r -p "ANTHROPIC_DEFAULT_SONNET_MODEL: " sonnet

    # Validate
    if [[ -z "$token" || -z "$url" || -z "$haiku" || -z "$opus" || -z "$sonnet" ]]; then
        error "All fields are required"
        return 1
    fi

    # Append to config
    mkdir -p "$CCS_DIR"
    chmod 600 "$PROVIDER_CONF" 2>/dev/null || true

    cat >> "$PROVIDER_CONF" << EOF

[${name}]
ANTHROPIC_AUTH_TOKEN=${token}
ANTHROPIC_BASE_URL=${url}
ANTHROPIC_DEFAULT_HAIKU_MODEL=${haiku}
ANTHROPIC_DEFAULT_OPUS_MODEL=${opus}
ANTHROPIC_DEFAULT_SONNET_MODEL=${sonnet}
EOF

    chmod 600 "$PROVIDER_CONF"
    success "Added profile [${name}] to provider.conf"
    info "Run \"ccs ${name}\" to use it."
}

cmd_remove() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        error "Usage: ccs remove <profile_name>"
        return 1
    fi

    # Check if exists
    if ! list_profiles | grep -qx "$name"; then
        error "Profile \"$name\" does not exist"
        return 1
    fi

    # Check if active
    local active
    active="$(get_active_profile)"
    if [[ "$name" == "$active" ]]; then
        error "Cannot delete active profile: [$name]"
        info "Run \"ccs <other_profile>\" first, then try again."
        return 1
    fi

    if ! confirm "Are you sure you want to delete profile [$name]?"; then
        return 0
    fi

    # Remove section from file
    local tmpfile
    tmpfile=$(mktemp)

    local in_section=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            section="${BASH_REMATCH[1]}"
            if [[ "$section" == "$name" ]]; then
                in_section=true
            else
                in_section=false
                echo "$line" >> "$tmpfile"
            fi
            continue
        fi

        if ! $in_section; then
            echo "$line" >> "$tmpfile"
        fi
    done < "$PROVIDER_CONF"

    mv "$tmpfile" "$PROVIDER_CONF"
    chmod 600 "$PROVIDER_CONF"

    success "Removed profile [${name}] from provider.conf"

    local remaining
    remaining=$(list_profiles | wc -l)
    info "${remaining} profiles remaining"
}

cmd_test() {
    local target="${1:-}"
    local timeout="${CCS_TEST_TIMEOUT:-5}"

    # If no profile specified, test all
    if [[ -z "$target" ]]; then
        echo "$(bold "Testing all profiles") (timeout: ${timeout}s, parallel)..."
        echo

        local profiles
        profiles=$(list_profiles)

        if [[ -z "$profiles" ]]; then
            error "No profiles found"
            return 1
        fi

        local count=0
        local passed=0

        # Test in parallel
        for profile in $profiles; do
            (
                test_single_profile "$profile" "$timeout"
            ) &
            ((count++))
        done

        wait

        echo
        info "Results: check log output above"
        return 0
    else
        # Test specific profile
        if ! list_profiles | grep -qx "$target"; then
            error "Profile \"$target\" does not exist"
            return 1
        fi

        echo "$(bold "Testing profile:") $target"
        test_single_profile "$target" "$timeout" detailed
    fi
}

test_single_profile() {
    local name="$1"
    local timeout="$2"
    local detailed="${3:-}"

    local config
    config=$(read_profile "$name")

    local token url haiku model
    while IFS='=' read -r key value; do
        case "$key" in
            ANTHROPIC_AUTH_TOKEN) token="$value" ;;
            ANTHROPIC_BASE_URL) url="$value" ;;
            ANTHROPIC_DEFAULT_SONNET_MODEL) model="$value" ;;
        esac
    done <<< "$config"

    if [[ -z "${model:-}" ]]; then
        model="claude-sonnet-4-6-20250514"
    fi

    # Mask token for display
    local masked_token
    if [[ ${#token} -gt 8 ]]; then
        masked_token="${token:0:4}***${token: -4}"
    else
        masked_token="***"
    fi

    if [[ -n "$detailed" ]]; then
        echo "  Endpoint:  $url"
        echo "  Auth:      $masked_token"
        echo
    fi

    # Perform test request
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time "$timeout" \
        --connect-timeout 3 \
        -H "x-api-key: $token" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -d '{"model":"'"$model"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        "$url/v1/messages" 2>/dev/null || echo "000")

    if [[ "$http_code" == "000" ]]; then
        echo "  [$name]  $(red "✗ TIMEOUT") (>${timeout}s)"
    elif [[ "$http_code" == "200" ]]; then
        echo "  [$name]  $(green "✓ OK")"
    else
        echo "  [$name]  $(red "✗ HTTP $http_code")"
        if [[ -n "$detailed" ]]; then
            echo "    API key may have expired or endpoint is incorrect."
        fi
    fi
}

cmd_backup() {
    if ! ensure_settings_exists; then
        return 1
    fi
    backup_settings
    success "Backup complete"
}

cmd_update() {
    echo "$(bold "Checking for updates...")"

    local latest
    latest=$(curl -sf --max-time 10 "${REPO_URL}/VERSION" 2>/dev/null || echo "")

    if [[ -z "$latest" ]]; then
        error "Cannot check for new version"
        return 1
    fi

    if [[ "$latest" == "$CCS_VERSION" ]]; then
        success "You are on the latest version: $CCS_VERSION"
        return 0
    fi

    echo "New version available: $latest (current: $CCS_VERSION)"

    if ! confirm "Update now?"; then
        return 0
    fi

    # Download new version
    local tmpfile
    tmpfile=$(mktemp)

    if curl -sf --max-time 30 -o "$tmpfile" "${REPO_URL}/ccs.sh"; then
        chmod +x "$tmpfile"
        mv "$tmpfile" "${CCS_DIR}/ccs.sh"
        success "Updated to v${latest}"
        info "Run ccs again to use the new version"
    else
        rm -f "$tmpfile"
        error "Cannot download new version"
        return 1
    fi
}

cmd_uninstall() {
    echo "$(bold "=== CCS Uninstall ===")"
    echo
    echo "This will:"
    echo "  1. Remove directory ~/.ccs/ (including config, backups)"
    echo "  2. Remove ccs symlink"
    echo "  3. (Optional) Restore settings.json"
    echo

    if confirm "Restore settings.json from latest backup?"; then
        cmd_restore || true
    fi

    if ! confirm "Confirm CCS uninstall"; then
        return 0
    fi

    # Find and remove symlink
    local symlink_path=""
    for path in "/usr/local/bin/ccs" "${HOME}/.local/bin/ccs"; do
        if [[ -L "$path" ]]; then
            symlink_path="$path"
            rm "$path"
            info "Removed symlink $path"
            break
        fi
    done

    # Remove CCS directory
    if [[ -d "$CCS_DIR" ]]; then
        rm -rf "$CCS_DIR"
        info "Removed ~/.ccs/"
    fi

    success "CCS has been completely uninstalled."
}

cmd_version() {
    echo "$(bold "CCS - Claude Code Switch") v${CCS_VERSION}"
    echo "Platform:  $(detect_platform)"
    echo "Shell:     bash ${BASH_VERSION}"

    local profile_count=0
    if [[ -f "$PROVIDER_CONF" ]]; then
        profile_count=$(list_profiles | wc -l)
    fi
    echo "Config:    ${PROVIDER_CONF} (${profile_count} profiles)"

    local active
    active="$(get_active_profile)"
    if [[ -n "$active" ]]; then
        echo "Active:    ${active}"
    fi

    echo "Settings:  $(get_settings_path)"
}

cmd_help() {
    local topic="${1:-}"

    if [[ -n "$topic" ]]; then
        case "$topic" in
            edit)
                echo "$(bold "CCS EDIT") - Edit provider config"
                echo
                echo "USAGE:"
                echo "  ccs edit"
                echo
                echo "Open ~/.ccs/provider.conf in text editor to add, edit, or remove profiles."
                echo "Uses \$EDITOR if set, defaults to vi."
                echo "After saving, new profiles are available immediately."
                ;;
            add)
                echo "$(bold "CCS ADD") - Add new profile"
                echo
                echo "USAGE:"
                echo "  ccs add <name>"
                echo
                echo "Add a new profile to provider.conf (interactive)."
                ;;
            test)
                echo "$(bold "CCS TEST") - Test API key/endpoint"
                echo
                echo "USAGE:"
                echo "  ccs test [profile_name]"
                echo
                echo "No profile specified → test all (parallel, timeout 5s)."
                echo "Override timeout: CCS_TEST_TIMEOUT=10 ccs test"
                ;;
            *)
                error "No help for: $topic"
                ;;
        esac
        return
    fi

    cat << 'EOF'
CCS - Claude Code Switch v1.0.0
Quick switch between AI provider profiles for Claude Code

USAGE:
  ccs <command> [options]

COMMANDS:
  <profile>           Switch to specified profile
                      e.g.: ccs opus, ccs kimi

  list                List all available profiles
  current             Show active profile
  edit                Open provider.conf in editor
  add <name>          Add new profile (interactive)
  remove <name>       Remove profile from provider.conf
  test [name]         Test API key/endpoint (default: test all)
  backup              Backup current settings.json
  restore             Restore settings.json from backup
  update              Update CCS to latest version
  uninstall           Uninstall CCS
  version             Show version info
  help [command]      Show help

OPTIONS:
  -h, --help          Show this help
  -v, --version       Show version
  -y, --yes           Skip all confirm prompts

EXAMPLES:
  ccs opus            Switch to Anthropic Opus profile
  ccs list            List profiles
  ccs edit            Edit provider.conf
  ccs test            Test all profiles
  CCS_TEST_TIMEOUT=10 ccs test  # Test with 10s timeout

FILES:
  ~/.ccs/provider.conf    Profile config file (managed by you)
  ~/.ccs/config.env       CCS configuration
  ~/.ccs/backups/         settings.json backups

EOF
}

#==============================================================================
# First Run Setup
#==============================================================================
first_run_setup() {
    echo "$(bold "=== CCS First Run Setup ===")"
    echo
    echo "No provider.conf found. Let's add your first profile!"
    echo

    # Create empty provider.conf
    mkdir -p "$CCS_DIR"
    touch "$PROVIDER_CONF"
    chmod 600 "$PROVIDER_CONF"

    # Interactive add
    cmd_add

    local profile_count
    profile_count=$(list_profiles | wc -l)

    if [[ "$profile_count" -gt 0 ]]; then
        echo
        success "Setup complete! Found ${profile_count} profile(s)."
        info "Run \"ccs list\" to see profiles."
        info "Run \"ccs <profile>\" to switch."
        echo
        info "To add more profiles: ccs add <name>"
    fi
}

#==============================================================================
# Main
#==============================================================================
main() {
    # Parse global flags first
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                _auto_yes=true
                shift
                ;;
            -h|--help)
                cmd_help
                exit 0
                ;;
            -v|--version)
                cmd_version
                exit 0
                ;;
            --no-color)
                _use_color=false
                shift
                ;;
            -*)
                error "Invalid flag: $1"
                cmd_help
                exit 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    set -- "${args[@]}"

    # Check dependencies
    if ! command -v jq &>/dev/null; then
        error "Missing dependency: jq"
        echo "Install:"
        echo "  Ubuntu/Debian: sudo apt install jq"
        echo "  macOS: brew install jq"
        exit 1
    fi

    # Ensure CCS directory exists
    mkdir -p "$CCS_DIR"
    mkdir -p "$BACKUP_DIR"

    # Route commands
    local cmd="${1:-}"

    case "$cmd" in
        list)
            cmd_list
            ;;
        current)
            cmd_current
            ;;
        edit)
            cmd_edit
            ;;
        add)
            shift
            cmd_add "$@"
            ;;
        remove)
            shift
            cmd_remove "$@"
            ;;
        test)
            shift
            cmd_test "$@"
            ;;
        backup)
            cmd_backup
            ;;
        restore)
            cmd_restore
            ;;
        update)
            cmd_update
            ;;
        uninstall)
            cmd_uninstall
            ;;
        version)
            cmd_version
            ;;
        help)
            shift
            cmd_help "$@"
            ;;
        "")
            # No command - check if provider.conf exists
            if [[ ! -f "$PROVIDER_CONF" ]]; then
                first_run_setup
            else
                cmd_help
            fi
            ;;
        *)
            # Try to switch to profile
            if list_profiles | grep -qx "$cmd"; then
                cmd_switch "$cmd"
            else
                error "Invalid command: $cmd"
                echo "  Available profiles: $(list_profiles | tr '\n' ' ')"
                echo "  Run 'ccs help' for usage."
                exit 1
            fi
            ;;
    esac
}

main "$@"
