#!/usr/bin/env bash
#
# CCS - Claude Code Switch
# Quick switch between multiple AI provider profiles for Claude Code
#
# Version: 1.4.7
# License: MIT

set -euo pipefail

#==============================================================================
# Constants
#==============================================================================
# Derive version from ~/.ccs/VERSION, falling back to the shipped VERSION file,
# and finally to the remote repo (cached for 4h to avoid excessive network calls).
_get_ccs_version() {
    # 1) ~/.ccs/VERSION (populated by install or update)
    if [[ -f "${HOME}/.ccs/VERSION" ]]; then
        head -1 "${HOME}/.ccs/VERSION"
        return
    fi
    # 2) VERSION file shipped alongside the script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    local version_file="${script_dir}/VERSION"
    if [[ -f "$version_file" ]]; then
        head -1 "$version_file"
        return
    fi
    # 3) One-time remote fetch + cache (backward compat for old installs)
    local cache_file="${HOME}/.ccs/.version_cache"
    local max_age=14400  # 4 hours
    if [[ -f "$cache_file" ]]; then
        local mtime
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        if [[ $(( now - mtime )) -lt $max_age ]]; then
            head -1 "$cache_file"
            return
        fi
    fi
    local remote_ver
    remote_ver=$(curl -sf --max-time 5 "https://raw.githubusercontent.com/buivankim2020/claude-code-switch/main/VERSION" 2>/dev/null || echo "")
    if [[ -n "$remote_ver" ]]; then
        mkdir -p "${HOME}/.ccs"
        echo "$remote_ver" > "$cache_file"
        echo "$remote_ver"
    else
        echo "unknown"
    fi
}
readonly CCS_VERSION="$(_get_ccs_version)"
readonly CCS_DIR="${HOME}/.ccs"
readonly CONFIG_FILE="${CCS_DIR}/config.env"
readonly PROVIDER_CONF="${CCS_DIR}/provider.conf"
readonly PROVIDER_EXAMPLE="${CCS_DIR}/provider.conf.example"
readonly BACKUP_DIR="${CCS_DIR}/backups"
readonly UPDATE_CHECK_FILE="${CCS_DIR}/.update_check"
readonly REPO_URL="https://raw.githubusercontent.com/buivankim2020/claude-code-switch/main"
readonly CUSTOM_PROMPT_DIR="${CCS_DIR}/custom-model"
readonly CUSTOM_PROMPT_FILE="${CUSTOM_PROMPT_DIR}/gpt-custom-prompt.md"
readonly CUSTOM_PROMPT_BEGIN='<!-- CCS-CUSTOM-PROMPT:BEGIN -->'
readonly CUSTOM_PROMPT_END='<!-- CCS-CUSTOM-PROMPT:END -->'

# Known provider types
readonly KNOWN_TYPES="anthropic foundry"

# All valid keys across every provider type (used for typo detection)
readonly ALL_VALID_KEYS="PROVIDER_TYPE CUSTOM_PROMPT \
ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL ANTHROPIC_FOUNDRY_API_KEY \
ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL"

# Return required keys for a given provider type.
# For the 'foundry' type, ANTHROPIC_FOUNDRY_RESOURCE and ANTHROPIC_FOUNDRY_BASE_URL
# are OR-required (at least one must be present) — handled separately in validate_conf.
get_required_keys() {
    local type="${1:-anthropic}"
    case "$type" in
        foundry)
            echo "ANTHROPIC_FOUNDRY_API_KEY \
ANTHROPIC_DEFAULT_HAIKU_MODEL \
ANTHROPIC_DEFAULT_OPUS_MODEL \
ANTHROPIC_DEFAULT_SONNET_MODEL"
            ;;
        anthropic|*)
            echo "ANTHROPIC_AUTH_TOKEN \
ANTHROPIC_BASE_URL \
ANTHROPIC_DEFAULT_HAIKU_MODEL \
ANTHROPIC_DEFAULT_OPUS_MODEL \
ANTHROPIC_DEFAULT_SONNET_MODEL"
            ;;
    esac
}

# Return the PROVIDER_TYPE declared in a profile; echoes "anthropic" if absent.
get_profile_type() {
    local profile="$1"
    local type=""
    local config
    config=$(read_profile "$profile") || return 1
    while IFS='=' read -r key value; do
        if [[ "$key" == "PROVIDER_TYPE" ]]; then
            type="$value"
            break
        fi
    done <<< "$config"
    echo "${type:-anthropic}"
}

# Derive the Foundry anthropic-compat base URL from either RESOURCE or BASE_URL.
# Echoes the resolved URL (no trailing slash, no /anthropic suffix stripping here).
resolve_foundry_url() {
    local resource="$1"
    local base_url="$2"
    if [[ -n "$base_url" ]]; then
        echo "${base_url%/}"
    elif [[ -n "$resource" ]]; then
        echo "https://${resource}.services.ai.azure.com/anthropic"
    else
        echo ""
    fi
}

# Available commands
readonly COMMANDS="list current edit add remove test backup restore update uninstall version help clear"

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

# Walk up from $PWD looking for a project root (.git/ or .claude/).
# Echoes the path and returns 0 if found, returns 1 otherwise.
find_project_root() {
    local dir="${1:-$PWD}"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" ]] || [[ -d "$dir/.claude" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

get_settings_path() {
    # Check for user override first
    if [[ -n "${CCS_SETTINGS_PATH:-}" ]]; then
        echo "$CCS_SETTINGS_PATH"
        return
    fi

    # Project scope: write to .claude/settings.local.json
    if [[ -n "${CCS_PROJECT_ROOT:-}" ]]; then
        echo "${CCS_PROJECT_ROOT}/.claude/settings.local.json"
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

get_claude_md_path() {
    if [[ -n "${CCS_PROJECT_ROOT:-}" ]]; then
        echo "${CCS_PROJECT_ROOT}/CLAUDE.md"
    else
        echo "${HOME}/.claude/CLAUDE.md"
    fi
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
cyan() { if $_use_color; then echo -e "\033[36m$1\033[0m"; else echo "$1"; fi; }

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

# Return the state file path for the current scope.
get_state_file() {
    if [[ -n "${CCS_PROJECT_ROOT:-}" ]]; then
        local hash
        hash=$(echo -n "$CCS_PROJECT_ROOT" | md5sum | cut -d' ' -f1)
        mkdir -p "${CCS_DIR}/projects"
        echo "${CCS_DIR}/projects/${hash}.env"
    else
        echo "$CONFIG_FILE"
    fi
}

get_active_profile() {
    local state_file
    state_file="$(get_state_file)"
    if [[ -f "$state_file" ]]; then
        grep "^ACTIVE_PROFILE=" "$state_file" 2>/dev/null | cut -d= -f2 || echo ""
    else
        echo ""
    fi
}

set_active_profile() {
    local profile="$1"
    local state_file
    state_file="$(get_state_file)"
    mkdir -p "$(dirname "$state_file")"
    if [[ -f "$state_file" ]]; then
        if grep -q "^ACTIVE_PROFILE=" "$state_file"; then
            sed -i.bak "s/^ACTIVE_PROFILE=.*/ACTIVE_PROFILE=${profile}/" "$state_file"
            rm -f "${state_file}.bak"
        else
            echo "ACTIVE_PROFILE=${profile}" >> "$state_file"
        fi
    else
        echo "ACTIVE_PROFILE=${profile}" > "$state_file"
    fi
}

# Resolve a profile name or numeric index to an actual profile name.
# Echos the resolved name; returns 1 if not found.
resolve_profile() {
    local input="$1"
    # If it's purely digits, treat it as an index
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx="$input"
        local i=1
        local profile
        for profile in $(list_profiles); do
            if [[ "$i" == "$idx" ]]; then
                echo "$profile"
                return 0
            fi
            ((i++)) || true
        done
        echo ""
        return 1
    fi
    # Otherwise treat as a name
    local p
    for p in $(list_profiles); do
        if [[ "$p" == "$input" ]]; then
            echo "$input"
            return 0
        fi
    done
    echo ""
    return 1
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

is_custom_prompt_enabled() {
    local profile="$1"
    local config
    local custom_prompt=""

    if ! config=$(read_profile "$profile"); then
        return 1
    fi

    while IFS='=' read -r key value; do
        if [[ "$key" == "CUSTOM_PROMPT" ]]; then
            custom_prompt="$value"
        fi
    done <<< "$config"

    [[ "$custom_prompt" == "1" ]]
}

remove_custom_prompt_block() {
    local target="$1"
    if [[ ! -f "$target" ]]; then
        return 1
    fi

    local marker_info
    if ! marker_info=$(awk -v begin="$CUSTOM_PROMPT_BEGIN" -v end="$CUSTOM_PROMPT_END" '
        {
            line = $0
            sub(/\r$/, "", line)
            lines[NR] = line
            if (line == begin) {
                begin_count++
                if (begin_count == 1) begin_line = NR
            }
            if (line == end) {
                end_count++
                if (end_count == 1) end_line = NR
            }
        }
        END {
            printf "%d %d %d %d\n", begin_count + 0, end_count + 0, begin_line + 0, end_line + 0
        }
    ' "$target"); then
        warn "Cannot inspect custom prompt markers in $target"
        return 2
    fi

    local begin_count end_count begin_line end_line
    read -r begin_count end_count begin_line end_line <<< "$marker_info"

    if [[ "$begin_count" -eq 0 && "$end_count" -eq 0 ]]; then
        return 1
    fi
    if [[ "$begin_count" -ne 1 || "$end_count" -ne 1 || "$begin_line" -ge "$end_line" ]]; then
        warn "Malformed custom prompt markers in $target; leaving file unchanged"
        return 2
    fi

    local mode=""
    mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || true)

    local tmpfile
    if ! tmpfile=$(mktemp "${target}.tmp.XXXXXX"); then
        warn "Cannot create temporary file for $target"
        return 2
    fi

    # Rewrite with CR stripped from lines so CRLF markers match consistently.
    if ! awk -v first="$begin_line" -v last="$end_line" '
        {
            line = $0
            sub(/\r$/, "", line)
            lines[NR] = line
        }
        END {
            remove_before = (first > 1 && lines[first - 1] == "")
            remove_after = (!remove_before && last < NR && lines[last + 1] == "")
            for (i = 1; i <= NR; i++) {
                if (i >= first && i <= last) continue
                if (remove_before && i == first - 1) continue
                if (remove_after && i == last + 1) continue
                print lines[i]
            }
        }
    ' "$target" > "$tmpfile"; then
        rm -f "$tmpfile"
        warn "Cannot rewrite $target"
        return 2
    fi

    if [[ -n "$mode" ]] && ! chmod "$mode" "$tmpfile"; then
        rm -f "$tmpfile"
        warn "Cannot preserve permissions for $target"
        return 2
    fi
    if ! mv "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        warn "Cannot replace $target"
        return 2
    fi

    return 0
}

inject_custom_prompt_block() {
    local target="$1"
    local prompt_source="$2"

    # Validate source before touching the target.
    if [[ ! -f "$prompt_source" || ! -s "$prompt_source" ]]; then
        warn "Custom prompt source is missing or empty: $prompt_source"
        return 1
    fi
    if grep -Fq "$CUSTOM_PROMPT_BEGIN" "$prompt_source" || grep -Fq "$CUSTOM_PROMPT_END" "$prompt_source"; then
        warn "Custom prompt source contains a reserved marker: $prompt_source"
        return 1
    fi

    local parent_dir
    parent_dir=$(dirname "$target")
    if ! mkdir -p "$parent_dir"; then
        warn "Cannot create directory for $target"
        return 1
    fi

    # Inspect existing target markers without mutating it.
    # begin_count/end_count of 0/0 is fine (no prior block).
    # Any other mismatch is malformed and must leave the target unchanged.
    local mode=""
    local begin_count=0 end_count=0 begin_line=0 end_line=0
    if [[ -f "$target" ]]; then
        mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || true)

        local marker_info
        if ! marker_info=$(awk -v begin="$CUSTOM_PROMPT_BEGIN" -v end="$CUSTOM_PROMPT_END" '
            {
                line = $0
                sub(/\r$/, "", line)
                if (line == begin) {
                    begin_count++
                    if (begin_count == 1) begin_line = NR
                }
                if (line == end) {
                    end_count++
                    if (end_count == 1) end_line = NR
                }
            }
            END {
                printf "%d %d %d %d\n", begin_count + 0, end_count + 0, begin_line + 0, end_line + 0
            }
        ' "$target"); then
            warn "Cannot inspect custom prompt markers in $target"
            return 1
        fi
        read -r begin_count end_count begin_line end_line <<< "$marker_info"

        if [[ "$begin_count" -ne 0 || "$end_count" -ne 0 ]]; then
            if [[ "$begin_count" -ne 1 || "$end_count" -ne 1 || "$begin_line" -ge "$end_line" ]]; then
                warn "Malformed custom prompt markers in $target; leaving file unchanged"
                return 1
            fi
        fi
    fi

    # Build the full replacement in a temp file; only mv on success.
    local tmpfile
    if ! tmpfile=$(mktemp "${target}.tmp.XXXXXX"); then
        warn "Cannot create temporary file for $target"
        return 1
    fi

    # Shellcheck: keep cleanup on every early return below.
    if [[ -f "$target" ]]; then
        # Copy user content, omitting any existing valid managed block (+ one
        # adjacent separator blank). Target stays untouched until final mv.
        # Strip trailing CR so CRLF CLAUDE.md files match markers reliably.
        if ! awk -v first="$begin_line" -v last="$end_line" -v has_block=$(( begin_count == 1 ? 1 : 0 )) '
            {
                line = $0
                sub(/\r$/, "", line)
                lines[NR] = line
            }
            END {
                if (has_block) {
                    remove_before = (first > 1 && lines[first - 1] == "")
                    remove_after = (!remove_before && last < NR && lines[last + 1] == "")
                    for (i = 1; i <= NR; i++) {
                        if (i >= first && i <= last) continue
                        if (remove_before && i == first - 1) continue
                        if (remove_after && i == last + 1) continue
                        print lines[i]
                    }
                } else {
                    for (i = 1; i <= NR; i++) print lines[i]
                }
            }
        ' "$target" > "$tmpfile"; then
            rm -f "$tmpfile"
            warn "Cannot rewrite $target"
            return 1
        fi
    else
        : > "$tmpfile" || {
            rm -f "$tmpfile"
            warn "Cannot create temporary file for $target"
            return 1
        }
    fi

    # Ensure a blank-line separator before the managed block when prior content exists.
    if [[ -s "$tmpfile" ]]; then
        local last_byte
        last_byte=$(LC_ALL=C tail -c 1 "$tmpfile" | od -An -t x1 | tr -d '[:space:]')
        if [[ "$last_byte" == "0a" ]]; then
            # Ends with newline; add one more blank line if last line is non-empty.
            local last_line
            last_line=$(tail -n 1 "$tmpfile")
            if [[ -n "$last_line" ]]; then
                if ! printf '\n' >> "$tmpfile"; then
                    rm -f "$tmpfile"
                    warn "Cannot write custom prompt block to $target"
                    return 1
                fi
            fi
        else
            if ! printf '\n\n' >> "$tmpfile"; then
                rm -f "$tmpfile"
                warn "Cannot write custom prompt block to $target"
                return 1
            fi
        fi
    fi

    if ! printf '%s\n' "$CUSTOM_PROMPT_BEGIN" >> "$tmpfile"; then
        rm -f "$tmpfile"
        warn "Cannot write custom prompt block to $target"
        return 1
    fi
    if ! cat "$prompt_source" >> "$tmpfile"; then
        rm -f "$tmpfile"
        warn "Cannot write custom prompt block to $target"
        return 1
    fi

    local source_last_byte
    source_last_byte=$(LC_ALL=C tail -c 1 "$prompt_source" | od -An -t x1 | tr -d '[:space:]')
    if [[ "$source_last_byte" != "0a" ]]; then
        if ! printf '\n' >> "$tmpfile"; then
            rm -f "$tmpfile"
            warn "Cannot write custom prompt block to $target"
            return 1
        fi
    fi
    if ! printf '%s\n' "$CUSTOM_PROMPT_END" >> "$tmpfile"; then
        rm -f "$tmpfile"
        warn "Cannot write custom prompt block to $target"
        return 1
    fi

    if [[ -n "$mode" ]] && ! chmod "$mode" "$tmpfile"; then
        rm -f "$tmpfile"
        warn "Cannot preserve permissions for $target"
        return 1
    fi
    if ! mv "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        warn "Cannot replace $target"
        return 1
    fi

    return 0
}

remove_custom_prompt_for_current_scope() {
    local target
    target=$(get_claude_md_path)

    if remove_custom_prompt_block "$target"; then
        info "Removed custom prompt from $target"
    fi

    return 0
}

# Best-effort download of the runtime prompt when missing.
# Covers first upgrade from pre-feature versions that only replaced ccs.sh + VERSION.
ensure_custom_prompt_file() {
    if [[ -s "$CUSTOM_PROMPT_FILE" ]]; then
        return 0
    fi

    mkdir -p "$CUSTOM_PROMPT_DIR"
    local prompt_tmp
    prompt_tmp=$(mktemp)
    if curl -sf --max-time 15 -o "$prompt_tmp" \
        "${REPO_URL}/custom-model/gpt-custom-prompt.md" \
        && [[ -s "$prompt_tmp" ]]; then
        mv "$prompt_tmp" "$CUSTOM_PROMPT_FILE"
        return 0
    fi
    rm -f "$prompt_tmp"
    return 1
}

sync_custom_prompt() {
    local profile="$1"

    if is_custom_prompt_enabled "$profile"; then
        local target
        target=$(get_claude_md_path)
        ensure_custom_prompt_file || true
        if inject_custom_prompt_block "$target" "$CUSTOM_PROMPT_FILE"; then
            info "Applied custom prompt to $target"
        fi
    else
        remove_custom_prompt_for_current_scope
    fi

    return 0
}

# Validate a single completed section: required-keys + Foundry OR-rule.
# Appends error strings (via printf) to stdout; caller reads them into the errors array.
_validate_section() {
    local section="$1"
    local type="$2"
    local keys="$3"   # space-separated list of keys seen

    local required
    required=$(get_required_keys "$type")
    local key
    for key in $required; do
        if ! echo " $keys " | grep -qw "$key"; then
            printf '[%s]: Missing %s\n' "$section" "$key"
        fi
    done

    if [[ "$type" == "foundry" ]]; then
        if ! echo " $keys " | grep -qw "ANTHROPIC_FOUNDRY_RESOURCE" && \
           ! echo " $keys " | grep -qw "ANTHROPIC_FOUNDRY_BASE_URL"; then
            printf '[%s]: Missing ANTHROPIC_FOUNDRY_RESOURCE or ANTHROPIC_FOUNDRY_BASE_URL\n' "$section"
        fi
    fi

    # Check type is known
    local known=false
    local t
    for t in $KNOWN_TYPES; do
        [[ "$type" == "$t" ]] && known=true
    done
    if ! $known; then
        printf '[%s]: Unknown PROVIDER_TYPE: %s (known: %s)\n' "$section" "$type" "$KNOWN_TYPES"
    fi
}

validate_conf() {
    local errors=()
    local section=""
    local section_type="anthropic"
    local -a sections=()
    local current_keys=""

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
                while IFS= read -r err; do
                    [[ -n "$err" ]] && errors+=("$err")
                done < <(_validate_section "$section" "$section_type" "$current_keys")
            fi

            section="${BASH_REMATCH[1]}"
            if echo "${sections[*]}" | grep -qw "$section"; then
                errors+=("Duplicate section: [$section]")
            fi
            sections+=("$section")
            current_keys=""
            section_type="anthropic"
            continue
        fi

        if [[ -n "$section" && "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%%#*}"
            val="${val%% }"
            val="${val## }"

            # PROVIDER_TYPE sets the section's type
            if [[ "$key" == "PROVIDER_TYPE" ]]; then
                section_type="$val"
            fi

            # Check for typos against ALL_VALID_KEYS
            local valid=false
            local vk
            for vk in $ALL_VALID_KEYS; do
                if [[ "$key" == "$vk" ]]; then
                    valid=true
                    break
                fi
            done
            if ! $valid; then
                if [[ "$key" == "ANTHROPIC_BASE_URLS" ]]; then
                    errors+=("[$section]: Invalid key: $key (did you mean ANTHROPIC_BASE_URL?)")
                else
                    errors+=("[$section]: Invalid key: $key")
                fi
            else
                current_keys="$current_keys $key"
            fi
        fi
    done < "$PROVIDER_CONF"

    # Validate last section
    if [[ -n "$section" ]]; then
        while IFS= read -r err; do
            [[ -n "$err" ]] && errors+=("$err")
        done < <(_validate_section "$section" "$section_type" "$current_keys")
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

update_settings_anthropic() {
    local token="$1"
    local url="$2"
    local haiku="$3"
    local opus="$4"
    local sonnet="$5"
    local settings_path
    settings_path="$(get_settings_path)"

    local tmpfile
    tmpfile=$(mktemp)

    # Write Anthropic keys; clear any Foundry-specific keys left from a previous switch.
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
        .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet |
        del(.env.CLAUDE_CODE_USE_FOUNDRY) |
        del(.env.ANTHROPIC_FOUNDRY_RESOURCE) |
        del(.env.ANTHROPIC_FOUNDRY_BASE_URL) |
        del(.env.ANTHROPIC_FOUNDRY_API_KEY)' \
       "$settings_path" > "$tmpfile"

    mv "$tmpfile" "$settings_path"
    info "Updated settings.json"
}

update_settings_foundry() {
    local resource="$1"
    local base_url="$2"
    local api_key="$3"
    local haiku="$4"
    local opus="$5"
    local sonnet="$6"
    local settings_path
    settings_path="$(get_settings_path)"

    local tmpfile
    tmpfile=$(mktemp)

    # Build a jq program that conditionally sets RESOURCE or BASE_URL (never both);
    # always clears the other one and the Anthropic-direct keys.
    local set_resource='del(.env.ANTHROPIC_FOUNDRY_RESOURCE)'
    local set_base_url='del(.env.ANTHROPIC_FOUNDRY_BASE_URL)'
    if [[ -n "$resource" ]]; then
        set_resource='.env.ANTHROPIC_FOUNDRY_RESOURCE = $resource'
    fi
    if [[ -n "$base_url" ]]; then
        set_base_url='.env.ANTHROPIC_FOUNDRY_BASE_URL = $base_url'
    fi

    jq --arg resource "$resource" \
       --arg base_url "$base_url" \
       --arg api_key "$api_key" \
       --arg haiku "$haiku" \
       --arg opus "$opus" \
       --arg sonnet "$sonnet" \
       ".env = (.env // {}) |
        .env.CLAUDE_CODE_USE_FOUNDRY = \"1\" |
        ${set_resource} |
        ${set_base_url} |
        .env.ANTHROPIC_FOUNDRY_API_KEY = \$api_key |
        .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = \$haiku |
        .env.ANTHROPIC_DEFAULT_OPUS_MODEL = \$opus |
        .env.ANTHROPIC_DEFAULT_SONNET_MODEL = \$sonnet |
        del(.env.ANTHROPIC_AUTH_TOKEN) |
        del(.env.ANTHROPIC_BASE_URL)" \
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

    # Parse values for both provider types in one pass
    local type="anthropic"
    local token url haiku opus sonnet
    local foundry_resource foundry_base_url foundry_api_key
    while IFS='=' read -r key value; do
        case "$key" in
            PROVIDER_TYPE) type="$value" ;;
            ANTHROPIC_AUTH_TOKEN) token="$value" ;;
            ANTHROPIC_BASE_URL) url="$value" ;;
            ANTHROPIC_FOUNDRY_RESOURCE) foundry_resource="$value" ;;
            ANTHROPIC_FOUNDRY_BASE_URL) foundry_base_url="$value" ;;
            ANTHROPIC_FOUNDRY_API_KEY) foundry_api_key="$value" ;;
            ANTHROPIC_DEFAULT_HAIKU_MODEL) haiku="$value" ;;
            ANTHROPIC_DEFAULT_OPUS_MODEL) opus="$value" ;;
            ANTHROPIC_DEFAULT_SONNET_MODEL) sonnet="$value" ;;
        esac
    done <<< "$config"

    # Ensure settings.json exists
    if ! ensure_settings_exists; then
        return 1
    fi

    # Backup first
    backup_settings

    case "$type" in
        foundry)
            if [[ -z "${foundry_resource:-}" && -z "${foundry_base_url:-}" ]]; then
                error "Profile \"$profile\" missing ANTHROPIC_FOUNDRY_RESOURCE or ANTHROPIC_FOUNDRY_BASE_URL"
                return 1
            fi
            if [[ -z "${foundry_api_key:-}" || -z "${haiku:-}" || -z "${opus:-}" || -z "${sonnet:-}" ]]; then
                error "Profile \"$profile\" is missing required Foundry fields"
                return 1
            fi
            update_settings_foundry "${foundry_resource:-}" "${foundry_base_url:-}" "$foundry_api_key" "$haiku" "$opus" "$sonnet"
            ;;
        anthropic)
            if [[ -z "${token:-}" || -z "${url:-}" || -z "${haiku:-}" || -z "${opus:-}" || -z "${sonnet:-}" ]]; then
                error "Profile \"$profile\" is missing required fields"
                return 1
            fi
            update_settings_anthropic "$token" "$url" "$haiku" "$opus" "$sonnet"
            ;;
        *)
            error "Unknown PROVIDER_TYPE for [$profile]: $type"
            return 1
            ;;
    esac

    # Keep the current scope's CLAUDE.md in sync with this profile (best-effort).
    sync_custom_prompt "$profile"

    # Save active profile
    set_active_profile "$profile"

    # Ask user to manually reload editor
    if confirm "Reload editor now to apply?"; then
        if [[ -n "${CODER:-}" ]] || [[ -n "${CODER_WORKSPACE_NAME:-}" ]]; then
            info "Coder/Web: press F1 or Ctrl+Shift+P → Reload Window"
            info "If changes do not apply, use manual reload again."
        elif [[ "${TERM_PROGRAM:-}" == "vscode" ]] || [[ -n "${VSCODE_PID:-}" ]]; then
            info "VSCode: press Ctrl+Shift+P → Reload Window"
            info "If changes do not apply, use manual reload."
        else
            info "Reload your editor window manually to apply changes"
        fi
    fi

    local scope_label="global"
    [[ -n "${CCS_PROJECT_ROOT:-}" ]] && scope_label="project"

    success "Switched to profile: $profile ($(cyan "$type")) [$(cyan "$scope_label")]"
    if [[ "$type" == "foundry" ]]; then
        local display_url
        display_url=$(resolve_foundry_url "${foundry_resource:-}" "${foundry_base_url:-}")
        echo "  Endpoint: $display_url"
    else
        echo "  Base URL: $url"
    fi
    echo "  Haiku:    $haiku"
    echo "  Opus:     $opus"
    echo "  Sonnet:   $sonnet"
}

cmd_list() {
    local active
    active="$(get_active_profile)"

    local scope_label="global"
    [[ -n "${CCS_PROJECT_ROOT:-}" ]] && scope_label="project"

    echo "$(bold "Available profiles:") [$(cyan "$scope_label")]"
    local profile i=1
    for profile in $(list_profiles); do
        local prefix="  $(printf '%2d' "$i")"
        if [[ "$profile" == "$active" ]]; then
            echo "${prefix} $(green "●") $profile $(green "(active)")"
        else
            echo "${prefix} ○ $profile"
        fi
        ((i++)) || true
    done
}

cmd_current() {
    local active
    active="$(get_active_profile)"

    if [[ -n "$active" ]]; then
        local config
        config=$(read_profile "$active")

        local type="anthropic" url model fres fbase
        while IFS='=' read -r key value; do
            case "$key" in
                PROVIDER_TYPE) type="$value" ;;
                ANTHROPIC_BASE_URL) url="$value" ;;
                ANTHROPIC_FOUNDRY_RESOURCE) fres="$value" ;;
                ANTHROPIC_FOUNDRY_BASE_URL) fbase="$value" ;;
                ANTHROPIC_DEFAULT_SONNET_MODEL) model="$value" ;;
            esac
        done <<< "$config"

        if [[ "$type" == "foundry" ]]; then
            url="$(resolve_foundry_url "${fres:-}" "${fbase:-}")"
        fi

        url="${url%/}"
        local host="${url#*://}"
        host="${host%%/*}"

        local scope_label="global"
        [[ -n "${CCS_PROJECT_ROOT:-}" ]] && scope_label="project"

        echo "$(green "●") $(bold "$active")  $(cyan "$model")  $host  [$(cyan "$scope_label")]"
    else
        warn "No profile is currently active"
    fi
}

cmd_status() {
    local active
    active="$(get_active_profile)"
    local settings_path
    settings_path="$(get_settings_path)"
    local platform
    platform="$(detect_platform)"

    echo "$(bold "CCS Status")  v${CCS_VERSION}"
    echo

    local scope_label="global"
    [[ -n "${CCS_PROJECT_ROOT:-}" ]] && scope_label="project ($CCS_PROJECT_ROOT)"

    echo "  $(bold "Scope:")       $(cyan "$scope_label")"
    echo

    # Active profile
    if [[ -n "$active" ]]; then
        local config type="anthropic" url model fres fbase
        config=$(read_profile "$active")
        while IFS='=' read -r key value; do
            case "$key" in
                PROVIDER_TYPE) type="$value" ;;
                ANTHROPIC_BASE_URL) url="$value" ;;
                ANTHROPIC_FOUNDRY_RESOURCE) fres="$value" ;;
                ANTHROPIC_FOUNDRY_BASE_URL) fbase="$value" ;;
                ANTHROPIC_DEFAULT_SONNET_MODEL) model="$value" ;;
            esac
        done <<< "$config"

        if [[ "$type" == "foundry" ]]; then
            url="$(resolve_foundry_url "${fres:-}" "${fbase:-}")"
        fi

        url="${url%/}"
        local host="${url#*://}"
        host="${host%%/*}"

        echo "  $(bold "Profile:")     $(green "●") $(bold "$active") ($(cyan "$type"))"
        echo "  $(bold "Model:")       $(cyan "$model")"
        echo "  $(bold "Endpoint:")    $host"
    else
        echo "  $(bold "Profile:")     $(yellow "none")"
    fi

    echo

    # Profiles overview
    local profiles count=0
    profiles=$(list_profiles)
    for p in $profiles; do
        ((count++)) || true
    done
    echo "  $(bold "Profiles:")    $count available"
    local pi=1
    for p in $profiles; do
        local pfx="$(printf '%2d' "$pi")"
        if [[ "$p" == "$active" ]]; then
            echo "               ${pfx} $(green "●") $p"
        else
            echo "               ${pfx} ○ $p"
        fi
        ((pi++)) || true
    done

    echo

    # Paths & platform
    echo "  $(bold "Platform:")    $platform"
    echo "  $(bold "Config:")      $PROVIDER_CONF"
    echo "  $(bold "Settings:")    $settings_path"
    if [[ -f "$settings_path" ]]; then
        echo "                 $(green "✓") exists"
    else
        echo "                 $(red "✗") not found"
    fi
}

cmd_reload() {
    local active
    active="$(get_active_profile)"

    if [[ -z "$active" ]]; then
        warn "No active profile to reload"
        info "Switch to a profile first: ccs <profile>"
        return 1
    fi

    info "Reloading profile: $active"
    cmd_switch "$active"
}

cmd_clear() {
    if [[ -z "${CCS_PROJECT_ROOT:-}" ]]; then
        error "clear requires project scope. Use: ccs -p clear"
        info "This removes project-level provider settings, falling back to global."
        return 1
    fi

    local settings_path
    settings_path="$(get_settings_path)"
    local state_file
    state_file="$(get_state_file)"

    if [[ ! -f "$settings_path" ]]; then
        warn "No project settings file found: $settings_path"
        rm -f "$state_file"
        remove_custom_prompt_for_current_scope
        success "Removed project state file (nothing else to do)"
        return 0
    fi

    local env_keys
    env_keys=$(jq -r '.env | keys[]' "$settings_path" 2>/dev/null || echo "")
    if [[ -z "$env_keys" ]]; then
        warn "No provider env keys in project settings"
        rm -f "$state_file"
        remove_custom_prompt_for_current_scope
        success "Removed project state file (nothing else to do)"
        return 0
    fi

    echo "$(bold "This will remove the following from project settings:")"
    echo "$env_keys" | while read -r k; do
        echo "  - $k"
    done
    echo

    if ! confirm "Remove project provider config and fall back to global?"; then
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp)
    jq 'del(.env)' "$settings_path" > "$tmpfile" && mv "$tmpfile" "$settings_path"
    rm -f "$state_file"
    remove_custom_prompt_for_current_scope
    success "Cleared project provider config. This project now uses the global profile."
}

prompt_with_default() {
    local label="$1" current="$2" var_name="$3"
    local display input
    # Mask tokens/keys in the prompt
    case "$label" in
        *TOKEN*|*API_KEY*)
            if [[ ${#current} -gt 8 ]]; then
                display="${current:0:4}***${current: -4}"
            else
                display="***"
            fi
            ;;
        *)
            display="$current"
            ;;
    esac
    read -r -p "${label} [${display}]: " input
    printf -v "$var_name" '%s' "${input:-$current}"
}

replace_profile_section() {
    local name="$1" new_block="$2"
    local tmpfile
    tmpfile=$(mktemp)
    local in_section=false section=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            section="${BASH_REMATCH[1]}"
            if [[ "$section" == "$name" ]]; then
                in_section=true
                printf '%s\n' "$new_block" >> "$tmpfile"
                continue
            else
                in_section=false
            fi
        fi
        if ! $in_section; then
            echo "$line" >> "$tmpfile"
        fi
    done < "$PROVIDER_CONF"

    mv "$tmpfile" "$PROVIDER_CONF"
    chmod 600 "$PROVIDER_CONF"
}

cmd_edit_profile() {
    local name="$1"

    # Resolve by name or number
    local resolved
    resolved="$(resolve_profile "$name" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
        error "Profile \"$name\" does not exist"
        local available
        available=$(list_profiles | tr '\n' ', ' | sed 's/, $//')
        [[ -n "$available" ]] && echo "  Available: $available" >&2
        return 1
    fi
    name="$resolved"

    local config
    config=$(read_profile "$name")

    local type="anthropic"
    local token url resource api_key haiku opus sonnet custom_prompt=""
    while IFS='=' read -r key value; do
        case "$key" in
            PROVIDER_TYPE) type="$value" ;;
            ANTHROPIC_AUTH_TOKEN) token="$value" ;;
            ANTHROPIC_BASE_URL) url="$value" ;;
            ANTHROPIC_FOUNDRY_RESOURCE) resource="$value" ;;
            ANTHROPIC_FOUNDRY_API_KEY) api_key="$value" ;;
            ANTHROPIC_DEFAULT_HAIKU_MODEL) haiku="$value" ;;
            ANTHROPIC_DEFAULT_OPUS_MODEL) opus="$value" ;;
            ANTHROPIC_DEFAULT_SONNET_MODEL) sonnet="$value" ;;
            CUSTOM_PROMPT) custom_prompt="$value" ;;
        esac
    done <<< "$config"

    echo "=== Edit profile: $name (${type}) ==="
    info "Press Enter to keep current value"
    echo

    local new_block
    if [[ "$type" == "foundry" ]]; then
        local n_resource n_api_key n_haiku n_opus n_sonnet
        prompt_with_default "ANTHROPIC_FOUNDRY_RESOURCE" "$resource" n_resource
        prompt_with_default "ANTHROPIC_FOUNDRY_API_KEY" "$api_key" n_api_key
        prompt_with_default "ANTHROPIC_DEFAULT_HAIKU_MODEL" "$haiku" n_haiku
        prompt_with_default "ANTHROPIC_DEFAULT_OPUS_MODEL" "$opus" n_opus
        prompt_with_default "ANTHROPIC_DEFAULT_SONNET_MODEL" "$sonnet" n_sonnet

        if [[ -z "$n_resource" || -z "$n_api_key" ]]; then
            error "ANTHROPIC_FOUNDRY_RESOURCE and ANTHROPIC_FOUNDRY_API_KEY are required"
            return 1
        fi

        new_block="[${name}]
PROVIDER_TYPE=foundry
ANTHROPIC_FOUNDRY_RESOURCE=${n_resource}
ANTHROPIC_FOUNDRY_API_KEY=${n_api_key}
ANTHROPIC_DEFAULT_HAIKU_MODEL=${n_haiku}
ANTHROPIC_DEFAULT_OPUS_MODEL=${n_opus}
ANTHROPIC_DEFAULT_SONNET_MODEL=${n_sonnet}"
    else
        local n_token n_url n_haiku n_opus n_sonnet
        prompt_with_default "ANTHROPIC_AUTH_TOKEN" "$token" n_token
        prompt_with_default "ANTHROPIC_BASE_URL" "$url" n_url
        prompt_with_default "ANTHROPIC_DEFAULT_HAIKU_MODEL" "$haiku" n_haiku
        prompt_with_default "ANTHROPIC_DEFAULT_OPUS_MODEL" "$opus" n_opus
        prompt_with_default "ANTHROPIC_DEFAULT_SONNET_MODEL" "$sonnet" n_sonnet

        if [[ -z "$n_token" || -z "$n_url" || -z "$n_haiku" || -z "$n_opus" || -z "$n_sonnet" ]]; then
            error "All fields are required"
            return 1
        fi

        new_block="[${name}]
ANTHROPIC_AUTH_TOKEN=${n_token}
ANTHROPIC_BASE_URL=${n_url}
ANTHROPIC_DEFAULT_HAIKU_MODEL=${n_haiku}
ANTHROPIC_DEFAULT_OPUS_MODEL=${n_opus}
ANTHROPIC_DEFAULT_SONNET_MODEL=${n_sonnet}"
    fi

    # Preserve optional CUSTOM_PROMPT so interactive edit does not silently disable it.
    if [[ -n "$custom_prompt" ]]; then
        new_block="${new_block}
CUSTOM_PROMPT=${custom_prompt}"
    fi

    replace_profile_section "$name" "$new_block"
    success "Updated profile [${name}]"

    # Re-apply if this is the active profile
    local active
    active="$(get_active_profile)"
    if [[ "$name" == "$active" ]]; then
        info "Reloading active profile..."
        cmd_switch "$name"
    fi
}

cmd_edit() {
    local name="${1:-}"

    if [[ ! -f "$PROVIDER_CONF" ]]; then
        warn "No provider.conf found."
        info "Run \"ccs add <name>\" to create your first profile."
        return 1
    fi

    # Interactive edit of a single profile when name is given
    if [[ -n "$name" ]]; then
        local resolved
        resolved="$(resolve_profile "$name" 2>/dev/null || true)"
        if [[ -z "$resolved" ]]; then
            error "Profile "$name" does not exist"
            return 1
        fi
        cmd_edit_profile "$resolved"
        return $?
    fi

    local editor="${EDITOR:-vi}"

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
    echo "Provider types:"
    echo "  1) anthropic  (Anthropic API, Kimi, OpenAI-compatible proxies)"
    echo "  2) foundry    (Microsoft Azure Foundry)"
    local type_choice type="anthropic"
    read -r -p "Select type [1]: " type_choice
    case "${type_choice:-1}" in
        2|foundry) type="foundry" ;;
        1|anthropic|"") type="anthropic" ;;
        *)
            error "Unknown type: $type_choice"
            return 1
            ;;
    esac
    echo

    mkdir -p "$CCS_DIR"
    chmod 600 "$PROVIDER_CONF" 2>/dev/null || true

    if [[ "$type" == "foundry" ]]; then
        local resource api_key haiku opus sonnet
        read -r -p "ANTHROPIC_FOUNDRY_RESOURCE (Azure resource name): " resource
        read -r -p "ANTHROPIC_FOUNDRY_API_KEY: " api_key
        read -r -p "ANTHROPIC_DEFAULT_HAIKU_MODEL [claude-haiku-4-5]: " haiku
        read -r -p "ANTHROPIC_DEFAULT_OPUS_MODEL [claude-opus-4-6]: " opus
        read -r -p "ANTHROPIC_DEFAULT_SONNET_MODEL [claude-sonnet-4-6]: " sonnet
        haiku="${haiku:-claude-haiku-4-5}"
        opus="${opus:-claude-opus-4-6}"
        sonnet="${sonnet:-claude-sonnet-4-6}"

        if [[ -z "$resource" || -z "$api_key" ]]; then
            error "ANTHROPIC_FOUNDRY_RESOURCE and ANTHROPIC_FOUNDRY_API_KEY are required"
            return 1
        fi

        cat >> "$PROVIDER_CONF" << EOF

[${name}]
PROVIDER_TYPE=foundry
ANTHROPIC_FOUNDRY_RESOURCE=${resource}
ANTHROPIC_FOUNDRY_API_KEY=${api_key}
ANTHROPIC_DEFAULT_HAIKU_MODEL=${haiku}
ANTHROPIC_DEFAULT_OPUS_MODEL=${opus}
ANTHROPIC_DEFAULT_SONNET_MODEL=${sonnet}
EOF
    else
        local token url haiku opus sonnet
        read -r -p "ANTHROPIC_AUTH_TOKEN: " token
        read -r -p "ANTHROPIC_BASE_URL: " url
        read -r -p "ANTHROPIC_DEFAULT_HAIKU_MODEL: " haiku
        read -r -p "ANTHROPIC_DEFAULT_OPUS_MODEL: " opus
        read -r -p "ANTHROPIC_DEFAULT_SONNET_MODEL: " sonnet

        if [[ -z "$token" || -z "$url" || -z "$haiku" || -z "$opus" || -z "$sonnet" ]]; then
            error "All fields are required"
            return 1
        fi

        cat >> "$PROVIDER_CONF" << EOF

[${name}]
ANTHROPIC_AUTH_TOKEN=${token}
ANTHROPIC_BASE_URL=${url}
ANTHROPIC_DEFAULT_HAIKU_MODEL=${haiku}
ANTHROPIC_DEFAULT_OPUS_MODEL=${opus}
ANTHROPIC_DEFAULT_SONNET_MODEL=${sonnet}
EOF
    fi

    chmod 600 "$PROVIDER_CONF"
    success "Added profile [${name}] (${type}) to provider.conf"
    info "Run \"ccs ${name}\" to use it."
}

cmd_remove() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        error "Usage: ccs remove <profile_name|number>"
        return 1
    fi
    # Resolve by name or number
    local resolved
    resolved="$(resolve_profile "$name" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
        error "Profile \"$name\" does not exist"
        return 1
    fi
    name="$resolved"

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
    local timeout="${CCS_TEST_TIMEOUT:-10}"

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

        local count=0 idx=0
        local tmpdir
        tmpdir=$(mktemp -d)

        # Test in parallel, capture output per profile
        for profile in $profiles; do
            ((idx++)) || true
            (
                set +e
                test_single_profile "$profile" "$timeout" "" "$idx" > "$tmpdir/$profile" 2>&1
            ) &
            ((count++)) || true
        done

        wait || true

        # Print results in order
        for profile in $profiles; do
            [[ -f "$tmpdir/$profile" ]] && cat "$tmpdir/$profile"
        done

        rm -rf "$tmpdir"

        echo
        info "Tested $count profiles"
        return 0
    else
        # Test specific profile (by name or number)
        local resolved
        resolved="$(resolve_profile "$target" 2>/dev/null || true)"
        if [[ -n "$resolved" ]]; then
            target="$resolved"
        fi
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
    local idx="${4:-}"

    local config
    config=$(read_profile "$name")

    local type="anthropic"
    local token url model
    local fres fbase fkey
    while IFS='=' read -r key value; do
        case "$key" in
            PROVIDER_TYPE) type="$value" ;;
            ANTHROPIC_AUTH_TOKEN) token="$value" ;;
            ANTHROPIC_BASE_URL) url="$value" ;;
            ANTHROPIC_FOUNDRY_RESOURCE) fres="$value" ;;
            ANTHROPIC_FOUNDRY_BASE_URL) fbase="$value" ;;
            ANTHROPIC_FOUNDRY_API_KEY) fkey="$value" ;;
            ANTHROPIC_DEFAULT_SONNET_MODEL) model="$value" ;;
        esac
    done <<< "$config"

    local label
    if [[ -n "$idx" ]]; then
        label="$(printf '%2d' "$idx") [$name]"
    else
        label="[$name]"
    fi

    if [[ "$type" == "foundry" ]]; then
        test_foundry_profile "$name" "$timeout" "$detailed" "${fres:-}" "${fbase:-}" "${fkey:-}" "${model:-claude-sonnet-4-6}" "$idx"
        return
    fi

    # Strip trailing slash from URL
    url="${url%/}"

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

    # Extract host from URL
    local host="${url#*://}"
    host="${host%%/*}"

    # Probe /v1/models to detect API type
    local probe_code api_type="anthropic"
    probe_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 3 --connect-timeout 2 \
        -H "Authorization: Bearer $token" \
        "$url/v1/models" 2>/dev/null || echo "000")

    # If /v1/models responds, it's an OpenAI-compatible proxy
    if [[ "$probe_code" == "200" ]]; then
        api_type="openai"
    fi

    local curl_out http_code time_total time_ms
    if [[ "$api_type" == "openai" ]]; then
        curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
            --max-time "$timeout" \
            --connect-timeout 3 \
            -H "Authorization: Bearer $token" \
            -H "content-type: application/json" \
            -d '{"model":"'"$model"'","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
            "$url/v1/chat/completions" 2>/dev/null || echo "000 0")
    else
        curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
            --max-time "$timeout" \
            --connect-timeout 3 \
            -H "x-api-key: $token" \
            -H "content-type: application/json" \
            -H "anthropic-version: 2023-06-01" \
            -d '{"model":"'"$model"'","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
            "$url/v1/messages" 2>/dev/null || echo "000 0")
    fi

    http_code="${curl_out%% *}"
    time_total="${curl_out##* }"

    time_ms=$(printf "%.0f" "$(echo "$time_total * 1000" | bc 2>/dev/null || echo "0")")

    if [[ "$http_code" == "000" ]]; then
        echo "  ${label}  $(red "✗ TIMEOUT") (>${timeout}s)  ${host}"
    elif [[ "$http_code" == "200" ]]; then
        echo "  ${label}  $(green "✓ OK")  ${time_ms}ms  ${host}  (${api_type})"
    else
        echo "  ${label}  $(red "✗ HTTP $http_code")  ${time_ms}ms  ${host}"
        if [[ -n "$detailed" ]]; then
            echo "    API key may have expired or endpoint is incorrect."
        fi
    fi
}

# Test a Foundry profile by POSTing a 1-token /v1/messages request to the
# Azure Foundry anthropic-compat endpoint with the api-key header.
test_foundry_profile() {
    local name="$1"
    local timeout="$2"
    local detailed="$3"
    local resource="$4"
    local base_url="$5"
    local api_key="$6"
    local model="$7"
    local idx="${8:-}"

    local label
    if [[ -n "$idx" ]]; then
        label="$(printf '%2d' "$idx") [$name]"
    else
        label="[$name]"
    fi

    local url
    url="$(resolve_foundry_url "$resource" "$base_url")"
    local host="${url#*://}"
    host="${host%%/*}"

    local masked_key
    if [[ ${#api_key} -gt 8 ]]; then
        masked_key="${api_key:0:4}***${api_key: -4}"
    else
        masked_key="***"
    fi

    if [[ -n "$detailed" ]]; then
        echo "  Endpoint:  $url"
        echo "  Auth:      x-api-key $masked_key"
        echo "  Model:     $model"
        echo
    fi

    if [[ -z "$api_key" ]]; then
        echo "  ${label}  $(yellow "⚠ SKIP") no api-key  ${host}  (foundry)"
        if [[ -n "$detailed" ]]; then
            echo "    Set ANTHROPIC_FOUNDRY_API_KEY in the profile to enable testing."
        fi
        return
    fi

    local curl_out http_code time_total time_ms
    # Foundry's /anthropic/ endpoint mimics api.anthropic.com and accepts
    # x-api-key (Anthropic convention), NOT Azure Cognitive Services' api-key header.
    curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --max-time "$timeout" \
        --connect-timeout 3 \
        -H "x-api-key: $api_key" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -d '{"model":"'"$model"'","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
        "$url/v1/messages" 2>/dev/null || echo "000 0")

    http_code="${curl_out%% *}"
    time_total="${curl_out##* }"
    time_ms=$(printf "%.0f" "$(echo "$time_total * 1000" | bc 2>/dev/null || echo "0")")

    if [[ "$http_code" == "000" ]]; then
        echo "  ${label}  $(red "✗ TIMEOUT") (>${timeout}s)  ${host}  (foundry)"
    elif [[ "$http_code" == "200" ]]; then
        echo "  ${label}  $(green "✓ OK")  ${time_ms}ms  ${host}  (foundry)"
    else
        echo "  ${label}  $(red "✗ HTTP $http_code")  ${time_ms}ms  ${host}  (foundry)"
        if [[ -n "$detailed" ]]; then
            case "$http_code" in
                401|403) echo "    API key rejected — check ANTHROPIC_FOUNDRY_API_KEY." ;;
                404)     echo "    Endpoint or deployment not found — check resource name and model deployment." ;;
                *)       echo "    Foundry endpoint returned $http_code." ;;
            esac
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
        # Also update the VERSION file
        echo "$latest" > "${CCS_DIR}/VERSION"

        # The repository copy is canonical; overwrite the runtime prompt on update.
        local prompt_tmp
        prompt_tmp=$(mktemp)
        if curl -sf --max-time 30 -o "$prompt_tmp" \
            "${REPO_URL}/custom-model/gpt-custom-prompt.md" \
            && [[ -s "$prompt_tmp" ]]; then
            mkdir -p "$CUSTOM_PROMPT_DIR"
            mv "$prompt_tmp" "$CUSTOM_PROMPT_FILE"
        else
            rm -f "$prompt_tmp"
            warn "Updated CCS, but could not update the custom prompt file"
        fi

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
CCS - Claude Code Switch
Quick switch between AI provider profiles for Claude Code

USAGE:
  ccs <command> [options]

COMMANDS:
  <profile>           Switch to specified profile (by name or number)
                      e.g.: ccs opus, ccs kimi, ccs 1

  list                List all available profiles (with numbers)
  current | active    Show active profile
  status              Show full status overview
  reload              Re-apply active profile after manual edit
  clear               Remove project provider config (requires -p)
  edit [name]         Edit a profile interactively, or open provider.conf
  add <name>          Add new profile (interactive)
  remove <name>       Remove profile from provider.conf
  test | check [name] Test API key/endpoint (default: test all)
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
  -p, --project       Use project-level settings (.claude/settings.local.json)

EXAMPLES:
  ccs opus            Switch to Anthropic Opus profile (global)
  ccs 1               Switch to profile #1 (global)
  ccs -p 3            Switch to profile #3 for current project
  ccs -p opus         Switch profile for current project
  ccs -p clear        Remove project config, fall back to global
  ccs list            List profiles with numbers
  ccs edit            Edit provider.conf
  ccs test            Test all profiles
  CCS_TEST_TIMEOUT=10 ccs test  # Test with 10s timeout

FILES:
  ~/.ccs/provider.conf           Profile config file (managed by you)
  ~/.ccs/config.env              CCS global configuration
  ~/.ccs/projects/<hash>.env     CCS per-project configuration
  ~/.ccs/backups/                settings.json backups

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
    local _project_scope=false
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
            -p|--project)
                _project_scope=true
                shift
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

    set -- "${args[@]+"${args[@]}"}"

    # Resolve project scope
    if $_project_scope; then
        local project_root
        project_root="$(find_project_root || true)"
        if [[ -z "$project_root" ]]; then
            error "No project root found (no .git/ or .claude/ directory)"
            info "Run ccs from within a project directory, or omit -p for global scope."
            exit 1
        fi
        export CCS_PROJECT_ROOT="$project_root"
    fi

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
        current|active)
            cmd_current
            ;;
        status)
            cmd_status
            ;;
        reload)
            cmd_reload
            ;;
        clear)
            cmd_clear
            ;;
        edit)
            shift
            cmd_edit "$@"
            ;;
        add)
            shift
            cmd_add "$@"
            ;;
        remove)
            shift
            cmd_remove "$@"
            ;;
        test|check)
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
            # Try to switch to profile by name or number
            local resolved
            resolved="$(resolve_profile "$cmd" 2>/dev/null || true)"
            if [[ -n "$resolved" ]]; then
                cmd_switch "$resolved"
            else
                error "Invalid command or profile: $cmd"
                echo "  Available: $(list_profiles | tr '
' ' ')"
                echo "  Run 'ccs help' for usage."
                exit 1
            fi
            ;;
    esac
}

main "$@"
