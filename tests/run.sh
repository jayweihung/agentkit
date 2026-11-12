#!/usr/bin/env bash
# End-to-end tests for the bash kit. Everything runs in a throwaway HOME,
# so your real ~/.claude is never touched.
set -u
# Started with Ctrl-C ignored (a background job of a script, `bash tests/run.sh &`, some runners): bash cannot undo
# that for itself or anything it starts, so the Ctrl-C tests below would fail without testing kit. Start again with
# Ctrl-C back to normal.
if [ -z "${KIT_TEST_SIGINT:-}" ] && [ "$(python3 -Ic 'import signal; print(signal.getsignal(signal.SIGINT) == signal.SIG_IGN)' 2>/dev/null)" = True ]; then
    export KIT_TEST_SIGINT=1
    exec python3 -Ic 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' bash "$0" "$@"
fi
HERE=$(cd "$(dirname "$0")" && pwd)
KIT="$HERE/../unix/kit"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR AGENTKIT_CONFIG AGENTKIT_SOURCES
export KIT_TRANSCRIPT_CHECK=0   # (kit sync --hook does not look at the Claude these tests may run in)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
kit() { "$KIT" "$@"; }
JA="$HERE/../unix/json.awk"
jget() { LC_ALL=C awk -f "$JA" -v get="$2" "$1" 2>/dev/null; }
# kit.ps1 next to unix/kit (found now: some parts below run with a PATH of fakes only)
PWSH=$(command -v pwsh 2>/dev/null || true)
kps() { "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" "$@"; }
# capped SECS CMD... : CMD, stopped after SECS seconds (then 124)
capped() { local s=$1 p w rc; shift; "$@" & p=$!; { sleep "$s"; kill "$p"; } >/dev/null 2>&1 & w=$!; wait "$p"; rc=$?; { kill "$w"; wait "$w"; } 2>/dev/null; [ $rc -lt 128 ] || rc=124; return $rc; }

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

# ---------- list --json (for programs) ----------
mkdir -p "$TEAM/skills/quote"; printf -- '---\nname: quote\ndescription: 中文 "引號" \\ 和\ttab\n---\nx\n' > "$TEAM/skills/quote/SKILL.md"
kit list --json > "$T/list.json" 2>&1; rc=$?
check "list --json: exit 0, valid JSON" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/list.json" > /dev/null'
check "list --json: version and source" '[ "$(jget "$T/list.json" kit)" = "\"$(cat "$HERE/../VERSION")\"" ] && grep -qF "{\"name\": \"team\", \"source\": \"$TEAM\", \"dir\": \"$TEAM\", \"push\": \"pr\", \"changed\": []}" "$T/list.json"'
check "list --json: required, used, unused" 'grep -qF "{\"kind\": \"rule\", \"name\": \"security\", \"status\": \"required\", \"new\": false, \"changed\": false, \"source\": \"team\", \"description\": \"\", \"path\": " "$T/list.json" &&
    grep -qF "{\"kind\": \"skill\", \"name\": \"gerrit-review\", \"status\": \"used\", \"new\": false, \"changed\": false, \"source\": \"team\", \"description\": \"review a change\", \"path\": " "$T/list.json" &&
    grep -qF "{\"kind\": \"skill\", \"name\": \"gerrit-workflow\", \"status\": \"unused\", \"new\": false, \"changed\": false, \"source\": \"third-party\", \"description\": \"upstream\", \"path\": " "$T/list.json"'
check "list --json: agent with its description" 'grep -qF "{\"kind\": \"agent\", \"name\": \"gerrit\", \"status\": \"agent\", \"new\": false, \"changed\": false, \"source\": \"team\", \"description\": \"Gerrit helper\", \"path\": " "$T/list.json"'
check "list --json: new item, text escaped (UTF-8 kept)" 'grep -qF "{\"kind\": \"skill\", \"name\": \"quote\", \"status\": \"unused\", \"new\": true, \"changed\": false, \"source\": \"team\", \"description\": \"中文 \\\"引號\\\" \\\\ 和\\ttab\", \"path\": " "$T/list.json"'
printf -- '---\r\nname: crlf\r\ndescription: Written on Windows\r\n---\r\nx\r\n' > "$TEAM/agents/crlf.md"   # CRLF line ends
check "list --json: an agent written with CRLF has its description too" 'kit list --json 2>/dev/null | grep -q "\"name\": \"crlf\",.*\"description\": \"Written on Windows\"" && { [ -z "$PWSH" ] || kps list --json 2>/dev/null | grep -q "\"name\": \"crlf\",.*\"description\": \"Written on Windows\""; }'
rm -f "$TEAM/agents/crlf.md"
check "list --json: tools and no version wanted" 'grep -q "^  \"tools\": \[\"claude\"" "$T/list.json" && [ "$(jget "$T/list.json" kit_version_wanted)" = "\"\"" ]'
check "list --json does not mark items seen" '[ "$(kit list --json | grep -c "\"new\": true")" = 1 ]'
if [ -n "$PWSH" ]; then
    check "list --json: kit.ps1 prints the same" 'kps list --json 2>&1 | cmp -s - "$T/list.json"'
fi
out=$(kit list --bad 2>&1); rc=$?
check "list with a wrong option: usage" '[ $rc -ne 0 ] && echo "$out" | grep -qF "kit list [--json"'
# changed: what kit push would send, per source (files) and per item (a skill: any file in its folder)
git -C "$TEAM" init -q; git -C "$TEAM" add -A; git -C "$TEAM" -c user.name=t -c user.email=t@t commit -qm init
echo more >> "$TEAM/skills/quote/SKILL.md"; echo x > "$TEAM/skills/gerrit-review/notes.md"; echo y >> "$TEAM/rules/security.md"; echo z > "$TEAM/README.md"
kit list --json > "$T/list-chg.json" 2>/dev/null
check "list --json: changed files of a source (only what kit push sends)" 'grep -qF "\"push\": \"pr\", \"changed\": [\"rules/security.md\", \"skills/quote/SKILL.md\", \"skills/gerrit-review/notes.md\"]}" "$T/list-chg.json"'
check "list --json: changed items (a skill by any file in its folder), the rest not" 'grep -qF "\"name\": \"security\", \"status\": \"required\", \"new\": false, \"changed\": true," "$T/list-chg.json" &&
    grep -qF "\"name\": \"quote\", \"status\": \"unused\", \"new\": true, \"changed\": true," "$T/list-chg.json" &&
    grep -qF "\"name\": \"gerrit-review\", \"status\": \"used\", \"new\": false, \"changed\": true," "$T/list-chg.json" &&
    grep -qF "\"name\": \"gerrit\", \"status\": \"agent\", \"new\": false, \"changed\": false," "$T/list-chg.json"'
if [ -n "$PWSH" ]; then
    check "list --json changed: kit.ps1 prints the same" 'kps list --json 2>/dev/null | cmp -s - "$T/list-chg.json"'
fi
git -C "$TEAM" checkout -q -- .; rm -f "$TEAM/skills/gerrit-review/notes.md" "$TEAM/README.md"; rm -rf "$TEAM/.git"
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
check "list --json --dir: valid JSON, the folder, no other user" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/here.json" > /dev/null && grep -qF "\"here\": {\"dir\": \"$PP\", \"user\": null, \"agent\": null, \"folder\": {\"dir\": \"$PP\", \"why\": \"\", \"items\": []}, \"items\": [" "$T/here.json"'
check "list --json --dir: rules here and above, AGENTS.md for codex/omp" 'grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \"CLAUDE.md\", \"path\": \"$PP/CLAUDE.md\", \"tools\": \"claude\", \"description\": \"\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \".claude/rules/r1.md\", \"path\": \"$PP/.claude/rules/r1.md\", \"tools\": \"claude\", \"description\": \"Rule one\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \"$PU/CLAUDE.md\", \"path\": \"$PU/CLAUDE.md\", \"tools\": \"claude\", \"description\": \"Project rules\"}" "$T/here.json" &&
    grep -qF "\"name\": \"$PU/AGENTS.md\", \"path\": \"$PU/AGENTS.md\", \"tools\": \"codex omp\"" "$T/here.json"'
check "list --json --dir: project skill, .mcp.json and local MCP" 'grep -qF "{\"scope\": \"dir\", \"kind\": \"skill\", \"name\": \"pskill\", \"path\": \"$PP/.claude/skills/pskill/SKILL.md\", \"tools\": \"claude\", \"description\": \"project skill\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"mcp\", \"name\": \"pm\", \"path\": \"$PP/.mcp.json\"" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"mcp\", \"name\": \"lm\", \"path\": \"$HOME/.claude.json\"" "$T/here.json"'
check "list --json --dir: this account's own skill and MCP, not kit's" 'grep -qF "{\"scope\": \"user\", \"kind\": \"skill\", \"name\": \"mine\"" "$T/here.json" && grep -qF "{\"scope\": \"user\", \"kind\": \"mcp\", \"name\": \"um\"" "$T/here.json" &&
    ! grep -q "\"scope\": \"user\", \"kind\": \"skill\", \"name\": \"gerrit-review\"" "$T/here.json" && ! grep -q "\"scope\": \"user\", \"kind\": \"mcp\", \"name\": \"gerrit\"" "$T/here.json"'
if [ -n "$PWSH" ]; then
    check "list --json --dir: kit.ps1 prints the same" 'kps list --json --dir "$T/proj/sub" --pid $$ > /tmp/here-ps.json 2>&1; cmp -s /tmp/here-ps.json "$T/here.json"'
fi
out=$(kit list --json --dir "$T/nope" 2>&1)
check "list --json --dir: a folder that is not there" 'echo "$out" | grep -qF "\"here\": {\"dir\": \"$T/nope\", \"user\": null, \"agent\": null, \"error\": \"找不到這個資料夾\", \"items\": []}"'
out=$(kit list --json --pid x 2>&1); rc=$?
check "list --json --pid: numbers only" '[ $rc -ne 0 ] && echo "$out" | grep -q "數字"'
RUND="$HOME/.config/agentkit/run"; mkdir -p "$RUND"; echo gerrit > "$RUND/$$"
( : ) & dp=$!; wait $dp; echo gone > "$RUND/$dp"
kit list --json --dir "$T/proj/sub" --pid $$ > "$T/here2.json" 2>&1
check "list --json --pid: the agent kit run started there" 'grep -qF "\"user\": null, \"agent\": {\"name\": \"gerrit\", \"source\": \"team\", \"rules\": [\"gerrit-flow\"], \"skills\": [\"gerrit-review\"], \"mcp\": [\"gerrit\"]}, \"folder\": {\"dir\": \"$PP\", \"why\": \"\", \"items\": []}, \"items\": [" "$T/here2.json"'
check "list --json --pid: the marker of a kit run that ended is dropped" '[ ! -e "$RUND/$dp" ] && [ -e "$RUND/$$" ]'
if [ -n "$PWSH" ]; then
    echo gone > "$RUND/$dp"
    check "list --json --pid: kit.ps1 finds the same agent" 'kps list --json --dir "$T/proj/sub" --pid $$ 2>&1 | cmp -s - "$T/here2.json" && [ ! -e "$RUND/$dp" ]'
fi
rm -f "$RUND/$$"
mkdir -p "$T/fakebin"; printf '#!/bin/sh\n"$FAKE_KIT" list --json --dir "$PWD" --pid $PPID > "$FAKE_OUT" 2>&1\n' > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
FAKE_KIT=$KIT FAKE_OUT="$T/fake.json" PATH="$T/fakebin:$PATH" kit run gerrit >/dev/null 2>&1; rc=$?
check "kit run: the agent in the pane is known while it runs, the marker goes after" '[ $rc -eq 0 ] && grep -qF "\"agent\": {\"name\": \"gerrit\", \"source\": \"team\"," "$T/fake.json" && [ -z "$(ls "$RUND")" ]'
cp "$T/cj.bak" "$HOME/.claude.json"; rm -rf "$T/proj" "$HOME/.claude/skills/mine"

# ---------- agents --json / agent add|rm (for programs that show agents) ----------
cp "$TEAM/agents/gerrit.md" "$T/gerrit.bak"
kit agents --json > "$T/agents.json" 2>&1; rc=$?
check "agents --json: valid JSON, what is available" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/agents.json" > /dev/null && grep -qF "\"rule\": [\"coding-style\", \"gerrit-flow\", \"security\"]" "$T/agents.json" && grep -q "\"skill\": \[.*\"gerrit-workflow\"\]" "$T/agents.json"'
check "agents --json: an agent with its rules, skills, MCP, tools, prompt" 'grep -qF "{\"name\": \"gerrit\", \"description\": \"Gerrit helper\", \"source\": \"team\", \"path\": \"$TEAM/agents/gerrit.md\", \"git\": \"no-git\"," "$T/agents.json" &&
    grep -qF "\"rules\": [\"gerrit-flow\"], \"skills\": [\"gerrit-review\"], \"mcp\": [\"gerrit\"], \"tools_only\": [\"Read\", \"Grep\", \"Glob\"], \"tools_deny\": [\"mcp__gerrit__submit_change\"]," "$T/agents.json" &&
    grep -qF "\"prompt\": \"You are the Gerrit helper.\"}" "$T/agents.json"'
if [ -n "$PWSH" ]; then
    check "agents --json: kit.ps1 prints the same" 'kps agents --json 2>&1 | cmp -s - "$T/agents.json"'
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
if [ -n "$PWSH" ]; then
    cp "$TEAM/agents/gerrit.md" "$T/g1"; kit agent gerrit add skill gerrit-workflow >/dev/null 2>&1; cp "$TEAM/agents/gerrit.md" "$T/g2"; cp "$T/g1" "$TEAM/agents/gerrit.md"
    kps agent gerrit add skill gerrit-workflow >/dev/null 2>&1
    check "agent add: kit.ps1 writes the same file" 'cmp -s "$TEAM/agents/gerrit.md" "$T/g2"'
fi
# a block list with blank and comment lines in it
printf -- '---\nname: gerrit\ndescription: Gerrit helper\nskills:\n  - gerrit-review\n\n  # the team one\n  - team-build\n\n# next\nrules: [gerrit-flow]\n---\nbody\n' > "$T/blk.md"
printf -- '---\nname: gerrit\ndescription: Gerrit helper\nskills: [gerrit-review]\n\n# next\nrules: [gerrit-flow]\n---\nbody\n' > "$T/blk.want"
cp "$T/blk.md" "$TEAM/agents/gerrit.md"; out=$(kit agent gerrit rm skill team-build 2>&1); rc=$?
check "agent rm: a block list with blank and comment lines in it is replaced whole" '[ $rc -eq 0 ] && cmp -s "$TEAM/agents/gerrit.md" "$T/blk.want"'
if [ -n "$PWSH" ]; then
    cp "$T/blk.md" "$TEAM/agents/gerrit.md"; kps agent gerrit rm skill team-build >/dev/null 2>&1
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
if [ -n "$PWSH" ]; then
    cp "$T/crlf.md" "$TEAM/agents/gerrit.md"
    kps agent gerrit add skill gerrit-workflow >/dev/null 2>&1; kps agent gerrit add mcp gerrit >/dev/null 2>&1
    check "agent add: kit.ps1 keeps CRLF the same" 'cmp -s "$TEAM/agents/gerrit.md" "$T/crlf.bash"'
fi
# a header kit cannot read: stop, change nothing
printf -- '---\nname: gerrit\ndescription: Gerrit helper\njust words\nskills: [gerrit-review]\n---\nbody\n' > "$T/bad.md"; cp "$T/bad.md" "$TEAM/agents/gerrit.md"
out=$(kit agent gerrit add skill gerrit-workflow 2>&1); rc=$?
check "agent add: a header kit cannot read stops it, the file is not changed" '[ $rc -ne 0 ] && echo "$out" | grep -q 讀不懂 && cmp -s "$TEAM/agents/gerrit.md" "$T/bad.md"'
if [ -n "$PWSH" ]; then
    out=$(kps agent gerrit add skill gerrit-workflow 2>&1); rc=$?
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
check "old kit: sync tells the user" 'echo "$out" | grep -qF "團隊要 kit 0.4.0 以上，你的是 $(cat "$HERE/../VERSION")。請打  kit self-update"'
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

# ---------- is Claude saving its transcript? (kit sync --hook under a fake claude started with a chosen environment) ----------
FC="$T/fake-claude"; mkdir -p "$FC" "$T/tch/.claude"
if [ "$(uname)" = Darwin ]; then   # ps -E shows no environment of Apple's own programs (bash, sh): a tiny one of our own
    printf '#include <stdlib.h>\nint main(int c, char **v) { return system(v[1]) == 0 ? 0 : 1; }\n' > "$FC/c.c"
    xcode-select -p >/dev/null 2>&1 && cc -o "$FC/claude" "$FC/c.c" 2>/dev/null
    fcl() { "$FC/claude" "$1"; }
else ln -s "$(command -v bash)" "$FC/claude"; fcl() { "$FC/claude" -c "$1; :"; }; fi   # (`; :`: it stays the parent)
tc() { ( unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE KIT_TRANSCRIPT_CHECK; export HOME="$T/tch" "$@"
         fcl "${HE:-} '$KIT' sync --hook" ); }   # HE: the hook's own environment
if [ -x "$FC/claude" ]; then
    out=$(tc); check "transcript: a normal claude: nothing said" '[ -z "$out" ]'
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1); rc=$?; printf '%s\n' "$out" > "$T/tc.json"
    check "transcript: claude started with CHILD_SESSION=1: warned, as JSON for Claude" '[ $rc -eq 0 ] && [ "$(jget "$T/tc.json" hookSpecificOutput.hookEventName)" = "\"SessionStart\"" ] && jget "$T/tc.json" systemMessage | grep -q /resume'
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1)
    check "transcript: ... and FORCE_SESSION_PERSISTENCE=1 too: nothing said" '[ -z "$out" ]'
    out=$(HE=CLAUDE_CODE_CHILD_SESSION=1 tc)
    check "transcript: the hook's own CHILD_SESSION=1 (Claude gives it to every hook) is not looked at" '[ -z "$out" ]'
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1 KIT_TRANSCRIPT_CHECK=0); check "transcript: KIT_TRANSCRIPT_CHECK=0: nothing said" '[ -z "$out" ]'
    printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/transcript-check.sh"}]}]}}\n' > "$T/tch/.claude/settings.json"
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1); check "transcript: your own transcript-check hook: kit says nothing (no second warning)" '[ -z "$out" ]'
else echo "(transcript check: skipped, no C compiler on this Mac)"; fi

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
check "export-self drops CHANGELOG, LICENSE, .github, private-words.txt; keeps README (the manual)" '[ -f "$EX/README.md" ] && [ ! -e "$EX/LICENSE" ] && [ ! -e "$EX/CHANGELOG.md" ] && [ ! -e "$EX/.github" ] && [ ! -e "$EX/private-words.txt" ]'
check "export-self keeps tests, .gitattributes, .gitignore, kit" '[ -f "$EX/tests/t.sh" ] && [ -f "$EX/.gitattributes" ] && [ -f "$EX/.gitignore" ] && [ -x "$EX/unix/kit" ] && [ -f "$EX/windows/kit.ps1" ]'
# kit's own repo must export too (a GitHub host in a test or an example once stopped every company update)
if git -C "$HERE/.." rev-parse --git-dir >/dev/null 2>&1; then
    mkdir -p "$T/exhome"; out=$(HOME="$T/exhome" "$KIT" export-self "$T/exself" 2>&1); rc=$?
    check "export-self: kit's own repo exports (nothing in it names GitHub)" '[ $rc -eq 0 ] && [ -f "$T/exself/VERSION" ] || { echo "$out" | grep "export-self:" | head -n 5; false; }'
    check "export-self: kit's own repo exports only kit (no screen program's add-ons)" '[ "$(cd "$T/exself" && ls -A | LC_ALL=C sort | tr "\n" " ")" = ".gitattributes .gitignore INSTALL.md README.md VERSION docs templates tests tools unix windows " ]'
fi
check "export-self leaves out untracked files" '[ ! -e "$EX/untracked.md" ]'
check "export-self writes VERSION" '[ "$(cat "$EX/VERSION")" = 0.4.0+gitea.12 ]'
check "export-self INSTALL.md, no URL" 'grep -q "sh unix/install.sh" "$EX/INSTALL.md" && grep -qF "windows\\install.ps1" "$EX/INSTALL.md" && ! grep -qE "://|@[A-Za-z0-9.-]+:" "$EX/INSTALL.md"'
check "export-self INSTALL.md: first use is docs/company.md, the manual README.md" 'grep -qF "照 docs/company.md 從頭做一次" "$EX/INSTALL.md" && grep -qF "用法看 README.md" "$EX/INSTALL.md"'
if [ -n "$PWSH" ]; then
    "$PWSH" -NoProfile -File "$FK/windows/kit.ps1" export-self "$T/export-ps" >/dev/null 2>&1
    check "export-self: kit.ps1 writes the same INSTALL.md" 'cmp -s "$T/export-ps/INSTALL.md" "$EX/INSTALL.md"'
    rm -rf "$T/export-ps"
fi
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
echo "not an item" > notes.txt
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: nothing to send, said in JSON (what is left out too)" '[ $rc -eq 0 ] && [ "$out" = "{\"source\": \"work\", \"dir\": \"$(pwd -P)\", \"push\": \"pr\", \"dry_run\": true, \"files\": [], \"skipped\": [\"notes.txt\"], \"commit\": null, \"branch\": null, \"into\": null, \"remotes\": [], \"sent\": false, \"pr_url\": null, \"compare_url\": null}" ]'
rm -f notes.txt
kit new skill pfoo >/dev/null 2>&1
head0=$(git rev-parse HEAD)
out=$(kit push --dry-run 2>&1); rc=$?
check "push --dry-run lists files and branch, sends nothing" '[ $rc -eq 0 ] && echo "$out" | grep -q "skills/pfoo/SKILL.md" && echo "$out" | grep -q "kit/pfoo-$DAY" && [ "$(git rev-parse HEAD)" = "$head0" ] && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --dry-run --json: only one JSON line on stdout: files, commit, branch, where the PR goes" '[ $rc -eq 0 ] && [ "$out" = "{\"source\": \"work\", \"dir\": \"$(pwd -P)\", \"push\": \"pr\", \"dry_run\": true, \"files\": [\"skills/pfoo/SKILL.md\"], \"skipped\": [], \"commit\": \"kit: add skill:pfoo\", \"branch\": \"kit/pfoo-$DAY\", \"into\": \"main\", \"remotes\": [\"origin\"], \"sent\": false, \"pr_url\": null, \"compare_url\": \"${KIT_GITEA_API%/api/v1}/acme/team/compare/main...kit/pfoo-$DAY\"}" ] && [ "$(git rev-parse HEAD)" = "$head0" ]'
if [ -n "$PWSH" ]; then
    check "push --dry-run --json: kit.ps1 prints the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
echo "TopSecretName here" >> skills/pfoo/SKILL.md
out=$(kit push 2>&1); rc=$?
check "push: check problem stops, nothing sent" '[ $rc -ne 0 ] && echo "$out" | grep -q 什麼都沒送 && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: a check problem is error check_failed" '[ $rc -ne 0 ] && [ "$out" = "{\"error\": {\"code\": \"check_failed\", \"message\": \"kit check 有問題，什麼都沒送（改好再 kit push）\"}}" ]'
if [ -n "$PWSH" ]; then
    check "push --json error: kit.ps1 prints the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
printf -- '---\nname: pfoo\ndescription: p\n---\nok\n' > skills/pfoo/SKILL.md
git config user.email me@home.example
out=$(kit push 2>&1); rc=$?
check "push: author domain must be company" '[ $rc -ne 0 ] && echo "$out" | grep -q "不是公司網域" && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: error author_not_allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"author_not_allowed\", \"message\": \"git 的作者信箱 me@home.example 不是公司網域"'
git config user.email me@corp.example
git remote set-url origin https://public-git.example/acme/team.git
out=$(kit push 2>&1); rc=$?
check "push: origin host not allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單" && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: error host_not_allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"host_not_allowed\", " && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ]'
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
echo "Be kindest." > rules/base.md
out=$(KIT_GITEA_TOKEN=fake-tok-123 kit push --json 2>/dev/null); rc=$?
check "push --json: sent, the PR's URL; nothing else on stdout" '[ $rc -eq 0 ] && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ] && echo "$out" | grep -qF "\"dry_run\": false, \"files\": [\"rules/base.md\"], " && echo "$out" | grep -qF "\"branch\": \"kit/base-$DAY\", \"into\": \"main\", \"remotes\": [\"origin\"], \"sent\": true, \"pr_url\": \"http://127.0.0.1/acme/team/pulls/1\", \"compare_url\": " && remote_heads | grep -qx "kit/base-$DAY"'
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
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push direct --dry-run --json: the branch and every remote, no PR" '[ $rc -eq 0 ] && [ "$out" = "{\"source\": \"work\", \"dir\": \"$(pwd -P)\", \"push\": \"direct\", \"dry_run\": true, \"files\": [\"rules/mine.md\"], \"skipped\": [\"notes.txt\"], \"commit\": \"kit: update rule:mine\", \"branch\": \"main\", \"into\": null, \"remotes\": [\"one\", \"two\"], \"sent\": false, \"pr_url\": null, \"compare_url\": null}" ]'
if [ -n "$PWSH" ]; then
    check "push direct --dry-run --json: kit.ps1 prints the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
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
out=$(kit push --json 2>/dev/null); rc=$?
check "push direct --json: error out_of_sync" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"out_of_sync\", \"message\": \"three 上沒有 main"'
git remote remove three
git clone -q "$R1" "$D/other" 2>/dev/null; git -C "$D/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m theirs; git -C "$D/other" push -q origin HEAD:main 2>/dev/null
out=$(kit push 2>&1); rc=$?
check "push direct: new commits on a remote stop it (pull first)" '[ $rc -ne 0 ] && echo "$out" | grep -qF "git pull one main" && [ "$(git status --porcelain rules)" = " M rules/mine.md" ]'
git pull -q --no-rebase one main 2>/dev/null; git push -q two main 2>/dev/null; git fetch -q two
# kit.yaml goes along only when all that changed in it is collect_sources (kit collect --allow)
printf 'collect_sources: [example.com/a/b]\n' >> kit.yaml
out=$(kit push 2>&1); rc=$?
check "push direct: kit.yaml with only collect_sources changed goes along" '[ $rc -eq 0 ] && [ "$(git show --name-only --format= HEAD | sort | paste -sd" " -)" = "kit.yaml rules/mine.md" ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$(git rev-parse HEAD)" ]'
echo "Mine, once more." > rules/mine.md; printf 'maintainers: [me]\n' >> kit.yaml
out=$(kit push 2>&1); rc=$?
check "push direct: kit.yaml with other changes stays behind" '[ $rc -eq 0 ] && [ "$(git show --name-only --format= HEAD)" = rules/mine.md ] && echo "$out" | grep -q "不會送：kit.yaml"'
git checkout -q -- kit.yaml
# a commit hook says no: git's words are shown, and nothing is left staged
printf '#!/bin/sh\necho "hook: no thanks" >&2\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
echo "Mine, blocked." > rules/mine.md; h=$(git rev-parse HEAD)
out=$(kit push 2>&1); rc=$?
check "push direct: a commit hook refusing: its words shown, nothing committed or left staged" '[ $rc -ne 0 ] && echo "$out" | grep -q "hook: no thanks" && [ "$(git rev-parse HEAD)" = "$h" ] && [ -z "$(git diff --cached --name-only)" ] && [ "$(git status --porcelain rules)" = " M rules/mine.md" ]'
rm -f .git/hooks/pre-commit
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
R="$T/clone"; mkdir -p "$R"; cp -R "$HERE/../unix" "$HERE/../templates" "$HERE/../tools" "$HERE/../VERSION" "$R/"
( cd "$R" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm v1 )
U="$T/clone2"; git clone -q "$R" "$U"
touch "$HOME/.bashrc"
out=$(PATH=/usr/bin:/bin sh "$U/unix/install.sh" 2>&1)
check "install puts kit in ~/.local/bin" '[ -x "$HOME/.local/bin/kit" ] && "$HOME/.local/bin/kit" --version | grep -qF "kit $(cat "$HERE/../VERSION")"'
check "install adds PATH once" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
mkdir -p "$HOME/.local/share/agentkit/herdr/kit-panel" "$HOME/.config/herdr-app/mods/kit"
echo old > "$HOME/.local/share/agentkit/herdr/kit-panel/main.js"
echo old > "$HOME/.config/herdr-app/mods/kit/main.js"; : > "$HOME/.config/herdr-app/mods/kit/.kit-panel"
PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
check "reinstall does not add PATH twice" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
check "reinstall removes the panel files kit 0.2 left in its own folder" '[ ! -e "$HOME/.local/share/agentkit/herdr" ] && [ -x "$HOME/.local/share/agentkit/kit" ]'
check "reinstall leaves a panel installed in a screen program alone" '[ "$(cat "$HOME/.config/herdr-app/mods/kit/main.js")" = old ] && [ -f "$HOME/.config/herdr-app/mods/kit/.kit-panel" ]'
rm -rf "$HOME/.config/herdr-app"
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

# ---------- a folder's own (kit add --dir): only agents started there get it ----------
H5="$T/home5"; mkdir -p "$H5/.codex" "$H5/.omp/agent"
printf 'model = "gpt-5"\n\n[mcp_servers.mine]\ncommand = "x"\n' > "$H5/.codex/config.toml"; cp -p "$H5/.codex/config.toml" "$T/codex5.orig"
P="$T/fproj"; mkdir -p "$P/sub/deeper"; P=$(cd "$P" && pwd -P)
printf '# my notes\n' > "$P/CLAUDE.md"; printf '{\n  "mcpServers": {\n    "own": {\n      "command": "y"\n    }\n  }\n}\n' > "$P/.mcp.json"
cp "$P/CLAUDE.md" "$T/p.claude"; cp "$P/.mcp.json" "$T/p.mcp"
(
export HOME="$H5"
kit init "$TEAM" >/dev/null 2>&1
out=$(kit add --dir "$P" skill gerrit-review 2>&1); rc=$?
check "add --dir: done, says where" '[ $rc -eq 0 ] && echo "$out" | grep -qF "$P"'
check "add --dir: .agentkit lists it" 'grep -qx "skill:gerrit-review" "$P/.agentkit"'
check "add --dir: Claude and Codex/omp skill folders" '[ -f "$P/.claude/skills/gerrit-review/SKILL.md" ] && [ -f "$P/.agents/skills/gerrit-review/SKILL.md" ]'
check "add --dir: not the account" '[ ! -e "$H5/.claude/skills/gerrit-review" ] && [ ! -e "$H5/.agents/skills/gerrit-review" ] && ! kit list | grep -q "^\* *skill:gerrit-review"'
out=$(kit add --dir "$P/sub/deeper" rule gerrit-flow 2>&1)
check "add --dir from a sub-folder goes to the folder that has .agentkit" '[ ! -e "$P/sub/deeper/.agentkit" ] && grep -qx "rule:gerrit-flow" "$P/.agentkit"'
check "add --dir rule: CLAUDE.md keeps the user text, imports the rule" 'head -1 "$P/CLAUDE.md" | grep -qx "# my notes" && grep -q "^@.*rules/gerrit-flow.md" "$P/CLAUDE.md"'
check "add --dir rule: AGENTS.md (Codex, omp) has the text" 'grep -q "Only comment, never submit." "$P/AGENTS.md"'
check "add --dir: account rules untouched" '! grep -q gerrit-flow "$H5/.claude/CLAUDE.md"'
check "codex: project_root_markers at the top, user part kept, valid TOML" 'head -1 "$H5/.codex/config.toml" | grep -q "agentkit:top:begin" && grep -qF "project_root_markers = [\".git\", \".agentkit\"]" "$H5/.codex/config.toml" && grep -qx "model = \"gpt-5\"" "$H5/.codex/config.toml" && { ! python3 -c "import tomllib" 2>/dev/null || python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"project_root_markers\"]==[\".git\",\".agentkit\"] and d[\"model\"]==\"gpt-5\"" "$H5/.codex/config.toml"; }'
kit add --dir "$P" mcp gerrit >/dev/null 2>&1
check "add --dir mcp: .mcp.json has it, the user's server kept" '[ "$(jget "$P/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && [ "$(jget "$P/.mcp.json" mcpServers.own.command)" = "\"y\"" ]'
check "add --dir mcp: Claude does not ask (settings.local.json)" 'jget "$P/.claude/settings.local.json" enabledMcpjsonServers | grep -q "\"gerrit\""'
check "add --dir mcp: the folder's Codex config" 'grep -q "^\[mcp_servers.gerrit\]" "$P/.codex/config.toml"'
check "add --dir mcp: Codex trusts the folder (valid TOML)" 'grep -qF "[projects.\"$P\"]" "$H5/.codex/config.toml" && { ! python3 -c "import tomllib" 2>/dev/null || python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"projects\"][sys.argv[2]][\"trust_level\"]==\"trusted\"" "$H5/.codex/config.toml" "$P"; }'
check "add --dir mcp: not the account" '! jget "$H5/.claude.json" mcpServers.gerrit >/dev/null'
kit list --json --dir "$P/sub" > "$T/here5.json" 2>/dev/null
check "list --json: folder = the one with .agentkit, its items" 'python3 -c "import json,sys;h=json.load(open(sys.argv[1]))[\"here\"];f=h[\"folder\"];assert f[\"dir\"]==sys.argv[2] and f[\"why\"]==\"\" and set(f[\"items\"])=={\"skill:gerrit-review\",\"rule:gerrit-flow\",\"mcp:gerrit\"}" "$T/here5.json" "$P"'
check "list --json: kit's folder things are not listed again as the folder's own" 'python3 -c "import json,sys;h=json.load(open(sys.argv[1]))[\"here\"];n=[(i[\"kind\"],i[\"name\"]) for i in h[\"items\"]];assert (\"skill\",\"gerrit-review\") not in n and not any(i[\"path\"].endswith(\"AGENTS.md\") for i in h[\"items\"]) and any(i[\"path\"].endswith(\"/CLAUDE.md\") for i in h[\"items\"])" "$T/here5.json"'
out=$(kit add --dir "$H5" skill gerrit-review 2>&1); rc=$?
check "add --dir: refuses the home folder" '[ $rc -ne 0 ] && echo "$out" | grep -q "家目錄" && [ ! -e "$H5/.agentkit" ]'
out=$(kit add --dir "$T" skill gerrit-review 2>&1); rc=$?
check "add --dir: refuses a folder the home folder is in" '[ $rc -ne 0 ] && [ ! -e "$T/.agentkit" ]'
out=$(kit rm --dir "$P" skill gerrit-workflow 2>&1); rc=$?
check "rm --dir: only what the folder added" '[ $rc -ne 0 ] && echo "$out" | grep -q "沒有加"'
printf 'review v2\n' >> "$TEAM/skills/gerrit-review/SKILL.md"; kit sync >/dev/null 2>&1
check "sync updates the folder's copy" 'grep -q "review v2" "$P/.claude/skills/gerrit-review/SKILL.md" && grep -q "review v2" "$P/.agents/skills/gerrit-review/SKILL.md"'
kit rm --dir "$P" skill gerrit-review >/dev/null 2>&1; kit rm --dir "$P" rule gerrit-flow >/dev/null 2>&1; kit rm --dir "$P" mcp gerrit >/dev/null 2>&1
check "rm --dir all: the folder exactly as before" 'cmp -s "$P/CLAUDE.md" "$T/p.claude" && cmp -s "$P/.mcp.json" "$T/p.mcp" && [ "$(cd "$P" && ls -A | LC_ALL=C sort | tr "\n" " ")" = ".mcp.json CLAUDE.md sub " ]'
check "rm --dir all: Codex config byte-identical" 'cmp -s "$H5/.codex/config.toml" "$T/codex5.orig"'
check "rm --dir all: kit forgets the folder" '[ ! -e "$HOME/.config/agentkit/dirs" ] && ! grep -qF "dir:$P:" "$HOME/.config/agentkit/state.tsv"'
kit add --dir "$P" skill gerrit-review >/dev/null 2>&1; kit add --dir "$P" mcp gerrit >/dev/null 2>&1
Q="$T/gone"; mkdir -p "$Q"; Q=$(cd "$Q" && pwd -P); kit add --dir "$Q" skill gerrit-review >/dev/null 2>&1; rm -rf "$Q"; kit sync >/dev/null 2>&1
check "sync: a folder that is gone leaves the list" '! grep -qxF "$Q" "$HOME/.config/agentkit/dirs" && grep -qxF "$P" "$HOME/.config/agentkit/dirs"'
kit uninstall >/dev/null 2>&1
check "uninstall: the folder exactly as before" 'cmp -s "$P/CLAUDE.md" "$T/p.claude" && cmp -s "$P/.mcp.json" "$T/p.mcp" && [ "$(cd "$P" && ls -A | LC_ALL=C sort | tr "\n" " ")" = ".mcp.json CLAUDE.md sub " ]'
check "uninstall: Codex config byte-identical" 'cmp -s "$H5/.codex/config.toml" "$T/codex5.orig"'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

# ---------- the programs a skill needs (kit tools / install-tool, "needs" in list --json) ----------
H6="$T/home6"; FB="$T/fakebin"; mkdir -p "$H6" "$FB"
printf '#!/bin/sh\necho v16.2.0\n' > "$FB/node"; chmod +x "$FB/node"
printf '#!/bin/sh\necho "$*" >> "%s/brew.log"\n[ "$1" = upgrade ] && printf "#!/bin/sh\\necho v26.1.0\\n" > "%s/node" && chmod +x "%s/node"\ncase $2 in bad*) exit 1;; frob) printf "#!/bin/sh\\necho frob 1.2.3\\n" > "%s/frob" && chmod +x "%s/frob";; esac\nexit 0\n' "$T" "$FB" "$FB" "$FB" "$FB" > "$FB/brew"; chmod +x "$FB/brew"
printf '#!/bin/sh\necho "$*" >> "%s/apt.log"\nexit 1\n' "$T" > "$FB/apt-get"; chmod +x "$FB/apt-get"     # (a Linux run as root: never the real one)
NT="$T/needteam"; mkdir -p "$NT/skills/drawer/bin" "$NT/skills/plain/scripts" "$NT/skills/told" "$NT/tools"
printf -- '---\nname: drawer\ndescription: draws\n---\nRun `node bin/draw.mjs <in>` to draw.\n' > "$NT/skills/drawer/SKILL.md"; echo 'x' > "$NT/skills/drawer/bin/draw.mjs"
printf '{"name": "drawer", "engines": {"node": ">=18"}}\n' > "$NT/skills/drawer/package.json"
printf -- '---\nname: plain\ndescription: only text\n---\nNo node, no python here.\n' > "$NT/skills/plain/SKILL.md"
printf '{"name": "plain", "private": true}\n' > "$NT/skills/plain/package.json"; echo 'print(1)' > "$NT/skills/plain/scripts/check.py"
printf -- '---\nname: told\ndescription: says what it needs\nrequires: [node>=20, frob]\n---\nx\n' > "$NT/skills/told/SKILL.md"
printf 'name: needteam\nrequires:\n  plain: [git]\n' > "$NT/kit.yaml"
mkdir -p "$NT/skills/packed/scripts"; printf -- '---\nname: packed\ndescription: has npm packages\n---\nRun `node scripts/run.mjs`.\n' > "$NT/skills/packed/SKILL.md"
echo 'x' > "$NT/skills/packed/scripts/run.mjs"; printf '{"name": "packed", "dependencies": {"left-pad": "1.3.0"}}\n' > "$NT/skills/packed/package.json"
printf '{"lockfileVersion": 3, "packages": {"": {"dependencies": {"left-pad": "1.3.0"}}, "node_modules/left-pad": {"version": "1.3.0", "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", "integrity": "sha512-XI5MPzVNApjAyhQzphX8BkmKsKUxD4LdyK24iZeQEGg9ylg3cs3KHoxHhvlaXRBmtqI9zaxOttfQ9EE5zORWb4w==", "license": "WTFPL"}}}\n' > "$NT/skills/packed/package-lock.json"
printf 'registry=http://elsewhere.invalid/\n' > "$NT/skills/packed/.npmrc"
# npm packages kit must not install: a git dependency; a lock with a package from git; a lock on another registry
for n in npmgit npmlock npmreg; do mkdir -p "$NT/skills/$n"; printf -- '---\nname: %s\ndescription: x\n---\nx\n' "$n" > "$NT/skills/$n/SKILL.md"; done
printf '{"name": "npmgit", "dependencies": {"left-pad": "1.3.0"}, "optionalDependencies": {"tool": "github:someone/tool"}}\n' > "$NT/skills/npmgit/package.json"
printf '{"name": "npmlock", "dependencies": {"tool": "^1.0.0"}}\n' > "$NT/skills/npmlock/package.json"
printf '{"lockfileVersion": 3, "packages": {"": {}, "node_modules/tool": {"version": "1.0.0", "resolved": "git+ssh://git@git.example.org/someone/tool.git#abc", "integrity": "sha512-x"}}}\n' > "$NT/skills/npmlock/package-lock.json"
printf '{"name": "npmreg", "dependencies": {"tool": "^1.0.0"}}\n' > "$NT/skills/npmreg/package.json"
printf '{"lockfileVersion": 3, "packages": {"": {}, "node_modules/tool": {"version": "1.0.0", "resolved": "https://npm.example.com/r/tool/-/tool-1.0.0.tgz", "integrity": "sha512-x"}}}\n' > "$NT/skills/npmreg/package-lock.json"
# a program a skill asks for that kit has no recipe for: never run
mkdir -p "$NT/skills/asks"; printf -- '---\nname: asks\ndescription: x\nrequires: [noprobe]\n---\nx\n' > "$NT/skills/asks/SKILL.md"
printf '#!/bin/sh\necho ran >> "%s/noprobe.log"\necho noprobe 1.0\n' "$T" > "$FB/noprobe"; chmod +x "$FB/noprobe"
mkdir -p "$NT/skills/pyskill/scripts" "$NT/skills/pybad"; printf -- '---\nname: pyskill\ndescription: python packages\n---\nRun `python3 scripts/go.py`.\n' > "$NT/skills/pyskill/SKILL.md"
echo 'print(1)' > "$NT/skills/pyskill/scripts/go.py"; printf '# what it needs\nrequests==2.32.0\nrich[jupyter] >=13, <15 ; python_version >= "3.9"\ncertifi ; sys_platform != '"'win32'"' and python_version < "4"  # ok\n' > "$NT/skills/pyskill/requirements.txt"
printf -- '---\nname: pybad\ndescription: b\n---\nx\n' > "$NT/skills/pybad/SKILL.md"; printf 'requests\n--index-url http://elsewhere.invalid/\n' > "$NT/skills/pybad/requirements.txt"
# an option after a marker (pip takes it from there too)
mkdir -p "$NT/skills/pymark"; printf -- '---\nname: pymark\ndescription: b\n---\nx\n' > "$NT/skills/pymark/SKILL.md"; printf 'requests ; python_version >= "3.8" --config-settings=x=y\n' > "$NT/skills/pymark/requirements.txt"
REALPY=$(command -v python3)
(
export HOME="$H6" PATH="$FB:/usr/bin:/bin"
kit init "$NT" >/dev/null 2>&1
kit list --json > "$T/needs.json" 2>/dev/null
nd() { python3 -c "import json,sys;d={i['name']:i for i in json.load(open(sys.argv[1]))['items']};print(json.dumps(d[sys.argv[2]]['needs'],sort_keys=True))" "$T/needs.json" "$1"; }
check "needs: SKILL.md runs node, package.json gives the lowest version, too old here, brew is there" '[ "$(nd drawer)" = "[{\"have\": \"16.2.0\", \"install\": \"brew upgrade node\", \"min\": \"18\", \"ok\": false, \"title\": \"Node.js\", \"tool\": \"node\"}]" ]'
check "needs: a package.json or a .py of the author says nothing; kit.yaml requires does" 'nd plain | grep -q "\"tool\": \"git\"" && ! nd plain | grep -q "\"tool\": \"node\"" && ! nd plain | grep -q python'
check "needs: SKILL.md requires, an unknown program has no install" 'nd told | grep -q "\"min\": \"20\"" && nd told | grep -q "\"install\": \"\", \"min\": \"\", \"ok\": false, \"title\": \"frob\", \"tool\": \"frob\""'
check "needs: kit.ps1 prints the same list" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(cat "$T/needs.json")" ]'
check "needs: a program kit has no recipe for is not run to look at it" 'nd asks | grep -qF "\"have\": \"\", \"install\": \"\"" && [ ! -e "$T/noprobe.log" ]'
out=$(kit tools 2>&1)
check "tools: what this machine has and how kit would install it" 'echo "$out" | grep -qE "^node +16.2.0 +brew install node$"'
out=$(kit install-tool node 2>&1)
check "install-tool: there (no lowest version asked)" 'echo "$out" | grep -qF "已經有 Node.js 16.2.0" && [ ! -e "$T/brew.log" ]'
out=$(KIT_DRY_RUN=1 kit install-tool node --min 18 2>&1)
check "install-tool --min, dry run: too old -> only says the upgrade command" 'echo "$out" | grep -qF "執行 brew upgrade node" && [ ! -e "$T/brew.log" ]'
out=$(kit install-tool node --min 18 2>&1); rc=$?
check "install-tool --min: runs kit's upgrade, then looks again" '[ $rc -eq 0 ] && [ "$(cat "$T/brew.log")" = "upgrade node" ] && echo "$out" | grep -qF "Node.js 26.1.0 裝好了"'
out=$(kit install-tool node --min 18 2>&1)
check "install-tool --min: new enough now" 'echo "$out" | grep -qF "已經有 Node.js 26.1.0"'
out=$(kit install-tool frob 2>&1); rc=$?
check "install-tool: no recipe, says how to add one" '[ $rc -ne 0 ] && echo "$out" | grep -qF "tools/frob.yaml"'
# a source's recipe adds programs, with only "manager package": a manager kit knows, a plain package name; never a command
rm -f "$T/brew.log"
printf 'name: frob\ntitle: Frob\ninstall:\n  mac: ["sh -c evil", "brew frob;rm", "curl x", "brew user/tap/frob", "brew -frob", "brew ../frob", "brew frob"]\n  linux: ["sh -c evil", "brew frob;rm", "curl x", "brew user/tap/frob", "brew -frob", "brew ../frob", "brew frob"]\n' > "$NT/tools/frob.yaml"
out=$(kit install-tool frob 2>&1)
check "install-tool: a recipe can only pick a known manager and a plain package name" '[ "$(cat "$T/brew.log")" = "install frob" ] && echo "$out" | grep -qF "執行 brew install frob" && echo "$out" | grep -qF "Frob 1.2.3 裝好了"'
rm -f "$T/brew.log" "$FB/frob"
printf 'name: frob\ntitle: Frob\ninstall:\n  mac: [brew badfrob, brew frob]\n  linux: [brew badfrob, brew frob]\n' > "$NT/tools/frob.yaml"
out=$(kit install-tool frob 2>&1); rc=$?
check "install-tool: one way fails -> the next way in the recipe" '[ $rc -eq 0 ] && [ "$(cat "$T/brew.log" | tr "\n" " ")" = "install badfrob install frob " ] && echo "$out" | grep -qF "用 brew 裝失敗" && echo "$out" | grep -qF "Frob 1.2.3 裝好了"'
printf 'name: frob\ntitle: Frob\ninstall:\n  mac: [brew badfrob]\n  linux: [brew badfrob]\n' > "$NT/tools/frob.yaml"; rm -f "$FB/frob"
out=$(kit install-tool frob 2>&1); rc=$?
check "install-tool: every way fails -> says so" '[ $rc -ne 0 ] && echo "$out" | grep -qF "每一種裝法都沒有成功（最後是 brew）"'
printf 'name: pyfrob\ninstall:\n  mac: [pip pyfrob]\n  linux: [pip pyfrob]\n' > "$NT/tools/pyfrob.yaml"
out=$(KIT_DRY_RUN=1 kit install-tool pyfrob 2>&1)
check "install-tool (pip): wheels only, for this account" 'echo "$out" | grep -qF "執行 python3 -m pip install --user --only-binary=:all: pyfrob"'
# kit's own recipes (node, python, git) cannot be replaced by a source
printf 'name: node\ntitle: Node\ninstall:\n  mac: [scoop node]\n  linux: [scoop node]\n' > "$NT/tools/node.yaml"; rm -f "$FB/node" "$T/brew.log"
out=$(kit install-tool node 2>&1); rc=$?
# (a machine with node in /usr/bin, like a Linux server, has it already: kit tools still shows kit's way)
check "install-tool: kit's own recipe wins over a source's" 'PATH=/usr/bin:/bin command -v node >/dev/null || { echo "$out" | grep -qF "執行 brew install node" && [ "$(cat "$T/brew.log")" = "install node" ] && ! echo "$out" | grep -q scoop; }'
check "tools: kit's own recipe for node, not the source's" 'kit tools 2>&1 | grep -E "^node " | grep -qE "(brew install node|apt-get install -y nodejs)$"'
# --version of a program that hangs (and what it started) or never stops talking: a few seconds, 4 KB
printf 'name: slowtool\nbin: [slowtool]\ninstall:\n  mac: [brew slowtool]\n  linux: [brew slowtool]\n' > "$NT/tools/slowtool.yaml"
printf '#!/bin/sh\nsleep 30\necho slowtool 1.0\n' > "$FB/slowtool"
printf 'name: chatty\nbin: [chatty]\ninstall:\n  mac: [brew chatty]\n  linux: [brew chatty]\n' > "$NT/tools/chatty.yaml"
printf '#!/bin/sh\nexec yes "chatty 2.5"\n' > "$FB/chatty"; chmod +x "$FB/slowtool" "$FB/chatty"
t0=$SECONDS; out=$(KIT_PROBE_WAIT=1 capped 25 kit tools 2>&1); rc=$?; took=$((SECONDS - t0))
check "tools: a --version that hangs is given up, one that never stops is cut" '[ $rc -eq 0 ] && [ $took -lt 15 ] && echo "$out" | grep -qE "^slowtool +（沒有）" && echo "$out" | grep -qE "^chatty +2.5 "'
if [ -n "$PWSH" ]; then
    t0=$SECONDS; out=$(KIT_PROBE_WAIT=1 capped 40 kps tools 2>&1); rc=$?; took=$((SECONDS - t0))
    check "tools: kit.ps1 gives up and cuts the same" '[ $rc -eq 0 ] && [ $took -lt 30 ] && echo "$out" | grep -qE "^slowtool +（沒有）" && echo "$out" | grep -qE "^chatty +2.5 "'
fi
rm -f "$NT/tools/slowtool.yaml" "$NT/tools/chatty.yaml" "$NT/tools/pyfrob.yaml" "$FB/slowtool" "$FB/chatty"
# a skill's own npm packages (kit install-deps): only when asked, in kit's folder, no package scripts, linked into each copy
pk() { kit list --json 2>/dev/null | python3 -c "import json,sys;d={i['name']:i for i in json.load(sys.stdin)['items']};p=[x for x in d[sys.argv[1]].get('packages') or [] if x['kind']==sys.argv[2]];print(json.dumps(p[0] if p else None,sort_keys=True))" "$1" "${2:-npm}"; }
check "packages: no npm here, nothing to run it with" '{ PATH=/usr/bin:/bin command -v npm >/dev/null || [ "$(pk packed)" = "{\"bad\": \"\", \"had\": false, \"install\": \"\", \"kind\": \"npm\", \"ok\": false}" ]; } && [ "$(pk drawer)" = null ] && [ "$(pk plain)" = null ] && [ "$(pk plain pip)" = null ]'
printf '#!/bin/sh\necho "$PWD $*" >> "%s/npm.log"\n[ -f .npmrc ] && exit 9\nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js\n' "$T" > "$FB/npm"; chmod +x "$FB/npm"
check "packages: a lock -> npm ci, no package scripts" '[ "$(pk packed)" = "{\"bad\": \"\", \"had\": false, \"install\": \"npm ci --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": false}" ]'
kit add skill packed >/dev/null 2>&1
out=$(KIT_DRY_RUN=1 kit install-deps packed 2>&1)
check "install-deps, dry run: only says the command" 'echo "$out" | grep -qF "執行 npm ci --ignore-scripts --omit=dev --no-audit --no-fund" && [ ! -e "$T/npm.log" ]'
S6="$H6/.config/agentkit/deps/packed"; C6="$H6/.claude/skills/packed"
out=$(kit install-deps packed 2>&1); rc=$?
nl=$(cat "$T/npm.log")
check "install-deps: npm ci in a new folder next to kit's, not the source, without the skill's .npmrc" '[ $rc -eq 0 ] && [ "${nl#"$S6".new.}" != "$nl" ] && [ "${nl#* }" = "ci --ignore-scripts --omit=dev --no-audit --no-fund" ] && [ -f "$S6/node_modules/left-pad/index.js" ] && [ ! -e "$NT/skills/packed/node_modules" ] && [ ! -e "$S6/.npmrc" ] && ! ls -d "$S6".new.* >/dev/null 2>&1'
check "install-deps: the copy kit put gets node_modules linked to it" '[ -L "$C6/node_modules" ] && [ -f "$C6/node_modules/left-pad/index.js" ]'
check "packages: installed now" '[ "$(pk packed)" = "{\"bad\": \"\", \"had\": true, \"install\": \"npm ci --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": true}" ]'
check "packages: kit.ps1 sees the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
out=$(kit install-deps packed 2>&1)
check "install-deps again: already there, npm not run" 'echo "$out" | grep -qF "已經裝好了" && [ "$(wc -l < "$T/npm.log")" -eq 1 ]'
out=$(kit sync 2>&1)
check "sync: the link is not a change to the skill" '! echo "$out" | grep -q "手動" && [ -L "$C6/node_modules" ]'
echo '{"lockfileVersion": 3, "x": 1}' > "$NT/skills/packed/package-lock.json"; kit sync >/dev/null 2>&1
check "the skill changed its lock: needs 更新, the new copy has no old packages" '[ "$(pk packed)" = "{\"bad\": \"\", \"had\": true, \"install\": \"npm ci --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": false}" ] && [ -f "$C6/SKILL.md" ] && [ ! -e "$C6/node_modules" ]'
out=$(kit install-deps packed 2>&1); rc=$?
check "install-deps after the change: again, and linked" '[ $rc -eq 0 ] && [ "$(wc -l < "$T/npm.log")" -eq 2 ] && [ -L "$C6/node_modules" ]'
# kit run: the agent's folder gets the links too, and goes with them (never into kit's store); a dry run has none
mkdir -p "$NT/agents"; printf -- '---\nname: packer\ndescription: x\nskills: [packed]\n---\nx\n' > "$NT/agents/packer.md"
out=$(KIT_DRY_RUN=1 kit run packer 2>&1); rt=$(printf '%s\n' "$out" | sed -n 's/^tmp=//p')
check "run, dry run: the agent's folder to look at, without kit's links" '[ -f "$rt/.claude/skills/packed/SKILL.md" ] && [ ! -e "$rt/.claude/skills/packed/node_modules" ] && [ ! -e "$rt/.kit-pid" ]'
rm -rf "$rt"
SR="${TMPDIR:-/tmp}/kit-run.kittest$$"; mkdir -p "$SR/x"; echo 999999 > "$SR/.kit-pid"; ln -s "$S6/node_modules" "$SR/x/node_modules"
printf '#!/bin/sh\necho "$*" > "%s/claude.args"\n[ -L "$2/.claude/skills/packed/node_modules" ] || exit 4\nexit 3\n' "$T" > "$FB/claude"; chmod +x "$FB/claude"
kit run packer >/dev/null 2>&1; rc=$?
rt=$(sed -n 's/^--add-dir \([^ ]*\) .*/\1/p' "$T/claude.args")
check "run: the agent's folder has kit's links; its exit code; the folder gone, kit's packages still there" '[ $rc -eq 3 ] && [ -n "$rt" ] && [ ! -e "$rt" ] && [ -f "$S6/node_modules/left-pad/index.js" ]'
check "run: the folder of a run that was killed goes (its links only)" '[ ! -e "$SR" ] && [ -f "$S6/node_modules/left-pad/index.js" ]'
if [ -n "$PWSH" ]; then
    mkdir -p "$SR/x"; echo 999999 > "$SR/.kit-pid"; ln -s "$S6/node_modules" "$SR/x/node_modules"; rm -f "$T/claude.args"
    kps run packer >/dev/null 2>&1; rc=$?
    rt=$(sed -n 's/^--add-dir \([^ ]*\) .*/\1/p' "$T/claude.args")
    check "run (kit.ps1): the same: links in, exit code, folder gone, packages there, a killed run's folder gone" '[ $rc -eq 3 ] && [ -n "$rt" ] && [ ! -e "$rt" ] && [ -f "$S6/node_modules/left-pad/index.js" ] && [ ! -e "$SR" ]'
fi
rm -f "$FB/claude" "$NT/agents/packer.md"
printf '#!/bin/sh\nexit 3\n' > "$FB/npm"; rm -rf "$S6"
out=$(kit install-deps packed 2>&1); rc=$?
check "install-deps: npm fails -> says so, nothing half-made" '[ $rc -ne 0 ] && echo "$out" | grep -qF "裝套件失敗" && [ ! -e "$S6" ] && ! ls -d "$S6".new.* >/dev/null 2>&1'
# npm stopped halfway (Ctrl-C, the panel closed): its half-made folder goes too
printf '#!/bin/sh\nmkdir -p node_modules/left-pad\necho started > "%s/npm.started"\nexec sleep 31\n' "$T" > "$FB/npm"
# (set -m: kit and npm in a process group of their own, which gets the Ctrl-C, like a terminal's)
set -m; kit install-deps packed >/dev/null 2>&1 & kp=$!; set +m
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/npm.started" ] && break; sleep 0.5; done
kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
check "install-deps: stopped halfway (Ctrl-C) -> no half-made folder, no lock left" '[ -e "$T/npm.started" ] && [ ! -e "$S6" ] && ! ls -d "$S6".new.* >/dev/null 2>&1 && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
rm -f "$T/npm.started"
if [ -n "$PWSH" ]; then
    set -m; kps install-deps packed >/dev/null 2>&1 & kp=$!; set +m
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/npm.started" ] && break; sleep 0.5; done
    kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
    check "install-deps (kit.ps1): stopped halfway (Ctrl-C) -> no half-made folder, no lock left" '[ -e "$T/npm.started" ] && [ ! -e "$S6" ] && ! ls -d "$S6".new.* >/dev/null 2>&1 && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
    rm -f "$T/npm.started"
fi
# what kit does not install: git, a URL, another registry without your ~/.npmrc
check "packages: a git dependency is shown as refused" '[ "$(pk npmgit)" = "{\"bad\": \"package.json: optionalDependencies.tool = github:someone/tool\", \"had\": false, \"install\": \"npm install --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": false}" ]'
check "packages: a lock with a package from git, or from another registry, is refused" 'pk npmlock | grep -qF "\"bad\": \"package-lock.json: node_modules/tool: resolved git+ssh://git@git.example.org/someone/tool.git#abc\"" && pk npmreg | grep -qF "\"bad\": \"package-lock.json: node_modules/tool: resolved https://npm.example.com/r/tool/-/tool-1.0.0.tgz\""'
check "packages (refused): kit.ps1 says the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
rm -f "$T/npm.log"
out=$(kit install-deps npmgit 2>&1); rc=$?
check "install-deps: refuses a git dependency, npm not run" '[ $rc -ne 0 ] && echo "$out" | grep -qF "kit 不裝這些 npm 套件" && echo "$out" | grep -qF "github:someone/tool" && [ ! -e "$T/npm.log" ] && [ ! -e "$H6/.config/agentkit/deps/npmgit" ]'
printf 'registry = https://npm.example.com/r\n' > "$H6/.npmrc"
check "packages: your own ~/.npmrc registry is fine" '[ "$(pk npmreg | grep -o "\"bad\": \"[^\"]*\"")" = "\"bad\": \"\"" ]'
check "packages (your registry): kit.ps1 says the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
rm -f "$H6/.npmrc"
out=$(kit install-deps drawer 2>&1); rc=$?
check "install-deps: a skill without packages" '[ $rc -eq 0 ] && echo "$out" | grep -qF "不用另外裝套件"'
printf '#!/bin/sh\nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js\n' > "$FB/npm"; kit install-deps packed >/dev/null 2>&1
kit rm skill packed >/dev/null 2>&1
check "rm skill: the copy goes, kit's packages stay (the link only)" '[ ! -e "$C6" ] && [ -f "$S6/node_modules/left-pad/index.js" ]'
# Python: a venv of the skill's own, only wheels, requirements.txt with names and versions only
printf '#!/bin/sh\n[ "$1 $2" = "-m venv" ] || exec "%s" "$@"\nmkdir -p "$3/bin" && printf "#!/bin/sh\\necho \\"\\$PWD \\$*\\" >> %s/pip.log\\n" > "$3/bin/python" && chmod +x "$3/bin/python"\n' "$REALPY" "$T" > "$FB/python3"; chmod +x "$FB/python3"
PIPX="-m pip install --only-binary=:all: --no-input --disable-pip-version-check -r requirements.txt"
check "packages (pip): a requirements.txt -> a venv and pip with wheels only" '[ "$(pk pyskill pip)" = "{\"bad\": \"\", \"had\": false, \"install\": \"python3 -m venv venv; venv/bin/python $PIPX\", \"kind\": \"pip\", \"ok\": false}" ] && [ "$(pk packed pip)" = null ]'
check "packages (pip): a requirements.txt with options is shown as refused" 'pk pybad pip | grep -qF "\"bad\": \"2: --index-url http://elsewhere.invalid/\""'
check "packages (pip): an option after a marker is refused too" 'pk pymark pip | grep -qF "\"bad\": \"1: requests ; python_version >= \\\"3.8\\\" --config-settings=x=y\""'
check "packages (pip): kit.ps1 sees the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
out=$(kit install-deps pybad 2>&1); rc=$?
check "install-deps (pip): refuses options in requirements.txt, nothing made" '[ $rc -ne 0 ] && echo "$out" | grep -qF "第 2: --index-url" && [ ! -e "$H6/.config/agentkit/pydeps/pybad" ] && [ ! -e "$T/pip.log" ]'
kit add skill pyskill >/dev/null 2>&1
S7="$H6/.config/agentkit/pydeps/pyskill"; C7="$H6/.claude/skills/pyskill"
out=$(kit install-deps pyskill 2>&1); rc=$?
check "install-deps (pip): a venv in kit's folder, pip with wheels only, run there" '[ $rc -eq 0 ] && [ "$(cat "$T/pip.log")" = "$S7 $PIPX" ] && [ -x "$S7/venv/bin/python" ] && [ ! -e "$NT/skills/pyskill/.venv" ] && [ ! -e "$S7.old" ]'
check "install-deps (pip): the copy gets .venv linked, the instructions say to use it" '[ -L "$C7/.venv" ] && [ -x "$C7/.venv/bin/python" ] && grep -qF ".venv/bin/python" "$H6/.claude/CLAUDE.md"'
# the python line is the account's (for the account's skills), never in a folder's own files
PD="$T/pyproj"; mkdir -p "$PD"; PD=$(cd "$PD" && pwd -P); printf '# mine\n' > "$PD/CLAUDE.md"; cp "$PD/CLAUDE.md" "$T/pd.orig"
kit add --dir "$PD" skill pyskill >/dev/null 2>&1
check "add --dir with kit's venv: the folder's copy gets .venv, its CLAUDE.md is not touched" '[ -L "$PD/.claude/skills/pyskill/.venv" ] && cmp -s "$PD/CLAUDE.md" "$T/pd.orig" && [ ! -e "$PD/AGENTS.md" ]'
kit rm --dir "$PD" skill pyskill >/dev/null 2>&1
check "rm --dir with kit's venv: the folder exactly as before" 'cmp -s "$PD/CLAUDE.md" "$T/pd.orig" && [ "$(cd "$PD" && ls -A | tr "\n" " ")" = "CLAUDE.md " ]'
kit rm skill pyskill >/dev/null 2>&1
check "python line: gone with the skill (kit's venv stays)" '[ -x "$S7/venv/bin/python" ] && ! grep -qF ".venv/bin/python" "$H6/.claude/CLAUDE.md" 2>/dev/null'
kit add skill pyskill >/dev/null 2>&1
check "packages (pip): installed now; kit.ps1 sees the same" 'pk pyskill pip | grep -qF "\"ok\": true" && { [ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]; }'
out=$(kit sync 2>&1)
check "sync (pip): the link is not a change to the skill" '! echo "$out" | grep -q "手動" && [ -L "$C7/.venv" ]'
printf 'requests==2.33.0\n' > "$NT/skills/pyskill/requirements.txt"; kit sync >/dev/null 2>&1
check "pip: requirements changed -> 更新, the new copy has no old venv" 'pk pyskill pip | grep -qF "\"had\": true" && pk pyskill pip | grep -qF "\"ok\": false" && [ ! -e "$C7/.venv" ]'
printf '#!/bin/sh\n[ "$1 $2" = "-m venv" ] || exec "%s" "$@"\nmkdir -p "$3/bin" && printf "#!/bin/sh\\nexit 4\\n" > "$3/bin/python" && chmod +x "$3/bin/python"\n' "$REALPY" > "$FB/python3"
out=$(kit install-deps pyskill pip 2>&1); rc=$?
check "install-deps (pip): pip fails -> the old venv stays" '[ $rc -ne 0 ] && echo "$out" | grep -qF "裝套件失敗" && [ -f "$S7/.kit-src/requirements.txt" ] && grep -q 2.32.0 "$S7/.kit-src/requirements.txt" && [ ! -e "$S7.old" ]'
printf '#!/bin/sh\n[ "$1 $2" = "-m venv" ] || exec "%s" "$@"\nmkdir -p "$3/bin" && printf "#!/bin/sh\\necho started > %s/pip.started\\nexec sleep 32\\n" > "$3/bin/python" && chmod +x "$3/bin/python"\n' "$REALPY" "$T" > "$FB/python3"
set -m; kit install-deps pyskill pip >/dev/null 2>&1 & kp=$!; set +m
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/pip.started" ] && break; sleep 0.5; done
kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
check "install-deps (pip): stopped halfway (Ctrl-C) -> the old venv back, no lock left" '[ -e "$T/pip.started" ] && grep -q 2.32.0 "$S7/.kit-src/requirements.txt" && [ -x "$S7/venv/bin/python" ] && [ ! -e "$S7.old" ] && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
if [ -n "$PWSH" ]; then
    rm -f "$T/pip.started"
    set -m; kps install-deps pyskill pip >/dev/null 2>&1 & kp=$!; set +m
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/pip.started" ] && break; sleep 0.5; done
    kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
    check "install-deps (pip, kit.ps1): stopped halfway (Ctrl-C) -> the old venv back, no lock left" '[ -e "$T/pip.started" ] && grep -q 2.32.0 "$S7/.kit-src/requirements.txt" && [ -x "$S7/venv/bin/python" ] && [ ! -e "$S7.old" ] && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
fi
out=$(kit install-deps pyskill npm 2>&1)
check "install-deps <skill> npm: only that kind" 'echo "$out" | grep -qF "不用另外裝套件"'
rm -f "$FB/python3"
kit uninstall >/dev/null 2>&1
check "uninstall: kit's packages go too" '[ ! -e "$H6/.config/agentkit/deps" ] && [ ! -e "$H6/.config/agentkit/pydeps" ] && ! grep -qF ".venv/bin/python" "$H6/.claude/CLAUDE.md" 2>/dev/null'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

# ---------- how full an agent's context is (kit context, kit statusline) ----------
H7="$T/home7"; P7="$T/ctxproj"; mkdir -p "$H7" "$P7"; P7=$(cd "$P7" && pwd -P)
(
export HOME="$H7"
mkdir -p "$H7/.codex/sessions/2026/11/12" "$H7/.omp/agent/sessions/x" "$H7/.claude/projects/$(printf '%s' "$P7" | sed 's|[^A-Za-z0-9]|-|g')"
RO="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T01-00-00-abc.jsonl"
printf '{"timestamp":"t","type":"session_meta","payload":{"id":"abc","cwd":"%s","originator":"codex-tui"}}\n' "$P7" > "$RO"
printf '{"type":"turn_context","payload":{"cwd":"%s","model":"gpt-6-luna"}}\n' "$P7" >> "$RO"
for u in 13878 48813; do printf '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"total_tokens":412129},"last_token_usage":{"input_tokens":48732,"cached_input_tokens":48512,"output_tokens":81,"total_tokens":%s},"model_context_window":258400}}}\n' "$u" >> "$RO"; done
printf '{"type":"session_meta","payload":{"id":"zzz","cwd":"/elsewhere"}}\n' > "$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T02-00-00-zzz.jsonl"
CX() { kit context "$@" 2>&1; }
out=$(CX --pid 1 --tool codex --dir "$P7")
check "context (codex): the folder's newest rollout, its last turn; % the way Codex counts it (85% left)" '[ "$out" = "{\"tool\": \"codex\", \"used\": 48813, \"window\": 258400, \"pct\": 15, \"source\": \"rollout\", \"model\": \"gpt-6-luna\"}" ]'
OS="$H7/.omp/agent/sessions/x/2026-11-12T01-00-00-000Z_s1.jsonl"
printf '{"type":"title","title":"secret words"}\n{"type":"session","version":3,"id":"s1","cwd":"%s"}\n{"type":"model_change","model":"anthropic/claude-opus-5-5"}\n' "$P7" > "$OS"
printf '{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":4,"output":12,"cacheRead":149319,"cacheWrite":222},"contextSnapshot":{"promptTokens":149545,"compactionEpoch":0},"stopReason":"stop"}}\n' >> "$OS"
printf '{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"0123456789abcdef\\"23"},{"type":"image","data":"%s","mimeType":"image/png"}],"details":{"text":"%s"}}}\n' "$(printf '%0600d' 0)" "$(printf '%0900d' 0)" >> "$OS"
printf '{"type":"message","message":{"role":"assistant","usage":{"input":9,"cacheRead":900000},"stopReason":"aborted"}}\n' >> "$OS"
out=$(CX --pid 1 --tool omp --dir "$P7")
check "context (omp): its last finished reply (not an aborted one), plus what came after it like omp's footer (text / 4, an image 1600)" '[ "$out" = "{\"tool\": \"omp\", \"used\": $((149545 + 20 / 4 + 1600)), \"window\": 1000000, \"pct\": 15, \"source\": \"session\", \"model\": \"anthropic/claude-opus-5-5\"}" ]'
printf '{"type":"compaction","summary":"x","tokensBefore":150000,"tokensAfter":20000}\n' >> "$OS"
out=$(CX --pid 1 --tool omp --dir "$P7")
check "context (omp): compacted since -> the size after it" 'echo "$out" | grep -qF "\"used\": 20000, \"window\": 1000000, \"pct\": 2"'
CT="$H7/.claude/projects/$(printf '%s' "$P7" | sed 's|[^A-Za-z0-9]|-|g')/t1.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1146,"cache_read_input_tokens":241932,"output_tokens":484}}}\n' > "$CT"
printf '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' >> "$CT"
mkdir -p "$H7/.claude"; printf '{\n  "modelSettings": {\n    "claude-opus-5-5": {\n      "autoCompactWindow": 400000\n    }\n  }\n}\n' > "$H7/.claude/settings.json"
out=$(CX --pid 1 --tool claude-code --dir "$P7")
check "context (claude, no status line): the transcript (not a <synthetic> reply), the window from autoCompactWindow" '[ "$out" = "{\"tool\": \"claude\", \"used\": 243080, \"window\": 400000, \"pct\": 61, \"source\": \"transcript\", \"model\": \"claude-opus-5-5\"}" ]'
printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":390000,"postTokens":19421}}\n' >> "$CT"
out=$(CX --pid 1 --tool claude --dir "$P7")
check "context (claude): compacted since -> the size after it" 'echo "$out" | grep -qF "\"used\": 19421, \"window\": 400000, \"pct\": 5"'
# kit statusline under a "claude" process keeps the numbers for that process; kit context prefers them
printf '{"session_id":"abc","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"total_input_tokens":5,"context_window_size":400000,"current_usage":{"input_tokens":2,"output_tokens":9,"cache_creation_input_tokens":1146,"cache_read_input_tokens":138452},"used_percentage":34.9}}' > "$T/sl.json"
mkdir -p "$T/fb7"; printf '#!/bin/sh\necho $$ > "%s/cpid"\n"%s" statusline < "%s/sl.json"\n' "$T" "$KIT" "$T" > "$T/fb7/claude"; chmod +x "$T/fb7/claude"
out=$("$T/fb7/claude"); cp=$(cat "$T/cpid")
check "statusline: a short line for Claude" '[ "$out" = "Opus 5.5 · context 35%（139k / 400k）" ]'
check "statusline: the numbers kept for that Claude process" '[ -f "$H7/.config/agentkit/ctx/claude-$cp.json" ]'
out=$(CX --pid "$cp" --tool claude --dir "$P7")
check "context (claude): what the status line kept wins" '[ "$out" = "{\"tool\": \"claude\", \"used\": 139600, \"window\": 400000, \"pct\": 35, \"source\": \"statusline\", \"model\": \"claude-opus-5-5\"}" ]'
# the window: what settings.json tells Claude Code (autoCompactWindow), as Claude's own /context shows, not the status line's
SID=0a1b2c3d-1111-2222-3333-444455556666; PD7="$H7/.claude/projects/$(printf '%s' "$P7" | sed 's|[^A-Za-z0-9]|-|g')"; TS7="$PD7/$SID.jsonl"
printf '{"pid": %s, "session": "%s", "used": 130000, "window": 1000000, "pct": 13, "model": "claude-opus-5-5", "transcript": "%s", "cwd": "%s"}\n' "$$" "$SID" "$TS7" "$P7" > "$H7/.config/agentkit/ctx/claude-$$.json"
out=$(CX --pid $$ --tool claude --dir "$P7")
check "context (claude): the window set in settings.json (autoCompactWindow) wins over the status line's" '[ "$out" = "{\"tool\": \"claude\", \"used\": 130000, \"window\": 400000, \"pct\": 33, \"source\": \"statusline\", \"model\": \"claude-opus-5-5\"}" ]'
printf '{"session_id":"%s","transcript_path":"%s","cwd":"/x","workspace":{"current_dir":"/x/sub","project_dir":"%s"},"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1146,"cache_read_input_tokens":138452},"used_percentage":14}}' "$SID" "$TS7" "$P7" > "$T/sl2.json"
mkdir -p "$T/fb9"; printf '#!/bin/sh\necho $$ > "%s/cpid9"\n"%s" statusline < "%s/sl2.json"\n' "$T" "$KIT" "$T" > "$T/fb9/claude"; chmod +x "$T/fb9/claude"
out=$("$T/fb9/claude"); cp9=$(cat "$T/cpid9")
check "statusline: the session, its transcript and folder kept too; the line uses the window from settings.json" '[ "$out" = "Opus 5.5 · context 35%（139k / 400k）" ] && grep -qF "\"session\": \"$SID\"" "$H7/.config/agentkit/ctx/claude-$cp9.json" && grep -qF "\"transcript\": \"$TS7\", \"cwd\": \"$P7\"}" "$H7/.config/agentkit/ctx/claude-$cp9.json"'
# kit context --detail (Claude): a fake claude answers Claude Code's control requests
FC="$T/fakeclaude"; mkdir -p "$FC"
cat > "$FC/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/claude-args"; pwd -P >> "$T/claude-cwd"
[ -z "\${FAKE_SLEEP:-}" ] || sleep "\$FAKE_SLEEP"
while IFS= read -r l; do
    case \$l in
        *'"request_id":"i1"'*) printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"i1","response":{"account":{"email":"secret@example.com"}}}}';;
        *'"request_id":"c1"'*) cat "$T/c1.json";;
    esac
done
EOF
chmod +x "$FC/claude"
cat > "$T/c1.json" <<EOF
{"type":"control_response","response":{"subtype":"success","request_id":"c1","response":{"categories":[{"id":"system_prompt","name":"System prompt","tokens":4000,"color":"promptBorder","kind":"used"},{"id":"system_tools","name":"System tools","tokens":6000,"color":"inactive","kind":"used"},{"id":"system_tools_deferred","name":"System tools (deferred)","tokens":13000,"color":"inactive","isDeferred":true,"kind":"deferred"},{"id":"mcp_tools","name":"MCP tools","tokens":3000,"color":"cyan","kind":"used"},{"id":"memory_files","name":"Memory files","tokens":1200,"color":"claude","kind":"used"},{"id":"skills","name":"Skills","tokens":800,"color":"warning","kind":"used"},{"id":"messages","name":"Messages","tokens":100000,"color":"purple","kind":"used"},{"id":"autocompact_buffer","name":"Autocompact buffer","tokens":33000,"color":"inactive","kind":"buffer"},{"id":"free_space","name":"Free space","tokens":252000,"color":"promptBorder","kind":"free"}],"totalTokens":115000,"maxTokens":400000,"rawMaxTokens":400000,"autocompactSource":"settings","percentage":29,"gridRows":[[{"color":"x","isFilled":true}]],"model":"claude-opus-5-5","memoryFiles":[{"path":"$H7/.claude/CLAUDE.md","type":"User","tokens":200},{"path":"$P7/CLAUDE.md","type":"Project","tokens":1000}],"mcpTools":[{"name":"mcp__gerrit__a","serverName":"gerrit","tokens":1000,"isLoaded":true},{"name":"mcp__gerrit__b","serverName":"gerrit","tokens":1500,"isLoaded":false},{"name":"mcp__kitping__ping","serverName":"kitping","tokens":500,"isLoaded":true}],"mcpInstructions":[],"agents":[{"agentType":"gerrit","source":"userSettings","tokens":120}],"slashCommands":{"totalCommands":5,"includedCommands":5,"tokens":300},"skills":{"totalSkills":2,"includedSkills":2,"tokens":800,"skillFrontmatter":[{"name":"tiny","source":"projectSettings","path":"$P7/.claude/skills/tiny/SKILL.md","tokens":300},{"name":"gerrit-review","source":"userSettings","path":"$H7/.claude/skills/gerrit-review/SKILL.md","tokens":500}]},"autoCompactThreshold":367000,"isAutoCompactEnabled":true,"messageBreakdown":{"toolCallTokens":1,"toolResultTokens":2,"toolCallsByType":[{"name":"Bash","callTokens":1,"resultTokens":2}],"attachmentsByType":[]},"apiUsage":{"input_tokens":2,"output_tokens":3,"cache_creation_input_tokens":4,"cache_read_input_tokens":5}}}}
EOF
# its transcript: what came before the compaction does not count; an image is about 1600, not its bytes
{
    printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_old","name":"Bash","input":{"command":"%s"}}],"stop_reason":"tool_use","usage":{"input_tokens":5}},"uuid":"u1"}\n' "$(printf '%0800d' 0)"
    printf '{"parentUuid":"u1","isSidechain":false,"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":300000,"postTokens":9000},"uuid":"u2"}\n'
    printf '{"parentUuid":"u2","isSidechain":false,"type":"user","message":{"role":"user","content":"%s"},"isCompactSummary":true,"uuid":"u3"}\n' "$(printf '%0400d' 0)"
    printf '{"parentUuid":"u3","isSidechain":false,"type":"user","message":{"role":"user","content":"look at this"},"uuid":"u4","timestamp":"t"}\n'
    printf '{"parentUuid":"u4","isSidechain":false,"type":"attachment","attachment":{"type":"skill_listing","content":"%s"},"rendered":[{"content":"%s"}],"renderedRole":"system","uuid":"u5"}\n' "$(printf '%0400d' 0)" "$(printf '%0400d' 0)"
    printf '{"parentUuid":"u5","isSidechain":false,"type":"attachment","attachment":{"type":"file","filename":"x"},"rendered":[{"content":"%s"}],"renderedRole":"user","uuid":"u6"}\n' "$(printf '%0200d' 0)"
    printf '{"parentUuid":"u6","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"%s","signature":"sig"},{"type":"text","text":"reading it"},{"type":"tool_use","id":"toolu_r1","name":"Read","input":{"file_path":"/x/a.png"}}],"stop_reason":"tool_use","usage":{"input_tokens":5}},"uuid":"u7"}\n' "$(printf '%0900d' 0)"
    printf '{"parentUuid":"u7","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_r1","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"%s"}}]}]},"uuid":"u8","toolUseResult":{"file":"%s"}}\n' "$(printf '%09000d' 0)" "$(printf '%09000d' 0)"
} > "$TS7"
rm -f "$T/claude-args" "$T/claude-cwd"
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail)
dj_claude=$out
check "context --detail (claude): Claude Code asked with every hook off, nothing kept, its session, in its folder" 'grep -qF -- "--resume $SID --no-session-persistence --settings {\"disableAllHooks\":true}" "$T/claude-args" && [ "$(cat "$T/claude-cwd")" = "$P7" ] && ! echo "$out" | grep -q secret@'
check "context --detail (claude): its numbers, the live total wins (the rest is its own row), the window from settings.json" 'echo "$out" | grep -qF "{\"tool\": \"claude\", \"used\": 130000, \"window\": 400000, \"pct\": 33, \"source\": \"get_context_usage\", \"model\": \"claude-opus-5-5\", \"at\": " && echo "$out" | grep -qF "\"exact\": true, \"session\": \"$SID\", \"compact_at\": 367000, \"commands\": {\"compact\": \"/compact\", \"with_text\": true, \"clear\": \"/clear\"}" && echo "$out" | grep -qF "\"error\": null"'
check "context --detail (claude): the categories in Chinese, deferred kept apart, free space what is left" 'echo "$out" | grep -qF "\"categories\": [{\"id\": \"system_prompt\", \"name\": \"系統提示\", \"tokens\": 4000, \"kind\": \"used\", \"est\": false}, {\"id\": \"system_tools\", \"name\": \"系統工具\", \"tokens\": 6000, \"kind\": \"used\", \"est\": false}, {\"id\": \"system_tools_deferred\", \"name\": \"系統工具（延後載入）\", \"tokens\": 13000, \"kind\": \"deferred\", \"est\": false}, {\"id\": \"mcp_tools\", \"name\": \"MCP 工具\", \"tokens\": 3000, \"kind\": \"used\", \"est\": false}, {\"id\": \"memory_files\", \"name\": \"記憶檔\", \"tokens\": 1200, \"kind\": \"used\", \"est\": false}, {\"id\": \"skills\", \"name\": \"Skills\", \"tokens\": 800, \"kind\": \"used\", \"est\": false}, {\"id\": \"messages\", \"name\": \"對話訊息\", \"tokens\": 100000, \"kind\": \"used\", \"est\": false}, {\"id\": \"other\", \"name\": \"其他／自上次更新以來\", \"tokens\": 15000, \"kind\": \"used\", \"est\": false}, {\"id\": \"autocompact_buffer\", \"name\": \"自動壓縮保留區\", \"tokens\": 33000, \"kind\": \"buffer\", \"est\": false}, {\"id\": \"free_space\", \"name\": \"可用空間\", \"tokens\": 237000, \"kind\": \"free\", \"est\": false}]"'
check "context --detail (claude): memory files, skills, MCP by server (its tools inside), agents, commands; most first" 'echo "$out" | grep -qF "{\"id\": \"memory\", \"name\": \"記憶檔\", \"tokens\": 1200, \"est\": false, \"items\": [{\"name\": \"$P7/CLAUDE.md\", \"tokens\": 1000, \"note\": \"Project\", \"path\": \"$P7/CLAUDE.md\"}, {\"name\": \"~/.claude/CLAUDE.md\", \"tokens\": 200, \"note\": \"User\", \"path\": \"$H7/.claude/CLAUDE.md\"}]}" && echo "$out" | grep -qF "{\"id\": \"skills\", \"name\": \"Skills\", \"tokens\": 800, \"est\": false, \"items\": [{\"name\": \"gerrit-review\", \"tokens\": 500," && echo "$out" | grep -qF "{\"id\": \"mcp\", \"name\": \"MCP（依伺服器）\", \"tokens\": 3000, \"est\": false, \"items\": [{\"name\": \"gerrit\", \"tokens\": 2500, \"note\": \"2 個工具\", \"path\": \"\", \"items\": [{\"name\": \"mcp__gerrit__b\", \"tokens\": 1500, \"note\": \"延後載入\", \"path\": \"\"}, {\"name\": \"mcp__gerrit__a\", \"tokens\": 1000, \"note\": \"已載入\", \"path\": \"\"}]}, {\"name\": \"kitping\", \"tokens\": 500," && echo "$out" | grep -qF "{\"id\": \"agents\", \"name\": \"自訂 agents\", \"tokens\": 120," && echo "$out" | grep -qF "{\"name\": \"5 個指令\", \"tokens\": 300,"'
tr_items=$(echo "$out" | sed -n 's/.*"id": "tool_results", "name": "[^"]*", "tokens": [0-9]*, "est": true, "items": \[\([^]]*\)\].*/\1/p')
msg_total=$(echo "$out" | sed -n 's/.*"id": "msgs", "name": "對話內容（依種類）", "tokens": \([0-9]*\),.*/\1/p')
check "context --detail (claude): what was said, estimated after the last compaction and scaled to Claude's own number (thinking and listings not counted)" '[ -n "$msg_total" ] && [ $((msg_total - 100000)) -ge -5 ] && [ $((msg_total - 100000)) -le 5 ] && echo "$tr_items" | grep -qF "\"name\": \"Read\"" && ! echo "$tr_items" | grep -q Bash && echo "$out" | grep -qF "\"name\": \"壓縮後的摘要\"" && echo "$out" | grep -qF "{\"id\": \"attachments\", \"name\": \"附加內容（依種類）\", \"tokens\": " && ! echo "$out" | grep -q skill_listing'
# the image: about 1600 (not its 9000 bytes); the Read result is about 1600 + its bytes / 4, scaled like the rest
n1=$(wc -l < "$T/claude-args")
out2=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail)
check "context --detail: kept a minute (Claude not asked again)" '[ "$(wc -l < "$T/claude-args")" = "$n1" ] && [ "$out2" = "$out" ]'
PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh >/dev/null
check "context --detail --fresh: asked again" '[ "$(wc -l < "$T/claude-args")" -gt "$n1" ]'
t0=$(date +%s); out=$(FAKE_SLEEP=20 KIT_CTX_PROBE_TIMEOUT=2 PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh); t1=$(date +%s)
check "context --detail: Claude Code that does not answer is stopped (timeout), the answer says so, still JSON, estimated" '[ $((t1 - t0)) -lt 10 ] && echo "$out" | grep -qF "\"error\": \"Claude Code 沒有回答" && echo "$out" | grep -qF "\"exact\": false" && echo "$out" | grep -qF "\"used\": 130000, \"window\": 400000" && echo "$out" | grep -qF "\"id\": \"msgs\""'
printf '{"pid": %s, "session": "x;rm -rf y", "used": 1, "window": 2, "pct": 50, "model": "m"}\n' "$$" > "$H7/.config/agentkit/ctx/claude-$$.json"
n1=$(wc -l < "$T/claude-args")
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh)
check "context --detail: a session id with other characters is not used (Claude not run)" '[ "$(wc -l < "$T/claude-args")" = "$n1" ] && echo "$out" | grep -qF "\"error\": \"找不到這個 Claude 的 session\""'
rm -f "$H7/.config/agentkit/ctx/claude-$$.json"
# no status line: ~/.claude/sessions/<pid>.json (older Claude Code), then the daemon roster (only pid / replPid / sessionId / cwd)
mkdir -p "$H7/.claude/sessions" "$H7/.claude/daemon"
printf '{"workers":{"w1":{"pid":1,"replPid":%s,"sessionId":"%s","cwd":"%s","token":"sk-secret-1"}}}\n' "$$" "$SID" "$P7" > "$H7/.claude/daemon/roster.json"
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh)
check "context --detail: the session from the daemon roster (its replPid); its token never shown" 'echo "$out" | grep -qF "\"session\": \"$SID\"" && echo "$out" | grep -qF "\"exact\": true" && ! echo "$out" | grep -q sk-secret'
rm -f "$H7/.claude/daemon/roster.json"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","startedAt":1}\n' "$$" "$SID" "$P7" > "$H7/.claude/sessions/$$.json"
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh)
check "context --detail: the session from ~/.claude/sessions/<pid>.json" 'echo "$out" | grep -qF "\"session\": \"$SID\"" && echo "$out" | grep -qF "\"exact\": true"'
rm -f "$H7/.claude/sessions/$$.json"
# Codex: its rollout, split by what it holds, scaled to its own total
P9="$T/cxproj"; mkdir -p "$P9/.git" "$P9/sub"; P9=$(cd "$P9" && pwd -P); RO9="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T03-00-00-c9.jsonl"
echo "team rules for the repo" > "$P9/AGENTS.md"; echo "only here" > "$P9/sub/AGENTS.md"; printf 'mine\n' > "$H7/.codex/AGENTS.md"
printf '[mcp_servers.kitping]\ncommand = "x"\n[mcp_servers.kitping.env]\nA = "1"\n[mcp_servers."unused"]\ncommand = "y"\n' > "$H7/.codex/config.toml"
{
    printf '{"timestamp":"t","type":"session_meta","payload":{"id":"c9","cwd":"%s/sub","base_instructions":{"text":"You are Codex, %s"}}}\n' "$P9" "$(printf '%0400d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"additional_tools","tools":[{"type":"namespace","name":"functions","description":"core","tools":[{"type":"custom","name":"exec","description":"%s"},{"type":"function","name":"wait","description":"w"}]},{"type":"namespace","name":"mcp__kitping","description":"ping","tools":[{"type":"function","name":"ping","description":"%s"}]}]}}\n' "$(printf '%0800d' 0)" "$(printf '%0200d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are Codex, %s"},{"type":"input_text","text":"<skills_instructions>\\n## Skills\\n### Skill roots\\n- `r0` = `%s/.agents/skills`\\n### Available skills\\n- alpha: does a %s (file: r0/alpha/SKILL.md)\\n- plug:beta: does b (file: r0/beta/SKILL.md)\\n</skills_instructions>"},{"type":"input_text","text":"<tools>\\nDeferred tool namespaces:\\n- mcp__apps__docs: docs %s\\n</tools>"}]}}\n' "$(printf '%0400d' 0)" "$H7" "$(printf '%0100d' 0)" "$(printf '%040d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\\n%s"},{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}\n' "$(printf '%0200d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix it"}]}}\n'
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"%s"}}\n' "$(printf '%02000d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"cmd\\":\\"ls\\"}","call_id":"c1"}}\n'
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"%s"}}\n' "$(printf '%01200d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"%s","call_id":"c2"}}\n' "$(printf '%0300d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":"ok"}}\n'
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done %s"}]}}\n' "$(printf '%0100d' 0)"
    printf '{"timestamp":"t","type":"turn_context","payload":{"cwd":"%s/sub","model":"gpt-6-luna"}}\n' "$P9"
    printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":99999},"last_token_usage":{"input_tokens":20000,"cached_input_tokens":18000,"output_tokens":500,"reasoning_output_tokens":100,"total_tokens":20500},"model_context_window":258400}}}\n'
} > "$RO9"
out=$(CX --pid 1 --tool codex --dir "$P9/sub" --detail)
dj_codex=$out
sum=0; for n in $(echo "$out" | sed 's/.*"categories": \[//; s/\], "groups".*//' | grep -o '"tokens": [0-9]*, "kind": "used"' | grep -o '[0-9]*'); do sum=$((sum + n)); done
check "context --detail (codex): Codex's own total and %, its commands (/compact takes no text here, /new)" 'echo "$out" | grep -qF "{\"tool\": \"codex\", \"used\": 20500, \"window\": 258400, \"pct\": 3, \"source\": \"rollout\", \"model\": \"gpt-6-luna\", \"at\": " && echo "$out" | grep -qF "\"exact\": false" && echo "$out" | grep -qF "\"commands\": {\"compact\": \"/compact\", \"with_text\": false, \"clear\": \"/new\"}"'
check "context --detail (codex): the parts add up to its total exactly" '[ "$sum" = 20500 ] && echo "$out" | grep -qF "{\"id\": \"free_space\", \"name\": \"可用空間\", \"tokens\": 237900, \"kind\": \"free\", \"est\": false}"'
check "context --detail (codex): AGENTS.md files from the git root down (and Codex's own), skills with their folder, tools by namespace, MCP (seen, deferred, configured)" 'echo "$out" | grep -qF "\"path\": \"$P9/AGENTS.md\"" && echo "$out" | grep -qF "\"path\": \"$P9/sub/AGENTS.md\"" && echo "$out" | grep -qF "{\"name\": \"~/.codex/AGENTS.md\"" && echo "$out" | grep -qF "{\"name\": \"alpha\", \"tokens\": " && echo "$out" | grep -qF "\"note\": \"~/.agents/skills\", \"path\": \"$H7/.agents/skills/alpha/SKILL.md\"" && echo "$out" | grep -qF "{\"name\": \"plug:beta\"" && echo "$out" | grep -qF "{\"name\": \"functions\", \"tokens\": " && echo "$out" | grep -qF "\"note\": \"2 個工具\"" && echo "$out" | grep -qF "{\"name\": \"mcp__kitping\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"mcp__apps__docs\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"unused\", \"tokens\": null, \"note\": \"設定裡有，這次對話沒看到它的工具\""'
check "context --detail (codex): calls and results by tool (reasoning not counted)" 'echo "$out" | grep -qF "{\"name\": \"shell\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"apply_patch\", \"tokens\": " && echo "$out" | grep -qF "\"note\": \"1 次\""'
printf '{"timestamp":"t","type":"compacted","payload":{"message":"%s","replacement_history":[]}}\n' "$(printf '%0400d' 0)" >> "$RO9"
printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":4000},"model_context_window":258400}}}\n' >> "$RO9"
out=$(CX --pid 1 --tool codex --dir "$P9/sub" --detail --fresh)
check "context --detail (codex): compacted -> what came before is gone, the summary counts" 'echo "$out" | grep -qF "\"used\": 4000," && echo "$out" | grep -qF "{\"id\": \"compaction\", \"name\": \"壓縮後的摘要\"" && ! echo "$out" | grep -qF "{\"name\": \"shell\""'
# omp: its own numbers (the conversation, the tools), the rest estimated and scaled
P10="$T/ompproj"; mkdir -p "$P10/.agents/skills/sk1"; P10=$(cd "$P10" && pwd -P); OS10="$H7/.omp/agent/sessions/y/s10.jsonl"; mkdir -p "$H7/.omp/agent/sessions/y"
printf -- '---\nname: sk1\ndescription: %s\n---\nbody\n' "$(printf '%0200d' 0)" > "$P10/.agents/skills/sk1/SKILL.md"; echo "omp rules" > "$H7/.omp/agent/AGENTS.md"; echo "repo rules" > "$P10/AGENTS.md"
printf '{"mcpServers":{"gerrit":{"command":"x"}}}\n' > "$H7/.omp/agent/mcp.json"
{
    printf '{"type":"session","version":3,"id":"s10","cwd":"%s"}\n{"type":"model_change","id":"m0","model":"anthropic/claude-opus-5-5"}\n' "$P10"
    printf '{"type":"message","id":"e1","message":{"role":"user","content":[{"type":"text","text":"old question %s"}]}}\n' "$(printf '%0800d' 0)"
    printf '{"type":"message","id":"e2","message":{"role":"user","content":[{"type":"text","text":"kept question"}]}}\n'
    printf '{"type":"message","id":"e3","message":{"role":"assistant","content":[{"type":"thinking","thinking":"%s"},{"type":"text","text":"ok"},{"type":"toolCall","id":"tc1","name":"read","arguments":{"path":"/x"}}],"usage":{"input":1},"contextSnapshot":{"promptTokens":50000,"nonMessageTokens":12000,"toolSchemaTokens":8000,"compactionEpoch":0},"stopReason":"toolUse"}}\n' "$(printf '%0500d' 0)"
    printf '{"type":"message","id":"e4","message":{"role":"toolResult","toolCallId":"tc1","toolName":"read","content":[{"type":"text","text":"%s"}],"details":{"x":"%s"}}}\n' "$(printf '%02000d' 0)" "$(printf '%09000d' 0)"
    printf '{"type":"compaction","id":"k1","summary":"%s","firstKeptEntryId":"e2","tokensBefore":60000,"tokensAfter":30000}\n' "$(printf '%0400d' 0)"
    printf '{"type":"custom_message","id":"x1","customType":"todo-nudge","content":"remember %s","display":false}\n' "$(printf '%0100d' 0)"
} > "$OS10"
out=$(CX --pid 1 --tool omp --dir "$P10" --detail)
dj_omp=$out
sum=0; for n in $(echo "$out" | sed 's/.*"categories": \[//; s/\], "groups".*//' | grep -o '"tokens": [0-9]*, "kind": "used"' | grep -o '[0-9]*'); do sum=$((sum + n)); done
check "context --detail (omp): omp's total (after the compaction), its tools exactly, /compact with text, /new" 'echo "$out" | grep -qF "{\"tool\": \"omp\", \"used\": 30000, \"window\": " && echo "$out" | grep -qF "\"source\": \"session\", \"model\": \"anthropic/claude-opus-5-5\"" && echo "$out" | grep -qF "{\"id\": \"system_tools\", \"name\": \"系統工具\", \"tokens\": 8000, \"kind\": \"used\", \"est\": false}" && echo "$out" | grep -qF "\"commands\": {\"compact\": \"/compact\", \"with_text\": true, \"clear\": \"/new\"}"'
check "context --detail (omp): the parts add up to its total; instruction files, skills, MCP from its settings, tools by name, what omp adds" '[ "$sum" = 30000 ] && echo "$out" | grep -qF "{\"name\": \"~/.omp/agent/AGENTS.md\"" && echo "$out" | grep -qF "\"path\": \"$P10/AGENTS.md\"" && echo "$out" | grep -qF "{\"name\": \"sk1\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"gerrit\", \"tokens\": null, \"note\": \"設定的 MCP" && echo "$out" | grep -qF "{\"name\": \"read\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"todo-nudge\", \"tokens\": " && echo "$out" | grep -qF "{\"id\": \"compaction\", \"name\": \"壓縮後的摘要\""'
if [ -n "$PWSH" ]; then
    printf '{"pid": %s, "session": "%s", "used": 130000, "window": 1000000, "pct": 13, "model": "claude-opus-5-5", "transcript": "%s", "cwd": "%s"}\n' "$$" "$SID" "$TS7" "$P7" > "$H7/.config/agentkit/ctx/claude-$$.json"
    same=1
    for a in "--pid $$ --tool claude --dir $P7" "--pid 1 --tool codex --dir $P9/sub" "--pid 1 --tool omp --dir $P10" "--pid 1 --tool codex --dir $P10"; do
        x=$(PATH="$FC:$PATH" kit context $a --detail --fresh 2>&1 | sed 's/"at": [0-9]*/"at": 0/')
        y=$(PATH="$FC:$PATH" kps context $a --detail --fresh 2>&1 | sed 's/"at": [0-9]*/"at": 0/')
        [ "$x" = "$y" ] || { same=0; echo "  differs: $a"; printf '%s\n' "$x" | tr ',' '\n' > "$T/dx"; printf '%s\n' "$y" | tr ',' '\n' > "$T/dy"; diff "$T/dx" "$T/dy" | head -n 6; }
    done
    check "context --detail: kit.ps1 says the same (Claude, Codex, omp, nothing found)" '[ $same = 1 ]'
    out=$(kps context --pid $$ --tool claude --dir "$P7" 2>&1); out2=$(kps statusline < "$T/sl2.json" 2>/dev/null)
    check "context, statusline (kit.ps1): the window set in settings.json (autoCompactWindow) too" '[ "$out" = "{\"tool\": \"claude\", \"used\": 130000, \"window\": 400000, \"pct\": 33, \"source\": \"statusline\", \"model\": \"claude-opus-5-5\"}" ] && [ "$out2" = "Opus 5.5 · context 35%（139k / 400k）" ]'
    rm -f "$H7/.config/agentkit/ctx/claude-$$.json"
fi
big=$(printf '%0400d' 0)
printf '{"type":"user","message":{"content":"%s"}}\n' "$big" >> "$CT"
printf '{"type":"event_msg","payload":{"type":"agent_message","message":"%s"}}\n' "$big" >> "$RO"
printf '{"type":"note","text":"%s"}\n' "$big" >> "$OS"
same=1
for a in "--tool codex" "--tool omp" "--tool claude"; do
    [ "$(KIT_CTX_TAIL=100 kit context --pid 1 $a --dir "$P7" 2>&1)" = "$(kit context --pid 1 $a --dir "$P7" 2>&1)" ] || { same=0; echo "  differs: $a"; }
done
check "context: a long log is read from its end; nothing there -> all of it, the same answer" '[ $same = 1 ]'
P8="$T/ctxfull"; mkdir -p "$P8"; P8=$(cd "$P8" && pwd -P); C8="$H7/.claude/projects/$(printf '%s' "$P8" | sed 's|[^A-Za-z0-9]|-|g')"; mkdir -p "$C8"
printf '{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":250000}}}\n' > "$C8/t.jsonl"
out=$(CX --pid 1 --tool claude --dir "$P8")
check "context: past the window -> 100 %" '[ "$out" = "{\"tool\": \"claude\", \"used\": 250000, \"window\": 200000, \"pct\": 100, \"source\": \"transcript\", \"model\": \"claude-sonnet-4-5\"}" ]'
out=$(capped 10 kit context --pid 2>&1); rc=$?
check "context: --pid with nothing after it -> how to use it (not a hang)" '[ $rc -eq 1 ] && echo "$out" | grep -qF "用法：kit context"'
if [ -n "$PWSH" ]; then
    same=1
    for a in "--pid 1 --tool codex --dir $P7" "--pid 1 --tool omp --dir $P7" "--pid 1 --tool claude --dir $P7" "--pid $cp --tool claude --dir $P7" "--pid 1 --tool claude --dir $P8"; do
        [ "$(kit context $a 2>&1)" = "$(kps context $a 2>&1)" ] || { same=0; echo "  differs: $a"; }
        [ "$(KIT_CTX_TAIL=100 kit context $a 2>&1)" = "$(KIT_CTX_TAIL=100 kps context $a 2>&1)" ] || { same=0; echo "  differs (tail): $a"; }
    done
    check "context: kit.ps1 says the same" '[ $same = 1 ]'
    out=$(kps statusline < "$T/sl.json")
    check "statusline: kit.ps1 prints the same line" '[ "$out" = "Opus 5.5 · context 35%（139k / 400k）" ]'
fi
echo '{}' > "$H7/.config/agentkit/ctx/claude-999999.json"
CX --pid 1 --tool claude --dir "$P7" >/dev/null
check "context: numbers of a Claude process that is gone are thrown away" '[ ! -e "$H7/.config/agentkit/ctx/claude-999999.json" ]'
out=$(CX --pid 1)
check "context: not an agent -> nothing" '[ "$out" = "{\"tool\": \"\", \"used\": null, \"window\": null, \"pct\": null, \"source\": \"\", \"model\": \"\"}" ]'
# the statusLine in settings.json: kit's when there is none, never over your own, gone again on uninstall
cp "$H7/.claude/settings.json" "$T/s7.orig"
mkdir -p "$T/src7/skills/a"; printf -- '---\nname: a\ndescription: a\n---\nx\n' > "$T/src7/skills/a/SKILL.md"
kit init "$T/src7" >/dev/null 2>&1
check "sync: kit's statusLine in settings.json" 'jget "$H7/.claude/settings.json" statusLine.command | grep -q "statusline" && jget "$H7/.claude/settings.json" modelSettings.claude-opus-5-5.autoCompactWindow | grep -q 400000'
# you take kit's statusLine out: it stays out (kit says so once); kit sync --force puts it back
printf 'del\tstatusLine\n' > "$T/ops7"; LC_ALL=C awk -f "$JA" -v ops="$T/ops7" "$H7/.claude/settings.json" > "$T/s7.new" && cp "$T/s7.new" "$H7/.claude/settings.json"
out=$(kit sync 2>&1)
check "statusLine taken out by you: not put back, kit says so (once) and how to get it back" '! jget "$H7/.claude/settings.json" statusLine >/dev/null && echo "$out" | grep -qF "kit sync --force" && ! kit sync 2>&1 | grep -q statusLine && ! jget "$H7/.claude/settings.json" statusLine >/dev/null'
kit sync --force >/dev/null 2>&1
check "kit sync --force: kit's statusLine back" 'jget "$H7/.claude/settings.json" statusLine.command | grep -q statusline'
if [ -n "$PWSH" ]; then
    LC_ALL=C awk -f "$JA" -v ops="$T/ops7" "$H7/.claude/settings.json" > "$T/s7.new" && cp "$T/s7.new" "$H7/.claude/settings.json"
    out=$(kps sync 2>&1)
    check "statusLine taken out by you (kit.ps1): not put back, says so; --force puts it back" '! jget "$H7/.claude/settings.json" statusLine >/dev/null && echo "$out" | grep -qF "kit sync --force" && ! kps sync 2>&1 | grep -q statusLine && kps sync --force >/dev/null 2>&1 && jget "$H7/.claude/settings.json" statusLine.command | grep -q statusline'
    kit sync --force >/dev/null 2>&1                         # (kit's own command and hook again, for uninstall below)
fi
kit uninstall >/dev/null 2>&1
check "uninstall: settings.json exactly as before, kit's numbers gone" 'cmp -s "$H7/.claude/settings.json" "$T/s7.orig" && [ ! -e "$H7/.config/agentkit/ctx" ]'
printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "my-line"\n  }\n}\n' > "$H7/.claude/settings.json"; cp "$H7/.claude/settings.json" "$T/s7.own"
out=$(kit init "$T/src7" 2>&1)
check "sync: your own statusLine stays, kit says so once" '[ "$(jget "$H7/.claude/settings.json" statusLine.command)" = "\"my-line\"" ] && echo "$out" | grep -q "statusLine" && ! kit sync 2>&1 | grep -q "statusLine"'
kit uninstall >/dev/null 2>&1
check "uninstall: your own statusLine stays" 'cmp -s "$H7/.claude/settings.json" "$T/s7.own"'
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
sed -i.bak "/^maintainers:/d" "$CO/kit.yaml"; rm -f "$CO/kit.yaml.bak"
# no --path: the only SKILL.md in the repo; several: kit lists them; --look says it all as JSON without writing anything
U2="$T/up-two"; mkdir -p "$U2/a" "$U2/b" "$U2/.hidden/c" "$U2/node_modules/d"
for x in a b .hidden/c node_modules/d; do printf -- '---\nname: %s\ndescription: say "%s" now\n---\nx\n' "${x##*/}" "${x##*/}" > "$U2/$x/SKILL.md"; done
echo 'echo' > "$U2/a/run.sh"; cp "$UP/LICENSE" "$U2/LICENSE"
( cd "$U2" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm x )
U1="$T/up-one"; mkdir -p "$U1/deep/one"; printf -- '---\nname: one\ndescription: o\n---\nx\n' > "$U1/deep/one/SKILL.md"; cp "$UP/LICENSE" "$U1/LICENSE"
( cd "$U1" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm x )
printf 'name: collector\ncollect_sources: [file://%s, file://%s]\n' "$U2" "$U1" > "$CO/kit.yaml"
cd "$CO"; rm -rf "$CO/skills/foo" "$CO/third_party.lock"
out=$(kit collect "file://$U1" 2>&1); rc=$?
check "collect without --path finds the only SKILL.md" '[ $rc -eq 0 ] && [ -f "$CO/skills/one/SKILL.md" ] && grep -q "^one	.*	deep/one	" "$CO/third_party.lock"'
out=$(kit collect "file://$U2" 2>&1); rc=$?
check "collect without --path, several skills: lists them, collects nothing" '[ $rc -ne 0 ] && echo "$out" | grep -q "  a$" && echo "$out" | grep -q "  b$" && ! echo "$out" | grep -q hidden && [ ! -e "$CO/skills/a" ]'
before=$(cd "$CO" && find . -type f | sort | xargs cksum)
out=$(kit collect "file://$U2" --look 2>/dev/null); rc=$?
v=$(printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["allowed"],d["can_allow"],";".join(s["path"]+","+s["name"]+","+s["description"]+","+s["license"]+","+s["scripts"]+","+s["exists"] for s in d["skills"]))' 2>&1)
check "collect --look: every skill, as JSON" '[ $rc -eq 0 ] && [ "$v" = "True False a,a,say \"a\" now,MIT,run.sh,;b,b,say \"b\" now,MIT,," ]'
check "collect --look writes nothing" '[ "$before" = "$(cd "$CO" && find . -type f | sort | xargs cksum)" ]'
out=$(kit collect "file://$UP" --look 2>&1); rc=$?
check "collect --look on an author not on the list of a team source (no --allow): says so, downloads nothing" '[ $rc -ne 0 ] && echo "$out" | grep -q "不在 collect_sources" && echo "$out" | grep -q 不下載 && ! echo "$out" | grep -q "\"skills\""'
out=$(kit collect "file://$UP" --look 2>/dev/null); rc=$?
check "collect --look: error not_allowed, only JSON on stdout" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"not_allowed\", \"message\": \".*不下載" && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ]'
out=$(kit collect "file://$UP" --path skills/foo --allow 2>&1); rc=$?
check "collect --allow refused in a team source (no push: direct)" '[ $rc -ne 0 ] && echo "$out" | grep -q "push: direct" && [ ! -e "$CO/skills/foo" ]'
# your own source: --allow adds the author to collect_sources ([a, b] on one line, or - lines, or no list yet)
# (allowed_hosts listed: a file:/// folder on this machine has no host, so it is not refused)
printf 'name: collector\npush: direct\nallowed_hosts: [gitea.example]\ncollect_sources: [file://%s]   # authors\n' "$U2" > "$CO/kit.yaml"
v=$(kit collect "file://$UP" --look 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["can_allow"])')
check "collect --look: your own source can add the author" '[ "$v" = True ]'
out=$(kit collect "file://$UP" 2>&1); rc=$?
check "collect without --allow says how to add the author" '[ $rc -ne 0 ] && echo "$out" | grep -q -- "--allow"'
out=$(kit collect "file://$UP" --allow 2>&1); rc=$?
check "collect --allow: collected, the author added to the list on its line" '[ $rc -eq 0 ] && [ -f "$CO/skills/foo/SKILL.md" ] && grep -qxF "collect_sources: [file://$U2, $UP]   # authors" "$CO/kit.yaml"'
out=$(kit collect foo 2>&1); rc=$?
check "after --allow the author is on the list" '[ $rc -eq 0 ]'
printf 'name: collector\npush: direct\ncollect_sources:\n    - file://%s\n\n# more\nrecommended:\n  rules: []\n' "$U2" > "$CO/kit.yaml"
out=$(kit collect "file://$U1" --allow 2>&1); rc=$?
check "collect --allow: a - list gets a - line" '[ $rc -eq 0 ] && [ "$(sed -n 4,5p "$CO/kit.yaml")" = "    - file://$U2
    - $U1" ] && grep -q "^recommended:" "$CO/kit.yaml"'
printf 'name: collector\npush: direct' > "$CO/kit.yaml"
rm -rf "$CO/skills/one"; out=$(kit collect "file://$U1" --allow 2>&1); rc=$?
check "collect --allow: no list yet gets one" '[ $rc -eq 0 ] && [ "$(tail -n 1 "$CO/kit.yaml")" = "collect_sources: [$U1]" ] && grep -qx "push: direct" "$CO/kit.yaml"'
# the host must be in allowed_hosts (the source's own list, else every source's): --look and collect never go elsewhere
printf 'name: collector\npush: direct\nallowed_hosts: [gitea.example]\ncollect_sources: [https://public-git.example/someone]\n' > "$CO/kit.yaml"
out=$(kit collect https://public-git.example/someone/skills --look 2>&1); rc=$?
check "collect --look: a host outside allowed_hosts is refused before anything is downloaded" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單" && ! echo "$out" | grep -q 沒辦法下載'
out=$(kit collect https://public-git.example/someone/skills --look 2>/dev/null); rc=$?
check "collect --look: error host_not_allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"host_not_allowed\", "'
out=$(kit collect https://public-git.example/someone/skills 2>&1); rc=$?
check "collect: a host outside allowed_hosts is refused (the same list)" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單" && ! echo "$out" | grep -q 沒辦法下載'
if [ -n "$PWSH" ]; then
    out=$(kps collect https://public-git.example/someone/skills --look 2>&1); rc=$?
    check "collect --look (kit.ps1): a host outside allowed_hosts is refused the same" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單"'
fi
rm -rf "$CO/skills/one" "$CO/skills/foo" "$CO/third_party.lock"
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

# ---------- api: the output format programs read ----------
out=$(kit api 2>&1); rc=$?
check "api: one line, major.minor (1.0)" '[ $rc -eq 0 ] && [ "$out" = 1.0 ]'
if [ -n "$PWSH" ]; then
    out=$(kps api 2>&1); rc=$?
    check "api: kit.ps1 says the same" '[ $rc -eq 0 ] && [ "$out" = 1.0 ]'
fi
# errors of the commands programs read: JSON on stdout, the words on stderr, exit not 0
out=$(AGENTKIT_CONFIG="$T/noconf" kit list --json 2>"$T/err"); rc=$?
check "list --json before kit init: error not_init on stdout, the words on stderr" '[ $rc -ne 0 ] && [ "$out" = "{\"error\": {\"code\": \"not_init\", \"message\": \"還沒設定：先打  kit init <網址或資料夾>\"}}" ] && grep -q "還沒設定" "$T/err"'
out2=$(AGENTKIT_CONFIG="$T/noconf" kit agents --json 2>/dev/null)
out3=$(kit list --json --bad 2>/dev/null)
check "agents --json before kit init: not_init; a wrong option: usage" '[ "$out2" = "$out" ] && echo "$out3" | grep -q "^{\"error\": {\"code\": \"usage\", "'
if [ -n "$PWSH" ]; then
    check "errors as JSON: kit.ps1 prints the same" '[ "$(AGENTKIT_CONFIG="$T/noconf" kps list --json 2>/dev/null)" = "$out" ] && [ "$(AGENTKIT_CONFIG="$T/noconf" kps agents --json 2>/dev/null)" = "$out" ] && [ "$(kps list --json --bad 2>/dev/null)" = "$out3" ]'
fi

# ---------- help ----------
out=$(kit help 2>&1)
check "help: kit api is there" 'echo "$out" | grep -q "^  kit api  "'
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
if [ "$(uname)" = Darwin ]; then
    IH="$RF/ih"; mkdir -p "$IH"; echo "# mine" > "$IH/.profile"
    HOME="$IH" SHELL=/bin/bash PATH=/usr/bin:/bin AGENTKIT_HOME="$IH/share" sh "$HERE/../unix/install.sh" --quiet >/dev/null 2>&1
    check "install.sh (Mac, bash): no new .bash_profile hiding .profile; .profile gets the PATH line" '[ ! -e "$IH/.bash_profile" ] && grep -q "added by agentkit" "$IH/.profile"'
fi

# ---------- code checks ----------
check "no \$var directly before non-ASCII (bash 3.2 reads it as part of the name)" '! LC_ALL=C grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" "$KIT" "$HERE/../unix/install.sh"'

echo "kit: $pass passed, $fail failed"
[ $fail -eq 0 ]
