#!/usr/bin/env bash
# End-to-end tests for the bash kit. Everything runs in a throwaway HOME,
# so your real ~/.claude is never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
KIT="$HERE/../unix/kit"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR AGENTKIT_CONFIG AGENTKIT_SOURCES
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
kit() { "$KIT" "$@"; }
JA="$HERE/../unix/json.awk"
jget() { LC_ALL=C awk -f "$JA" -v get="$2" "$1" 2>/dev/null; }

# ---------- fixture sources ----------
TP="$T/third-party"; TEAM="$T/team"
mkdir -p "$TP/skills/gerrit-workflow" "$TEAM/rules" "$TEAM/skills/gerrit-review" "$TEAM/mcp" "$TEAM/agents"
printf -- '---\nname: gerrit-workflow\ndescription: upstream\n---\nupstream body\n' > "$TP/skills/gerrit-workflow/SKILL.md"
echo "Apache-2.0" > "$TP/skills/gerrit-workflow/LICENSE"
cat > "$TEAM/kit.yaml" <<EOF
name: team
include: [$TP]
allowed_hosts: [gitea.example]
required:
  rules: [security]
  tools:
    deny: [mcp__gerrit__submit_change]
recommended:
  rules:  [coding-style]
  skills: [gerrit-workflow]
EOF
echo "Never paste secrets." > "$TEAM/rules/security.md"
echo "Use 4 spaces." > "$TEAM/rules/coding-style.md"
echo "Only comment, never submit." > "$TEAM/rules/gerrit-flow.md"
printf -- '---\nname: gerrit-review\ndescription: review a change\n---\nhow to review\n' > "$TEAM/skills/gerrit-review/SKILL.md"
cat > "$TEAM/mcp/gerrit.yaml" <<'EOF'
name: gerrit
command: uvx
args: [--index-url, "https://pypi.example/simple", gerrit-mcp-server==1.0]
env:
  GERRIT_CONFIG: ${HOME}/.config/gerrit/gerrit_config.json   # expanded by Claude, not kit
EOF
cat > "$TEAM/agents/gerrit.md" <<'EOF'
---
name: gerrit
description: Gerrit helper
rules:  [gerrit-flow]
skills: [gerrit-review]
mcp:    [gerrit]
tools:
  only: [Read, Grep, Glob]
  deny: [mcp__gerrit__submit_change]
---
You are the Gerrit helper.
EOF

# ---------- the user's own files, which kit must keep ----------
mkdir -p "$HOME/.claude/skills/my-own"
echo "my own skill" > "$HOME/.claude/skills/my-own/SKILL.md"
printf '# My notes\nBe brief.\n' > "$HOME/.claude/CLAUDE.md"
printf '{\n  "model": "opus",\n  "permissions": {\n    "deny": [\n      "Bash(rm -rf:*)"\n    ]\n  }\n}\n' > "$HOME/.claude/settings.json"
printf '{\n  "numStartups": 5,\n  "projects": {\n    "/x": {\n      "note": "中文 \\"q\\""\n    }\n  }\n}' > "$HOME/.claude.json"
chmod 600 "$HOME/.claude.json"; cp -p "$HOME/.claude.json" "$T/claude.json.orig"

# ---------- init ----------
out=$(kit init "$TEAM" 2>&1); rc=$?
check "init exit 0" '[ $rc -eq 0 ]'
check "include pulled third-party" 'grep -qF "$TP" "$HOME/.config/agentkit/machine.yaml"'
check "recommended added" 'grep -q "added: \[rule:coding-style, skill:gerrit-workflow\]" "$HOME/.config/agentkit/machine.yaml"'
check "CLAUDE.md keeps user text" 'head -2 "$HOME/.claude/CLAUDE.md" | grep -q "Be brief."'
check "CLAUDE.md imports required rule" 'grep -qxF "@$TEAM/rules/security.md" "$HOME/.claude/CLAUDE.md"'
check "CLAUDE.md imports recommended rule" 'grep -qxF "@$TEAM/rules/coding-style.md" "$HOME/.claude/CLAUDE.md"'
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
kit sync --force >/dev/null 2>&1
check "--force overwrites" 'grep -q "team change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
mkdir -p "$TEAM/skills/team-build"; printf -- '---\nname: team-build\ndescription: b\n---\nx\n' > "$TEAM/skills/team-build/SKILL.md"
out=$(kit sync 2>&1)
check "new item announced" 'echo "$out" | grep -q "新： skill:team-build"'
out=$(kit sync 2>&1)
check "announced only once" '! echo "$out" | grep -q "新："'

# ---------- a skill folder that is not kit's ----------
mkdir -p "$TEAM/skills/clash" "$HOME/.claude/skills/clash"
printf -- '---\nname: clash\ndescription: team\n---\nteam clash\n' > "$TEAM/skills/clash/SKILL.md"; echo "mine" > "$HOME/.claude/skills/clash/SKILL.md"
out=$(kit add skill clash 2>&1)
check "someone else's skill folder: warned, not overwritten" 'echo "$out" | grep -q "不是 kit 放的" && [ "$(cat "$HOME/.claude/skills/clash/SKILL.md")" = mine ]'
out=$(kit sync 2>&1)
check "... and warned only once" '! echo "$out" | grep -q "不是 kit 放的"'
rm -rf "$HOME/.claude/skills/clash"; kit sync >/dev/null 2>&1
check "... kit puts it there once the folder is gone" 'grep -q "team clash" "$HOME/.claude/skills/clash/SKILL.md"'
kit rm skill clash >/dev/null 2>&1; rm -rf "$TEAM/skills/clash"

# ---------- list ----------
out=$(kit list 2>&1)
check "list marks required" 'echo "$out" | grep -q "^R  rule:security"'
check "list marks in use" 'echo "$out" | grep -q "^\*  skill:gerrit-review"'
check "list shows unused" 'echo "$out" | grep -q "^   skill:gerrit-workflow"'
check "list shows agent" 'echo "$out" | grep -q "agent:gerrit"'

# ---------- list --json (for the Herdr panel) ----------
mkdir -p "$TEAM/skills/quote"; printf -- '---\nname: quote\ndescription: 中文 "引號" \\ 和\ttab\n---\nx\n' > "$TEAM/skills/quote/SKILL.md"
kit list --json > "$T/list.json" 2>&1; rc=$?
check "list --json: exit 0, valid JSON" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/list.json" > /dev/null'
check "list --json: version and source" '[ "$(jget "$T/list.json" kit)" = "\"0.1.0\"" ] && grep -qF "{\"name\": \"team\", \"source\": \"$TEAM\", \"dir\": \"$TEAM\", \"push\": \"pr\"}" "$T/list.json"'
check "list --json: required, used, unused" 'grep -qF "{\"kind\": \"rule\", \"name\": \"security\", \"status\": \"required\", \"new\": false, \"source\": \"team\", \"description\": \"\", \"path\": " "$T/list.json" &&
    grep -qF "{\"kind\": \"skill\", \"name\": \"gerrit-review\", \"status\": \"used\", \"new\": false, \"source\": \"team\", \"description\": \"review a change\", \"path\": " "$T/list.json" &&
    grep -qF "{\"kind\": \"skill\", \"name\": \"gerrit-workflow\", \"status\": \"unused\", \"new\": false, \"source\": \"third-party\", \"description\": \"upstream\", \"path\": " "$T/list.json"'
check "list --json: agent with its description" 'grep -qF "{\"kind\": \"agent\", \"name\": \"gerrit\", \"status\": \"agent\", \"new\": false, \"source\": \"team\", \"description\": \"Gerrit helper\", \"path\": " "$T/list.json"'
check "list --json: new item, text escaped (UTF-8 kept)" 'grep -qF "{\"kind\": \"skill\", \"name\": \"quote\", \"status\": \"unused\", \"new\": true, \"source\": \"team\", \"description\": \"中文 \\\"引號\\\" \\\\ 和\\ttab\", \"path\": " "$T/list.json"'
check "list --json: tools and no version wanted" 'grep -q "^  \"tools\": \[\"claude\"" "$T/list.json" && [ "$(jget "$T/list.json" kit_version_wanted)" = "\"\"" ]'
check "list --json does not mark items seen" '[ "$(kit list --json | grep -c "\"new\": true")" = 1 ]'
if command -v pwsh >/dev/null 2>&1; then
    check "list --json: kit.ps1 prints the same" 'pwsh -NoProfile -File "$HERE/../windows/kit.ps1" list --json 2>&1 | cmp -s - "$T/list.json"'
fi
out=$(kit list --bad 2>&1); rc=$?
check "list with a wrong option: usage" '[ $rc -ne 0 ] && echo "$out" | grep -qF "kit list [--json"'
# --dir: what an agent started in a folder reads besides kit's (the panel follows the agent you click)
mkdir -p "$T/proj/sub/.claude/rules" "$T/proj/sub/.claude/skills/pskill" "$HOME/.claude/skills/mine"
printf '# Project rules\nx\n' > "$T/proj/CLAUDE.md"; printf '# For codex\n' > "$T/proj/AGENTS.md"
printf 'no heading\n' > "$T/proj/sub/CLAUDE.md"; printf '# Rule one\n' > "$T/proj/sub/.claude/rules/r1.md"
printf -- '---\nname: pskill\ndescription: project skill\n---\nx\n' > "$T/proj/sub/.claude/skills/pskill/SKILL.md"
printf -- '---\nname: mine\ndescription: my own\n---\nx\n' > "$HOME/.claude/skills/mine/SKILL.md"
printf '{"mcpServers": {"pm": {"command": "x"}}}\n' > "$T/proj/sub/.mcp.json"
PP=$(cd "$T/proj/sub" && pwd -P); PU=$(cd "$T/proj" && pwd -P)
cp "$HOME/.claude.json" "$T/cj.bak"
printf 'set\tprojects|%s|mcpServers|lm\t{"command": "y"}\nset\tmcpServers|um\t{"command": "z"}\n' "$PP" > "$T/cj.ops"
LC_ALL=C awk -f "$JA" -v ops="$T/cj.ops" -v sep="|" "$T/cj.bak" > "$HOME/.claude.json"
kit list --json --dir "$T/proj/sub" --pid $$ > "$T/here.json" 2>&1; rc=$?
check "list --json --dir: valid JSON, the folder, no other user" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/here.json" > /dev/null && grep -qF "\"here\": {\"dir\": \"$PP\", \"user\": null, \"agent\": null, \"items\": [" "$T/here.json"'
check "list --json --dir: rules here and above, AGENTS.md for codex/omp" 'grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \"CLAUDE.md\", \"path\": \"$PP/CLAUDE.md\", \"tools\": \"claude\", \"description\": \"\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \".claude/rules/r1.md\", \"path\": \"$PP/.claude/rules/r1.md\", \"tools\": \"claude\", \"description\": \"Rule one\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \"$PU/CLAUDE.md\", \"path\": \"$PU/CLAUDE.md\", \"tools\": \"claude\", \"description\": \"Project rules\"}" "$T/here.json" &&
    grep -qF "\"name\": \"$PU/AGENTS.md\", \"path\": \"$PU/AGENTS.md\", \"tools\": \"codex omp\"" "$T/here.json"'
check "list --json --dir: project skill, .mcp.json and local MCP" 'grep -qF "{\"scope\": \"dir\", \"kind\": \"skill\", \"name\": \"pskill\", \"path\": \"$PP/.claude/skills/pskill/SKILL.md\", \"tools\": \"claude\", \"description\": \"project skill\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"mcp\", \"name\": \"pm\", \"path\": \"$PP/.mcp.json\"" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"mcp\", \"name\": \"lm\", \"path\": \"$HOME/.claude.json\"" "$T/here.json"'
check "list --json --dir: this account's own skill and MCP, not kit's" 'grep -qF "{\"scope\": \"user\", \"kind\": \"skill\", \"name\": \"mine\"" "$T/here.json" && grep -qF "{\"scope\": \"user\", \"kind\": \"mcp\", \"name\": \"um\"" "$T/here.json" &&
    ! grep -q "\"scope\": \"user\", \"kind\": \"skill\", \"name\": \"gerrit-review\"" "$T/here.json" && ! grep -q "\"scope\": \"user\", \"kind\": \"mcp\", \"name\": \"gerrit\"" "$T/here.json"'
if command -v pwsh >/dev/null 2>&1; then
    check "list --json --dir: kit.ps1 prints the same" 'pwsh -NoProfile -File "$HERE/../windows/kit.ps1" list --json --dir "$T/proj/sub" --pid $$ > /tmp/here-ps.json 2>&1; cmp -s /tmp/here-ps.json "$T/here.json"'
fi
out=$(kit list --json --dir "$T/nope" 2>&1)
check "list --json --dir: a folder that is not there" 'echo "$out" | grep -qF "\"here\": {\"dir\": \"$T/nope\", \"user\": null, \"agent\": null, \"error\": \"找不到這個資料夾\", \"items\": []}"'
out=$(kit list --json --pid x 2>&1); rc=$?
check "list --json --pid: numbers only" '[ $rc -ne 0 ] && echo "$out" | grep -q "數字"'
RUND="$HOME/.config/agentkit/run"; mkdir -p "$RUND"; echo gerrit > "$RUND/$$"
( : ) & dp=$!; wait $dp; echo gone > "$RUND/$dp"
kit list --json --dir "$T/proj/sub" --pid $$ > "$T/here2.json" 2>&1
check "list --json --pid: the agent kit run started there" 'grep -qF "\"user\": null, \"agent\": {\"name\": \"gerrit\", \"source\": \"team\", \"rules\": [\"gerrit-flow\"], \"skills\": [\"gerrit-review\"], \"mcp\": [\"gerrit\"]}, \"items\": [" "$T/here2.json"'
check "list --json --pid: the marker of a kit run that ended is dropped" '[ ! -e "$RUND/$dp" ] && [ -e "$RUND/$$" ]'
if command -v pwsh >/dev/null 2>&1; then
    echo gone > "$RUND/$dp"
    check "list --json --pid: kit.ps1 finds the same agent" 'pwsh -NoProfile -File "$HERE/../windows/kit.ps1" list --json --dir "$T/proj/sub" --pid $$ 2>&1 | cmp -s - "$T/here2.json" && [ ! -e "$RUND/$dp" ]'
fi
rm -f "$RUND/$$"
mkdir -p "$T/fakebin"; printf '#!/bin/sh\n"$FAKE_KIT" list --json --dir "$PWD" --pid $PPID > "$FAKE_OUT" 2>&1\n' > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
FAKE_KIT=$KIT FAKE_OUT="$T/fake.json" PATH="$T/fakebin:$PATH" kit run gerrit >/dev/null 2>&1; rc=$?
check "kit run: the agent in the pane is known while it runs, the marker goes after" '[ $rc -eq 0 ] && grep -qF "\"agent\": {\"name\": \"gerrit\", \"source\": \"team\"," "$T/fake.json" && [ -z "$(ls "$RUND")" ]'
cp "$T/cj.bak" "$HOME/.claude.json"; rm -rf "$T/proj" "$HOME/.claude/skills/mine"

# ---------- agents --json / agent add|rm (the Herdr agent panel) ----------
cp "$TEAM/agents/gerrit.md" "$T/gerrit.bak"
kit agents --json > "$T/agents.json" 2>&1; rc=$?
check "agents --json: valid JSON, what is available" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/agents.json" > /dev/null && grep -qF "\"rule\": [\"coding-style\", \"gerrit-flow\", \"security\"]" "$T/agents.json" && grep -q "\"skill\": \[.*\"gerrit-workflow\"\]" "$T/agents.json"'
check "agents --json: an agent with its rules, skills, MCP, tools, prompt" 'grep -qF "{\"name\": \"gerrit\", \"description\": \"Gerrit helper\", \"source\": \"team\", \"path\": \"$TEAM/agents/gerrit.md\", \"git\": \"no-git\"," "$T/agents.json" &&
    grep -qF "\"rules\": [\"gerrit-flow\"], \"skills\": [\"gerrit-review\"], \"mcp\": [\"gerrit\"], \"tools_only\": [\"Read\", \"Grep\", \"Glob\"], \"tools_deny\": [\"mcp__gerrit__submit_change\"]," "$T/agents.json" &&
    grep -qF "\"prompt\": \"You are the Gerrit helper.\"}" "$T/agents.json"'
if command -v pwsh >/dev/null 2>&1; then
    check "agents --json: kit.ps1 prints the same" 'pwsh -NoProfile -File "$HERE/../windows/kit.ps1" agents --json 2>&1 | cmp -s - "$T/agents.json"'
fi
out=$(kit agent gerrit add skill gerrit-workflow 2>&1); rc=$?
check "agent add: list grows, the rest of the file kept" '[ $rc -eq 0 ] && grep -qx "skills: \[gerrit-review, gerrit-workflow\]" "$TEAM/agents/gerrit.md" && grep -qx "  deny: \[mcp__gerrit__submit_change\]" "$TEAM/agents/gerrit.md" && grep -qx "You are the Gerrit helper." "$TEAM/agents/gerrit.md" && echo "$out" | grep -qF "kit push --to team"'
out=$(kit agent gerrit rm mcp gerrit 2>&1); rc=$?
check "agent rm: empty list" '[ $rc -eq 0 ] && grep -qx "mcp: \[\]" "$TEAM/agents/gerrit.md"'
out=$(kit agent gerrit add mcp nope 2>&1); rc=$?
check "agent add: only what the sources have" '[ $rc -ne 0 ] && echo "$out" | grep -q "找不到 mcp:nope"'
out=$(kit agent gerrit add tool Bash 2>&1); rc=$?
check "agent add: kinds checked" '[ $rc -ne 0 ] && echo "$out" | grep -q "種類只能是"'
printf -- '---\nname: gerrit\ndescription: Gerrit helper\nskills:\n  - gerrit-review\n  - team-build\nrules: [gerrit-flow]\n---\nbody\n' > "$TEAM/agents/gerrit.md"
out=$(kit agent gerrit rm skill team-build 2>&1); rc=$?
check "agent rm: a block list becomes [..], other keys kept" '[ $rc -eq 0 ] && grep -qx "skills: \[gerrit-review\]" "$TEAM/agents/gerrit.md" && ! grep -q "^  - " "$TEAM/agents/gerrit.md" && grep -qx "rules: \[gerrit-flow\]" "$TEAM/agents/gerrit.md"'
out=$(kit agent gerrit add mcp gerrit 2>&1); rc=$?
check "agent add: a missing key is added to the header" '[ $rc -eq 0 ] && [ "$(sed -n 6p "$TEAM/agents/gerrit.md")" = "mcp: [gerrit]" ] && [ "$(sed -n 7p "$TEAM/agents/gerrit.md")" = "---" ]'
if command -v pwsh >/dev/null 2>&1; then
    cp "$TEAM/agents/gerrit.md" "$T/g1"; kit agent gerrit add skill gerrit-workflow >/dev/null 2>&1; cp "$TEAM/agents/gerrit.md" "$T/g2"; cp "$T/g1" "$TEAM/agents/gerrit.md"
    pwsh -NoProfile -File "$HERE/../windows/kit.ps1" agent gerrit add skill gerrit-workflow >/dev/null 2>&1
    check "agent add: kit.ps1 writes the same file" 'cmp -s "$TEAM/agents/gerrit.md" "$T/g2"'
fi
# a block list with blank and comment lines in it
printf -- '---\nname: gerrit\ndescription: Gerrit helper\nskills:\n  - gerrit-review\n\n  # the team one\n  - team-build\n\n# next\nrules: [gerrit-flow]\n---\nbody\n' > "$T/blk.md"
printf -- '---\nname: gerrit\ndescription: Gerrit helper\nskills: [gerrit-review]\n\n# next\nrules: [gerrit-flow]\n---\nbody\n' > "$T/blk.want"
cp "$T/blk.md" "$TEAM/agents/gerrit.md"; out=$(kit agent gerrit rm skill team-build 2>&1); rc=$?
check "agent rm: a block list with blank and comment lines in it is replaced whole" '[ $rc -eq 0 ] && cmp -s "$TEAM/agents/gerrit.md" "$T/blk.want"'
if command -v pwsh >/dev/null 2>&1; then
    cp "$T/blk.md" "$TEAM/agents/gerrit.md"; pwsh -NoProfile -File "$HERE/../windows/kit.ps1" agent gerrit rm skill team-build >/dev/null 2>&1
    check "agent rm: kit.ps1 replaces the block list the same" 'cmp -s "$TEAM/agents/gerrit.md" "$T/blk.want"'
fi
# a CRLF file (from a Windows editor)
printf -- '---\r\nname: gerrit\r\ndescription: Gerrit helper\r\nskills: [gerrit-review]\r\nrules: [gerrit-flow]\r\n---\r\nYou are the Gerrit helper.\r\n' > "$T/crlf.md"
cp "$T/crlf.md" "$TEAM/agents/gerrit.md"
out=$(kit agent gerrit add skill gerrit-workflow 2>&1); rc=$?
out2=$(kit agent gerrit add mcp gerrit 2>&1); rc2=$?
check "agent add: a CRLF file is read and stays CRLF" '[ $rc -eq 0 ] && [ $rc2 -eq 0 ] && grep -qx "skills: \[gerrit-review, gerrit-workflow\]$(printf "\r")" "$TEAM/agents/gerrit.md" && grep -qx "mcp: \[gerrit\]$(printf "\r")" "$TEAM/agents/gerrit.md" && [ "$(tr -cd "\r" < "$TEAM/agents/gerrit.md" | wc -c | tr -d " ")" = 8 ] && [ "$(wc -l < "$TEAM/agents/gerrit.md" | tr -d " ")" = 8 ]'
cp "$TEAM/agents/gerrit.md" "$T/crlf.bash"
check "agents --json: a CRLF agent's prompt without CR" 'kit agents --json 2>&1 | grep -qF "\"prompt\": \"You are the Gerrit helper.\"}"'
check "check: a CRLF agent's header is read" '! kit check "$TEAM" 2>&1 | grep -q "agents/gerrit.md: 開頭要有"'
if command -v pwsh >/dev/null 2>&1; then
    cp "$T/crlf.md" "$TEAM/agents/gerrit.md"
    pwsh -NoProfile -File "$HERE/../windows/kit.ps1" agent gerrit add skill gerrit-workflow >/dev/null 2>&1; pwsh -NoProfile -File "$HERE/../windows/kit.ps1" agent gerrit add mcp gerrit >/dev/null 2>&1
    check "agent add: kit.ps1 keeps CRLF the same" 'cmp -s "$TEAM/agents/gerrit.md" "$T/crlf.bash"'
fi
# a header kit cannot read: stop, change nothing
printf -- '---\nname: gerrit\ndescription: Gerrit helper\njust words\nskills: [gerrit-review]\n---\nbody\n' > "$T/bad.md"; cp "$T/bad.md" "$TEAM/agents/gerrit.md"
out=$(kit agent gerrit add skill gerrit-workflow 2>&1); rc=$?
check "agent add: a header kit cannot read stops it, the file is not changed" '[ $rc -ne 0 ] && echo "$out" | grep -q 讀不懂 && cmp -s "$TEAM/agents/gerrit.md" "$T/bad.md"'
if command -v pwsh >/dev/null 2>&1; then
    out=$(pwsh -NoProfile -File "$HERE/../windows/kit.ps1" agent gerrit add skill gerrit-workflow 2>&1); rc=$?
    check "agent add: kit.ps1 stops too" '[ $rc -ne 0 ] && echo "$out" | grep -q 讀不懂 && cmp -s "$TEAM/agents/gerrit.md" "$T/bad.md"'
fi
# kit check: what an agent uses must exist (rules, skills and mcp)
printf -- '---\nname: gerrit\ndescription: Gerrit helper\nmcp: [nope]\n---\nbody\n' > "$TEAM/agents/gerrit.md"
out=$(kit check "$TEAM" 2>&1)
check "check: an agent's missing MCP is reported" 'echo "$out" | grep -qF "agents/gerrit.md: 找不到 mcp:nope"'
cp "$T/gerrit.bak" "$TEAM/agents/gerrit.md"
rm -rf "$TEAM/skills/quote"

# ---------- kit_version: tell once when the team wants a newer kit ----------
cp "$TEAM/kit.yaml" "$T/kit.yaml.orig"
echo "kit_version: 0.4.0" >> "$TEAM/kit.yaml"
out=$(kit sync 2>&1)
check "old kit: sync tells the user" 'echo "$out" | grep -qF "團隊要 kit 0.4.0 以上，你的是 0.1.0。請打  kit self-update"'
out=$(kit sync 2>&1; kit list 2>&1)
check "old kit: told only once" '! echo "$out" | grep -q 團隊要'
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"; echo "kit_version: 0.10.0" >> "$TEAM/kit.yaml"
out=$(kit list 2>&1)
check "team version changed: list tells again (numbers, not text)" 'echo "$out" | grep -qF "團隊要 kit 0.10.0 以上"'
mkdir -p "$T/dev/unix"; cp "$HERE"/../unix/* "$T/dev/unix/"
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"; echo "kit_version: 0.6.0" >> "$TEAM/kit.yaml"
out=$("$T/dev/unix/kit" sync 2>&1)
check "dev build (no VERSION) is not told" '! echo "$out" | grep -q 團隊要'
echo "0.6.0+local" > "$T/dev/VERSION"
out=$("$T/dev/unix/kit" sync 2>&1)
check "+build part ignored" '! echo "$out" | grep -q 團隊要'
echo "0.5.9" > "$T/dev/VERSION"
out=$("$T/dev/unix/kit" sync 2>&1)
check "older patch level is told" 'echo "$out" | grep -qF "團隊要 kit 0.6.0 以上，你的是 0.5.9"'
state_nag() { awk -F'\t' '$1 == "nag"' "$HOME/.config/agentkit/state.tsv"; }
echo "0.6.0" > "$T/dev/VERSION"; "$T/dev/unix/kit" sync >/dev/null 2>&1
check "new enough: note forgotten" '[ -z "$(state_nag)" ]'
# kit_version 0.6.0 stays for the background sync below

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
check "codex run: values are valid TOML" 'printf "a = %s\nb = %s\n" "$dev" "$srv" | python3 -c "import sys,tomllib; d=tomllib.loads(sys.stdin.read()); assert d[\"b\"][\"command\"]==\"uvx\"" 2>/dev/null'
check "codex run: deny -> disabled_tools" 'echo "$srv" | grep -qF "disabled_tools=[\"submit_change\"]"'
check "codex run: env not expanded" 'echo "$srv" | grep -qF "\${HOME}/.config/gerrit"'
check "codex run: warns tools.only, keeps user args" 'echo "$out" | grep -q "tools.only" && echo "$out" | grep -qx exec'
rm -rf "$tmp"

out=$(KIT_DRY_RUN=1 kit run gerrit --tool omp 2>&1)
tmp=$(echo "$out" | sed -n 's/^tmp=//p')
check "omp run: config overlay points at skills" 'grep -qF "$tmp/skills" "$tmp/omp.yml" && [ -f "$tmp/skills/gerrit-review/SKILL.md" ]'
check "omp run: prompt + lowercase tools" 'echo "$out" | grep -qx -- --append-system-prompt && echo "$out" | grep -qx "read,grep,glob"'
check "omp run: warns no per-agent mcp" 'echo "$out" | grep -q "kit add mcp"'
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
check "hook synced in the background" 'grep -q "hook change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
check "hook logs" 'grep -q "^== " "$HOME/.config/agentkit/sync.log"'
check "hook: kit_version not told in the background" '! grep -q 團隊要 "$HOME/.config/agentkit/sync.log" && [ -z "$(state_nag)" ]'
echo "second change" >> "$TEAM/skills/gerrit-review/SKILL.md"
kit sync --hook; sleep 2
check "hook runs at most every 10 minutes" '! grep -q "second change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
out=$(kit sync 2>&1)
check "hook: kit_version told at the next sync" 'echo "$out" | grep -qF "團隊要 kit 0.6.0 以上"'
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"

# ---------- a source starts including another one ----------
mkdir -p "$T/extra-src/rules"; echo "Extra rule." > "$T/extra-src/rules/extra-rule.md"
before=$(grep '^added' "$HOME/.config/agentkit/machine.yaml")
sed "s#^include: \[\(.*\)\]#include: [\1, ../extra-src]#" "$TEAM/kit.yaml" > "$T/k.tmp" && mv "$T/k.tmp" "$TEAM/kit.yaml"
out=$(kit sync 2>&1)
check "sync adds a new include (relative to the source)" 'grep -qxF "  - $T/extra-src" "$HOME/.config/agentkit/machine.yaml" && echo "$out" | grep -q "加了來源"'
check "sync keeps what you added" '[ "$(grep "^added" "$HOME/.config/agentkit/machine.yaml")" = "$(echo "$before" | grep "^added")" ]'
check "items of the new source are announced" 'echo "$out" | grep -q "rule:extra-rule"'
out=$(kit sync 2>&1)
check "include added only once" '[ "$(grep -c "extra-src" "$HOME/.config/agentkit/machine.yaml")" = 1 ]'
# a clone of a URL source sits in ~/agentkit/<name>; an include pointing at that folder is the same source
mkdir -p "$T/lc/rules"; echo "x" > "$T/lc/rules/lc.md"
( cd "$T/lc" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm x && git clone -q --bare . "$T/lc.git" )
git clone -q "$T/lc.git" "$HOME/agentkit/lib-clone"     # as if kit had cloned the URL source (pull stays local)
cp "$HOME/.config/agentkit/machine.yaml" "$T/m.bak"
awk '{ print } /^sources:/ { print "  - https://gitea.example/team/lib-clone.git" }' "$T/m.bak" > "$HOME/.config/agentkit/machine.yaml"
sed "s#, ../extra-src]#, ../extra-src, $HOME/agentkit/lib-clone]#" "$TEAM/kit.yaml" > "$T/k.tmp" && mv "$T/k.tmp" "$TEAM/kit.yaml"
out=$(kit sync 2>&1); rc=$?
check "include of a cloned source's folder is not added twice" '[ $rc -eq 0 ] && [ "$(grep -c lib-clone "$HOME/.config/agentkit/machine.yaml")" = 1 ] && echo "$out" | grep -q "rule:lc"'
sed "s#, $HOME/agentkit/lib-clone]#]#" "$TEAM/kit.yaml" > "$T/k.tmp" && mv "$T/k.tmp" "$TEAM/kit.yaml"; cp "$T/m.bak" "$HOME/.config/agentkit/machine.yaml"; rm -rf "$HOME/agentkit/lib-clone"

# ---------- allowed_hosts ----------
out=$(kit init "$TEAM" https://public-git.example/someone/agentkit-library.git 2>&1); rc=$?
check "host outside allowed_hosts refused" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單"'
kit init "$TEAM" >/dev/null 2>&1

# ---------- new / diff / update / check (authoring, local only) ----------
AU="$T/authoring"; LIB="$T/lib"
mkdir -p "$AU" "$LIB/skills/foo/scripts" "$LIB/skills/foo/.git" "$LIB/skills/bar"
printf 'name: authoring\ncontent_hosts: [gitea.example]\nrequired:\n  rules: [sec]\n' > "$AU/kit.yaml"
printf -- '---\nname: foo\ndescription: foo skill\n---\nRun scripts/x.sh, see https://gitea.example/doc\n' > "$LIB/skills/foo/SKILL.md"
echo 'echo hi' > "$LIB/skills/foo/scripts/x.sh"; echo MIT > "$LIB/skills/foo/LICENSE"; echo readme > "$LIB/skills/foo/README.md"
printf '\0\1\2' > "$LIB/skills/foo/logo.png"; echo x > "$LIB/skills/foo/.git/config"
printf -- '---\nname: bar\ndescription: >-\n  Use for bar.\n  Two lines # not a comment\n\nlicense: MIT\n---\nbar\n' > "$LIB/skills/bar/SKILL.md"; echo 'echo no' > "$LIB/skills/bar/run.sh"
cd "$AU"
out=$(kit new rule sec 2>&1); rc=$?
check "new rule skeleton in the folder with kit.yaml" '[ $rc -eq 0 ] && [ -s "$AU/rules/sec.md" ]'
kit new agent bot >/dev/null 2>&1
check "new agent skeleton has frontmatter" 'head -2 "$AU/agents/bot.md" | grep -qx "name: bot"'
out=$(kit new skill foo --from "$LIB/skills/foo" 2>&1); rc=$?
check "new --from copies md and declared scripts" '[ $rc -eq 0 ] && [ -f "$AU/skills/foo/SKILL.md" ] && [ -f "$AU/skills/foo/scripts/x.sh" ]'
check "new --from skips LICENSE, README, binaries, .git" '[ ! -e "$AU/skills/foo/LICENSE" ] && [ ! -e "$AU/skills/foo/README.md" ] && [ ! -e "$AU/skills/foo/logo.png" ] && [ ! -e "$AU/skills/foo/.git" ]'
check "new --from reminds to delete the temp folder" 'echo "$out" | grep -q 記得刪掉'
kit new skill bar --from "$LIB/skills/bar" >/dev/null 2>&1
check "undeclared extra files not copied" '[ ! -e "$AU/skills/bar/run.sh" ]'
check "yaml block text joined into one line" '[ "$(LC_ALL=C awk -f "$HERE/../unix/yaml.awk" -v frontmatter=1 "$AU/skills/bar/SKILL.md" | tr "\t" "|")" = "name|bar
description|Use for bar. Two lines # not a comment
license|MIT" ]'
out=$(kit new skill foo 2>&1); rc=$?
check "new refuses an existing name" '[ $rc -ne 0 ]'
out=$(kit new skill gerrit-review 2>&1); rc=$?
check "new refuses a name another source has" '[ $rc -ne 0 ] && echo "$out" | grep -q 名字重複'
out=$(kit new skill Bad_Name 2>&1); rc=$?
check "new refuses bad names" '[ $rc -ne 0 ]'
for u in https://public-git.example/x/y git@public-git.example:x/y.git; do
    out=$(kit new skill zz --from "$u" 2>&1); rc=$?
    check "--from refuses $u" '[ $rc -ne 0 ] && echo "$out" | grep -q 本機'
done
echo "new line" >> "$LIB/skills/foo/SKILL.md"
out=$(kit diff foo --from "$LIB/skills/foo" 2>&1)
check "diff shows the change" 'echo "$out" | grep -q "^+new line"'
out=$(kit update foo --from "$LIB/skills/foo" 2>&1); rc=$?
check "update applies it" '[ $rc -eq 0 ] && grep -q "new line" "$AU/skills/foo/SKILL.md"'
echo "colleague edit" >> "$AU/skills/foo/SKILL.md"; echo "second" >> "$LIB/skills/foo/SKILL.md"
out=$(kit update foo --from "$LIB/skills/foo" 2>&1); rc=$?
check "update stops when someone changed it" '[ $rc -ne 0 ] && grep -q "colleague edit" "$AU/skills/foo/SKILL.md" && echo "$out" | grep -q 被改過'
out=$(kit update skill foo --from "$LIB/skills/foo" --force 2>&1); rc=$?
check "update --force overwrites" '[ $rc -eq 0 ] && ! grep -q "colleague edit" "$AU/skills/foo/SKILL.md" && grep -q second "$AU/skills/foo/SKILL.md"'
printf -- '---\nname: bot\ndescription: b\nskills: [foo]\n---\nhi\n' > "$AU/agents/bot.md"
out=$(kit check 2>&1); rc=$?
check "check passes on clean content" '[ $rc -eq 0 ]'
printf -- '---\nname: bot\ndescription: b\nskills: [foo, nope]\n---\nsee https://evil.example/x\n' > "$AU/agents/bot.md"
mkdir -p "$AU/mcp"; printf 'command: uvx\nargs: [git+https://gitea.example/x.git]\n' > "$AU/mcp/m.yaml"
mkdir -p "$AU/skills/baz"; printf 'no header\n' > "$AU/skills/baz/SKILL.md"
cp "$LIB/skills/foo/logo.png" "$AU/skills/foo/"; ln -s /etc/hosts "$AU/rules/link.md"
mkdir -p "$AU/skills/foo/.git"; echo "[submodule]" > "$AU/.gitmodules"
mkdir -p "$HOME/.config/agentkit"; printf '# mine\nTopSecretName\n' > "$HOME/.config/agentkit/private-words.txt"
echo "by topsecretname" >> "$AU/rules/sec.md"
out=$(kit check 2>&1); rc=$?
check "check fails" '[ $rc -ne 0 ]'
check "check: missing reference" 'echo "$out" | grep -q "agents/bot.md: 找不到 skill:nope"'
check "check: url not in content_hosts" 'echo "$out" | grep -q "agents/bot.md:6: 網址 evil.example"'
check "check: mcp from git" 'echo "$out" | grep -q "mcp/m.yaml: MCP 只能"'
check "check: skill header" 'echo "$out" | grep -q "skills/baz/SKILL.md: 開頭要有"'
check "check: binary, symlink, submodule, nested git" 'echo "$out" | grep -q "logo.png: 只能放文字檔" && echo "$out" | grep -q "link.md: 不能放捷徑" && echo "$out" | grep -q ".gitmodules: 不能用" && echo "$out" | grep -q "skills/foo/.git: 裡面不能有"'
check "check: private word found, never printed" 'echo "$out" | grep -q "rules/sec.md:[0-9]*: 有不該公開的字" && ! echo "$out" | grep -qi topsecret'
check "check: counts every problem" 'echo "$out" | grep -q "kit check：9 個問題"'
mkdir -p "$AU/skills/gerrit-review"; printf -- '---\nname: gerrit-review\ndescription: x\n---\nx\n' > "$AU/skills/gerrit-review/SKILL.md"
out=$(kit check "$AU" 2>&1)
check "check: duplicate name across sources" 'echo "$out" | grep -q "名字重複：skill:gerrit-review"'
rm -rf "$AU/skills/gerrit-review"
# --ci: author emails from the company domain only
rm -rf "$AU/skills/foo/.git" "$AU/.gitmodules" "$AU/rules/link.md" "$AU/skills/foo/logo.png" "$AU/skills/baz" "$AU/mcp"
printf -- '---\nname: bot\ndescription: b\nskills: [foo]\n---\nhi\n' > "$AU/agents/bot.md"; echo "Be safe." > "$AU/rules/sec.md"
echo "author_domains: [corp.example]" >> "$AU/kit.yaml"
git -C "$AU" init -q && git -C "$AU" add -A && git -C "$AU" -c user.name=a -c user.email=me@home.example commit -qm x
out=$(kit check --ci 2>&1); rc=$?
check "check --ci: author email must be company" '[ $rc -ne 0 ] && echo "$out" | grep -q "作者 email 不是公司網域"'
git -C "$AU" -c user.name=a -c user.email=me@corp.example commit -q --amend --reset-author -m x
out=$(kit check --ci 2>&1); rc=$?
check "check --ci passes" '[ $rc -eq 0 ]'
cd "$T"

# ---------- export-self (a fake kit repo; the private word list of this HOME is still set) ----------
FK="$T/fakekit"; EX="$T/export"; EX2="$T/export2"
mkdir -p "$FK/unix" "$FK/windows" "$FK/.github/workflows" "$FK/tests" "$FK/docs"
cp "$HERE/../unix/kit" "$HERE/../unix/json.awk" "$HERE/../unix/yaml.awk" "$FK/unix/"; cp "$HERE/../windows/kit.ps1" "$FK/windows/"
echo 0.3.0 > "$FK/VERSION"; echo "# kit" > "$FK/README.md"; echo notes > "$FK/CHANGELOG.md"; echo MIT > "$FK/LICENSE"; echo "on: push" > "$FK/.github/workflows/ci.yml"
echo "echo test" > "$FK/tests/t.sh"; echo "* text=auto" > "$FK/.gitattributes"; echo "*.tmp" > "$FK/.gitignore"; echo guide > "$FK/docs/guide.md"
echo repoword > "$FK/private-words.txt"
fkcommit() { git -C "$FK" add -A && git -C "$FK" -c user.name=t -c user.email=t@t commit -qm x; }
git -C "$FK" init -q; fkcommit
echo "not tracked" > "$FK/untracked.md"
out=$("$FK/unix/kit" export-self "$EX" --version 0.4.0+gitea.12 2>&1); rc=$?
check "export-self succeeds, says the commit message" '[ $rc -eq 0 ] && echo "$out" | grep -q "kit 0.4.0+gitea.12"'
check "export-self drops README, CHANGELOG, LICENSE, .github, private-words.txt" '[ ! -e "$EX/README.md" ] && [ ! -e "$EX/LICENSE" ] && [ ! -e "$EX/CHANGELOG.md" ] && [ ! -e "$EX/.github" ] && [ ! -e "$EX/private-words.txt" ]'
check "export-self keeps tests, .gitattributes, .gitignore, kit" '[ -f "$EX/tests/t.sh" ] && [ -f "$EX/.gitattributes" ] && [ -f "$EX/.gitignore" ] && [ -x "$EX/unix/kit" ] && [ -f "$EX/windows/kit.ps1" ]'
check "export-self leaves out untracked files" '[ ! -e "$EX/untracked.md" ]'
check "export-self writes VERSION" '[ "$(cat "$EX/VERSION")" = 0.4.0+gitea.12 ]'
check "export-self INSTALL.md, no URL" 'grep -q "sh unix/install.sh" "$EX/INSTALL.md" && grep -qF "windows\\install.ps1" "$EX/INSTALL.md" && ! grep -qE "://|@[A-Za-z0-9.-]+:" "$EX/INSTALL.md"'
out=$("$FK/unix/kit" export-self "$EX" 2>&1); rc=$?
check "export-self stops when the folder is not empty" '[ $rc -ne 0 ] && echo "$out" | grep -q 不是空的 && [ -f "$EX/VERSION" ]'
gh='github''.com'
mkdir "$EX2"; echo "see https://$gh/x" >> "$FK/docs/guide.md"; fkcommit
out=$("$FK/unix/kit" export-self "$EX2" 2>&1); rc=$?
check "export-self: GitHub word fails, folder deleted" '[ $rc -ne 0 ] && echo "$out" | grep -q "docs/guide.md:2: 有 GitHub 的字" && [ ! -e "$EX2" ]'
echo guide > "$FK/docs/guide.md"; echo "by TopSecretName" > "$FK/tests/t.sh"; echo x > "$FK/docs/my-repoword.md"; printf '\0\1' > "$FK/docs/logo.png"; fkcommit
out=$("$FK/unix/kit" export-self "$EX2" 2>&1); rc=$?
check "export-self: private words (this machine and the repo's list), file names, binaries" '[ $rc -ne 0 ] && echo "$out" | grep -q "tests/t.sh:1: 有不該公開的字" && echo "$out" | grep -q "docs/<不公開>: 檔名有不該公開的字" && echo "$out" | grep -q "docs/logo.png: 只能放文字檔" && [ ! -e "$EX2" ]'
check "export-self never prints the private word" '! echo "$out" | grep -qi -e topsecret -e repoword'
git -C "$FK" rm -q docs/my-repoword.md docs/logo.png; echo "echo test" > "$FK/tests/t.sh"; fkcommit
mkdir -p "$T/inst"; cp "$HERE/../unix/kit" "$HERE/../unix/json.awk" "$HERE/../unix/yaml.awk" "$T/inst/"; echo "$FK" > "$T/inst/.repo"
out=$("$T/inst/kit" export-self "$EX2" 2>&1); rc=$?
check "export-self from an installed kit uses the clone in .repo" '[ $rc -eq 0 ] && [ "$(cat "$EX2/VERSION")" = 0.3.0 ] && [ -f "$EX2/docs/guide.md" ]'

# ---------- push (local bare repo as origin, fake Gitea on localhost) ----------
P="$T/push"; W="$P/work"; ORIGIN="$P/remote/acme/team.git"; DAY=$(date +%Y%m%d)
mkdir -p "$P/remote/acme"; git -c init.defaultBranch=main init -q --bare "$ORIGIN"
git -c init.defaultBranch=main init -q "$W"
printf 'name: team\nallowed_hosts: [gitea.example, 127.0.0.1]\nauthor_domains: [corp.example]\n' > "$W/kit.yaml"
mkdir -p "$W/rules"; echo "Be kind." > "$W/rules/base.md"
git -C "$W" config user.name tester; git -C "$W" config user.email me@corp.example
git -C "$W" add -A; git -C "$W" commit -qm init; git -C "$W" remote add origin "$ORIGIN"
git -C "$W" push -q origin main 2>/dev/null; git -C "$W" fetch -q origin; git -C "$W" remote set-head origin main
cat > "$P/fake-gitea" <<'PYEOF'
import http.server, json, sys
port_file, log_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(log_file, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": json.loads(body)}) + "\n")
        out = json.dumps({"number": 1, "html_url": "http://127.0.0.1/acme/team/pulls/1"}).encode()
        self.send_response(201); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PYEOF
: > "$P/req.log"; python3 -I "$P/fake-gitea" "$P/port" "$P/req.log" & FAKE=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$P/port" ] && break; sleep 1; done
export KIT_GITEA_API="http://127.0.0.1:$(cat "$P/port")/api/v1"; unset KIT_GITEA_TOKEN
remote_heads() { git --git-dir="$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads; }
cd "$W"
out=$(kit push 2>&1); rc=$?
check "push: nothing to send" '[ $rc -eq 0 ] && echo "$out" | grep -q 沒有要送的'
kit new skill pfoo >/dev/null 2>&1
head0=$(git rev-parse HEAD)
out=$(kit push --dry-run 2>&1); rc=$?
check "push --dry-run lists files and branch, sends nothing" '[ $rc -eq 0 ] && echo "$out" | grep -q "skills/pfoo/SKILL.md" && echo "$out" | grep -q "kit/pfoo-$DAY" && [ "$(git rev-parse HEAD)" = "$head0" ] && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
echo "TopSecretName here" >> skills/pfoo/SKILL.md
out=$(kit push 2>&1); rc=$?
check "push: check problem stops, nothing sent" '[ $rc -ne 0 ] && echo "$out" | grep -q 什麼都沒送 && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
printf -- '---\nname: pfoo\ndescription: p\n---\nok\n' > skills/pfoo/SKILL.md
git config user.email me@home.example
out=$(kit push 2>&1); rc=$?
check "push: author domain must be company" '[ $rc -ne 0 ] && echo "$out" | grep -q "不是公司網域" && [ "$(remote_heads)" = main ]'
git config user.email me@corp.example
git remote set-url origin https://public-git.example/acme/team.git
out=$(kit push 2>&1); rc=$?
check "push: origin host not allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單" && [ "$(remote_heads)" = main ]'
git remote set-url origin "$ORIGIN"
echo "local only" > notes.txt; git add notes.txt; git commit -qm "local only"   # an unpushed commit on main
out=$(kit push 2>&1); rc=$?
check "push: no token -> compare URL" '[ $rc -eq 0 ] && echo "$out" | grep -qF "開 PR：${KIT_GITEA_API%/api/v1}/acme/team/compare/main...kit/pfoo-$DAY"'
check "push: only the kit branch is pushed" '[ "$(remote_heads | sort | paste -sd" " -)" = "kit/pfoo-$DAY main" ] && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$head0" ]'
check "push: commit has only the item, message" '[ "$(git --git-dir="$ORIGIN" log -1 --format=%s "kit/pfoo-$DAY")" = "kit: add skill:pfoo" ] && [ "$(git --git-dir="$ORIGIN" diff --name-only main "kit/pfoo-$DAY")" = skills/pfoo/SKILL.md ]'
check "push: back on main, no PR request" '[ "$(git symbolic-ref --short HEAD)" = main ] && [ ! -s "$P/req.log" ]'
echo "Be kinder." > rules/base.md; kit new rule pnew >/dev/null 2>&1; echo "x" > rules/pnew.md
out=$(KIT_GITEA_TOKEN=fake-tok-123 kit push 2>&1); rc=$?
req=$(tail -1 "$P/req.log")
check "push: PR opened, URL printed" '[ $rc -eq 0 ] && echo "$out" | grep -qF "已開 PR：http://127.0.0.1/acme/team/pulls/1"'
check "push: PR request path, token header, head/base" 'echo "$req" | grep -qF "\"path\": \"/api/v1/repos/acme/team/pulls\"" && echo "$req" | grep -qF "\"auth\": \"token fake-tok-123\"" && echo "$req" | grep -qF "\"head\": \"kit/base-pnew-$DAY\"" && echo "$req" | grep -qF "\"base\": \"main\""'
check "push: PR title is the commit message" 'echo "$req" | grep -qF "\"title\": \"kit: add rule:pnew; update rule:base\""'
check "push: token never printed" '! echo "$out" | grep -q fake-tok'
mkdir -p "$HOME/.config/agentkit"; echo "file-tok-456" > "$HOME/.config/agentkit/gitea-token"; chmod 644 "$HOME/.config/agentkit/gitea-token"
kit new skill pfoo >/dev/null 2>&1; printf -- '---\nname: pfoo\ndescription: p\n---\nagain\n' > skills/pfoo/SKILL.md
out=$(kit push 2>&1); rc=$?
check "push: same branch name taken -> -2" '[ $rc -eq 0 ] && remote_heads | grep -qx "kit/pfoo-$DAY-2"'
check "push: token file used, loose permission warned" 'tail -1 "$P/req.log" | grep -qF "token file-tok-456" && echo "$out" | grep -q "chmod 600" && ! echo "$out" | grep -q file-tok'
rm -f "$HOME/.config/agentkit/gitea-token"
kill $FAKE 2>/dev/null; unset KIT_GITEA_API
cd "$T"

# ---------- push: direct (kit.yaml): your own source, straight to every remote, no PR ----------
D="$T/pushdirect"; DW="$D/work"; R1="$D/one.git"; R2="$D/two.git"
git -c init.defaultBranch=main init -q --bare "$R1"; git -c init.defaultBranch=main init -q --bare "$R2"
git -c init.defaultBranch=main init -q "$DW"
printf 'name: mine\npush: direct\nallowed_hosts: [gitea.example]\n' > "$DW/kit.yaml"; mkdir -p "$DW/rules"; echo "Mine." > "$DW/rules/mine.md"
git -C "$DW" config user.name tester; git -C "$DW" config user.email me@home.example
git -C "$DW" add -A; git -C "$DW" commit -qm init
git -C "$DW" remote add one "$R1"; git -C "$DW" remote add two "$R2"
git -C "$DW" push -q one main 2>/dev/null; git -C "$DW" push -q two main 2>/dev/null; git -C "$DW" fetch -q one; git -C "$DW" fetch -q two
cd "$DW"
echo "Mine, changed." > rules/mine.md; echo "not an item" > notes.txt
dh0=$(git rev-parse HEAD)
printf 'name: mine\n' > kit.yaml
out=$(kit push --dry-run 2>&1); rc=$?
check "push (pr, the default) without origin: stops and says to write push: direct" '[ $rc -ne 0 ] && echo "$out" | grep -q "沒有 origin" && echo "$out" | grep -qF "push: direct" && [ "$(git rev-parse HEAD)" = "$dh0" ]'
printf 'name: mine\npush: maybe\n' > kit.yaml
out=$(kit check . 2>&1); rc=$?
check "check: push is pr or direct" '[ $rc -ne 0 ] && echo "$out" | grep -qF "kit.yaml: push 只能是 pr 或 direct"'
git checkout -q -- kit.yaml
git config remote.one.pushurl https://evil.example/one.git
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct: a push URL to a host not allowed stops it" '[ $rc -ne 0 ] && echo "$out" | grep -q "evil.example 不在允許的主機清單"'
git config --unset remote.one.pushurl
git config "url.https://evil.example/.pushInsteadOf" "$D/"
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct: pushInsteadOf to a host not allowed stops it" '[ $rc -ne 0 ] && echo "$out" | grep -q "evil.example 不在允許的主機清單"'
git config --remove-section "url.https://evil.example/"
git config "url.evil.example:.pushInsteadOf" "$D/"
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct: pushInsteadOf to host:path (no user@) is a host too" '[ $rc -ne 0 ] && echo "$out" | grep -q "evil.example 不在允許的主機清單"'
git config --remove-section "url.evil.example:"
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct --dry-run: straight to the remotes, nothing sent" '[ $rc -eq 0 ] && echo "$out" | grep -qF "push: direct" && echo "$out" | grep -q "one two" && echo "$out" | grep -q "rules/mine.md" && [ "$(git rev-parse HEAD)" = "$dh0" ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$dh0" ]'
out=$(kit push 2>&1); rc=$?
check "push direct: commit on main, pushed to every remote" '[ $rc -eq 0 ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$(git rev-parse HEAD)" ] && [ "$(git --git-dir="$R2" rev-parse main)" = "$(git rev-parse HEAD)" ] && [ "$(git log -1 --format=%s)" = "kit: update rule:mine" ] && [ "$(git symbolic-ref --short HEAD)" = main ]'
check "push direct: only the item is committed" '[ "$(git show --name-only --format= HEAD)" = rules/mine.md ] && [ "$(git status --porcelain)" = "?? notes.txt" ]'
git commit -q --allow-empty -m unpushed; echo "Mine, again." > rules/mine.md; dh1=$(git rev-parse HEAD)
out=$(kit push 2>&1); rc=$?
check "push direct: a commit not on a remote yet stops it, nothing committed" '[ $rc -ne 0 ] && echo "$out" | grep -q "還沒推到 one" && [ "$(git rev-parse HEAD)" = "$dh1" ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$(git rev-parse HEAD~1)" ]'
git reset -q --soft HEAD~1
git -c init.defaultBranch=main init -q --bare "$D/three.git"; git remote add three "$D/three.git"
out=$(kit push 2>&1); rc=$?
check "push direct: a remote without this branch stops it" '[ $rc -ne 0 ] && echo "$out" | grep -q "three 上沒有 main" && [ "$(git rev-parse HEAD)" = "$(git --git-dir="$R1" rev-parse main)" ]'
git remote remove three
git clone -q "$R1" "$D/other" 2>/dev/null; git -C "$D/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m theirs; git -C "$D/other" push -q origin HEAD:main 2>/dev/null
out=$(kit push 2>&1); rc=$?
check "push direct: new commits on a remote stop it (pull first)" '[ $rc -ne 0 ] && echo "$out" | grep -qF "git pull one main" && [ "$(git status --porcelain rules)" = " M rules/mine.md" ]'
cd "$T"

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

# ---------- install / self-update / uninstall --self ----------
R="$T/clone"; mkdir -p "$R"; cp -R "$HERE/../unix" "$HERE/../templates" "$HERE/../herdr" "$HERE/../VERSION" "$R/"
( cd "$R" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm v1 )
U="$T/clone2"; git clone -q "$R" "$U"
touch "$HOME/.bashrc"
out=$(PATH=/usr/bin:/bin sh "$U/unix/install.sh" 2>&1)
check "install puts kit in ~/.local/bin" '[ -x "$HOME/.local/bin/kit" ] && "$HOME/.local/bin/kit" --version | grep -q "kit 0.1.0"'
check "install adds PATH once" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
check "reinstall does not add PATH twice" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
check "installed kit works" '"$HOME/.local/bin/kit" init "$TEAM" >/dev/null 2>&1 && grep -q agentkit:begin "$HOME/.claude/CLAUDE.md"'
check "installed kit has the ci template" '"$HOME/.local/bin/kit" ci-template | cmp -s - "$R/templates/gitea-kit-check.yaml"'
( cd "$R" && echo 0.1.1 > VERSION && git -c user.name=t -c user.email=t@t commit -qam v2 )
out=$("$HOME/.local/bin/kit" self-update 2>&1)
check "self-update pulls new version" '"$HOME/.local/bin/kit" --version | grep -q "kit 0.1.1"'
check "self-update shows the commit" 'echo "$out" | grep -qF "已更新到 0.1.1（$(git -C "$R" rev-parse --short=12 HEAD)）"'
out=$("$HOME/.local/bin/kit" self-update 2>&1)
check "self-update with nothing new says so" 'echo "$out" | grep -q "已經是最新"'
"$HOME/.local/bin/kit" uninstall --self >/dev/null 2>&1
# a new Mac: zsh, no startup files at all
H2="$T/home2"; mkdir -p "$H2"
HOME="$H2" SHELL=/bin/zsh PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
check "zsh user without rc gets ~/.zshrc" 'grep -q "added by agentkit" "$H2/.zshrc"'
command -v zsh >/dev/null && check "zsh PATH line works" '[ "$(HOME="$H2" PATH=/usr/bin:/bin zsh -c ". \"$H2/.zshrc\"; command -v kit")" = "$H2/.local/bin/kit" ]' || echo "skip: zsh not installed"
H3="$T/home3"; mkdir -p "$H3"
HOME="$H3" SHELL=/bin/bash PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
if [ "$(uname)" = Darwin ]; then check "mac bash user gets ~/.bash_profile" 'grep -q "added by agentkit" "$H3/.bash_profile"'
else check "linux bash user gets ~/.bashrc" 'grep -q "added by agentkit" "$H3/.bashrc"'; fi
check "uninstall --self removes kit" '[ ! -e "$HOME/.local/bin/kit" ] && [ ! -e "$HOME/.local/share/agentkit" ] && ! grep -q agentkit:begin "$HOME/.claude/CLAUDE.md"'

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
check "codex toml args" 'grep -qF "args = [\"--index-url\", \"https://pypi.example/simple\", \"gerrit-mcp-server==1.0\"]" "$H4/.codex/config.toml"'
check "codex team deny -> disabled_tools" 'grep -qF "disabled_tools = [\"submit_change\"]" "$H4/.codex/config.toml"'
check "codex env table, not expanded" 'grep -q "^\[mcp_servers.gerrit.env\]" "$H4/.codex/config.toml" && grep -qF "GERRIT_CONFIG = \"\${HOME}/.config" "$H4/.codex/config.toml"'
check "codex toml stays private" '[ "$(ls -l "$H4/.codex/config.toml" | cut -c1-10)" = "-rw-------" ]'
if python3 -c "import tomllib" 2>/dev/null; then
  check "codex toml is valid TOML" 'python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"mcp_servers\"][\"gerrit\"][\"env\"][\"GERRIT_CONFIG\"]" "$H4/.codex/config.toml"'
fi
check "no backup for a file kit created" '[ ! -e "$H4/.agents/mcp.json.kit-backup" ] && [ ! -e "$H4/.omp/agent/mcp.json.kit-backup" ] || [ "$(cat "$H4/.omp/agent/mcp.json.kit-backup")" != "{}" ]'
check "omp mcp.json has kit server and own" '[ "$(jget "$H4/.omp/agent/mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && [ "$(jget "$H4/.omp/agent/mcp.json" mcpServers.own.command)" = "\"y\"" ]'
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
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

# ---------- collect / outdated (other people's skills; a local repo plays the author) ----------
UP="$T/upstream"; CO="$T/collector"
mkdir -p "$UP/skills/foo/scripts" "$CO"
printf -- '---\nname: foo\ndescription: >-\n  Upstream foo.\n---\nfoo v1\n' > "$UP/skills/foo/SKILL.md"
echo 'echo hi' > "$UP/skills/foo/scripts/run.sh"; mkdir -p "$UP/skills/foo/.github"; echo x > "$UP/skills/foo/.github/ci.yml"; printf '\0\1' > "$UP/skills/foo/logo.png"; ln -s SKILL.md "$UP/skills/foo/link.md"
printf 'MIT License\n\nPermission is hereby granted, free of charge, ...\n' > "$UP/LICENSE"
( cd "$UP" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm v1 )
mkdir -p "$T/nolic/skills/bar"; printf -- '---\nname: bar\ndescription: b\n---\nb\n' > "$T/nolic/skills/bar/SKILL.md"
( cd "$T/nolic" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm x )
printf 'name: collector\ncollect_sources: [file://%s, file://%s]\n' "$UP" "$T/nolic" > "$CO/kit.yaml"
cd "$CO"
out=$(kit collect "file://$UP" --path skills/foo 2>&1); rc=$?
check "collect copies the skill with the repo's LICENSE" '[ $rc -eq 0 ] && [ -f "$CO/skills/foo/SKILL.md" ] && grep -q "MIT License" "$CO/skills/foo/LICENSE" && [ -f "$CO/skills/foo/scripts/run.sh" ]'
check "collect skips binaries, links and dot folders" '[ ! -e "$CO/skills/foo/logo.png" ] && [ ! -e "$CO/skills/foo/link.md" ] && [ ! -e "$CO/skills/foo/.github" ]'
check "collect points at files that run" 'echo "$out" | grep -q "會執行的檔案" && echo "$out" | grep -q scripts/run.sh'
v1=$(git -C "$UP" rev-parse HEAD)
check "third_party.lock records author, commit, license" 'awk -F"\t" -v u="file://$UP" -v s="$v1" "\$1 == \"foo\" && \$2 == u && \$3 == \"skills/foo\" && \$5 == s && \$6 == \"MIT\"" "$CO/third_party.lock" | grep -q .'
out=$(kit collect "file://$T/elsewhere" 2>&1); rc=$?
check "collect refuses authors not in collect_sources" '[ $rc -ne 0 ] && echo "$out" | grep -q "不在 collect_sources"'
out=$(kit collect "file://$T/nolic" --path skills/bar 2>&1); rc=$?
check "collect refuses a repo without a license" '[ $rc -ne 0 ] && echo "$out" | grep -q "沒有 LICENSE" && [ ! -e "$CO/skills/bar" ]'
mkdir -p "$CO/skills/own"; printf -- '---\nname: own\ndescription: mine\n---\nmine\n' > "$CO/skills/own/SKILL.md"
out=$(kit collect "file://$UP" --path skills/foo --name own 2>&1); rc=$?
check "collect will not replace your own skill without --force" '[ $rc -ne 0 ] && grep -q mine "$CO/skills/own/SKILL.md"'
rm -rf "$CO/skills/own"
out=$(kit outdated 2>&1)
check "outdated: up to date" 'echo "$out" | grep -q "foo：最新"'
( cd "$UP" && echo "foo v2" >> skills/foo/SKILL.md && git commit -qam v2 )
out=$(kit outdated 2>&1)
check "outdated: new version upstream" 'echo "$out" | grep -q "foo：有新版本" && echo "$out" | grep -q "kit collect foo"'
echo "local edit" >> "$CO/skills/foo/SKILL.md"
out=$(kit collect foo 2>&1); rc=$?
check "collect <name> replaces the whole copy with the new version" '[ $rc -eq 0 ] && grep -q "foo v2" "$CO/skills/foo/SKILL.md" && ! grep -q "local edit" "$CO/skills/foo/SKILL.md" && grep -q "$(git -C "$UP" rev-parse HEAD)" "$CO/third_party.lock" && [ "$(grep -c "^foo" "$CO/third_party.lock")" = 1 ]'
( cd "$UP" && git tag -a v1.0 -m rel && echo "foo v3" >> skills/foo/SKILL.md && git commit -qam v3 )
out=$(kit collect foo --ref v1.0 2>&1); rc=$?
check "collect --ref takes a tag" '[ $rc -eq 0 ] && ! grep -q "foo v3" "$CO/skills/foo/SKILL.md"'
out=$(kit outdated 2>&1)
check "outdated follows the tag, not the branch" 'echo "$out" | grep -q "foo：最新"'
printf 'maintainers: [someone-else]\n' >> "$CO/kit.yaml"
out=$(kit collect foo 2>&1); rc=$?
check "only maintainers may collect" '[ $rc -ne 0 ] && echo "$out" | grep -q 維護者'
cd "$T"

# ---------- signed approvals (root uses only versions signed on the Mac) ----------
SA="$T/signed"; mkdir -p "$SA"
ssh-keygen -q -t ed25519 -N '' -C approver -f "$SA/key"
printf 'jay namespaces="agentkit" %s\n' "$(cat "$SA/key.pub")" > "$SA/allowed_signers"
ssh-keygen -q -t ed25519 -N '' -C mallory -f "$SA/badkey"
mkdir -p "$SA/work/srcA/rules"; echo "Approved rule v1." > "$SA/work/srcA/rules/ar.md"; printf 'name: srcA\nrequired:\n  rules: [ar]\n' > "$SA/work/srcA/kit.yaml"
( cd "$SA/work/srcA" && git init -q && git config user.name t && git config user.email t@t && git add -A && git commit -qm v1 && git clone -q --bare . "$SA/srcA.git" && git remote add origin "$SA/srcA.git" && git fetch -q origin )
mkdir -p "$SA/appr-work"; ( cd "$SA/appr-work" && git init -q && git config user.name t && git config user.email t@t && git commit -q --allow-empty -m start && git clone -q --bare . "$SA/approvals.git" && git remote add origin "$SA/approvals.git" )
out=$(kit approve "$SA/appr-work" "$SA/work/srcA" --key "$SA/key" --yes 2>&1); rc=$?
check "approve signs and commits" '[ $rc -eq 0 ] && [ -f "$SA/appr-work/approved.txt.sig" ] && grep -q "^serial: 1$" "$SA/appr-work/approved.txt" && grep -q "^srcA " "$SA/appr-work/approved.txt"'
git -C "$SA/appr-work" push -q origin HEAD:master 2>/dev/null || git -C "$SA/appr-work" push -q origin HEAD 2>/dev/null
RH="$T/roothome"; mkdir -p "$RH"
rk() { HOME="$RH" AGENTKIT_CONFIG="$RH/.config/agentkit" AGENTKIT_SOURCES="$RH/agentkit" "$KIT" "$@"; }
out=$(rk init "file://$SA/srcA.git" --approvals "file://$SA/approvals.git" --signers "$SA/allowed_signers" 2>&1); rc=$?
v1=$(git -C "$SA/work/srcA" rev-parse HEAD)
check "signed init uses the approved commit" '[ $rc -eq 0 ] && [ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$v1" ] && grep -q "ar.md" "$RH/.claude/CLAUDE.md"'
check "machine.yaml keeps approvals and signers" 'grep -q "^approvals: file://" "$RH/.config/agentkit/machine.yaml" && grep -q "^signers: " "$RH/.config/agentkit/machine.yaml"'
( cd "$SA/work/srcA" && echo "Unapproved v2." > rules/ar.md && git commit -qam v2 && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "unapproved new commit is not used" '[ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$v1" ] && grep -q "v1" "$RH/agentkit/srcA/rules/ar.md"'
rk add skill nothing >/dev/null 2>&1
check "add/rm keep the approvals setting" 'grep -q "^approvals: " "$RH/.config/agentkit/machine.yaml"'
out=$(kit approve "$SA/appr-work" "$SA/work/srcA" --key "$SA/key" --yes 2>&1)
check "approve shows what changed" 'echo "$out" | grep -q "v2" && echo "$out" | grep -q "rules/ar.md"'
cp "$SA/appr-work/approved.txt" "$SA/appr1.txt.v2"; git -C "$SA/appr-work" show HEAD~1:approved.txt > "$SA/old.txt"; git -C "$SA/appr-work" show HEAD~1:approved.txt.sig > "$SA/old.sig"
git -C "$SA/appr-work" push -q origin HEAD 2>/dev/null
out=$(rk sync 2>&1)
check "approved v2 is used after approve" '[ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$(git -C "$SA/work/srcA" rev-parse HEAD)" ] && echo "$out" | grep -q 換到核准的版本'
# someone with write access to the approvals repo but without the key
( cd "$SA/appr-work" && printf '# x\nserial: 9\nsrcA %s\n' "$v1" > approved.txt && git commit -qam forged && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "edited list without a new signature is refused" 'echo "$out" | grep -q 簽章不對 && grep -q "Unapproved v2" "$RH/agentkit/srcA/rules/ar.md"'
( cd "$SA/appr-work" && rm -f approved.txt.sig && ssh-keygen -Y sign -q -f "$SA/badkey" -n agentkit approved.txt && git add -A && git commit -qm forged2 && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "list signed by another key is refused" 'echo "$out" | grep -q 簽章不對 && grep -q "Unapproved v2" "$RH/agentkit/srcA/rules/ar.md"'
( cd "$SA/appr-work" && cp "$SA/old.txt" approved.txt && cp "$SA/old.sig" approved.txt.sig && git add -A && git commit -qm replay && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "an older signed list (serial 1) cannot roll back" 'echo "$out" | grep -q "比上次用的舊" && grep -q "Unapproved v2" "$RH/agentkit/srcA/rules/ar.md"'
echo "local edit" >> "$RH/agentkit/srcA/rules/ar.md"
( cd "$SA/appr-work" && git checkout -q HEAD~3 -- approved.txt approved.txt.sig && git commit -qm restore && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "local edits in the clone are reset to the approved commit" '! grep -q "local edit" "$RH/agentkit/srcA/rules/ar.md"'
out=$(HOME="$RH" AGENTKIT_CONFIG="$RH/.config/agentkit" AGENTKIT_SOURCES="$RH/agentkit2" "$KIT" init "file://$SA/srcA.git" --approvals "$SA/nowhere" --signers "$SA/allowed_signers" 2>&1); rc=$?
check "signed init without a valid list stops" '[ $rc -ne 0 ] && [ ! -e "$RH/agentkit2/srcA/rules" ]'

# ---------- herdr-panel: the kit panel as a Herdr mod ----------
HH="$T/herdr-app"; mkdir -p "$HH/mods" "$HH/layouts"
printf '{"id":"root","type":"row","children":[{"id":"bar","type":"row","children":[{"id":"tabs","type":"block","content":{"mod":"tabs"}}]},{"id":"body","type":"row","children":[{"id":"main","type":"block","content":{"tab":"active","pane":{"header":{"content":{"mod":"pane"},"reveal":"always"}}}}]}]}\n' > "$HH/layouts/mine.json"
cp "$HH/layouts/mine.json" "$T/mine.orig"
printf '{"main":1}\n' > "$HH/layouts/main.json"
printf '{\n  "layout": "mine"\n}\n' > "$HH/shared.json"
hp() { HERDR_APP_HOME="$HH" kit herdr-panel "$@"; }
out=$(hp install 2>&1); rc=$?
check "herdr-panel install: mod files, config with the kit command" '[ $rc -eq 0 ] && [ -f "$HH/mods/kit/main.js" ] && [ -f "$HH/mods/kit/.kit-panel" ] && grep -qF "\"kit\": [\"$(cd "$HERE/../unix" && pwd)/kit\"]" "$HH/mods/kit/config.json" && grep -qF "\"env\": {}" "$HH/mods/kit/config.json"'
check "herdr-panel install: button in the tab bar, panel beside the work area" '[ "$(jget "$HH/layouts/mine.json" children | grep -c "\"kit-toggle\"")" = 1 ] && grep -q "\"kit-panel\"" "$HH/layouts/mine.json" && grep -q "\"place\": \"none\"" "$HH/mods/kit/mod.json"'
check "herdr-panel install: an Agents button before Kit's, its panel hidden beside Kit's" 'tr -d " \n" < "$HH/layouts/mine.json" | grep -q "\"kit-agents-toggle\".*\"kit-toggle\"" && tr -d " \n" < "$HH/layouts/mine.json" | grep -q "\"kit-panel\".*\"kit-agents-panel\".*\"hidden\":true"'
check "herdr-panel install: the Agents window (mods/kit-agents)" '[ -f "$HH/mods/kit-agents/main.js" ] && [ -f "$HH/mods/kit-agents/.kit-panel" ] && grep -q "\"kind\": \"window\"" "$HH/mods/kit-agents/mod.json"'
check "herdr-panel install: each pane's header is kit's (mods/kit-pane)" 'grep -q "\"mod\": \"kit-pane\"" "$HH/layouts/mine.json" && ! grep -q "\"mod\": \"pane\"" "$HH/layouts/mine.json" && [ -f "$HH/mods/kit-pane/main.js" ] && [ -f "$HH/mods/kit-pane/.kit-panel" ] && grep -q "\"place\": \"none\"" "$HH/mods/kit-pane/mod.json"'
if command -v pwsh >/dev/null 2>&1; then
    mkdir -p "$T/hh2/mods" "$T/hh2/layouts"; cp "$T/mine.orig" "$T/hh2/layouts/mine.json"; cp "$HH/shared.json" "$T/hh2/"
    HERDR_APP_HOME="$T/hh2" pwsh -NoProfile -File "$HERE/../windows/kit.ps1" herdr-panel install >/dev/null 2>&1
    check "herdr-panel install: kit.ps1 edits the layout the same" 'cmp -s "$T/hh2/layouts/mine.json" "$HH/layouts/mine.json" && [ -f "$T/hh2/mods/kit-pane/.kit-panel" ]'
fi
check "herdr-panel install: layout backed up first" 'cmp -s "$(ls "$HH"/layouts/mine.json.kit-backup-* | head -n 1)" "$T/mine.orig"'
out=$(hp install --keep-env 2>&1); rc=$?
check "herdr-panel install again: layout not changed twice" '[ $rc -eq 0 ] && [ "$(grep -c "\"kit-toggle\"" "$HH/layouts/mine.json")" = 1 ] && [ "$(ls "$HH"/layouts/ | grep -c kit-backup)" = 1 ]'
sed 's/"px": 56/"px": 42/' "$HH/layouts/mine.json" > "$T/mine.moved" && cp "$T/mine.moved" "$HH/layouts/mine.json"
out=$(hp install --keep-env 2>&1); rc=$?
check "herdr-panel install again: a hand-arranged layout is kept" '[ $rc -eq 0 ] && grep -q "\"px\": 42" "$HH/layouts/mine.json" && cmp -s "$T/mine.moved" "$HH/layouts/mine.json"'
check "herdr-panel --keep-env: the panel runs kit with this HOME" 'grep -qF "\"HOME\": \"$HOME\"" "$HH/mods/kit/config.json"'
echo old > "$HH/mods/kit/main.js"; echo old > "$HH/mods/kit-pane/main.js"; cp "$HH/mods/kit/config.json" "$T/panel-cfg"
HERDR_APP_HOME="$HH" AGENTKIT_HOME="$T/inst-p" sh "$HERE/../unix/install.sh" --quiet >/dev/null 2>&1
check "reinstall / self-update refreshes an installed panel, keeps its settings" 'cmp -s "$HH/mods/kit/main.js" "$HERE/../herdr/kit-panel/main.js" && cmp -s "$HH/mods/kit/config.json" "$T/panel-cfg"'
check "reinstall / self-update refreshes the pane header too" 'cmp -s "$HH/mods/kit-pane/main.js" "$HERE/../herdr/kit-pane/main.js"'
out=$(hp uninstall 2>&1); rc=$?
check "herdr-panel uninstall: mod and layout blocks gone" '[ $rc -eq 0 ] && [ ! -e "$HH/mods/kit" ] && ! grep -q "kit" "$HH/layouts/mine.json" && grep -q "\"tabs\"" "$HH/layouts/mine.json"'
check "herdr-panel uninstall: Herdr's own pane header is back, Agents window gone" '[ ! -e "$HH/mods/kit-pane" ] && [ ! -e "$HH/mods/kit-agents" ] && grep -q "\"mod\": \"pane\"" "$HH/layouts/mine.json"'
printf '{\n  "layout": "main"\n}\n' > "$HH/shared.json"
out=$(hp install --keep-env 2>&1); rc=$?
check "herdr-panel on a Herdr layout: not edited, panel docks on the right" '[ $rc -eq 0 ] && [ "$(cat "$HH/layouts/main.json")" = "{\"main\":1}" ] && grep -q "\"place\": \"right\"" "$HH/mods/kit/mod.json" && echo "$out" | grep -q 放進上排'
hp uninstall >/dev/null 2>&1
mkdir -p "$HH/mods/kit"; echo mine > "$HH/mods/kit/main.js"
out=$(hp install 2>&1); rc=$?
check "herdr-panel: someone else's mods/kit is left alone" '[ $rc -ne 0 ] && echo "$out" | grep -q "不是 kit 放的" && [ "$(cat "$HH/mods/kit/main.js")" = mine ]'
HERDR_APP_HOME="$HH" AGENTKIT_HOME="$T/inst-p" sh "$HERE/../unix/install.sh" --quiet >/dev/null 2>&1
check "reinstall leaves someone else's mods/kit alone" '[ "$(cat "$HH/mods/kit/main.js")" = mine ]'
out=$(hp uninstall 2>&1); rc=$?
check "herdr-panel uninstall: someone else's mods/kit is left alone" '[ $rc -ne 0 ] && [ -f "$HH/mods/kit/main.js" ]'
rm -rf "$HH/mods/kit"; mkdir -p "$HH/mods/kit-agents"; echo theirs > "$HH/mods/kit-agents/main.js"
printf '{\n  "layout": "mine"\n}\n' > "$HH/shared.json"; cp "$HH/layouts/mine.json" "$T/mine.before"
out=$(hp install 2>&1); rc=$?
check "herdr-panel: someone else's mods/kit-agents stops it before anything is written" '[ $rc -ne 0 ] && echo "$out" | grep -q "kit-agents 已經有東西" && [ ! -e "$HH/mods/kit" ] && [ ! -e "$HH/mods/kit-pane" ] && cmp -s "$HH/layouts/mine.json" "$T/mine.before" && ! ls "$HH/layouts" | grep -q "\.kit\." && [ "$(cat "$HH/mods/kit-agents/main.js")" = theirs ]'
rm -rf "$HH/mods/kit-agents"
printf '{"id":"root","children":[{"id":"main","content":{"tab":"active","pane":{"header":{"content":{"mod":"kit-pane"}}}}}]}\n' > "$HH/layouts/compact.json"
printf '{"id":"root","children":[{"id":"tabs","content":{"mod":"tabs"}}]}\n' > "$HH/layouts/plain.json"; cp "$HH/layouts/plain.json" "$T/plain.orig"
out=$(hp uninstall 2>&1); rc=$?
check "herdr-panel uninstall: kit's parts go however the layout is written" '[ $rc -eq 0 ] && ! grep -q kit-pane "$HH/layouts/compact.json" && grep -q "\"mod\": \"pane\"" "$HH/layouts/compact.json"'
check "herdr-panel uninstall: a layout without kit's parts is not touched" 'cmp -s "$HH/layouts/plain.json" "$T/plain.orig" && ! ls "$HH/layouts" | grep -q "plain.json.kit-backup"'
if command -v pwsh >/dev/null 2>&1; then
    printf '{"id":"root","children":[{"id":"main","content":{"tab":"active","pane":{"header":{"content":{"mod":"kit-pane"}}}}}]}\n' > "$HH/layouts/compact.json"
    cp "$HH/layouts/compact.json" "$T/compact.orig"; hp uninstall >/dev/null 2>&1; cp "$HH/layouts/compact.json" "$T/compact.bash"; cp "$T/compact.orig" "$HH/layouts/compact.json"
    HERDR_APP_HOME="$HH" pwsh -NoProfile -File "$HERE/../windows/kit.ps1" herdr-panel uninstall >/dev/null 2>&1
    check "herdr-panel uninstall: kit.ps1 the same (and a plain layout untouched)" 'cmp -s "$HH/layouts/compact.json" "$T/compact.bash" && cmp -s "$HH/layouts/plain.json" "$T/plain.orig" && ! ls "$HH/layouts" | grep -q "plain.json.kit-backup"'
fi
out=$(HERDR_APP_HOME="$T/no-herdr" kit herdr-panel install 2>&1); rc=$?
check "herdr-panel without Herdr: says so" '[ $rc -ne 0 ] && echo "$out" | grep -q "找不到 Herdr"'

# ---------- help ----------
out=$(kit help 2>&1)
check "help: --json --dir is under kit list" 'echo "$out" | grep -A1 "^  kit list" | grep -q -- "--json --dir" && ! echo "$out" | grep -A1 "^  kit agent " | grep -q -- "--json --dir"'

# ---------- sync: why a source could not be updated ----------
SY="$T/syncwhy"; git -c init.defaultBranch=main init -q "$SY/w"
printf 'name: s\n' > "$SY/w/kit.yaml"; mkdir -p "$SY/w/rules"; echo v1 > "$SY/w/rules/a.md"
git -C "$SY/w" add -A; git -C "$SY/w" -c user.name=t -c user.email=t@t commit -qm v1; git clone -q --bare "$SY/w" "$SY/s.git"
sk() { HOME="$SY/home" AGENTKIT_CONFIG="$SY/home/.config/agentkit" AGENTKIT_SOURCES="$SY/home/agentkit" "$KIT" "$@"; }
sk init "file://$SY/s.git" >/dev/null 2>&1; C="$SY/home/agentkit/s"
echo v2 > "$SY/w/rules/a.md"; git -C "$SY/w" -c user.name=t -c user.email=t@t commit -qam v2; git -C "$SY/w" push -q "$SY/s.git" HEAD:main 2>/dev/null
echo mine > "$C/rules/a.md"
out=$(sk sync 2>&1)
check "sync: a source with your own changes in the way says so" 'echo "$out" | grep -q "沒辦法更新 s（.*自己改過"'
git -C "$C" checkout -q -- rules/a.md; git -C "$C" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
out=$(sk sync 2>&1)
check "sync: a source with its own commits says it went its own way" 'echo "$out" | grep -q "沒辦法更新 s（.*分岔"'
git -C "$C" remote set-url origin "file://$SY/gone.git"
out=$(sk sync 2>&1)
check "sync: no network is told apart" 'echo "$out" | grep -qF "沒辦法更新 s（沒網路？）"'

# ---------- review fixes: the user's own MCP, state only after writing, CRLF / links / markers, URLs, push ----------
RF="$T/rf"; RS="$RF/src dir"; mkdir -p "$RF/home" "$RS/rules" "$RS/mcp"
rf() { HOME="$RF/home" AGENTKIT_CONFIG="$RF/home/.config/agentkit" AGENTKIT_SOURCES="$RF/home/agentkit" "$KIT" "$@"; }
printf 'name: rfsrc\nrequired:\n  rules: [r1]\n' > "$RS/kit.yaml"; echo "Rule one." > "$RS/rules/r1.md"
printf 'command: theirs\n' > "$RS/mcp/m1.yaml"; printf 'command: kits\n' > "$RS/mcp/m2.yaml"
printf '{\n  "mcpServers": {\n    "m1": {\n      "command": "mine"\n    }\n  }\n}\n' > "$RF/home/.claude.json"; cp "$RF/home/.claude.json" "$RF/cj.orig"
printf 'My line one\r\nMy line two\r\n' > "$RF/crlf.md"; mkdir -p "$RF/home/.claude"; cp "$RF/crlf.md" "$RF/home/.claude/CLAUDE.md"
rf init "$RS" >/dev/null 2>&1
check "@import: a folder with a space is escaped (Claude's @path stops at a space)" 'tr -d "\r" < "$RF/home/.claude/CLAUDE.md" | grep -qxF "@$(printf "%s" "$RS" | sed "s/ /\\\\ /g")/rules/r1.md"'
check "CLAUDE.md with CRLF: kit's lines get CRLF too, the user's kept" '[ "$(head -c 24 "$RF/home/.claude/CLAUDE.md")" = "$(printf "My line one\r\nMy line two")" ] && [ "$(grep -c "agentkit:begin.*$(printf "\r")\$" "$RF/home/.claude/CLAUDE.md")" = 1 ]'
rf sync >/dev/null 2>&1
check "CLAUDE.md with CRLF: one kit block after another sync" '[ "$(grep -c "agentkit:begin" "$RF/home/.claude/CLAUDE.md")" = 1 ]'
out=$(rf add mcp m1 2>&1); rc=$?
check "the user's own MCP with the same name is not replaced (warned)" '[ $rc -eq 0 ] && [ "$(jget "$RF/home/.claude.json" mcpServers.m1.command)" = "\"mine\"" ] && echo "$out" | grep -q "已經有自己的 MCP m1"'
rf add mcp m2 >/dev/null 2>&1; rf rm mcp m2 >/dev/null 2>&1
check "the backup is the file before kit first changed it" 'cmp -s "$RF/home/.claude.json.kit-backup" "$RF/cj.orig"'
cp "$RF/home/.claude.json" "$RF/cj.good"; printf '{"mcpServers": {' > "$RF/home/.claude.json"
out=$(rf add mcp m2 2>&1); rc=$?
check "a file kit cannot write stops kit, and state.tsv does not say it was done" '[ $rc -ne 0 ] && ! grep -q "^mcp	m2	" "$RF/home/.config/agentkit/state.tsv"'
printf '\357\273\277' > "$RF/home/.claude.json"; tr -d '\r' < "$RF/cj.good" | sed 's/$/\r/' >> "$RF/home/.claude.json"
out=$(rf sync 2>&1); rc=$?
check "the next sync adds it; a BOM and CRLF in .claude.json are kept" '[ $rc -eq 0 ] && [ "$(LC_ALL=C tr -d "\r" < "$RF/home/.claude.json" | tail -c +4 | LC_ALL=C awk -f "$JA" -v get=mcpServers.m2.command)" = "\"kits\"" ] && [ "$(od -An -tx1 -N3 "$RF/home/.claude.json" | tr -d " ")" = efbbbf ] && grep -q "$(printf "\r")\$" "$RF/home/.claude.json"'
rf uninstall >/dev/null 2>&1
check "uninstall leaves the user's own MCP" '[ "$(LC_ALL=C tr -d "\r" < "$RF/home/.claude.json" | tail -c +4 | LC_ALL=C awk -f "$JA" -v get=mcpServers.m1.command)" = "\"mine\"" ]'
check "uninstall gives the CRLF CLAUDE.md back byte for byte" 'cmp -s "$RF/home/.claude/CLAUDE.md" "$RF/crlf.md"'
mv "$RF/home/.claude/CLAUDE.md" "$RF/dot-claude.md"; ln -s "$RF/dot-claude.md" "$RF/home/.claude/CLAUDE.md"
rf init "$RS" >/dev/null 2>&1
check "a linked CLAUDE.md stays a link; the file it points to gets the block" '[ -L "$RF/home/.claude/CLAUDE.md" ] && grep -q "agentkit:begin" "$RF/dot-claude.md"'
rf uninstall >/dev/null 2>&1
printf 'Mine\n<!-- agentkit:begin (managed by kit, do not edit) -->\nkeep me\n' > "$RF/half.md"; rm -f "$RF/home/.claude/CLAUDE.md"; cp "$RF/half.md" "$RF/home/.claude/CLAUDE.md"
out=$(rf init "$RS" 2>&1)
check "a begin marker without an end: the file is not touched, kit says so" 'cmp -s "$RF/home/.claude/CLAUDE.md" "$RF/half.md" && echo "$out" | grep -q "找不到結束標記"'
out=$(rf uninstall 2>&1); rc=$?
check "uninstall with such a file: stops, state kept for another try" '[ $rc -ne 0 ] && [ -f "$RF/home/.config/agentkit/state.tsv" ]'
cp "$RF/crlf.md" "$RF/home/.claude/CLAUDE.md"; rf uninstall >/dev/null 2>&1
mkdir -p "$RF/home/.config/agentkit/sync.lock"
out=$(KIT_LOCK_WAIT=1 rf add mcp m2 2>&1); rc=$?
check "another kit running (the lock): waits, then stops" '[ $rc -ne 0 ] && echo "$out" | grep -q "另一個 kit 正在跑"'
rmdir "$RF/home/.config/agentkit/sync.lock"
out=$(rf init "https://me:s3cr3t-tok@gitea.example/acme/team.git" 2>&1); rc=$?
check "init: a URL with a password or token is refused, the token never printed" '[ $rc -ne 0 ] && echo "$out" | grep -q "https://gitea.example/acme/team.git" && ! echo "$out" | grep -q s3cr3t'
# kit check: URLs in MCP args only to listed hosts
printf 'command: uvx\nargs: [--index-url, "https://PyPI.corp.example/simple", srv]\n' > "$RS/mcp/m3.yaml"
out=$(rf check "$RS" 2>&1); rc=$?
check "check: an MCP package index not in allowed_hosts / content_hosts is a problem" '[ $rc -ne 0 ] && echo "$out" | grep -q "pypi.corp.example 不在 allowed_hosts"'
printf 'name: rfsrc\ncontent_hosts: [pypi.corp.example]\n' > "$RS/kit.yaml"
out=$(rf check "$RS" 2>&1); rc=$?
check "check: a listed package index is fine" '[ $rc -eq 0 ]'
# push (pr): origin's default branch from origin itself; no token to a host the source does not list; names with spaces
# origin is read over plain http from a local folder (so it is a URL, host 127.0.0.1) and pushed to that folder directly
PR="$RF/pr"; PO="$PR/srv/acme/team.git"; mkdir -p "$PR/srv/acme"
git -c init.defaultBranch=master init -q --bare "$PO"; git -c init.defaultBranch=master init -q "$PR/w"
printf 'name: prsrc\nauthor_domains: [corp.example]\n' > "$PR/w/kit.yaml"; mkdir -p "$PR/w/rules"; echo base > "$PR/w/rules/b.md"
git -C "$PR/w" config user.name t; git -C "$PR/w" config user.email me@CORP.example
git -C "$PR/w" add -A; git -C "$PR/w" commit -qm init; git -C "$PR/w" push -q "$PO" master 2>/dev/null; git --git-dir="$PO" update-server-info
cat > "$PR/serve" <<'PYEOF'
import functools, http.server, sys
s = http.server.HTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]))
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
PYEOF
python3 -I "$PR/serve" "$PR/srv" "$PR/port" >/dev/null 2>&1 & HTTPD=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$PR/port" ] && break; sleep 1; done
git -C "$PR/w" remote add origin "http://127.0.0.1:$(cat "$PR/port")/acme/team.git"; git -C "$PR/w" config remote.origin.pushurl "$PO"
mkdir -p "$PR/w/skills/sp"; printf -- '---\nname: sp\ndescription: s\n---\nx\n' > "$PR/w/skills/sp/SKILL.md"; echo y > "$PR/w/skills/sp/my file.md"
out=$(cd "$PR/w" && GIT_AUTHOR_EMAIL=x@home.example rf push --dry-run 2>&1); rc=$?
check "push: the author email git really uses (GIT_AUTHOR_EMAIL) is checked" '[ $rc -ne 0 ] && echo "$out" | grep -q "x@home.example 不是公司網域"'
out=$(cd "$PR/w" && KIT_GITEA_TOKEN=tok-777 rf push 2>&1); rc=$?
check "push: the PR goes to origin's default branch (master), asked from origin" '[ $rc -eq 0 ] && echo "$out" | grep -q "PR 到 master"'
check "push: a file name with a space is sent" 'git --git-dir="$PO" ls-tree -r --name-only "kit/sp-$DAY" | grep -qxF "skills/sp/my file.md"'
check "push: no token to a host this source does not list in allowed_hosts" 'echo "$out" | grep -q "不把 Gitea token 送過去" && echo "$out" | grep -qF "開 PR：https://127.0.0.1/acme/team/compare/master...kit/sp-$DAY" && ! echo "$out" | grep -q tok-777'
check "push: the kit branch does not track origin" '[ -z "$(git -C "$PR/w" config "branch.kit/sp-$DAY.remote")" ]'
kill $HTTPD 2>/dev/null
# herdr-panel: decided on node ids; a renamed column that held only kit's block goes on uninstall
RH="$RF/herdr"; mkdir -p "$RH/layouts" "$RH/mods"; printf '{\n  "layout": "x"\n}\n' > "$RH/shared.json"
printf '{"id":"root","type":"row","title":"kit-toggle","note":"kit-panel","children":[{"id":"bar","type":"row","children":[{"id":"tabs","type":"block","content":{"mod":"tabs"}}]},{"id":"body","type":"row","children":[{"id":"main","type":"block","content":{"tab":"active"}}]}]}\n' > "$RH/layouts/x.json"
HERDR_APP_HOME="$RH" rf herdr-panel install >/dev/null 2>&1
check "herdr-panel: the words in a title are not kit's nodes (they get added)" 'grep -q "\"id\": \"kit-toggle\"" "$RH/layouts/x.json" && grep -q "\"id\": \"kit-panel\"" "$RH/layouts/x.json"'
sed 's/"id": "kit-panel"/"id": "my-col"/' "$RH/layouts/x.json" > "$RH/x.tmp" && mv "$RH/x.tmp" "$RH/layouts/x.json"
HERDR_APP_HOME="$RH" rf herdr-panel uninstall >/dev/null 2>&1
check "herdr-panel uninstall: a renamed column with only kit's block is gone too" '! grep -q "my-col" "$RH/layouts/x.json" && ! grep -q "\"mod\": \"kit" "$RH/layouts/x.json"'
if [ "$(uname)" = Darwin ]; then
    IH="$RF/ih"; mkdir -p "$IH"; echo "# mine" > "$IH/.profile"
    HOME="$IH" SHELL=/bin/bash PATH=/usr/bin:/bin AGENTKIT_HOME="$IH/share" sh "$HERE/../unix/install.sh" --quiet >/dev/null 2>&1
    check "install.sh (Mac, bash): no new .bash_profile hiding .profile; .profile gets the PATH line" '[ ! -e "$IH/.bash_profile" ] && grep -q "added by agentkit" "$IH/.profile"'
fi

# ---------- code checks ----------
check "no \$var directly before non-ASCII (bash 3.2 reads it as part of the name)" '! LC_ALL=C grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" "$KIT" "$HERE/../unix/install.sh"'

echo "kit: $pass passed, $fail failed"
[ $fail -eq 0 ]
