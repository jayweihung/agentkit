#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
kit init "$TEAM" >/dev/null 2>&1; kit add skill gerrit-review >/dev/null 2>&1; kit add mcp gerrit >/dev/null 2>&1; kit rm skill gerrit-workflow >/dev/null 2>&1
mkdir -p "$TEAM/skills/team-build"; printf -- '---\nname: team-build\ndescription: b\n---\nx\n' > "$TEAM/skills/team-build/SKILL.md"; kit sync >/dev/null 2>&1
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
printf 'note\r\n# 標題 one\r\n# second\r\n' > "$TEAM/rules/headed.md"
check "list --json: a rule says its first # heading (CRLF too)" 'kit list --json 2>&1 | grep -qF "{\"kind\": \"rule\", \"name\": \"headed\", \"status\": \"unused\", \"new\": true, \"changed\": false, \"source\": \"team\", \"description\": \"標題 one\", \"path\": "'
rm -f "$TEAM/rules/headed.md"
# kit describe: Chinese descriptions for the panel, in the source's descriptions-zh.txt, kept until the description changes
out=$(kit describe --todo 2>&1); rc=$?
check "describe --todo: English descriptions without a Chinese one, not the Chinese ones" '[ $rc -eq 0 ] && printf "%s\n" "$out" | grep -qxF "skill:gerrit-workflow	upstream" && ! printf "%s\n" "$out" | grep -q "^skill:quote	"'
out=$(kit describe skill gerrit-workflow "上游	的
說明" 2>&1); rc=$?
check "describe: written in the source that has it, one line (tabs, line breaks made spaces)" '[ $rc -eq 0 ] && [ "$(cat "$TP/descriptions-zh.txt")" = "skill:gerrit-workflow	$(printf upstream | git hash-object --stdin | cut -c1-12)	上游 的 說明" ]'
kit describe skill gerrit-workflow "上游的說明" >/dev/null 2>&1
check "describe: again replaces its line; list --json has description_zh; --todo no longer lists it" '[ "$(wc -l < "$TP/descriptions-zh.txt")" -eq 1 ] &&
    kit list --json 2>&1 | grep -qF "\"description\": \"upstream\", \"description_zh\": \"上游的說明\", \"path\": " && ! kit describe --todo 2>&1 | grep -q gerrit-workflow'
if [ -n "$PWSH" ]; then
    check "describe: kit.ps1 reads the same line (same hash)" 'kps list --json 2>&1 | grep -qF "\"description\": \"upstream\", \"description_zh\": \"上游的說明\", \"path\": "'
fi
cp "$TP/skills/gerrit-workflow/SKILL.md" "$T/gw.md"; sed 's/^description: upstream$/description: upstream v2/' "$T/gw.md" > "$TP/skills/gerrit-workflow/SKILL.md"
check "describe: a changed description is not shown in Chinese until translated again" '! kit list --json 2>&1 | grep -q description_zh && kit describe --todo 2>&1 | grep -qxF "skill:gerrit-workflow	upstream v2"'
cp "$T/gw.md" "$TP/skills/gerrit-workflow/SKILL.md"
printf 'skill:gerrit-review\t%s\t審查\nskill:quote\tffffffffffff\t舊的\n' "$(printf 'review a change' | git hash-object --stdin | cut -c1-12)" > "$TEAM/descriptions-zh.txt"
printf 'skill:gerrit-workflow\t%s\t上游\n' "$(printf upstream | git hash-object --stdin | cut -c1-12)" > "$TP/descriptions-zh.txt"
out=$(kit list --json 2>&1)
check "list --json: each item its own Chinese line (two sources, a stale one between)" 'printf "%s\n" "$out" | grep -qF "\"description\": \"review a change\", \"description_zh\": \"審查\", \"path\": " &&
    printf "%s\n" "$out" | grep -qF "\"description\": \"upstream\", \"description_zh\": \"上游\", \"path\": " && [ "$(printf "%s\n" "$out" | grep -c description_zh)" = 2 ]'
rm -f "$TEAM/descriptions-zh.txt" "$TP/descriptions-zh.txt"
out=$(kit describe skill nope "x" 2>&1); rc=$?
check "describe: unknown item or no text refused" '[ $rc -ne 0 ] && echo "$out" | grep -q "找不到 skill:nope" && ! kit describe skill gerrit-workflow "  " >/dev/null 2>&1 && [ ! -e "$TP/descriptions-zh.txt" ]'
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
# status --json (a panel: which kit, api and commits this account uses; read only): team is a git repo now, third-party not
snap() { find "$1" -type f -print0 | xargs -0 cksum | LC_ALL=C sort; }   # snap DIR : every file and its checksum
snap "$HOME" > "$T/st.snap"
kit status --json > "$T/status.json" 2>"$T/status.err"; rc=$?
check "status --json: exit 0, valid JSON, nothing on stderr" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/status.json" > /dev/null && [ ! -s "$T/status.err" ]'
check "status --json: kit, api, user, at" '[ "$(jget "$T/status.json" kit)" = "\"$(cat "$HERE/../VERSION")\"" ] && [ "$(jget "$T/status.json" api)" = "\"$(kit api)\"" ] &&
    [ "$(jget "$T/status.json" user)" = "\"$(id -un)\"" ] && grep -qE "^  \"at\": [0-9]{10},$" "$T/status.json"'
check "status --json: no self (kit not installed from a clone), no approvals, nothing pending" 'grep -qxF "  \"self\": null," "$T/status.json" && grep -qxF "  \"approvals\": null," "$T/status.json" && grep -qxF "  \"pending\": []," "$T/status.json"'
check "status --json: a git source has its commit, a folder that is not git null" 'grep -qxF "    {\"name\": \"team\", \"source\": \"$TEAM\", \"dir\": \"$TEAM\", \"commit\": \"$(git -C "$TEAM" rev-parse HEAD)\", \"approved\": null}," "$T/status.json" &&
    grep -qxF "    {\"name\": \"third-party\", \"source\": \"$TP\", \"dir\": \"$TP\", \"commit\": null, \"approved\": null}" "$T/status.json" && [ "$(tail -n 2 "$T/status.json")" = "$(printf "  ]\n}")" ]'
check "status --json writes nothing (state.tsv and the rest of HOME the same)" 'snap "$HOME" | cmp -s - "$T/st.snap"'
out=$(AGENTKIT_CONFIG="$T/noconf" kit status --json 2>/dev/null); rc=$?
check "status --json before kit init: exit 0, sources [], approvals null" '[ $rc -eq 0 ] && echo "$out" | grep -qxF "  \"sources\": []" && echo "$out" | grep -qxF "  \"approvals\": null," && [ ! -e "$T/noconf" ]'
out=$(kit status 2>/dev/null); rc=$?
check "status without --json: usage error as JSON" '[ $rc -ne 0 ] && [ "$out" = "{\"error\": {\"code\": \"usage\", \"message\": \"用法：kit status --json\"}}" ]'
if [ -n "$PWSH" ]; then
    at0() { sed -E 's/^  "at": [0-9]+,$/  "at": 0,/'; }
    check "status --json: kit.ps1 prints the same" '[ "$(kps status --json 2>/dev/null | at0)" = "$(at0 < "$T/status.json")" ]'
    check "status --json before kit init, without --json: kit.ps1 prints the same" '[ "$(AGENTKIT_CONFIG="$T/noconf" kps status --json 2>/dev/null | at0)" = "$(AGENTKIT_CONFIG="$T/noconf" kit status --json 2>/dev/null | at0)" ] &&
        [ "$(kps status 2>/dev/null)" = "$out" ] && [ ! -e "$T/noconf" ]'
fi
echo more >>"$TEAM/skills/quote/SKILL.md"; echo x > "$TEAM/skills/gerrit-review/notes.md"; echo y >> "$TEAM/rules/security.md"; echo z > "$TEAM/README.md"
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
# what Codex and omp read there too: .agents/skills, the nearest .omp (its RULES.md, skills), mcp.json, .codex/config.toml
mkdir -p "$T/proj/.agents/skills/ask" "$T/proj/.omp" "$T/proj/sub/.omp/skills/os" "$T/proj/sub/.codex"
printf -- '---\nname: ask\ndescription: agents skill\n---\nx\n' > "$T/proj/.agents/skills/ask/SKILL.md"
printf -- '---\nname: os\ndescription: omp skill\n---\nx\n' > "$T/proj/sub/.omp/skills/os/SKILL.md"
printf '# Sticky\n' > "$T/proj/sub/.omp/RULES.md"; printf '# Far\n' > "$T/proj/.omp/RULES.md"
printf '{"mcpServers": {"om": {"command": "x"}}}\n' > "$T/proj/sub/mcp.json"
printf '[mcp_servers.cx]\ncommand = "x"\n\n# agentkit:begin (managed by kit, do not edit)\n[mcp_servers.kitone]\ncommand = "y"\n# agentkit:end\n' > "$T/proj/sub/.codex/config.toml"
PP=$(cd "$T/proj/sub" && pwd -P); PU=$(cd "$T/proj" && pwd -P)
cp "$HOME/.claude.json" "$T/cj.bak"
printf 'set\tprojects|%s|mcpServers|lm\t{"command": "y"}\nset\tmcpServers|um\t{"command": "z"}\n' "$PP" > "$T/cj.ops"
LC_ALL=C awk -f "$JA" -v ops="$T/cj.ops" -v sep="|" "$T/cj.bak" > "$HOME/.claude.json"
kit list --json --dir "$T/proj/sub" --pid $$ > "$T/here.json" 2>&1; rc=$?
check "list --json --dir: valid JSON, the folder, no other user" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/here.json" > /dev/null && grep -qF "\"here\": {\"dir\": \"$PP\", \"user\": null, \"agent\": null, \"folder\": {\"dir\": \"$PP\", \"why\": \"\", \"items\": [], \"agent\": null, \"plugins\": []}, \"items\": [" "$T/here.json"'
check "list --json --dir: rules here and above, AGENTS.md for codex/omp" 'grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \"CLAUDE.md\", \"path\": \"$PP/CLAUDE.md\", \"tools\": \"claude omp\", \"description\": \"\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \".claude/rules/r1.md\", \"path\": \"$PP/.claude/rules/r1.md\", \"tools\": \"claude\", \"description\": \"Rule one\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \"$PU/CLAUDE.md\", \"path\": \"$PU/CLAUDE.md\", \"tools\": \"claude\", \"description\": \"Project rules\"}" "$T/here.json" &&
    grep -qF "\"name\": \"$PU/AGENTS.md\", \"path\": \"$PU/AGENTS.md\", \"tools\": \"codex omp\"" "$T/here.json"'
check "list --json --dir: project skill, .mcp.json and local MCP" 'grep -qF "{\"scope\": \"dir\", \"kind\": \"skill\", \"name\": \"pskill\", \"path\": \"$PP/.claude/skills/pskill/SKILL.md\", \"tools\": \"claude omp\", \"description\": \"project skill\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"mcp\", \"name\": \"pm\", \"path\": \"$PP/.mcp.json\"" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"mcp\", \"name\": \"lm\", \"path\": \"$HOME/.claude.json\"" "$T/here.json"'
check "list --json --dir: omp reads one file per folder level (CLAUDE.md here, AGENTS.md above), .agents/skills for Codex and omp" 'grep -qF "\"name\": \"$PU/CLAUDE.md\", \"path\": \"$PU/CLAUDE.md\", \"tools\": \"claude\"," "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"skill\", \"name\": \"ask\", \"path\": \"$PU/.agents/skills/ask/SKILL.md\", \"tools\": \"codex omp\", \"description\": \"agents skill\"}" "$T/here.json"'
check "list --json --dir: the nearest .omp only (its RULES.md and skills), not one farther up" 'grep -qF "{\"scope\": \"dir\", \"kind\": \"rule\", \"name\": \".omp/RULES.md\", \"path\": \"$PP/.omp/RULES.md\", \"tools\": \"omp\", \"description\": \"Sticky\"}" "$T/here.json" &&
    grep -qF "{\"scope\": \"dir\", \"kind\": \"skill\", \"name\": \"os\", \"path\": \"$PP/.omp/skills/os/SKILL.md\", \"tools\": \"omp\"," "$T/here.json" && ! grep -qF "$PU/.omp/RULES.md" "$T/here.json"'
check "list --json --dir: MCP omp reads (.mcp.json, mcp.json) and Codex's .codex/config.toml, not kit's block there" 'grep -qF "\"name\": \"pm\", \"path\": \"$PP/.mcp.json\", \"tools\": \"claude omp\"" "$T/here.json" &&
    grep -qF "\"name\": \"om\", \"path\": \"$PP/mcp.json\", \"tools\": \"omp\"" "$T/here.json" &&
    grep -qF "\"name\": \"cx\", \"path\": \"$PP/.codex/config.toml\", \"tools\": \"codex omp\"" "$T/here.json" && ! grep -qF "kitone" "$T/here.json"'
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
check "list --json --pid: the agent kit run started there" 'grep -qF "\"user\": null, \"agent\": {\"name\": \"gerrit\", \"source\": \"team\", \"rules\": [\"gerrit-flow\"], \"skills\": [\"gerrit-review\"], \"mcp\": [\"gerrit\"]}, \"folder\": {\"dir\": \"$PP\", \"why\": \"\", \"items\": [], \"agent\": null, \"plugins\": []}, \"items\": [" "$T/here2.json"'
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

finish
