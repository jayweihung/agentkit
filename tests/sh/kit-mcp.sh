#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
mj() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
# ---------- Claude's MCP in kit's own plugin (kit-mcp): /reload-plugins brings a change, no restart ----------
MG="$T/mcpplug"; MPH="$MG/home"; MPB="$MG/bin"; mkdir -p "$MPH" "$MPB" "$MG/src/mcp"
mpk() { HOME="$MPH" AGENTKIT_CONFIG="$MPH/.config/agentkit" AGENTKIT_SOURCES="$MPH/agentkit" PATH="$MPB:$PATH" FAKE_LOG="$MG/log" FAKE_DIR="$MG" "$KIT" "$@"; }
# a Claude whose version is in $FAKE_DIR/ver; plugin install/uninstall kept in installed_plugins.json ($FAKE_DIR/fail: fails)
cat > "$MPB/claude" <<'SH'
#!/bin/sh
[ "$1" = --version ] && { echo "$(cat "$FAKE_DIR/ver") (Claude Code)"; exit 0; }
echo "claude $*" >> "$FAKE_LOG"
f="$HOME/.claude/plugins/installed_plugins.json"; l="$FAKE_DIR/installed"; touch "$l"
case "$1 $2" in
  "plugin install") [ -f "$FAKE_DIR/fail" ] && { echo "Unknown command" >&2; exit 1; }; echo "$3" >> "$l";;
  "plugin uninstall") grep -vxF "$3" "$l" > "$l.t"; mv "$l.t" "$l";;
esac
mkdir -p "${f%/*}"; printf '{"version":2,"plugins":{%s}}\n' "$(awk '{ printf "%s\"%s\":[{}]", (NR > 1 ? "," : ""), $0 }' "$l")" > "$f"
SH
printf '#!/bin/sh\nexit 0\n' > "$MPB/omp"; chmod +x "$MPB"/*
printf 'name: src\nrequired:\n  tools:\n    deny: [mcp__kp__boom]\n' > "$MG/src/kit.yaml"
for n in kp kq kr; do printf 'name: %s\ncommand: python3\nargs: [/x/%s.py]\nenv:\n  TOKEN: ${KP_TOKEN}\n' $n $n > "$MG/src/mcp/$n.yaml"; done
( cd "$MG/src" && git init -q && git config user.name t && git config user.email t@t && git add -A && git commit -qm v1 )
MCJ="$MPH/.claude.json"; MPC="$MPH/.config/agentkit/plugins"
printf '{"mcpServers":{"mine":{"command":"mine"},"kq":{"command":"my-kq"}}}\n' > "$MCJ"
echo 1.0.0 > "$MG/ver"; out0=$(mpk init "$MG/src" 2>&1)
out=$(mpk add mcp kp kq 2>&1)
check "mcp plugin: an older Claude -> ~/.claude.json as before, said once" '[ "$(jget "$MCJ" mcpServers.kp.command)" = "\"python3\"" ] && [ ! -e "$MPC/kit-mcp" ] && echo "$out0" | grep -qF "比 2.1.330 舊" && ! echo "$out" | grep -qF "比 2.1.330 舊" && ! grep -q "plugin install" "$MG/log" 2>/dev/null'
check "mcp plugin: list --json claude_mcp config (an older Claude)" '[ "$(mpk list --json 2>/dev/null | jget /dev/stdin claude_mcp)" = "\"config\"" ]'
echo 2.1.330 > "$MG/ver"; touch "$MG/fail"; mpk sync >/dev/null 2>&1
check "mcp plugin: the install fails -> still in ~/.claude.json, claude_mcp config" '[ "$(jget "$MCJ" mcpServers.kp.command)" = "\"python3\"" ] && [ ! -e "$MPC/kit-mcp" ] && [ "$(mpk list --json 2>/dev/null | jget /dev/stdin claude_mcp)" = "\"config\"" ]'
rm -f "$MG/fail"; : > "$MG/log"; out=$(mpk sync 2>&1)
check "mcp plugin: list --json claude_mcp plugin" '[ "$(mpk list --json 2>/dev/null | jget /dev/stdin claude_mcp)" = "\"plugin\"" ]'
check "mcp plugin: a new Claude -> kit's in kit-mcp, out of ~/.claude.json; yours stay; the env placeholder as it was" '[ "$(jget "$MPC/kit-mcp/.mcp.json" mcpServers.kp.env.TOKEN)" = "\"\${KP_TOKEN}\"" ] && [ -z "$(jget "$MCJ" mcpServers.kp)" ] && [ "$(jget "$MCJ" mcpServers.mine.command)" = "\"mine\"" ] && [ "$(jget "$MCJ" mcpServers.kq.command)" = "\"my-kq\"" ] && [ -z "$(jget "$MPC/kit-mcp/.mcp.json" mcpServers.kq)" ]'
check "mcp plugin: installed once, account scope, listed in kit's marketplace (not Codex's)" '[ "$(grep -c "plugin install" "$MG/log")" = 1 ] && grep -qxF "claude plugin install kit-mcp@kit --scope user" "$MG/log" && grep -qF "\"name\":\"kit-mcp\"" "$MPC/.claude-plugin/marketplace.json" && ! grep -qF kit-mcp "$MPC/.agents/plugins/marketplace.json" && echo "$out" | grep -qF /reload-plugins'
check "mcp plugin: the team's MCP deny in both names" 'grep -qF "\"mcp__kp__boom\"" "$MPH/.claude/settings.json" && grep -qF "\"mcp__plugin_kit-mcp_kp__boom\"" "$MPH/.claude/settings.json"'
check "mcp plugin: not blocked (kit's), the folder private" '! grep -qF "kit-mcp@kit" "$MPH/.claude/settings.json" && [ "$(ls -ld "$MPC/kit-mcp" | cut -c1-10)" = drwx------ ]'
: > "$MG/log"; out=$(mpk add mcp kr 2>&1)
check "mcp plugin: kit add -> only its .mcp.json rewritten (no install), the version changes" '[ "$(jget "$MPC/kit-mcp/.mcp.json" mcpServers.kr.command)" = "\"python3\"" ] && ! grep -q "plugin install" "$MG/log" && [ -z "$(jget "$MCJ" mcpServers.kr)" ]'
out=$(mpk list --json 2>/dev/null)
check "mcp plugin: list --json still has Claude's installed version" 'echo "$out" | mj /dev/stdin "assert [x[\"installed\"][\"claude\"] is not None for x in d[\"items\"] if x[\"name\"]==\"kr\"]==[True]"'
: > "$MG/log"; mpk rm mcp kr >/dev/null 2>&1
check "mcp plugin: kit rm -> out of .mcp.json, still installed" '[ -z "$(jget "$MPC/kit-mcp/.mcp.json" mcpServers.kr)" ] && [ -n "$(jget "$MPC/kit-mcp/.mcp.json" mcpServers.kp)" ] && [ ! -s "$MG/log" ]'
MD="$MG/proj"; mkdir -p "$MD"; MD=$(cd "$MD" && pwd -P); MDP=$(printf '%s' "$MD" | cksum | awk '{ printf "kit-mcp-%x", $1 }')
: > "$MG/log"; out=$(mpk add --dir "$MD" mcp kr 2>&1)
check "mcp plugin --dir: kit-mcp-<id> --scope local; .mcp.json kept for omp, Claude's copy off; folder trusted" 'grep -qxF "claude plugin install $MDP@kit --scope local" "$MG/log" && [ "$(jget "$MPC/$MDP/.mcp.json" mcpServers.kr.command)" = "\"python3\"" ] && [ "$(jget "$MD/.mcp.json" mcpServers.kr.command)" = "\"python3\"" ] && grep -qF "\"kr\"" "$MD/.claude/settings.local.json" && [ -n "$(jget "$MD/.claude/settings.local.json" disabledMcpjsonServers)" ] && [ -z "$(jget "$MD/.claude/settings.local.json" enabledMcpjsonServers)" ] && mj "$MCJ" "assert d[\"projects\"][sys.argv[3]][\"hasTrustDialogAccepted\"] is True" "$MD"'
check "mcp plugin --dir: the team's deny in the folder plugin's name" 'grep -qF "\"mcp__plugin_${MDP}_kp__boom\"" "$MD/.claude/settings.local.json"'
: > "$MG/log"; mpk rm --dir "$MD" mcp kr >/dev/null 2>&1
check "mcp plugin --dir: kit rm -> uninstalled there, kit's files gone" 'grep -qxF "claude plugin uninstall $MDP@kit --scope local" "$MG/log" && [ ! -e "$MPC/$MDP" ] && [ ! -e "$MD/.claude/settings.local.json" ] && [ ! -e "$MD/.mcp.json" ]'
# the plugin install fails (an older claude plugin): the old way, nothing lost
touch "$MG/fail"; mpk add --dir "$MD" mcp kr >/dev/null 2>&1
check "mcp plugin --dir: install fails -> enabledMcpjsonServers as before" '[ ! -e "$MPC/$MDP" ] && [ -n "$(jget "$MD/.claude/settings.local.json" enabledMcpjsonServers)" ] && [ -z "$(jget "$MD/.claude/settings.local.json" disabledMcpjsonServers)" ]'
mpk rm --dir "$MD" mcp kr >/dev/null 2>&1; rm -f "$MG/fail"
: > "$MG/log"; mpk uninstall >/dev/null 2>&1
check "mcp plugin: kit uninstall -> kit-mcp uninstalled, the marketplace gone, yours stay" 'grep -qxF "claude plugin uninstall kit-mcp@kit --scope user" "$MG/log" && grep -qxF "claude plugin marketplace remove kit" "$MG/log" && [ ! -e "$MPC" ] && [ "$(jget "$MCJ" mcpServers.mine.command)" = "\"mine\"" ] && [ "$(jget "$MCJ" mcpServers.kq.command)" = "\"my-kq\"" ] && [ -z "$(jget "$MCJ" mcpServers.kp)" ]'
cd "$T"

finish
