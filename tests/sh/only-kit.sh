#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; team_later; printf 'review v2\n' >> "$TEAM/skills/gerrit-review/SKILL.md"
# ---------- only through kit: what kit did not put there and is not the company's is turned off ----------
HB="$T/home-block"; PB="$T/blockproj"; mkdir -p "$HB/.omp/agent" "$PB"; PB=$(cd "$PB" && pwd -P)
sk() { mkdir -p "$1"; printf -- '---\nname: %s\ndescription: x\n---\nx\n' "${1##*/}" > "$1/SKILL.md"; }
sk "$HB/.claude/skills/npxed"; sk "$HB/.codex/skills/.system/sysskill"; sk "$HB/.codex/skills/cxown"
mkdir -p "$HB/.claude/skills/gerrit-review"; echo mine > "$HB/.claude/skills/gerrit-review/SKILL.md"   # a team skill's name
sk "$HB/.claude/skills/synced/org1_u1/vendor1"; sk "$HB/.claude/skills/synced/org1_u1/mine1"
printf '{"skills": [{"name": "vendor1", "source": "anthropic"}, {"name": "mine1", "source": "user"}]}\n' > "$HB/.claude/skills/synced/org1_u1/manifest.json"
printf '{\n  "model": "opus",\n  "skillOverrides": {\n    "npxed": "on"\n  }\n}\n' > "$HB/.claude/settings.json"
printf '{\n  "mcpServers": {\n    "selfmcp": {\n      "command": "x"\n    }\n  }\n}\n' > "$HB/.claude.json"
mkdir -p "$HB/.claude/plugins"; printf '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user"}]}}\n' > "$HB/.claude/plugins/installed_plugins.json"
printf 'model = "gpt-5"\n\n[mcp_servers.cxmcp]\ncommand = "x"\n\n[plugins."foo@mkt"]\nenabled = true\n' > "$HB/.codex/config.toml"; cp "$HB/.codex/config.toml" "$T/blockcx.orig"
printf 'theme: dark\ndisabledExtensions:\n  - context-file:user:CLAUDE.md\n' > "$HB/.omp/agent/config.yml"; cp "$HB/.omp/agent/config.yml" "$T/blockomp.orig"
sk "$PB/.claude/skills/committed"; sk "$PB/.claude/skills/loose"; printf '{"mcpServers": {"projmcp": {"command": "x"}}}\n' > "$PB/.mcp.json"
( cd "$PB" && git init -q && git config user.name t && git config user.email t@t && git add .claude/skills/committed && git commit -qm c )
(
export HOME="$HB"
# omp's plugins: one omp has turned off already ("enabled": false in its first entry), one on; a fake omp logs what kit asks
mkdir -p "$HB/.omp/plugins" "$T/fakeomp"; printf '{"version": 2, "plugins": {"off@mkt": [{"scope": "user", "enabled": false}], "on@mkt": [{"scope": "user"}]}}\n' > "$HB/.omp/plugins/installed_plugins.json"
printf '#!/bin/sh\necho "$*" >> "%s/omp.log"\n' "$T" > "$T/fakeomp/omp"; chmod +x "$T/fakeomp/omp"; export PATH="$T/fakeomp:$PATH"
out=$(KIT_HOOK_DIR="$PB" kit init "$TEAM" 2>&1); out=$out$(kit add skill gerrit-review 2>&1)
S="$HB/.claude/settings.json"; CX="$HB/.codex/config.toml"
check "block: a skill kit did not put there is off in Claude, your own setting for it kept to put back" '[ "$(jget "$S" skillOverrides.npxed)" = "\"off\"" ] && [ "$(jget "$S" model)" = "\"opus\"" ] && echo "$out" | grep -q "已經讓工具不載入"'
check "block: Claude synced: anthropic's left alone, the user's own off" '[ -z "$(jget "$S" skillOverrides.vendor1)" ] && [ "$(jget "$S" skillOverrides.mine1)" = "\"off\"" ]'
check "block: Claude MCP and plugin off (deniedMcpServers, enabledPlugins); ~/.claude.json untouched" '[ "$(jget "$S" deniedMcpServers | tr -d " \n")" = "[{\"serverName\":\"selfmcp\"}]" ] && [ "$(jget "$S" enabledPlugins.pl@mkt)" = false ] && [ -n "$(jget "$HB/.claude.json" mcpServers.selfmcp)" ]'
check "block: Codex skills off in kit's block (not Claude's folder: Codex does not read it), its .system left alone" 'grep -A1 -F "[[skills.config]]" "$CX" | grep -qxF "name = \"cxown\"" && ! grep -qF "\"npxed\"" "$CX" && ! grep -qF "\"sysskill\"" "$CX"'
check "block: Codex MCP and plugin enabled = false in their own tables" '[ "$(awk "/^\\[mcp_servers.cxmcp\\]/{t=1;next} /^\\[/{t=0} t && /^enabled/" "$CX")" = "enabled = false" ] && [ "$(awk "/^\\[plugins.\"foo@mkt\"\\]/{t=1;next} /^\\[/{t=0} t && /^enabled/" "$CX")" = "enabled = false" ]'
check "block: omp skills in disabledExtensions (yours kept), MCP in disabledServers" 'ox=$(LC_ALL=C awk -f "$HERE/../unix/yaml.awk" "$HB/.omp/agent/config.yml"); echo "$ox" | grep -qxF "disabledExtensions[]	skill:npxed" && echo "$ox" | grep -qxF "disabledExtensions[]	context-file:user:CLAUDE.md" && ! echo "$ox" | grep -qF sysskill && jget "$HB/.omp/agent/mcp.json" disabledServers | grep -qF "\"selfmcp\""'
check "block: the project: what git tracks left alone, the rest off in its settings.local.json" '[ "$(jget "$PB/.claude/settings.local.json" skillOverrides.loose)" = "\"off\"" ] && [ -z "$(jget "$PB/.claude/settings.local.json" skillOverrides.committed)" ] && [ -z "$(jget "$S" skillOverrides.committed)" ] && jget "$PB/.claude/settings.local.json" disabledMcpjsonServers | grep -qF "\"projmcp\""'
check "block: a folder that is not kit's where kit puts a skill: backed up, then kit's (never blocked)" 'grep -qx mine "$HB"/.config/agentkit/backups/skills/gerrit-review-*/SKILL.md && grep -q "how to review" "$HB/.claude/skills/gerrit-review/SKILL.md" && [ -z "$(jget "$S" skillOverrides.gerrit-review)" ]'
out=$(kit list --json 2>/dev/null)
check "block: kit list --json has blocked" 'echo "$out" | grep -qF "{\"kind\": \"skill\", \"name\": \"npxed\", \"tool\": \"claude\", \"path\": \"$HB/.claude/skills/npxed\", \"scope\": \"account\"}" && echo "$out" | grep -qF "\"name\": \"loose\", \"tool\": \"claude\", \"path\": \"$PB/.claude/skills/loose\", \"scope\": \"folder\", \"dir\": \"$PB\"}"'
check "block: an omp plugin omp has off already is left alone (not disabled, not in blocked); the other one is" '! grep -qF "off@mkt" "$T/omp.log" && grep -qxF "plugin disable --scope user on@mkt" "$T/omp.log" && ! echo "$out" | grep -qF "\"name\": \"off@mkt\"" && echo "$out" | grep -qF "{\"kind\": \"plugin\", \"name\": \"on@mkt\", \"tool\": \"omp\""'
mv "$HB/.claude/skills/npxed" "$T/npxed.away"; mv "$PB/.claude" "$T/pbclaude.away"; out2=$(kit list --json 2>/dev/null)
check "block: kit list --json: blocked from what kit sync kept, less what is gone since (removed by hand)" '! echo "$out2" | grep -qF "\"name\": \"npxed\"" && ! echo "$out2" | grep -qF "\"name\": \"loose\"" && echo "$out2" | grep -qF "\"name\": \"selfmcp\"" && echo "$out2" | grep -qF "\"name\": \"cxown\""'
mv "$T/npxed.away" "$HB/.claude/skills/npxed"; mv "$T/pbclaude.away" "$PB/.claude"
sed -i.bak '/"npxed": "off"/d' "$S"; rm -f "$S.bak"; out=$(kit sync 2>&1)
check "block: told once; taken out by hand: back on the next sync (the project too)" '! echo "$out" | grep -q "已經讓工具不載入" && [ "$(jget "$S" skillOverrides.npxed)" = "\"off\"" ] && [ "$(jget "$PB/.claude/settings.local.json" skillOverrides.loose)" = "\"off\"" ]'
sk "$TEAM/skills/npxed"; out=$(kit add skill npxed 2>&1)
check "block: once kit has it, kit's entry goes and yours is back" '[ "$(jget "$S" skillOverrides.npxed)" = "\"on\"" ] && ! grep -A1 -F "[[skills.config]]" "$CX" | grep -qF "\"npxed\"" && ! LC_ALL=C awk -f "$HERE/../unix/yaml.awk" "$HB/.omp/agent/config.yml" | grep -qF skill:npxed && echo "$out" | grep -q "不再擋"'
rm -rf "$HB/.codex/skills/cxown"; out=$(kit sync 2>&1)
check "block: removed by hand: kit sync says it is gone (not that it is kit's now)" 'echo "$out" | grep -A3 "已經刪掉了" | grep -qF cxown && ! echo "$out" | grep -A3 "不再擋" | grep -qF cxown && ! grep -qF "\"cxown\"" "$CX"'
kit uninstall >/dev/null 2>&1
check "block: uninstall puts everything back" '[ "$(jget "$S" skillOverrides.npxed)" = "\"on\"" ] && [ -z "$(jget "$S" skillOverrides.mine1)$(jget "$S" deniedMcpServers)$(jget "$S" enabledPlugins)" ] && cmp -s "$CX" "$T/blockcx.orig" && cmp -s "$HB/.omp/agent/config.yml" "$T/blockomp.orig" && [ ! -e "$PB/.claude/settings.local.json" ] && [ ! -e "$HB/.config/agentkit/blocked.tsv" ]'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"
rm -rf "$TEAM/skills/npxed"

finish
