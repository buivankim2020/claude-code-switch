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
<!-- CCS-CUSTOM-PROMPT:ORIGINAL-EOF:NO-NL -->
<contents of gpt-custom-prompt.md>
<!-- CCS-CUSTOM-PROMPT:END -->
```

Placement and ownership:

- BEGIN and END are recognized only when each occupies a complete line (LF or CRLF). Literal marker strings inside prose or code examples are user content.
- Append at end of file when no block exists; replace a valid existing block in place.
- Do not remove or normalize adjacent whitespace.
- If non-empty user content has no final newline, insert one so BEGIN remains a standalone Markdown line and include the `ORIGINAL-EOF:NO-NL` metadata inside the managed block. Removal owns and removes only that inserted LF, restoring the exact original bytes.

Idempotency:

- Re-switch never duplicates the block.
- If the generated file is byte-identical, injection is a no-op: no replacement and no backup slot consumed.
- Content inside markers is fully owned by CCS; user edits inside the block are overwritten on next inject.

## Core helpers (`ccs.sh`)

### Constants

```bash
readonly CUSTOM_PROMPT_DIR="${CCS_DIR}/custom-model"
readonly CUSTOM_PROMPT_FILE="${CUSTOM_PROMPT_DIR}/gpt-custom-prompt.md"
readonly CUSTOM_PROMPT_BEGIN='<!-- CCS-CUSTOM-PROMPT:BEGIN -->'
readonly CUSTOM_PROMPT_END='<!-- CCS-CUSTOM-PROMPT:END -->'
readonly CUSTOM_PROMPT_NO_FINAL_NEWLINE='<!-- CCS-CUSTOM-PROMPT:ORIGINAL-EOF:NO-NL -->'
readonly CUSTOM_PROMPT_BACKUP_LIMIT=50
```

### `is_custom_prompt_enabled(profile) → status`

- Read profile via `read_profile`.
- Return success (bash 0) only when `CUSTOM_PROMPT=1`.

### `get_claude_md_path`

As above.

### `remove_custom_prompt_block(file)`

- Missing file or no exact-line markers → clean no-op (`1`, used internally to suppress UX noise).
- Duplicate, missing, reversed, or malformed markers/metadata → `warn`, leave file unchanged, return failure (`2`).
- Snapshot the resolved target (following a `CLAUDE.md` symlink without replacing the symlink), inspect byte offsets, and build the replacement from exact prefix/suffix byte ranges.
- Remove only the managed range. Remove the preceding LF only when the internal `ORIGINAL-EOF:NO-NL` metadata proves CCS inserted it.
- Never collapse adjacent blank lines or normalize LF/CRLF/final-newline state.
- Before replacement, publish an atomic recovery entry and verify the target still matches the snapshot.

### `inject_custom_prompt_block(file, prompt_src)`

1. If `prompt_src` is missing/empty or contains a reserved marker → `warn`, return non-zero.
2. Resolve symlinks to the referent, snapshot an existing target once, and validate exact-line markers.
3. Build a same-directory temporary replacement from exact byte ranges; replace an existing valid block in place or append when absent.
4. Insert an owned LF + `ORIGINAL-EOF:NO-NL` metadata only when required to keep BEGIN on a standalone line.
5. If the result equals the snapshot, return success without backup or replacement.
6. Otherwise publish a pre-mutation recovery entry, re-check the snapshot, preserve mode, then atomically `mv` the replacement.

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

Failure of inject/remove must **not** roll back or abort `cmd_switch` after settings were already written, but it must propagate to the caller so the final switch output explicitly warns that provider settings changed while `CLAUDE.md` synchronization did not.

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

## Multiline edit strategy

Use **byte-offset inspection + same-directory snapshot/temp file + `mv`**.

- `awk` inspects exact marker lines and reports byte offsets under `LC_ALL=C`; it never prints/reconstructs user lines.
- Buffered `head -c` / `tail -c +N` copy exact preserved ranges, avoiding line-ending normalization and byte-at-a-time I/O.
- Snapshot once, build from that immutable copy, compare the live target before and after backup, then atomically replace it.
- Follow symlinks to their referent so `mv` does not replace the symlink object.
- Avoid embedding the full prompt as a bash heredoc inside `ccs.sh`; append the runtime prompt file with `cat`.

### Recovery entries

Before each non-no-op mutation of an existing file, build a private hidden temporary directory under `~/.ccs/backups/claude-md/`, write `CLAUDE.md`, `target.path`, and `mode`, then rename it to `backup.<unique-id>/`. Only published entries participate in recovery/retention. Keep the 50 most recent entries globally.

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
| Malformed exact-line markers or metadata | Warn; do not rewrite |
| Marker strings inside prose/code | User content; ignored unless each marker is a complete line |
| Prompt contains reserved marker text | Warn; skip inject |
| Existing content has no final newline | Insert owned LF + metadata; restore exact EOF state on removal |
| `CLAUDE.md` is a symlink | Mutate referent; preserve symlink |
| Backup cannot be published | Leave `CLAUDE.md` unchanged and surface synchronization failure in switch output |
| `CUSTOM_PROMPT=true` | Treated as off |
| GPT project then global non-GPT | Only global file cleaned; project file may still hold block (v1 OK) |
| Concurrent editor on CLAUDE.md | Snapshot and compare before/after backup; abort if a change is detected. A tiny final compare-to-rename race remains because editors do not share a lock. |

## Files to change

| File | Change |
|------|--------|
| `ccs.sh` | Constants, helpers, `cmd_switch` / `cmd_clear` hooks, `cmd_update` download, `ALL_VALID_KEYS`, optional status line |
| `install.sh` | Create dir + download prompt file |
| `provider.conf.example` | Commented `CUSTOM_PROMPT=1` |
| `README.md` | Document feature, key, paths, markers, byte preservation, recovery entries, update overwrite policy |
| `tests/custom_prompt_preservation_test.sh` | Regression coverage for LF/CRLF/EOF bytes, literal markers, no-op, backups, symlinks, and failure propagation |
| `VERSION` | Bump (also keep `ccs.sh` / `install.sh` version sources consistent with project practice) |
| `custom-model/gpt-custom-prompt.md` | Rename from `gpt-custom-promt.md` |
| `custom-model/specs.txt` | Optional pointer to this design doc |

## Manual verification checklist

1. Profile with `CUSTOM_PROMPT=1`, global `ccs <profile>` → `~/.claude/CLAUDE.md` contains exactly one marked block with prompt content.
2. Switch to profile without the flag → block removed; compare original and restored bytes for LF, CRLF, trailing blank lines, and missing final newline.
3. Re-switch an unchanged enabled profile → still exactly one block, unchanged inode, and no additional recovery entry.
4. Literal marker strings in prose/code remain untouched.
5. Existing content without a final newline keeps valid Markdown structure while active and returns byte-exactly after removal.
6. A symlinked `CLAUDE.md` remains a symlink and its referent round-trips exactly.
7. `ccs -p <gpt-profile>` → only `<project>/CLAUDE.md` changes; global file untouched.
8. `ccs -p clear` → managed block removed from project `CLAUDE.md`.
9. A failed recovery publication leaves `CLAUDE.md` unchanged and prints a final synchronization warning while provider settings still switch.
10. Delete/rename runtime prompt file, switch enabled profile → settings still switch; warn about missing prompt.
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
