# Custom Prompt → CLAUDE.md (Design)

**Date:** 2026-08-08  
**Status:** Approved for implementation planning  
**Approach:** A — hook inside `cmd_switch` (bash helpers in `ccs.sh`)  
**Source request:** `custom-model/specs.txt`

## Problem

CCS switches Claude Code provider profiles by rewriting `settings.json` / `settings.local.json` env keys only. GPT-oriented profiles benefit from an extra system-style policy document (`custom-model/gpt-custom-prompt.md`), but today nothing injects that into Claude Code’s instruction files (`CLAUDE.md`). Users must paste/remove content by hand when switching models.

## Goals

1. When switching to a profile that opts in, inject a managed custom-prompt block into the correct `CLAUDE.md` for the active CCS scope (global vs project).
2. When switching to a profile that does not opt in, remove that managed block cleanly if present.
3. Feature is **opt-in per profile** via `provider.conf` (`CUSTOM_PROMPT=1`). Missing key or any value other than `1` means off (default).
4. Prompt body is maintained in the **repo** and shipped to `~/.ccs/` on install/update (repo is source of truth; update overwrites local copy).
5. Switch must still succeed if prompt inject fails (settings switch is primary); inject failures are warnings.

## Non-goals (v1)

- Auto-detect GPT by profile name or model id.
- Global kill-switch in `config.env`.
- Per-profile custom prompt file path / multiple prompt templates.
- Interactive `ccs add` question for `CUSTOM_PROMPT`.
- Auto-stripping every project `CLAUDE.md` on uninstall.
- Full Windows-native `CLAUDE.md` path parity with WSL Windows-side settings paths.
- Automated unit test framework introduction (manual checklist only).

## Decisions (locked)

| Topic | Decision |
|-------|----------|
| Opt-in | Per-profile key `CUSTOM_PROMPT=1` in `provider.conf` only |
| Detection | No name/model heuristics |
| Scope | Same as CCS switch: global or `-p` project |
| CLAUDE.md paths | Global → `~/.claude/CLAUDE.md`; project → `$CCS_PROJECT_ROOT/CLAUDE.md` |
| Markers | HTML comments `<!-- CCS-CUSTOM-PROMPT:BEGIN -->` / `<!-- CCS-CUSTOM-PROMPT:END -->` |
| Runtime prompt path | `~/.ccs/custom-model/gpt-custom-prompt.md` |
| Repo prompt path | `custom-model/gpt-custom-prompt.md` (rename from `gpt-custom-promt.md`) |
| Install/update | Copy/overwrite prompt file from repo |
| Uninstall | Do not auto-edit user `CLAUDE.md`; document manual cleanup |
| Implementation style | Bash helpers in `ccs.sh`; multiline edit via temp file + `awk` (no new hard deps) |

## Architecture

```
cmd_switch(profile)
  validate + read profile
  backup + update settings.json env          # existing
  sync_custom_prompt(profile)                # NEW
  set_active_profile
  success UX (include custom-prompt line when relevant)

cmd_clear (-p only)
  clear project settings env + state         # existing
  remove managed block from project CLAUDE.md  # NEW
```

`ccs reload` already re-enters `cmd_switch`, so it inherits sync for free.

### Scope isolation

- Global switch only touches `~/.claude/CLAUDE.md`.
- Project switch (`ccs -p`) only touches `$CCS_PROJECT_ROOT/CLAUDE.md`.
- Leaving a managed block in the *other* scope is accepted in v1 (same isolation model as settings).

## Profile config

```ini
[gpt-standard]
ANTHROPIC_AUTH_TOKEN=...
ANTHROPIC_BASE_URL=...
ANTHROPIC_DEFAULT_HAIKU_MODEL=...
ANTHROPIC_DEFAULT_OPUS_MODEL=...
ANTHROPIC_DEFAULT_SONNET_MODEL=...
CUSTOM_PROMPT=1
```

Rules:

- Enabled **iff** the profile key `CUSTOM_PROMPT` equals exactly `1` after normal profile parse (trim as existing parser does).
- Values `0`, empty, `true`, `yes`, missing → disabled.
- Add `CUSTOM_PROMPT` to `ALL_VALID_KEYS` so `validate_conf` does not flag it as a typo.
- Do **not** add it to `get_required_keys` for any provider type.

Document the key in `provider.conf.example` as a commented optional line. Do not prompt for it in `cmd_add` in v1.

## CLAUDE.md target resolution

```
get_claude_md_path():
  if CCS_PROJECT_ROOT is set:
    echo "$CCS_PROJECT_ROOT/CLAUDE.md"
  else:
    echo "$HOME/.claude/CLAUDE.md"
```

Notes:

- Independent of `CCS_SETTINGS_PATH` and of WSL Windows settings path logic. v1 always uses `$HOME/.claude/CLAUDE.md` for global.
- Project file is project-root `CLAUDE.md`, not `.claude/CLAUDE.md`.

## Managed block format

```markdown
<!-- CCS-CUSTOM-PROMPT:BEGIN -->
<contents of gpt-custom-prompt.md>
<!-- CCS-CUSTOM-PROMPT:END -->
```

Placement:

- Append at end of file.
- If file is non-empty and does not already end with a newline, add one before the block.
- Prefer a single blank line separator between pre-existing user content and the managed block when the file is non-empty.

Idempotency:

- Inject always runs remove-then-append so GPT→GPT re-switch never duplicates the block.
- Content inside markers is fully owned by CCS; user edits inside the block are overwritten on next inject.

## Core helpers (`ccs.sh`)

### Constants

```bash
readonly CUSTOM_PROMPT_DIR="${CCS_DIR}/custom-model"
readonly CUSTOM_PROMPT_FILE="${CUSTOM_PROMPT_DIR}/gpt-custom-prompt.md"
readonly CUSTOM_PROMPT_BEGIN='<!-- CCS-CUSTOM-PROMPT:BEGIN -->'
readonly CUSTOM_PROMPT_END='<!-- CCS-CUSTOM-PROMPT:END -->'
```

### `is_custom_prompt_enabled(profile) → status`

- Read profile via `read_profile`.
- Return success (bash 0) only when `CUSTOM_PROMPT=1`.

### `get_claude_md_path`

As above.

### `remove_custom_prompt_block(file)`

- Missing file → success no-op.
- No BEGIN marker → success no-op.
- BEGIN without matching END (or END before BEGIN) → `warn`, leave file unchanged, return non-zero.
- Otherwise rewrite file without the managed region (inclusive of markers).
- Collapse at most one extra blank line left solely by removal; do not strip user blank lines aggressively.
- Echo whether a removal occurred (for UX) via return code or a side channel consistent with existing helpers (prefer stdout flag only if needed; default: return 0 always on clean no-op/remove, non-zero only on malformed markers).

### `inject_custom_prompt_block(file, prompt_src)`

1. If `prompt_src` missing or empty → `warn`, return non-zero (do not create empty managed block).
2. If prompt body contains the BEGIN or END marker strings → `warn`, skip inject, return non-zero.
3. `remove_custom_prompt_block` first.
4. `mkdir -p "$(dirname "$file")"` as needed.
5. Append separator + BEGIN + prompt body + END.
6. Preserve user content outside markers.

### `sync_custom_prompt(profile)`

```
target=$(get_claude_md_path)
if is_custom_prompt_enabled profile:
  inject_custom_prompt_block target CUSTOM_PROMPT_FILE
  success/info: "Custom prompt: applied → $target"  (or warn on failure)
else:
  remove_custom_prompt_block target
  if a block was removed: info "Custom prompt: removed from $target"
  if no block: silent
```

Failure of inject/remove must **not** abort `cmd_switch` after settings were already written. Call as best-effort (`sync_custom_prompt ... || true` or internal soft-fail).

## Hook points

| Location | Behavior |
|----------|----------|
| `cmd_switch` after successful settings update, before or after `set_active_profile` (either is fine; prefer after settings write, before final success message so UX can mention it) | `sync_custom_prompt "$profile"` |
| `cmd_clear` after successful project env clear | `remove_custom_prompt_block` on project `CLAUDE.md` |
| `cmd_status` (optional polish) | One line: enabled/disabled for active profile + target path existence |

No changes to `cmd_test` connectivity probes.

## Install / update / uninstall

### Repo layout

```
custom-model/
  gpt-custom-prompt.md   # renamed; canonical body
  specs.txt              # design notes only; not required at runtime
```

### `install.sh`

- `mkdir -p "${CCS_DIR}/custom-model"`
- `download_file "custom-model/gpt-custom-prompt.md" "${CCS_DIR}/custom-model/gpt-custom-prompt.md"`
- Failure to download prompt is a **warning** during install (CCS core still works); document that custom-prompt feature needs the file.

### `cmd_update` in `ccs.sh`

Today update only replaces `ccs.sh` + `VERSION`. Extend to also:

- `mkdir -p "${CUSTOM_PROMPT_DIR}"`
- Download/overwrite `"${REPO_URL}/custom-model/gpt-custom-prompt.md"` → `CUSTOM_PROMPT_FILE`

Always overwrite local prompt on update (repo is source of truth). Document that local edits to `~/.ccs/custom-model/gpt-custom-prompt.md` are replaced on update.

### Uninstall

- Removing `~/.ccs/` deletes the prompt file copy.
- **Do not** automatically edit `~/.claude/CLAUDE.md` or project `CLAUDE.md`.
- Document: switch to a non-custom-prompt profile (or manually delete the marker block) before uninstall if cleanup is desired.

## Multline edit strategy

Prefer **awk + temp file + `mv`**, matching the repo’s existing “rewrite via temp” style (`jq` settings updates).

- No new hard dependency (awk is expected on Linux/macOS/WSL targets CCS already supports).
- Avoid embedding the full prompt as a bash heredoc inside `ccs.sh`.

Pseudo-remove (illustrative):

```awk
BEGIN { skip=0 }
$0 == BEGIN { skip=1; next }
$0 == END { skip=0; next }
!skip { print }
```

Inject: write user content (post-remove) then append markers + `cat` of prompt file.

## UX copy

Noise rules:

| Situation | Output |
|-----------|--------|
| Enabled + inject OK | `Custom prompt: applied → <path>` |
| Enabled + inject fail | `warn` with reason (missing file / malformed / marker collision) |
| Disabled + block removed | `Custom prompt: removed from <path>` |
| Disabled + no block | silent |

Include the applied/removed line near the existing switch success summary.

## Edge cases

| Case | Behavior |
|------|----------|
| Target file missing + inject | Create file with only the managed block |
| Target file missing + remove | No-op |
| Malformed markers | Warn; do not rewrite |
| Prompt contains marker text | Warn; skip inject |
| `CUSTOM_PROMPT=true` | Treated as off |
| GPT project then global non-GPT | Only global file cleaned; project file may still hold block (v1 OK) |
| Concurrent editor on CLAUDE.md | Best-effort write; no file lock (same class of risk as settings.json) |

## Files to change

| File | Change |
|------|--------|
| `ccs.sh` | Constants, helpers, `cmd_switch` / `cmd_clear` hooks, `cmd_update` download, `ALL_VALID_KEYS`, optional status line |
| `install.sh` | Create dir + download prompt file |
| `provider.conf.example` | Commented `CUSTOM_PROMPT=1` |
| `README.md` | Document feature, key, paths, markers, update overwrite policy |
| `VERSION` | Bump (also keep `ccs.sh` / `install.sh` version sources consistent with project practice) |
| `custom-model/gpt-custom-prompt.md` | Rename from `gpt-custom-promt.md` |
| `custom-model/specs.txt` | Optional pointer to this design doc |

## Manual verification checklist

1. Profile with `CUSTOM_PROMPT=1`, global `ccs <profile>` → `~/.claude/CLAUDE.md` contains exactly one marked block with prompt content.
2. Switch to profile without the flag → block removed from global file; user content outside markers preserved.
3. Re-switch between two `CUSTOM_PROMPT=1` profiles → still exactly one block; content matches current prompt file.
4. `ccs -p <gpt-profile>` → only `<project>/CLAUDE.md` changes; global file untouched.
5. `ccs -p clear` → managed block removed from project `CLAUDE.md`.
6. Delete/rename runtime prompt file, switch enabled profile → settings still switch; warn about missing prompt.
7. `validate_conf` / profile load does not error on `CUSTOM_PROMPT` key.
8. Install path creates `~/.ccs/custom-model/gpt-custom-prompt.md`; update overwrites it.

## Testing notes

Repo has no unit test harness. v1 verification is the manual checklist above. Do not block the feature on introducing bats/pytest.

## Open follow-ups (explicitly deferred)

- `ccs doctor` to scan known projects for orphan managed blocks.
- Optional uninstall confirm to strip global CLAUDE.md block.
- `CUSTOM_PROMPT_FILE=` per profile.
- Broader feature-flag system in `config.env`.

## Self-review

- No TBD/placeholder sections left for v1 behavior.
- Consistent with locked decisions: per-profile only, markers, scope paths, install overwrite.
- Scope is one feature vertical (switch-time CLAUDE.md sync + ship prompt file).
- Ambiguity resolved: only value `1` enables; project path is root `CLAUDE.md`; update overwrites prompt; uninstall does not strip CLAUDE.md.
