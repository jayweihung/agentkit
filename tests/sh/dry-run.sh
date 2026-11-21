#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- sync --dry-run on a git source: the clone and machine.yaml stay as they are (rules point into the clone) ----------
HD="$T/homed"; DS="$T/drysrc"; mkdir -p "$HD" "$DS/rules" "$DS/skills/da" "$T/dtmp"
(
export HOME="$HD" TMPDIR="$T/dtmp"
dc() { git -C "$DS" add -A && git -C "$DS" -c user.name=t -c user.email=t@t commit -qm "$1"; }
printf 'One.\n' > "$DS/rules/dr.md"; printf -- '---\nname: da\ndescription: a\n---\na1\n' > "$DS/skills/da/SKILL.md"
git -C "$DS" init -q; dc first
kit init "file://$DS" >/dev/null 2>&1; kit add rule dr >/dev/null 2>&1; kit add skill da >/dev/null 2>&1
CD="$HD/agentkit/drysrc"; MY="$HD/.config/agentkit/machine.yaml"; h0=$(git -C "$CD" rev-parse HEAD); cp "$MY" "$T/dmy"
printf 'Two.\n' > "$DS/rules/dr.md"; printf -- '---\nname: da\ndescription: a\n---\na2\n' > "$DS/skills/da/SKILL.md"; dc second
out=$(kit sync --dry-run 2>&1); h=$(printf '%s\n' "$out" | sed -n 's/.*--expect \([0-9]*\).*/\1/p' | head -n 1)
check "sync --dry-run (git source): sees the new commit's skill, the clone and machine.yaml unchanged, no copy left" 'printf "%s\n" "$out" | grep -qF "/da：更新" && [ "$(git -C "$CD" rev-parse HEAD)" = "$h0" ] && grep -qx "One." "$CD/rules/dr.md" && cmp -s "$MY" "$T/dmy" && [ -z "$(ls -d "$TMPDIR"/kit-dry.* 2>/dev/null)" ]'
kit sync --expect "$h" >/dev/null 2>&1; rc=$?
check "sync --expect after a dry run: brings the clone up to date, the same plan" '[ $rc -eq 0 ] && [ "$(git -C "$CD" rev-parse HEAD)" = "$(git -C "$DS" rev-parse HEAD)" ] && grep -qx a2 "$HD/.claude/skills/da/SKILL.md"'
if [ -n "$PWSH" ]; then   # its own HOME: kit.ps1 set it up (it takes unix/kit's copies for edited ones)
    export HOME="$T/homedp"; mkdir -p "$HOME"; kps init "file://$DS" >/dev/null 2>&1; kps add skill da >/dev/null 2>&1
    CD="$HOME/agentkit/drysrc"; MY="$HOME/.config/agentkit/machine.yaml"; h1=$(git -C "$CD" rev-parse HEAD); cp "$MY" "$T/dmy"
    printf -- '---\nname: da\ndescription: a\n---\na3\n' > "$DS/skills/da/SKILL.md"; dc third; out=$(kps sync --dry-run 2>&1)
    check "kit.ps1 sync --dry-run (git source): the same" 'printf "%s\n" "$out" | grep -qF "/da：更新" && [ "$(git -C "$CD" rev-parse HEAD)" = "$h1" ] && cmp -s "$MY" "$T/dmy" && [ -z "$(ls -d "$TMPDIR"/kit-dry.* 2>/dev/null)" ]'
fi
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
