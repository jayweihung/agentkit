#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
kit init "$TEAM" >/dev/null 2>&1; kit add skill gerrit-review >/dev/null 2>&1; kit add mcp gerrit >/dev/null 2>&1
# ---------- kit_version: tell once when the team wants a newer kit ----------
cp "$TEAM/kit.yaml" "$T/kit.yaml.orig"
echo "kit_version: 9.9.0" >> "$TEAM/kit.yaml"
out=$(kit sync 2>&1)
check "old kit: sync tells the user" 'echo "$out" | grep -qF "團隊要 kit 9.9.0 以上，你的是 $(cat "$HERE/../VERSION")。請打  kit self-update"'
out=$(kit sync 2>&1; kit list 2>&1)
check "old kit: told only once" '! echo "$out" | grep -q 團隊要'
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"; echo "kit_version: 9.10.1" >> "$TEAM/kit.yaml"
out=$(kit list 2>&1)
check "team version changed: list tells again (numbers, not text)" 'echo "$out" | grep -qF "團隊要 kit 9.10.1 以上"'
mkdir -p "$T/dev/unix"; cp "$HERE"/../unix/* "$T/dev/unix/"
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"; echo "kit_version: 9.6.0" >> "$TEAM/kit.yaml"
out=$("$T/dev/unix/kit" sync 2>&1)
check "dev build (no VERSION) is not told" '! echo "$out" | grep -q 團隊要'
echo "9.6.0+local" > "$T/dev/VERSION"
out=$("$T/dev/unix/kit" sync 2>&1)
check "+build part ignored" '! echo "$out" | grep -q 團隊要'
echo "9.5.9" > "$T/dev/VERSION"
out=$("$T/dev/unix/kit" sync 2>&1)
check "older patch level is told" 'echo "$out" | grep -qF "團隊要 kit 9.6.0 以上，你的是 9.5.9"'
state_nag() { awk -F'\t' '$1 == "nag"' "$HOME/.config/agentkit/state.tsv"; }
echo "9.6.0" > "$T/dev/VERSION"; "$T/dev/unix/kit" sync >/dev/null 2>&1
check "new enough: note forgotten" '[ -z "$(state_nag)" ]'
# kit_version 9.6.0 stays for the background sync below

# ---------- ci-template ----------
out=$(kit ci-template)
check "ci-template prints the template" '[ "$out" = "$(cat "$HERE/../templates/gitea-kit-check.yaml")" ]'
kit ci-template "$T/ci/.gitea/workflows/kit-check.yaml" >/dev/null
check "ci-template writes a file" 'cmp -s "$T/ci/.gitea/workflows/kit-check.yaml" "$HERE/../templates/gitea-kit-check.yaml"'


# ---------- run (dry run: show the claude command) ----------
out=$(KIT_DRY_RUN=1 kit run gerrit --model sonnet 2>&1)
tmp=$(echo "$out" | sed -n 's/^tmp=//p')
check "run passes --tools" 'echo "$out" | grep -qx -- "Read,Grep,Glob"'
check "run passes deny" 'echo "$out" | grep -qx "mcp__gerrit__submit_change"'
check "run keeps user args" 'echo "$out" | grep -qx "sonnet"'
check "run skill in temp dir" '[ -f "$tmp/.claude/skills/gerrit-review/SKILL.md" ]'
check "run prompt has rule and body" 'grep -q "Only comment" "$tmp/prompt.md" && grep -q "Gerrit helper" "$tmp/prompt.md" && ! grep -q "^name:" "$tmp/prompt.md"'
check "run mcp json valid" 'LC_ALL=C awk -f "$JA" "$tmp/mcp.json" >/dev/null && grep -q gerrit-mcp-server "$tmp/mcp.json"'
rm -rf "$tmp"

out=$(KIT_DRY_RUN=1 kit run gerrit --tool codex exec 2>&1)
tmp=$(echo "$out" | sed -n 's/^tmp=//p')
dev=$(echo "$out" | sed -n 's/^developer_instructions=//p')
srv=$(echo "$out" | sed -n 's/^mcp_servers\.gerrit=//p')
check "codex run: instructions have rule, body, skill path" 'echo "$dev" | grep -q "Only comment" && echo "$dev" | grep -q "Gerrit helper" && echo "$dev" | grep -qF "$tmp/skills/gerrit-review/SKILL.md"'
check "codex run: values are valid TOML" 'printf "a = %s\nb = %s\n" "$dev" "$srv" | python3 -c "import sys,tomllib; d=tomllib.loads(sys.stdin.read()); assert d[\"b\"][\"command\"]==\"uvx\" and d[\"b\"][\"default_tools_approval_mode\"]==\"approve\"" 2>/dev/null'
check "codex run: what kit codex-guard cannot hold back, said" 'echo "$out" | grep -qF "Codex 的 tools.only 只管得到 shell（Bash）和改檔（Edit、Write）：Codex 其他的內建工具照樣能用" && echo "$out" | grep -qF "tools.only 沒有 Bash：Codex 讀檔、找檔也是用 shell，所以在 Codex 裡也不能讀檔"'
mkdir -p "$T/fakecx"; printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$KIT_CODEX_ONLY" "$KIT_CODEX_DENY" > "%s/cxenv"\n' "$T" > "$T/fakecx/codex"; chmod +x "$T/fakecx/codex"
PATH="$T/fakecx:$PATH" kit run gerrit --tool codex >/dev/null 2>&1
check "codex run: the agent's tools.only and tools.deny in that Codex's environment (for kit codex-guard)" '[ "$(cat "$T/cxenv" 2>/dev/null)" = "Read,Grep,Glob|mcp__gerrit__submit_change" ]'
check "codex run: deny -> disabled_tools" 'echo "$srv" | grep -qF "disabled_tools=[\"submit_change\"]"'
check "codex run: env not expanded" 'echo "$srv" | grep -qF "\${HOME}/.config/gerrit"'
check "codex run: warns tools.only, keeps user args" 'echo "$out" | grep -q "tools.only" && echo "$out" | grep -qx exec'
rm -rf "$tmp"

out=$(KIT_DRY_RUN=1 kit run gerrit --tool omp 2>&1)
tmp=$(echo "$out" | sed -n 's/^tmp=//p')
check "omp run: config overlay points at skills" 'grep -qF "$tmp/skills" "$tmp/omp.yml" && [ -f "$tmp/skills/gerrit-review/SKILL.md" ]'
check "omp run: prompt + tools.only as omp's tools (Grep: grep, ast_grep; Glob: glob, find)" 'echo "$out" | grep -qx -- --append-system-prompt && echo "$out" | grep -qx "read,grep,ast_grep,glob,find"'
check "omp run: tools.deny through kit's hook module (--extension)" 'echo "$out" | grep -qx -- --extension && echo "$out" | grep -qx "$tmp/kit-tools.js" && grep -qF "const DENY = [\"mcp__gerrit__submit_change\"];" "$tmp/kit-tools.js" && grep -qF "const SYNC = null;" "$tmp/kit-tools.js" && ! echo "$out" | grep -q "不能禁用"'
check "omp run: the agent's MCP in a plugin folder's .mcp.json (--plugin-dir), nothing to warn" 'echo "$out" | grep -qx -- --plugin-dir && echo "$out" | grep -qx "$tmp/omp-plugin" && [ "$(jget "$tmp/omp-plugin/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && [ -f "$tmp/omp-plugin/.claude-plugin/plugin.json" ] && ! echo "$out" | grep -q "kit add mcp"'
rm -rf "$tmp"
out=$(kit run gerrit --tool vim 2>&1); rc=$?
check "run rejects unknown tool" '[ $rc -ne 0 ]'

# ---------- auto sync when Claude starts ----------
check "SessionStart hook added" 'jget "$HOME/.claude/settings.json" hooks.SessionStart | grep -qF "sync --hook"'
check "hook added once" '[ "$(jget "$HOME/.claude/settings.json" hooks.SessionStart | grep -c "sync --hook")" = 1 ]'
echo "hook change" >> "$TEAM/skills/gerrit-review/SKILL.md"
start=$(date +%s); kit sync --hook; rc=$?; took=$(( $(date +%s) - start ))
check "hook returns at once, exit 0" '[ $rc -eq 0 ] && [ $took -le 1 ]'
for i in 1 2 3 4 5 6 7 8 9 10; do [ -d "$HOME/.config/agentkit/sync.lock" ] || break; sleep 1; done
check "hook synced in the background: what this machine has stays (kit 0.13.0: kit sync typed brings it)" '[ ! -d "$HOME/.config/agentkit/sync.lock" ] && grep -q "^== " "$HOME/.config/agentkit/sync.log" && ! grep -q "hook change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
check "hook logs" 'grep -q "^== " "$HOME/.config/agentkit/sync.log"'
check "hook: kit_version not told in the background" '! grep -q 團隊要 "$HOME/.config/agentkit/sync.log" && [ -z "$(state_nag)" ]'
echo "second change" >> "$TEAM/skills/gerrit-review/SKILL.md"
kit sync --hook; sleep 2
check "hook runs at most every 10 minutes" '! grep -q "second change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
out=$(kit sync 2>&1)
check "hook: kit_version told at the next sync" 'echo "$out" | grep -qF "團隊要 kit 9.6.0 以上"'
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"

finish
