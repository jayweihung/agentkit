#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# ---------- init ----------
out=$(kit init "$TEAM" 2>&1); rc=$?
check "init exit 0" '[ $rc -eq 0 ]'
check "include pulled third-party" 'grep -qF "$TP" "$HOME/.config/agentkit/machine.yaml"'
check "recommended added" 'grep -q "added: \[rule:coding-style, skill:gerrit-workflow\]" "$HOME/.config/agentkit/machine.yaml"'
check "CLAUDE.md keeps user text" 'head -2 "$HOME/.claude/CLAUDE.md" | grep -q "Be brief."'
check "CLAUDE.md imports required rule (kit's copy of it, kit 0.13.0)" 'grep -qxF "@$HOME/.config/agentkit/store/rules/security.md" "$HOME/.claude/CLAUDE.md" && cmp -s "$TEAM/rules/security.md" "$HOME/.config/agentkit/store/rules/security.md"'
check "CLAUDE.md imports recommended rule" 'grep -qxF "@$HOME/.config/agentkit/store/rules/coding-style.md" "$HOME/.claude/CLAUDE.md"'
check "third-party skill copied with LICENSE" '[ -f "$HOME/.claude/skills/gerrit-workflow/LICENSE" ]'
check "own skill untouched" '[ "$(cat "$HOME/.claude/skills/my-own/SKILL.md")" = "my own skill" ]'
check "deny added, user deny kept" '[ "$(jget "$HOME/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"Bash(rm-rf:*)\",\"mcp__gerrit__submit_change\"]" ]'
check "settings other keys kept" '[ "$(jget "$HOME/.claude/settings.json" model)" = "\"opus\"" ]'
check "claude.json untouched (no mcp yet)" 'cmp -s "$HOME/.claude.json" "$T/claude.json.orig"'

# ---------- add ----------
kit add skill gerrit-review >/dev/null 2>&1
check "add skill" '[ -f "$HOME/.claude/skills/gerrit-review/SKILL.md" ]'
kit add mcp gerrit >/dev/null 2>&1
check "mcp written" '[ "$(jget "$HOME/.claude.json" mcpServers.gerrit.command)" = "\"uvx\"" ]'
check "claude.json stays private (600)" '[ "$(ls -l "$HOME/.claude.json" | cut -c1-10)" = "-rw-------" ]'
check "no temp files left" '[ -z "$(ls -a "$HOME" | grep kit\\.)" ]'
check "mcp env not expanded" 'jget "$HOME/.claude.json" mcpServers.gerrit.env | grep -qF "\${HOME}/.config/gerrit"'
check "claude.json other data kept" 'jget "$HOME/.claude.json" projects | grep -qF "中文 \\\"q\\\""'
out=$(kit add skill nope 2>&1); rc=$?; check "add unknown fails with a message" '[ $rc -ne 0 ] && echo "$out" | grep -q "找不到 skill:nope"'
MY="$HOME/.config/agentkit/machine.yaml"; cp "$MY" "$T/my.keep"
out=$(kit add skill gerrit-review nope 2>&1); rc=$?
check "add several: one not found, none added" '[ $rc -ne 0 ] && echo "$out" | grep -q "找不到 skill:nope" && cmp -s "$MY" "$T/my.keep"'
kit rm skill gerrit-review >/dev/null 2>&1; kit rm skill gerrit-workflow >/dev/null 2>&1
out=$(kit add skill gerrit-review gerrit-workflow 2>&1); rc=$?
check "add several at once (the whole account)" '[ $rc -eq 0 ] && [ -f "$HOME/.claude/skills/gerrit-review/SKILL.md" ] && [ -f "$HOME/.claude/skills/gerrit-workflow/SKILL.md" ] && ! grep -q "^removed:.*gerrit" "$MY"'
out=$(kit add --dir "$T" skill gerrit-review gerrit-workflow 2>&1); rc=$?
check "add --dir: one at a time" '[ $rc -ne 0 ] && echo "$out" | grep -q 用法'
cp "$T/my.keep" "$MY"; kit sync >/dev/null 2>&1

# ---------- rm ----------
out=$(kit rm rule security 2>&1); rc=$?
check "required cannot be removed" '[ $rc -ne 0 ] && echo "$out" | grep -q 團隊必備'
kit rm skill gerrit-workflow >/dev/null 2>&1
check "rm skill deletes copy" '[ ! -e "$HOME/.claude/skills/gerrit-workflow" ]'
kit sync >/dev/null 2>&1
check "removed stays removed after sync" '[ ! -e "$HOME/.claude/skills/gerrit-workflow" ]'

# ---------- hand edits and new items ----------
echo "my change" >> "$HOME/.claude/skills/gerrit-review/SKILL.md"
echo "team change" >> "$TEAM/skills/gerrit-review/SKILL.md"
out=$(kit sync 2>&1)
check "hand-edited skill not overwritten" 'grep -q "my change" "$HOME/.claude/skills/gerrit-review/SKILL.md" && echo "$out" | grep -q 手動改過'
# look first: kit sync --dry-run lists what it would do with skills and a hash; --expect HASH does it only while that list holds
hsnap() { find "$HOME/.claude" "$HOME/.agents" "$HOME/.config/agentkit/state.tsv" -type f -print0 2>/dev/null | xargs -0 cksum | LC_ALL=C sort; }
hashof() { printf '%s\n' "$1" | LC_ALL=C sed -n 's/.*--expect \([0-9][0-9]*\).*/\1/p' | head -n 1; }
hsnap > "$T/dr.snap"
out=$(kit sync --force --dry-run 2>&1); rc=$?; h=$(hashof "$out")
check "sync --force --dry-run: your edited skill backed up then replaced, a hash, nothing changed" '[ $rc -eq 0 ] && echo "$out" | grep -qF "/gerrit-review：你改過的先備份，再換新的" && [ -n "$h" ] && echo "$out" | grep -qF "kit sync --force --expect $h" && hsnap | cmp -s - "$T/dr.snap"'
out=$(kit sync --dry-run 2>&1)
check "sync --dry-run without --force: your edited skill skipped, another hash" 'echo "$out" | grep -qF "/gerrit-review：你改過：跳過" && [ "$(hashof "$out")" != "$h" ] && hsnap | cmp -s - "$T/dr.snap"'
out=$(kit sync --dry-run 2>&1)
check "sync --dry-run twice: the same hash" '[ "$(hashof "$out")" = "$(hashof "$(kit sync --dry-run 2>&1)")" ]'
echo "my change 2" >> "$HOME/.claude/skills/gerrit-review/SKILL.md"
out=$(kit sync --force --expect "$h" 2>&1); rc=$?
check "sync --expect: you changed the skill after --dry-run: nothing changed, says look again" '[ $rc -ne 0 ] && echo "$out" | grep -q "清單跟 --dry-run" && grep -q "my change 2" "$HOME/.claude/skills/gerrit-review/SKILL.md" && [ ! -d "$HOME/.config/agentkit/backups" ]'
out=$(kit sync --dry-run --expect 1 2>&1); rc=$?
check "sync: --dry-run with --expect, or --expect alone without a hash: usage" '[ $rc -ne 0 ] && echo "$out" | grep -q 不能一起用 && ! kit sync --expect >/dev/null 2>&1 && ! kit sync --bogus >/dev/null 2>&1'
if [ -n "$PWSH" ]; then
    out=$(kps sync --force --dry-run 2>&1); b=$(hashof "$out")
    check "kit.ps1 sync --force --dry-run: the same list (its own hash); a wrong hash changes nothing" 'echo "$out" | grep -qF "/gerrit-review：你改過的先備份，再換新的" && [ -n "$b" ] && ! kps sync --force --expect 1 >/dev/null 2>&1 && grep -q "my change 2" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
fi
kit sync --force --expect "$(hashof "$(kit sync --force --dry-run 2>&1)")" >/dev/null 2>&1
check "--force overwrites" 'grep -q "team change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
check "--force keeps your edit as a backup (outside the skills folder)" 'grep -q "my change" "$HOME"/.config/agentkit/backups/skills/gerrit-review-*/SKILL.md'
# Python's caches (written next to a skill's scripts when they run) are not part of the skill: not a hand edit, not copied
G="$HOME/.claude/skills/gerrit-review"
mkdir -p "$G/scripts/__pycache__" "$TEAM/skills/gerrit-review/scripts/__pycache__"
printf '\0\1\2' > "$G/scripts/__pycache__/x.cpython-314.pyc"; printf '\0\1\2' > "$G/y.pyc"
printf '\0\1\2' > "$TEAM/skills/gerrit-review/scripts/__pycache__/x.cpython-314.pyc"
out=$(kit sync 2>&1)
check "python caches in a skill's copy: not a hand edit" '! echo "$out" | grep -q 手動改過'
echo "team change 2" >> "$TEAM/skills/gerrit-review/SKILL.md"
out=$(kit sync 2>&1)
check "... the skill still updates; the source's caches are not copied" 'grep -q "team change 2" "$G/SKILL.md" && [ ! -e "$G/scripts/__pycache__" ] && ! echo "$out" | grep -q 手動改過'
rm -rf "$TEAM/skills/gerrit-review/scripts"
# the copy already became the source's new version some other way (another tool, a copy by hand): not a hand edit
echo "team change 3" >> "$TEAM/skills/gerrit-review/SKILL.md"; cp "$TEAM/skills/gerrit-review/SKILL.md" "$G/SKILL.md"
out=$(kit sync 2>&1)
check "a copy that already equals the source's new version: not a hand edit, kit's again" '! echo "$out" | grep -q 手動改過 && grep -q "team change 3" "$G/SKILL.md" && ! echo "$(kit sync 2>&1)" | grep -q 手動改過'
mkdir -p "$TEAM/skills/team-build"; printf -- '---\nname: team-build\ndescription: b\n---\nx\n' > "$TEAM/skills/team-build/SKILL.md"
out=$(kit sync 2>&1)
check "new item announced" 'echo "$out" | grep -q "新： skill:team-build"'
out=$(kit sync 2>&1)
check "announced only once" '! echo "$out" | grep -q "新："'
# a skill you changed is never deleted: kit rm keeps it (yours from then on), sync --force backs it up first
kit add skill team-build >/dev/null 2>&1
echo "my build" >> "$HOME/.claude/skills/team-build/SKILL.md"
out=$(kit rm skill team-build 2>&1)
check "rm of a hand-edited skill: kept, kit says so" 'grep -q "my build" "$HOME/.claude/skills/team-build/SKILL.md" && echo "$out" | grep -q 沒有刪'
out=$(kit sync --force 2>&1)
check "... yours from then on: sync --force leaves it, says nothing" 'grep -q "my build" "$HOME/.claude/skills/team-build/SKILL.md" && ! echo "$out" | grep -q team-build'
rm -rf "$HOME/.claude/skills/team-build"
kit add skill team-build >/dev/null 2>&1
echo "my build 2" >> "$HOME/.claude/skills/team-build/SKILL.md"
M="$HOME/.config/agentkit/machine.yaml"; cp "$M" "$T/m.bak"
awk '/^added:/ { gsub(/, skill:team-build|skill:team-build, |skill:team-build/, "") } { print }' "$T/m.bak" > "$M"
out=$(kit sync --force 2>&1)
check "taken out + sync --force: the copy goes, your edit kept as a backup" '[ ! -e "$HOME/.claude/skills/team-build" ] && grep -q "my build 2" "$HOME"/.config/agentkit/backups/skills/team-build-*/SKILL.md && echo "$out" | grep -q 備份在'

# ---------- a skill folder that is not kit's ----------
mkdir -p "$TEAM/skills/clash" "$HOME/.claude/skills/clash"
printf -- '---\nname: clash\ndescription: team\n---\nteam clash\n' > "$TEAM/skills/clash/SKILL.md"; echo "mine" > "$HOME/.claude/skills/clash/SKILL.md"
out=$(kit add skill clash 2>&1)
check "someone else's skill folder: backed up, then kit's" 'echo "$out" | grep -q "不是 kit 放的：備份在" && grep -qx mine "$HOME"/.config/agentkit/backups/skills/clash-*/SKILL.md && grep -q "team clash" "$HOME/.claude/skills/clash/SKILL.md"'
out=$(kit sync 2>&1)
check "... once: kit's from then on" '! echo "$out" | grep -q "不是 kit 放的"'
rm -rf "$TEAM/skills/clash"; out=$(kit rm skill clash 2>&1); rc=$?
check "rm: one the account has, though no source has it any more" '[ $rc -eq 0 ] && ! kit sync 2>&1 | grep -q "clash not found"'

# ---------- list ----------
out=$(kit list 2>&1)
check "list marks required" 'echo "$out" | grep -q "^R  rule:security"'
check "list marks in use" 'echo "$out" | grep -q "^\*  skill:gerrit-review"'
check "list shows unused" 'echo "$out" | grep -q "^   skill:gerrit-workflow"'
check "list shows agent" 'echo "$out" | grep -q "agent:gerrit"'

finish
