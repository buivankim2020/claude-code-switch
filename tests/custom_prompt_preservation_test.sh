#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.ccs"
printf 'test\n' > "${HOME}/.ccs/VERSION"

# Source the production script without dispatching its CLI main function.
python3 - "$REPO_ROOT/ccs.sh" "${TEST_ROOT}/ccs-under-test.sh" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
needle = '\nmain "$@"\n'
if source.count(needle) != 1:
    raise SystemExit('expected exactly one main dispatch')
Path(sys.argv[2]).write_text(source.replace(needle, '\nif [[ "${CCS_TESTING:-}" != "1" ]]; then\n    main "$@"\nfi\n'))
PY

export CCS_TESTING=1
# shellcheck source=/dev/null
source "${TEST_ROOT}/ccs-under-test.sh"

prompt="${TEST_ROOT}/prompt.md"
printf 'managed prompt\nsecond line\n' > "$prompt"

canonical_prompt="${REPO_ROOT}/custom-model/gpt-custom-prompt.md"
python3 - "$canonical_prompt" <<'PY'
from pathlib import Path
import sys

prompt_text = Path(sys.argv[1]).read_text()
expected = """## Activation indicator

On the first user-facing assistant response of each new conversation, begin with exactly:

🟢 CCS custom prompt active

Show this indicator only once per conversation.
"""
if prompt_text.count(expected) != 1:
    raise SystemExit('FAIL: canonical prompt must contain exactly one activation indicator instruction')
print('PASS: activation-indicator')
PY

assert_round_trip() {
    local name="$1"
    local target="${TEST_ROOT}/${name}.md"
    local original="${target}.original"

    cp "$target" "$original"
    inject_custom_prompt_block "$target" "$prompt"
    remove_custom_prompt_block "$target"

    if ! cmp -s "$original" "$target"; then
        echo "FAIL: $name did not preserve original bytes" >&2
        cmp -l "$original" "$target" >&2 || true
        return 1
    fi
    echo "PASS: $name"
}

no_final="${TEST_ROOT}/no-final-newline.md"
no_final_original="${no_final}.original"
printf '```text\nalpha\n```' > "$no_final"
cp "$no_final" "$no_final_original"
inject_custom_prompt_block "$no_final" "$prompt"
if ! grep -Fqx "$CUSTOM_PROMPT_BEGIN" "$no_final"; then
    echo "FAIL: no-final-newline injection did not use a standalone BEGIN marker" >&2
    exit 1
fi
remove_custom_prompt_block "$no_final"
if ! cmp -s "$no_final_original" "$no_final"; then
    echo "FAIL: no-final-newline did not preserve original bytes" >&2
    exit 1
fi
echo "PASS: no-final-newline"

printf 'alpha\n\n\n' > "${TEST_ROOT}/trailing-blank-lines.md"
assert_round_trip "trailing-blank-lines"

printf 'alpha\r\nbeta\r\n\r\n' > "${TEST_ROOT}/crlf.md"
assert_round_trip "crlf"

: > "${TEST_ROOT}/empty.md"
assert_round_trip "empty"

# Literal marker strings in prose or examples are user content unless each marker
# occupies its own complete line.
inline_markers="${TEST_ROOT}/inline-markers.md"
inline_original="${inline_markers}.original"
printf 'Document %s through %s; keep all of this.' \
    "$CUSTOM_PROMPT_BEGIN" "$CUSTOM_PROMPT_END" > "$inline_markers"
cp "$inline_markers" "$inline_original"
inject_custom_prompt_block "$inline_markers" "$prompt"
remove_custom_prompt_block "$inline_markers"
if ! cmp -s "$inline_original" "$inline_markers"; then
    echo "FAIL: inline marker literals were treated as a managed block" >&2
    exit 1
fi
echo "PASS: inline-marker-literals"

# Malformed exact-line markers and prompt write failures must be atomic.
malformed="${TEST_ROOT}/malformed.md"
printf 'keep\n%s\nuser text\n' "$CUSTOM_PROMPT_BEGIN" > "$malformed"
cp "$malformed" "${malformed}.original"
if inject_custom_prompt_block "$malformed" "$prompt" > "${TEST_ROOT}/malformed-inject.log" 2>&1; then
    echo "FAIL: malformed markers were accepted for injection" >&2
    exit 1
fi
if remove_custom_prompt_block "$malformed" > "${TEST_ROOT}/malformed-remove.log" 2>&1; then
    echo "FAIL: malformed markers were accepted for removal" >&2
    exit 1
fi
cmp -s "${malformed}.original" "$malformed" || { echo "FAIL: malformed target changed" >&2; exit 1; }
echo "PASS: malformed-markers-atomic"

write_failure_target="${TEST_ROOT}/write-failure.md"
cat() { return 1; }
if inject_custom_prompt_block "$write_failure_target" "$prompt" > "${TEST_ROOT}/write-failure.log" 2>&1; then
    unset -f cat
    echo "FAIL: simulated prompt write failure returned success" >&2
    exit 1
fi
unset -f cat
[[ ! -e "$write_failure_target" ]] || { echo "FAIL: write failure created or changed target" >&2; exit 1; }
echo "PASS: prompt-write-failure-atomic"

# Existing managed blocks may have user-owned bytes on both sides. Replacing and
# then removing the block must preserve those outside bytes exactly.
existing="${TEST_ROOT}/existing-block.md"
expected="${TEST_ROOT}/existing-block.expected"
printf 'before\r\n\r\n%s\r\nold managed text\r\n%s\r\n\r\nafter' \
    "$CUSTOM_PROMPT_BEGIN" "$CUSTOM_PROMPT_END" > "$existing"
printf 'before\r\n\r\n\r\nafter' > "$expected"

inject_custom_prompt_block "$existing" "$prompt"
remove_custom_prompt_block "$existing"
if ! cmp -s "$expected" "$existing"; then
    echo "FAIL: existing block changed bytes outside markers" >&2
    cmp -l "$expected" "$existing" >&2 || true
    exit 1
fi
echo "PASS: existing-block-outside-bytes"

# Every mutation of an existing user CLAUDE.md must first publish an exact,
# self-describing recovery entry. Reapplying identical content is a no-op and
# must not consume another recovery slot or replace the file inode.
backup_target="${TEST_ROOT}/backup-target.md"
backup_original="${TEST_ROOT}/backup-target.original"
backup_injected="${TEST_ROOT}/backup-target.injected"
printf 'important user instructions' > "$backup_target"
cp "$backup_target" "$backup_original"

inject_custom_prompt_block "$backup_target" "$prompt"
cp "$backup_target" "$backup_injected"
count_backup_entries() {
    local count=0 entry
    for entry in "${BACKUP_DIR}/claude-md/"backup.*; do
        [[ -d "$entry" ]] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

backup_count_before=$(count_backup_entries)
inode_before=$(stat -c '%i' "$backup_target" 2>/dev/null || stat -f '%i' "$backup_target")
inject_custom_prompt_block "$backup_target" "$prompt"
backup_count_after=$(count_backup_entries)
inode_after=$(stat -c '%i' "$backup_target" 2>/dev/null || stat -f '%i' "$backup_target")
if [[ "$backup_count_before" -ne "$backup_count_after" || "$inode_before" != "$inode_after" ]]; then
    echo "FAIL: identical injection was not a no-op" >&2
    exit 1
fi
echo "PASS: identical-injection-no-op"

remove_custom_prompt_block "$backup_target"

python3 - "$BACKUP_DIR" "$backup_original" "$backup_injected" <<'PY'
from pathlib import Path
import sys

backup_root = Path(sys.argv[1]) / 'claude-md'
expected = [Path(path).read_bytes() for path in sys.argv[2:]]
entries = [path for path in backup_root.glob('backup.*') if path.is_dir()]
actual = []
for entry in entries:
    required = [entry / 'CLAUDE.md', entry / 'target.path', entry / 'mode']
    if not all(path.is_file() for path in required):
        raise SystemExit(f'FAIL: incomplete recovery entry: {entry}')
    actual.append((entry / 'CLAUDE.md').read_bytes())
if list(backup_root.glob('.tmp.*')):
    raise SystemExit('FAIL: temporary recovery entries were published')
for content in expected:
    if content not in actual:
        raise SystemExit('FAIL: exact pre-mutation CLAUDE.md backup not found')
print('PASS: atomic-pre-mutation-backups')
PY

# Mutating through a CLAUDE.md symlink must update its referent without replacing
# the symlink itself.
symlink_referent="${TEST_ROOT}/shared-claude.md"
symlink_target="${TEST_ROOT}/symlink-CLAUDE.md"
printf 'shared instructions' > "$symlink_referent"
cp "$symlink_referent" "${symlink_referent}.original"
ln -s "$symlink_referent" "$symlink_target"
inject_custom_prompt_block "$symlink_target" "$prompt"
[[ -L "$symlink_target" ]] || { echo "FAIL: injection replaced CLAUDE.md symlink" >&2; exit 1; }
remove_custom_prompt_block "$symlink_target"
[[ -L "$symlink_target" ]] || { echo "FAIL: removal replaced CLAUDE.md symlink" >&2; exit 1; }
cmp -s "${symlink_referent}.original" "$symlink_referent" || { echo "FAIL: symlink referent was not preserved" >&2; exit 1; }
echo "PASS: symlink-preserved"

# Prompt synchronization failures must propagate so the caller can report that
# provider settings changed while CLAUDE.md remained untouched.
failure_scope="${TEST_ROOT}/backup-failure-project"
mkdir -p "$failure_scope"
failure_target="${failure_scope}/CLAUDE.md"
printf '%s\nmanaged\n%s\n' "$CUSTOM_PROMPT_BEGIN" "$CUSTOM_PROMPT_END" > "$failure_target"
cp "$failure_target" "${failure_target}.original"
mv "${BACKUP_DIR}/claude-md" "${BACKUP_DIR}/claude-md.saved"
printf 'block backup directory creation' > "${BACKUP_DIR}/claude-md"
export CCS_PROJECT_ROOT="$failure_scope"
failure_log="${TEST_ROOT}/backup-failure.log"
if remove_custom_prompt_for_current_scope > "$failure_log" 2>&1; then
    echo "FAIL: prompt synchronization failure was swallowed" >&2
    exit 1
fi
if ! grep -Fiq 'leaving' "$failure_log"; then
    echo "FAIL: backup failure did not explain that CLAUDE.md was unchanged" >&2
    exit 1
fi
unset CCS_PROJECT_ROOT
cmp -s "${failure_target}.original" "$failure_target" || { echo "FAIL: backup failure changed target" >&2; exit 1; }
rm -f "${BACKUP_DIR}/claude-md"
mv "${BACKUP_DIR}/claude-md.saved" "${BACKUP_DIR}/claude-md"
echo "PASS: synchronization-failure-propagates"

echo "All custom prompt preservation tests passed."
