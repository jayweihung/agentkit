#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; team_later
# ---------- Codex and omp ----------
H4="$T/home4"; mkdir -p "$H4/.codex" "$H4/.omp/agent"
printf '# my codex notes\n' > "$H4/.codex/AGENTS.md"
printf 'model = "gpt-5"\n\n[mcp_servers.mine]\ncommand = "x"\n' > "$H4/.codex/config.toml"; chmod 600 "$H4/.codex/config.toml"
cp -p "$H4/.codex/config.toml" "$T/codex.orig"
printf '{\n  "mcpServers": {\n    "own": {\n      "command": "y"\n    }\n  }\n}\n' > "$H4/.omp/agent/mcp.json"; cp "$H4/.omp/agent/mcp.json" "$T/omp.orig"
(
export HOME="$H4"
kit init "$TEAM" >/dev/null 2>&1; kit add mcp gerrit >/dev/null 2>&1; kit add skill gerrit-review >/dev/null 2>&1
check "list shows targets" 'kit list | grep -q "寫到：Claude、Codex、omp"'
check "codex AGENTS.md keeps user text" 'head -1 "$H4/.codex/AGENTS.md" | grep -q "my codex notes"'
check "codex AGENTS.md has rule text inline" 'grep -q "Never paste secrets." "$H4/.codex/AGENTS.md" && grep -q "Use 4 spaces." "$H4/.codex/AGENTS.md"'
check "omp AGENTS.md has rule text" 'grep -q "Never paste secrets." "$H4/.omp/agent/AGENTS.md"'
check "skills in ~/.agents/skills" '[ -f "$H4/.agents/skills/gerrit-review/SKILL.md" ] && [ -f "$H4/.agents/skills/gerrit-workflow/LICENSE" ]'
check "codex toml keeps user part" 'head -4 "$H4/.codex/config.toml" | grep -q "^\[mcp_servers.mine\]"'
check "codex toml has kit server" 'grep -q "^\[mcp_servers.gerrit\]" "$H4/.codex/config.toml" && grep -q "^command = \"uvx\"" "$H4/.codex/config.toml"'
check "codex toml: kit's MCP tools run without asking" 'grep -q "^default_tools_approval_mode = \"approve\"" "$H4/.codex/config.toml"'
check "codex toml args" 'grep -qF "args = [\"--index-url\", \"https://pypi.example/simple\", \"gerrit-mcp-server==1.0\"]" "$H4/.codex/config.toml"'
check "codex team deny -> disabled_tools" 'grep -qF "disabled_tools = [\"submit_change\"]" "$H4/.codex/config.toml"'
check "codex env table, not expanded" 'grep -q "^\[mcp_servers.gerrit.env\]" "$H4/.codex/config.toml" && grep -qF "GERRIT_CONFIG = \"\${HOME}/.config" "$H4/.codex/config.toml"'
check "codex toml stays private" '[ "$(ls -l "$H4/.codex/config.toml" | cut -c1-10)" = "-rw-------" ]'
check "codex toml: kit's notes folder writable in Codex's sandbox (kit note)" 'grep -qxF "writable_roots = [\"$H4/.config/agentkit/notes\"]" "$H4/.codex/config.toml" && [ -d "$H4/.config/agentkit/notes" ]'
if python3 -c "import tomllib" 2>/dev/null; then
  check "codex toml is valid TOML" 'python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"mcp_servers\"][\"gerrit\"][\"env\"][\"GERRIT_CONFIG\"] and d[\"sandbox_workspace_write\"][\"writable_roots\"]" "$H4/.codex/config.toml"'
fi
check "no backup for a file kit created" '[ ! -e "$H4/.agents/mcp.json.kit-backup" ] && [ ! -e "$H4/.omp/agent/mcp.json.kit-backup" ] || [ "$(cat "$H4/.omp/agent/mcp.json.kit-backup")" != "{}" ]'
check "omp mcp.json has kit server and own" '[ "$(jget "$H4/.omp/agent/mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && [ "$(jget "$H4/.omp/agent/mcp.json" mcpServers.own.command)" = "\"y\"" ]'
check "codex hooks.json: kit sync when Codex starts, handoff-hook before each prompt (Claude's hook format)" 'jget "$H4/.codex/hooks.json" hooks.SessionStart | grep -qF "sync --hook" && jget "$H4/.codex/hooks.json" hooks.UserPromptSubmit | grep -qF "handoff-hook"'
check "codex-guard: the team's tools.deny kept by kit sync (no reading the sources each time)" 'grep -qx "mcp__gerrit__submit_change" "$H4/.config/agentkit/ctx/required-deny.txt"'
check "codex hooks.json: codex-guard before its shell commands and patches" 'jget "$H4/.codex/hooks.json" hooks.PreToolUse | grep -qF "codex-guard" && jget "$H4/.codex/hooks.json" hooks.PreToolUse | grep -qF "\"Bash|apply_patch\""'
check "omp hook module: kit sync --hook at session_start (in the background), the team's tools.deny" 'head -n 1 "$H4/.omp/agent/hooks/pre/kit.js" | grep -qF "written by kit (agentkit)" && grep -qF "sync --hook" "$H4/.omp/agent/hooks/pre/kit.js" && grep -qF "pi.on(\"session_start\"" "$H4/.omp/agent/hooks/pre/kit.js" && grep -qF "const DENY = [\"mcp__gerrit__submit_change\"];" "$H4/.omp/agent/hooks/pre/kit.js"'
if command -v node >/dev/null 2>&1; then
    cp "$H4/.omp/agent/hooks/pre/kit.js" "$T/omphook.mjs"
    check "omp hook module: valid JavaScript" 'node --check "$T/omphook.mjs"'
fi
kit sync >/dev/null 2>&1
check "codex hooks once, after another sync" '[ "$(jget "$H4/.codex/hooks.json" hooks.SessionStart | grep -c "sync --hook")" = 1 ]'
# Codex runs a new hook only after you trust it (/hooks): kit asks only while Codex has not
mkdir -p "$T/cxtrust"; cat > "$T/cxtrust/codex" <<'SH'
#!/bin/sh
[ "$1" = app-server ] || exit 0
h() { printf '{"key":"%s/.codex/hooks.json:%s:0:0","source":"user","pluginId":null,"command":"'"'"'/k/kit'"'"' %s","trustStatus":"%s"}' "$HOME" "$1" "$2" "$(cat "$HOME/cxtrust")"; }
while IFS= read -r l; do case $l in *'"method":"hooks/list"'*)
  printf '{"id":2,"result":{"data":[{"cwd":"/","hooks":[%s,%s,%s]}]}}\n' "$(h session_start 'sync --hook')" "$(h user_prompt_submit handoff-hook)" "$(h pre_tool_use codex-guard)";; esac; done
SH
chmod +x "$T/cxtrust/codex"
for x in untrusted trusted; do
    mkdir -p "$T/cx-$x/.codex"; echo $x > "$T/cx-$x/cxtrust"
    out=$(HOME="$T/cx-$x" PATH="$T/cxtrust:$PATH" kit init "$TEAM" 2>&1); eval "cx_$x=\$out"
done
check "codex hooks new, Codex has not trusted them: asked once (/hooks)" 'echo "$cx_untrusted" | grep -qF "/hooks" && [ -f "$T/cx-untrusted/.config/agentkit/notes/pending/codex-hooks" ]'
check "codex hooks new, Codex already trusts them: not asked" '! echo "$cx_trusted" | grep -qF "/hooks" && [ ! -f "$T/cx-trusted/.config/agentkit/notes/pending/codex-hooks" ]'
echo trusted > "$T/cx-untrusted/cxtrust"; out=$(HOME="$T/cx-untrusted" PATH="$T/cxtrust:$PATH" kit sync 2>&1)
check "codex hooks trusted later (/hooks): the reminder goes, not asked again" '! echo "$out" | grep -qF "/hooks" && [ ! -f "$T/cx-untrusted/.config/agentkit/notes/pending/codex-hooks" ]'
# a server the user already has in config.toml is left alone
printf '\n[mcp_servers.gerrit]\ncommand = "theirs"\n' > "$T/extra"; cp "$H4/.codex/config.toml" "$T/c2"
awk '/^# agentkit:begin/{exit} {print}' "$T/c2" > "$H4/.codex/config.toml"; cat "$T/extra" >> "$H4/.codex/config.toml"
out=$(kit sync 2>&1)
check "codex: user server with same name wins" 'echo "$out" | grep -q "已經有自己的 mcp_servers.gerrit" && [ "$(grep -c "^\[mcp_servers.gerrit\]" "$H4/.codex/config.toml")" = 1 ]'
cp "$T/c2" "$H4/.codex/config.toml"; kit sync >/dev/null 2>&1
kit rm mcp gerrit >/dev/null 2>&1
check "rm mcp clears codex and omp" '! grep -q "mcp_servers.gerrit" "$H4/.codex/config.toml" && ! jget "$H4/.omp/agent/mcp.json" mcpServers.gerrit >/dev/null'
kit uninstall >/dev/null 2>&1
check "uninstall: codex AGENTS.md back" '[ "$(cat "$H4/.codex/AGENTS.md")" = "# my codex notes" ]'
check "uninstall: codex toml byte-identical" 'cmp -s "$T/codex.orig" "$H4/.codex/config.toml"'
check "uninstall: omp mcp.json byte-identical" 'cmp -s "$T/omp.orig" "$H4/.omp/agent/mcp.json"'
check "uninstall: omp AGENTS.md (made by kit) gone" '[ ! -e "$H4/.omp/agent/AGENTS.md" ]'
check "uninstall: ~/.agents/skills emptied" '[ -z "$(ls -A "$H4/.agents/skills" 2>/dev/null)" ]'
check "uninstall: Codex's hooks.json (made by kit) and omp's hook module gone" '[ ! -e "$H4/.codex/hooks.json" ] && [ ! -e "$H4/.omp/agent/hooks/pre/kit.js" ]'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
