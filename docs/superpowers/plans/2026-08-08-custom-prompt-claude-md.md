# Custom Prompt → CLAUDE.md Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each CCS profile opt into a repo-managed custom prompt that CCS idempotently injects into or removes from the scope-appropriate `CLAUDE.md` during profile switches.

**Architecture:** Keep orchestration in `ccs.sh`: profile key `CUSTOM_PROMPT=1` controls a managed HTML-comment block, with helpers for scope path resolution, marker-safe removal, and atomic append. Ship the canonical prompt from `custom-model/gpt-custom-prompt.md` to `~/.ccs/custom-model/` through install/update; switch failures related to the prompt warn but never roll back a successful provider settings switch.

**Tech Stack:** Bash 4+, `awk`, `grep`, `stat`, `mktemp`, existing `jq`/`curl`; Markdown documentation; deterministic sandbox smoke tests.

**Approved design:** `docs/superpowers/specs/2026-08-08-custom-prompt-claude-md-design.md`

**Repository rule:** Do **not** run `git commit`. The user has explicitly disabled automatic commits. Stage files only at the final checkpoint if useful, then stop for the user to choose the commit.

---

## File structure and responsibilities

| Path | Responsibility in this feature |
|------|--------------------------------|
| `ccs.sh` | Recognize profile opt-in, resolve target `CLAUDE.md`, atomically remove/inject markers, hook switch/clear, update runtime prompt copy |
| `install.sh` | Create runtime prompt directory and download the canonical prompt during installation |
| `custom-model/gpt-custom-prompt.md` | Canonical repo-owned prompt body (rename typo from `gpt-custom-promt.md`) |
| `provider.conf.example` | Document optional `CUSTOM_PROMPT=1` profile key |
| `README.md` | User-facing feature behavior, scope paths, update overwrite and cleanup policy |
| `VERSION` | Release bump to `1.4.7` after implementation |
| `docs/superpowers/specs/2026-08-08-custom-prompt-claude-md-design.md` | Approved design reference (already created) |
| `/tmp/ccs-custom-prompt-smoke.sh` | Disposable integration smoke test; not committed |
| `/tmp/ccs-custom-prompt-update-smoke.sh` | Disposable update-path smoke test; not committed |

No new permanent test framework or production source file is introduced; this follows the approved v1 scope.

---

### Task 1: Protect current work and canonicalize the prompt filename

**Files:**
- Rename: `custom-model/gpt-custom-promt.md` → `custom-model/gpt-custom-prompt.md`
- Inspect only: `ccs.sh`, `VERSION`, `custom-model/specs.txt`

- [ ] **Step 1: Record existing uncommitted work before editing**

Run:

```bash
git status --short
git diff -- VERSION ccs.sh install.sh provider.conf.example README.md
git diff --no-index /dev/null custom-model/specs.txt || true
```

Expected: current user changes are visible (at session start: modified `VERSION`, modified `ccs.sh`, untracked `custom-model/`). Preserve them; do not reset, checkout, or overwrite unrelated hunks.

- [ ] **Step 2: Rename the prompt file without changing its content**

Run:

```bash
mv custom-model/gpt-custom-promt.md custom-model/gpt-custom-prompt.md
```

Expected: the correctly spelled file exists and the old misspelled path does not.

- [ ] **Step 3: Verify the canonical prompt is non-empty and does not contain CCS markers**

Run:

```bash
test -s custom-model/gpt-custom-prompt.md
! grep -Fq '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' custom-model/gpt-custom-prompt.md
! grep -Fq '<!-- CCS-CUSTOM-PROMPT:END -->' custom-model/gpt-custom-prompt.md
wc -l custom-model/gpt-custom-prompt.md
```

Expected: all tests return 0; line count is approximately 354.

- [ ] **Step 4: Confirm only the intended rename happened in `custom-model/`**

Run:

```bash
git status --short custom-model/
```

Expected: `custom-model/gpt-custom-prompt.md` and the existing `custom-model/specs.txt` appear as untracked/renamed work as appropriate; no unrelated file disappears.

---

### Task 2: Add prompt configuration, path resolution, and marker-safe file helpers

**Files:**
- Modify: `ccs.sh:54-69` (constants and valid profile keys)
- Modify: `ccs.sh:160-196` (CLAUDE.md path resolution)
- Modify: `ccs.sh:314-351` area (custom prompt helpers after `read_profile`)

- [ ] **Step 1: Add runtime prompt constants and the valid profile key**

Immediately after `readonly REPO_URL=...`, add:

```bash
readonly CUSTOM_PROMPT_DIR="${CCS_DIR}/custom-model"
readonly CUSTOM_PROMPT_FILE="${CUSTOM_PROMPT_DIR}/gpt-custom-prompt.md"
readonly CUSTOM_PROMPT_BEGIN='<!-- CCS-CUSTOM-PROMPT:BEGIN -->'
readonly CUSTOM_PROMPT_END='<!-- CCS-CUSTOM-PROMPT:END -->'
```

Change `ALL_VALID_KEYS` to include the optional key without adding it to any provider’s required keys:

```bash
readonly ALL_VALID_KEYS="PROVIDER_TYPE \
ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL ANTHROPIC_FOUNDRY_API_KEY \
ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
CUSTOM_PROMPT"
```

- [ ] **Step 2: Add scope-aware CLAUDE.md path resolution**

Immediately after `get_settings_path`, add:

```bash
# Return the CLAUDE.md path managed for the current CCS scope.
get_claude_md_path() {
    if [[ -n "${CCS_PROJECT_ROOT:-}" ]]; then
        echo "${CCS_PROJECT_ROOT}/CLAUDE.md"
    else
        echo "${HOME}/.claude/CLAUDE.md"
    fi
}
```

Do not use `CCS_SETTINGS_PATH` here: global custom prompt always targets `$HOME/.claude/CLAUDE.md`; project prompt always targets project-root `CLAUDE.md`.

- [ ] **Step 3: Add exact per-profile enable detection**

Immediately after `read_profile`, add:

```bash
# Return success only when a profile explicitly sets CUSTOM_PROMPT=1.
is_custom_prompt_enabled() {
    local profile="$1"
    local config key value

    config=$(read_profile "$profile") || return 1
    while IFS='=' read -r key value; do
        if [[ "$key" == "CUSTOM_PROMPT" ]]; then
            if [[ "$value" == "1" ]]; then
                return 0
            fi
            return 1
        fi
    done <<< "$config"

    return 1
}
```

This intentionally treats missing, `0`, `true`, `yes`, and empty values as disabled.

- [ ] **Step 4: Add atomic marker block removal**

Add after `is_custom_prompt_enabled`:

```bash
# Remove the CCS-managed prompt block.
# Returns: 0=removed, 1=no block/file, 2=malformed markers or write error.
remove_custom_prompt_block() {
    local target="$1"
    [[ -f "$target" ]] || return 1

    local begin_count end_count begin_line end_line
    begin_count=$(grep -Fxc -- "$CUSTOM_PROMPT_BEGIN" "$target" 2>/dev/null || true)
    end_count=$(grep -Fxc -- "$CUSTOM_PROMPT_END" "$target" 2>/dev/null || true)

    if [[ "$begin_count" -eq 0 && "$end_count" -eq 0 ]]; then
        return 1
    fi

    if [[ "$begin_count" -ne 1 || "$end_count" -ne 1 ]]; then
        warn "Malformed CCS custom prompt markers in $target; file left unchanged"
        return 2
    fi

    begin_line=$(grep -Fnx -- "$CUSTOM_PROMPT_BEGIN" "$target" | cut -d: -f1)
    end_line=$(grep -Fnx -- "$CUSTOM_PROMPT_END" "$target" | cut -d: -f1)
    if [[ "$begin_line" -ge "$end_line" ]]; then
        warn "Malformed CCS custom prompt marker order in $target; file left unchanged"
        return 2
    fi

    local tmpfile mode
    tmpfile=$(mktemp "${target}.ccs.XXXXXX") || {
        warn "Cannot create temporary file for $target"
        return 2
    }
    mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || echo 644)

    if ! awk -v begin="$CUSTOM_PROMPT_BEGIN" -v end="$CUSTOM_PROMPT_END" '
        $0 == begin {
            if (count > 0 && lines[count] == "") count--
            skipping = 1
            next
        }
        skipping && $0 == end {
            skipping = 0
            skip_blank_after = 1
            next
        }
        skipping { next }
        skip_blank_after && $0 == "" {
            skip_blank_after = 0
            next
        }
        {
            skip_blank_after = 0
            lines[++count] = $0
        }
        END {
            for (i = 1; i <= count; i++) print lines[i]
        }
    ' "$target" > "$tmpfile"; then
        rm -f "$tmpfile"
        warn "Cannot remove custom prompt block from $target"
        return 2
    fi

    chmod "$mode" "$tmpfile" 2>/dev/null || true
    if ! mv "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        warn "Cannot replace $target after custom prompt removal"
        return 2
    fi

    return 0
}
```

The awk buffer removes one CCS-owned separator blank line immediately before/after the block while preserving all other user content.

- [ ] **Step 5: Add atomic prompt injection**

Add after `remove_custom_prompt_block`:

```bash
# Replace any existing managed block with the current custom prompt body.
inject_custom_prompt_block() {
    local target="$1"
    local prompt_source="$2"

    if [[ ! -s "$prompt_source" ]]; then
        warn "Custom prompt file missing or empty: $prompt_source"
        return 1
    fi

    if grep -Fq -- "$CUSTOM_PROMPT_BEGIN" "$prompt_source" || \
       grep -Fq -- "$CUSTOM_PROMPT_END" "$prompt_source"; then
        warn "Custom prompt file contains reserved CCS marker text: $prompt_source"
        return 1
    fi

    local remove_status=0
    if remove_custom_prompt_block "$target"; then
        :
    else
        remove_status=$?
        if [[ "$remove_status" -ne 1 ]]; then
            return 1
        fi
    fi

    local target_dir tmpfile mode last_byte_lines last_line
    target_dir=$(dirname "$target")
    if ! mkdir -p "$target_dir"; then
        warn "Cannot create CLAUDE.md directory: $target_dir"
        return 1
    fi

    tmpfile=$(mktemp "${target}.ccs.XXXXXX") || {
        warn "Cannot create temporary file for $target"
        return 1
    }
    mode=644

    if [[ -f "$target" ]]; then
        mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || echo 644)
        if ! cat "$target" > "$tmpfile"; then
            rm -f "$tmpfile"
            warn "Cannot read existing CLAUDE.md: $target"
            return 1
        fi
    fi

    if [[ -s "$tmpfile" ]]; then
        last_byte_lines=$(tail -c 1 "$tmpfile" | wc -l | tr -d ' ')
        if [[ "$last_byte_lines" == "0" ]]; then
            printf '\n' >> "$tmpfile"
        fi
        last_line=$(tail -n 1 "$tmpfile")
        if [[ -n "$last_line" ]]; then
            printf '\n' >> "$tmpfile"
        fi
    fi

    printf '%s\n' "$CUSTOM_PROMPT_BEGIN" >> "$tmpfile"
    cat "$prompt_source" >> "$tmpfile"
    last_byte_lines=$(tail -c 1 "$prompt_source" | wc -l | tr -d ' ')
    if [[ "$last_byte_lines" == "0" ]]; then
        printf '\n' >> "$tmpfile"
    fi
    printf '%s\n' "$CUSTOM_PROMPT_END" >> "$tmpfile"

    chmod "$mode" "$tmpfile" 2>/dev/null || true
    if ! mv "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        warn "Cannot replace $target after custom prompt injection"
        return 1
    fi

    return 0
}
```

- [ ] **Step 6: Add orchestration helpers with non-fatal behavior**

Add after `inject_custom_prompt_block`:

```bash
# Remove the managed block for the current scope and report only real removal.
remove_custom_prompt_for_current_scope() {
    local target status
    target=$(get_claude_md_path)

    if remove_custom_prompt_block "$target"; then
        info "Custom prompt: removed from $target"
    else
        status=$?
        # Status 1 is a clean no-op; status 2 already emitted a warning.
        [[ "$status" -eq 1 ]] || true
    fi

    return 0
}

# Synchronize the current scope's managed prompt with the selected profile.
sync_custom_prompt() {
    local profile="$1"
    local target
    target=$(get_claude_md_path)

    if is_custom_prompt_enabled "$profile"; then
        if inject_custom_prompt_block "$target" "$CUSTOM_PROMPT_FILE"; then
            info "Custom prompt: applied → $target"
        fi
    else
        remove_custom_prompt_for_current_scope
    fi

    # Prompt management is best-effort and must never fail provider switching.
    return 0
}
```

- [ ] **Step 7: Run syntax validation**

Run:

```bash
bash -n ccs.sh
```

Expected: exit 0 with no output.

---

### Task 3: Hook prompt synchronization into switch and project clear

**Files:**
- Modify: `ccs.sh:645-755` (`cmd_switch`)
- Modify: `ccs.sh:906-949` (`cmd_clear`)
- Create temporarily: `/tmp/ccs-custom-prompt-smoke.sh`

- [ ] **Step 1: Hook switch after settings update succeeds**

In `cmd_switch`, after the provider `case "$type"` finishes successfully and before `set_active_profile`, add:

```bash
    # Keep the current scope's CLAUDE.md in sync with this profile.
    sync_custom_prompt "$profile"

    # Save active profile
    set_active_profile "$profile"
```

Do not place the hook before settings validation/update. A missing prompt must warn but the settings switch and active-profile state still complete.

- [ ] **Step 2: Remove project prompt in every successful `cmd_clear` path**

In the `settings_path` missing branch, change the success path to:

```bash
    if [[ ! -f "$settings_path" ]]; then
        warn "No project settings file found: $settings_path"
        rm -f "$state_file"
        remove_custom_prompt_for_current_scope
        success "Removed project state file (nothing else to do)"
        return 0
    fi
```

In the no-env branch, change the success path to:

```bash
    if [[ -z "$env_keys" ]]; then
        warn "No provider env keys in project settings"
        rm -f "$state_file"
        remove_custom_prompt_for_current_scope
        success "Removed project state file (nothing else to do)"
        return 0
    fi
```

After confirmed `jq 'del(.env)'` and state removal, add:

```bash
    jq 'del(.env)' "$settings_path" > "$tmpfile" && mv "$tmpfile" "$settings_path"
    rm -f "$state_file"
    remove_custom_prompt_for_current_scope
    success "Cleared project provider config. This project now uses the global profile."
```

If the user declines the clear confirmation, do not remove the prompt block.

- [ ] **Step 3: Create a disposable end-to-end smoke test**

Write `/tmp/ccs-custom-prompt-smoke.sh` exactly as follows:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo="/home/kimbui/service-apps/claude-code-switch"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
home="$sandbox/home"
project="$sandbox/project"

mkdir -p "$home/.ccs/custom-model" "$home/.claude" "$project/.git"
printf '1.4.7\n' > "$home/.ccs/VERSION"
cp "$repo/custom-model/gpt-custom-prompt.md" \
   "$home/.ccs/custom-model/gpt-custom-prompt.md"
printf '# User global instructions\n' > "$home/.claude/CLAUDE.md"
printf '{}\n' > "$home/.claude/settings.json"

cat > "$home/.ccs/provider.conf" <<'CONF'
[gpt-test]
ANTHROPIC_AUTH_TOKEN=test-token
ANTHROPIC_BASE_URL=https://example.invalid
ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-test
ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-test
ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-test
CUSTOM_PROMPT=1

[plain-test]
ANTHROPIC_AUTH_TOKEN=test-token
ANTHROPIC_BASE_URL=https://example.invalid
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-test
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-test
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-test
CONF
chmod 600 "$home/.ccs/provider.conf"

run_global() {
    HOME="$home" CCS_SETTINGS_PATH="$home/.claude/settings.json" \
        bash "$repo/ccs.sh" -y "$@"
}

run_global gpt-test >/tmp/ccs-smoke-global-1.log
[[ $(grep -Fxc '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' "$home/.claude/CLAUDE.md") -eq 1 ]]
[[ $(grep -Fxc '<!-- CCS-CUSTOM-PROMPT:END -->' "$home/.claude/CLAUDE.md") -eq 1 ]]
grep -Fq '# User global instructions' "$home/.claude/CLAUDE.md"
grep -Fq '# Evidence-Bounded Execution Policy' "$home/.claude/CLAUDE.md"

run_global gpt-test >/tmp/ccs-smoke-global-2.log
[[ $(grep -Fxc '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' "$home/.claude/CLAUDE.md") -eq 1 ]]

run_global plain-test >/tmp/ccs-smoke-global-remove.log
! grep -Fq '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' "$home/.claude/CLAUDE.md"
grep -Fq '# User global instructions' "$home/.claude/CLAUDE.md"

rm "$home/.ccs/custom-model/gpt-custom-prompt.md"
run_global gpt-test >/tmp/ccs-smoke-missing.log
! grep -Fq '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' "$home/.claude/CLAUDE.md"
grep -Fq 'Custom prompt file missing or empty' /tmp/ccs-smoke-missing.log
cp "$repo/custom-model/gpt-custom-prompt.md" \
   "$home/.ccs/custom-model/gpt-custom-prompt.md"

(
    cd "$project"
    HOME="$home" bash "$repo/ccs.sh" -y -p gpt-test \
        >/tmp/ccs-smoke-project.log
)
[[ -f "$project/CLAUDE.md" ]]
grep -Fq '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' "$project/CLAUDE.md"
! grep -Fq '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' "$home/.claude/CLAUDE.md"

(
    cd "$project"
    HOME="$home" bash "$repo/ccs.sh" -y -p clear \
        >/tmp/ccs-smoke-project-clear.log
)
! grep -Fq '<!-- CCS-CUSTOM-PROMPT:BEGIN -->' "$project/CLAUDE.md"

echo 'custom prompt smoke test: PASS'
```

- [ ] **Step 4: Run the smoke test and verify it initially catches integration mistakes**

Run:

```bash
chmod +x /tmp/ccs-custom-prompt-smoke.sh
/tmp/ccs-custom-prompt-smoke.sh
```

Expected after the hooks/helpers are correct:

```text
custom prompt smoke test: PASS
```

If it fails, inspect the named `/tmp/ccs-smoke-*.log` file for the exact failed stage; fix only the implementation defect, then rerun.

- [ ] **Step 5: Verify malformed markers are left unchanged**

Run this focused sandbox command after the smoke test:

```bash
sandbox=$(mktemp -d)
mkdir -p "$sandbox/home/.ccs/custom-model" "$sandbox/home/.claude"
printf '1.4.7\n' > "$sandbox/home/.ccs/VERSION"
cp custom-model/gpt-custom-prompt.md "$sandbox/home/.ccs/custom-model/gpt-custom-prompt.md"
printf '{}\n' > "$sandbox/home/.claude/settings.json"
printf '<!-- CCS-CUSTOM-PROMPT:BEGIN -->\nuser-edited-without-end\n' > "$sandbox/home/.claude/CLAUDE.md"
cat > "$sandbox/home/.ccs/provider.conf" <<'CONF'
[plain-test]
ANTHROPIC_AUTH_TOKEN=test-token
ANTHROPIC_BASE_URL=https://example.invalid
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-test
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-test
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-test
CONF
before=$(sha256sum "$sandbox/home/.claude/CLAUDE.md" | cut -d' ' -f1)
HOME="$sandbox/home" CCS_SETTINGS_PATH="$sandbox/home/.claude/settings.json" \
    bash ccs.sh -y plain-test > "$sandbox/output.log"
after=$(sha256sum "$sandbox/home/.claude/CLAUDE.md" | cut -d' ' -f1)
[[ "$before" == "$after" ]]
grep -Fq 'Malformed CCS custom prompt markers' "$sandbox/output.log"
rm -rf "$sandbox"
```

Expected: exit 0; malformed user file hash is unchanged; warning is present.

---

### Task 4: Ship the canonical prompt through install and update

**Files:**
- Modify: `install.sh:136-160`
- Modify: `ccs.sh:1546-1584` (`cmd_update`)
- Create temporarily: `/tmp/ccs-custom-prompt-update-smoke.sh`

- [ ] **Step 1: Create the custom-model directory during install**

In `install_ccs`, extend directory creation:

```bash
    # Create directories
    mkdir -p "$CCS_DIR"
    mkdir -p "${CCS_DIR}/backups"
    mkdir -p "${CCS_DIR}/custom-model"
```

- [ ] **Step 2: Download the prompt during install without making core install fatal**

After the existing completion-file downloads, add:

```bash
    if ! download_file "custom-model/gpt-custom-prompt.md" \
        "${CCS_DIR}/custom-model/gpt-custom-prompt.md"; then
        warn "CCS installed without the optional custom prompt file"
    fi
```

The existing `download_file` error is expected; wrapping with `if !` prevents `set -e` from aborting core installation.

- [ ] **Step 3: Download and overwrite the runtime prompt during a successful update**

In `cmd_update`, after replacing `${CCS_DIR}/ccs.sh` and writing `${CCS_DIR}/VERSION`, but before the success message, add:

```bash
        # The repository copy is canonical; overwrite the runtime prompt on update.
        local prompt_tmp
        prompt_tmp=$(mktemp)
        if curl -sf --max-time 30 -o "$prompt_tmp" \
            "${REPO_URL}/custom-model/gpt-custom-prompt.md"; then
            mkdir -p "$CUSTOM_PROMPT_DIR"
            mv "$prompt_tmp" "$CUSTOM_PROMPT_FILE"
        else
            rm -f "$prompt_tmp"
            warn "Updated CCS, but could not update the custom prompt file"
        fi

        success "Updated to v${latest}"
```

Keep the update successful if only the optional prompt download fails.

- [ ] **Step 4: Validate both scripts parse**

Run:

```bash
bash -n ccs.sh
bash -n install.sh
```

Expected: both exit 0 with no output.

- [ ] **Step 5: Create a disposable update-path smoke test with a fake curl**

Write `/tmp/ccs-custom-prompt-update-smoke.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo="/home/kimbui/service-apps/claude-code-switch"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
home="$sandbox/home"
bin="$sandbox/bin"
mkdir -p "$home/.ccs" "$bin"
printf '1.4.6\n' > "$home/.ccs/VERSION"
printf '# stale local prompt\n' > "$home/.ccs/stale-prompt.md"

cat > "$bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=''
url="${!#}"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == '-o' ]]; then
        out="${args[$((i+1))]}"
    fi
done
case "$url" in
    */VERSION)
        if [[ -n "$out" ]]; then printf '1.4.7\n' > "$out"; else printf '1.4.7\n'; fi
        ;;
    */ccs.sh)
        cp "$CCS_FIXTURE_SCRIPT" "$out"
        ;;
    */custom-model/gpt-custom-prompt.md)
        cp "$CCS_FIXTURE_PROMPT" "$out"
        ;;
    *)
        echo "unexpected curl URL: $url" >&2
        exit 1
        ;;
esac
CURL
chmod +x "$bin/curl"

PATH="$bin:$PATH" \
HOME="$home" \
CCS_FIXTURE_SCRIPT="$repo/ccs.sh" \
CCS_FIXTURE_PROMPT="$repo/custom-model/gpt-custom-prompt.md" \
bash "$repo/ccs.sh" -y update > "$sandbox/update.log"

[[ $(cat "$home/.ccs/VERSION") == '1.4.7' ]]
[[ -s "$home/.ccs/ccs.sh" ]]
cmp "$repo/custom-model/gpt-custom-prompt.md" \
    "$home/.ccs/custom-model/gpt-custom-prompt.md"
grep -Fq 'Updated to v1.4.7' "$sandbox/update.log"
echo 'custom prompt update smoke test: PASS'
```

- [ ] **Step 6: Run update smoke test**

Run:

```bash
chmod +x /tmp/ccs-custom-prompt-update-smoke.sh
/tmp/ccs-custom-prompt-update-smoke.sh
```

Expected:

```text
custom prompt update smoke test: PASS
```

---

### Task 5: Document profile opt-in and lifecycle

**Files:**
- Modify: `provider.conf.example:7-30`
- Modify: `README.md:143-235`
- Optional small edit: `custom-model/specs.txt` (link to approved design only; do not duplicate it)

- [ ] **Step 1: Document the optional key in `provider.conf.example`**

After the provider-format introduction and before type-specific required keys, add:

```ini
# Optional per-profile behavior:
#   CUSTOM_PROMPT=1                    Inject the CCS-managed custom prompt into
#                                      CLAUDE.md when this profile is active.
#                                      Missing or any value other than 1 = off.
```

Do not add the key to every sample profile; keeping it commented communicates default-off behavior.

- [ ] **Step 2: Add runtime prompt file to the README directory tree**

Under `~/.ccs/` in “Directory structure”, add:

```text
├── custom-model/
│   └── gpt-custom-prompt.md  # Canonical runtime copy (overwritten on update)
```

- [ ] **Step 3: Add a focused README subsection after “Managed keys”**

Add this exact subsection:

````markdown
### Optional custom prompt per profile

Set `CUSTOM_PROMPT=1` in a profile to let CCS manage the bundled custom prompt for that profile:

```ini
[gpt-standard]
ANTHROPIC_AUTH_TOKEN=sk-your-key-here
ANTHROPIC_BASE_URL=https://api.example.com/v1
ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-latest
ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-latest
ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-latest
CUSTOM_PROMPT=1
```

CCS does not infer GPT from the profile or model name. Only the exact value `CUSTOM_PROMPT=1` enables this feature; the default is off.

- Global switch (`ccs <profile>`) manages `~/.claude/CLAUDE.md`.
- Project switch (`ccs -p <profile>`) manages `<project-root>/CLAUDE.md`.
- Switching to a profile without `CUSTOM_PROMPT=1` removes the managed block from the current scope only.
- The managed content is wrapped by `<!-- CCS-CUSTOM-PROMPT:BEGIN -->` and `<!-- CCS-CUSTOM-PROMPT:END -->`. Content inside those markers is owned by CCS and is replaced on the next enabled switch.
- The runtime prompt is `~/.ccs/custom-model/gpt-custom-prompt.md`. Install and update copy it from this repository and updates overwrite local edits.
- Uninstall does not edit user or project `CLAUDE.md` files. Switch to a non-custom-prompt profile first, or manually remove the marked block before uninstalling.

If the runtime prompt file is missing, CCS warns but still completes the provider switch.
````

- [ ] **Step 4: Update “How It Works” switch flow**

Change the numbered flow so it includes prompt synchronization after settings update and before saving/reporting the active profile. The final sequence must state:

1. Read profile/provider type and optional `CUSTOM_PROMPT`.
2. Back up settings.
3. Update managed settings env keys.
4. Apply/remove the managed prompt in the current scope.
5. Save active profile state.
6. Prompt for editor reload.

- [ ] **Step 5: Check docs for stale typo and marker consistency**

Run:

```bash
! rg -n 'gpt-custom-promt' README.md provider.conf.example install.sh ccs.sh
rg -n 'CUSTOM_PROMPT|gpt-custom-prompt|CCS-CUSTOM-PROMPT' \
    README.md provider.conf.example ccs.sh install.sh \
    docs/superpowers/specs/2026-08-08-custom-prompt-claude-md-design.md
```

Expected: no misspelled runtime filename; all feature names/markers use the same spelling and exact constants.

---

### Task 6: Bump and synchronize the CCS version

**Files:**
- Modify: `VERSION:1`
- Modify: `ccs.sh:6`
- Modify: `install.sh:3-5`
- Modify: `ccs.sh:1682-1684` (remove stale hard-coded help version)

- [ ] **Step 1: Bump the release file to 1.4.7**

Set `VERSION` to exactly:

```text
1.4.7
```

- [ ] **Step 2: Synchronize version comments in both scripts**

Set the `ccs.sh` header comment to:

```bash
# Version: 1.4.7
```

Add under the `install.sh` title comment:

```bash
# Version: 1.4.7
```

Runtime `CCS_VERSION` continues to derive from `VERSION`; do not replace that behavior with another hard-coded constant.

- [ ] **Step 3: Remove stale hard-coded version from general help**

The single-quoted help heredoc currently says `CCS - Claude Code Switch v1.0.0`. Change that line to version-neutral text:

```text
CCS - Claude Code Switch
```

`ccs version` and `ccs status` remain the authoritative dynamic version output.

- [ ] **Step 4: Verify all release values are synchronized**

Run:

```bash
test "$(cat VERSION)" = "1.4.7"
grep -Fq '# Version: 1.4.7' ccs.sh
grep -Fq '# Version: 1.4.7' install.sh
! grep -Fq 'Claude Code Switch v1.0.0' ccs.sh
bash -n ccs.sh
bash -n install.sh
```

Expected: all commands return 0.

---

### Task 7: Run complete verification and stage for user review

**Files:**
- Verify all modified files
- Stage only; do not commit

- [ ] **Step 1: Run syntax and whitespace checks**

Run:

```bash
bash -n ccs.sh
bash -n install.sh
git diff --check
```

Expected: all commands return 0 with no errors.

- [ ] **Step 2: Run both disposable integration suites against the final code**

Run:

```bash
/tmp/ccs-custom-prompt-smoke.sh
/tmp/ccs-custom-prompt-update-smoke.sh
```

Expected:

```text
custom prompt smoke test: PASS
custom prompt update smoke test: PASS
```

- [ ] **Step 3: Validate profile config accepts the new key**

Use a sandboxed HOME so real credentials/settings are not read:

```bash
sandbox=$(mktemp -d)
mkdir -p "$sandbox/.ccs"
printf '1.4.7\n' > "$sandbox/.ccs/VERSION"
cat > "$sandbox/.ccs/provider.conf" <<'CONF'
[test]
ANTHROPIC_AUTH_TOKEN=test
ANTHROPIC_BASE_URL=https://example.invalid
ANTHROPIC_DEFAULT_HAIKU_MODEL=test
ANTHROPIC_DEFAULT_OPUS_MODEL=test
ANTHROPIC_DEFAULT_SONNET_MODEL=test
CUSTOM_PROMPT=1
CONF
HOME="$sandbox" bash ccs.sh list > "$sandbox/list.log"
grep -Fq 'test' "$sandbox/list.log"
rm -rf "$sandbox"
```

Expected: exit 0 and profile `test` appears; no “unknown key CUSTOM_PROMPT” validation error.

- [ ] **Step 4: Review the final diff for scope and preservation**

Run:

```bash
git status --short
git diff --stat
git diff -- ccs.sh install.sh provider.conf.example README.md VERSION \
    custom-model/gpt-custom-prompt.md \
    docs/superpowers/specs/2026-08-08-custom-prompt-claude-md-design.md \
    docs/superpowers/plans/2026-08-08-custom-prompt-claude-md.md
```

Check explicitly:

- Existing unrelated edits in `ccs.sh`/`VERSION` were preserved.
- No credential-bearing `~/.ccs/provider.conf` or real user `CLAUDE.md` is staged.
- Only exact marker blocks are managed.
- Global/project scope paths match the approved design.
- Prompt failures remain warnings and do not fail `cmd_switch`.
- No auto-detection by GPT profile/model name was added.

- [ ] **Step 5: Stage implementation files only (no commit)**

Run:

```bash
git add ccs.sh install.sh provider.conf.example README.md VERSION \
    custom-model/gpt-custom-prompt.md custom-model/specs.txt \
    docs/superpowers/specs/2026-08-08-custom-prompt-claude-md-design.md \
    docs/superpowers/plans/2026-08-08-custom-prompt-claude-md.md
```

If Git reports the old tracked misspelled path as a rename, stage its deletion too:

```bash
git add -u custom-model/
```

Expected: files are staged for user review. Do **not** run `git commit`.

- [ ] **Step 6: Report evidence and stop**

Report:

- Files changed.
- Version bumped to `1.4.7`.
- Exact verification commands run and whether each passed.
- Any skipped test or remaining limitation (especially WSL Windows-side global path and uninstall cleanup).
- Explicit statement: “Changes staged; no commit created.”

Then stop and let the user decide how/when to commit.

---

## Plan self-review

### Spec coverage

- Per-profile exact opt-in → Task 2 (`ALL_VALID_KEYS`, `is_custom_prompt_enabled`).
- Global/project path → Task 2 (`get_claude_md_path`) and Task 3 smoke test.
- Idempotent markers and clean removal → Task 2 helpers and Task 3 global repeat/remove checks.
- Malformed-marker protection → Task 2 validation and Task 3 focused hash test.
- Non-fatal prompt failure → Task 2 orchestration and Task 3 missing-file test.
- `cmd_clear` cleanup → Task 3 and project smoke test.
- Repo source/runtime copy → Task 1 rename + Task 4 install/update.
- Docs and overwrite/uninstall policy → Task 5.
- Version bump across `ccs.sh`, `install.sh`, `VERSION` → Task 6.
- Final verification/stage-only → Task 7.

### Placeholder scan

No unresolved placeholders are used. Deferred v1 features are explicitly excluded by the approved design rather than left incomplete.

### Name/signature consistency

The plan consistently uses:

- `CUSTOM_PROMPT`
- `CUSTOM_PROMPT_DIR`, `CUSTOM_PROMPT_FILE`
- `CUSTOM_PROMPT_BEGIN`, `CUSTOM_PROMPT_END`
- `get_claude_md_path`
- `is_custom_prompt_enabled`
- `remove_custom_prompt_block`
- `inject_custom_prompt_block`
- `remove_custom_prompt_for_current_scope`
- `sync_custom_prompt`
- `custom-model/gpt-custom-prompt.md`
