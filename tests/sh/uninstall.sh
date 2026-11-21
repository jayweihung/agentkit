#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; kit init "$TEAM" >/dev/null 2>&1
# ---------- uninstall ----------
kit add skill gerrit-review >/dev/null 2>&1; kit add mcp gerrit >/dev/null 2>&1
kit uninstall >/dev/null 2>&1
check "uninstall restores CLAUDE.md" '[ "$(cat "$HOME/.claude/CLAUDE.md")" = "$(printf "# My notes\nBe brief.")" ]'
check "uninstall removes kit skills" '[ ! -e "$HOME/.claude/skills/gerrit-review" ] && [ -f "$HOME/.claude/skills/my-own/SKILL.md" ]'
check "uninstall removes hook" '! grep -q "sync --hook" "$HOME/.claude/settings.json"'
check "uninstall removes only kit deny" '[ "$(jget "$HOME/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"Bash(rm-rf:*)\"]" ]'
check "uninstall leaves no empty deny" '[ "$(jget "$HOME/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"Bash(rm-rf:*)\"]" ]'
printf '{\n  "model": "opus",\n  "hooks": {\n    "SessionStart": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "my-hook"\n          }\n        ]\n      }\n    ]\n  }\n}\n' > "$T/s.orig"; cp "$T/s.orig" "$HOME/.claude/settings.json"
kit init "$TEAM" >/dev/null 2>&1
check "user hook kept next to kit hook" '[ "$(jget "$HOME/.claude/settings.json" hooks.SessionStart | grep -c "my-hook\|sync --hook")" = 2 ]'
kit uninstall >/dev/null 2>&1
check "settings.json byte-identical after init+uninstall" 'cmp -s "$T/s.orig" "$HOME/.claude/settings.json"'
check "uninstall leaves no empty mcpServers" '! grep -q mcpServers "$HOME/.claude.json"'
check "claude.json byte-identical after everything" 'cmp -s "$HOME/.claude.json" "$T/claude.json.orig"'
check "uninstall removes mcp" '! jget "$HOME/.claude.json" mcpServers.gerrit >/dev/null'

finish
