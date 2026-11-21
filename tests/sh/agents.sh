#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
kit init "$TEAM" >/dev/null 2>&1
mkdir -p "$TEAM/skills/quote"; printf -- '---\nname: quote\ndescription: 中文 "引號" \\ 和\ttab\n---\nx\n' > "$TEAM/skills/quote/SKILL.md"
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
out=$(kit check "$TEAM" 2>&1)
check "check: an agent with tools.only: a note for its author (what Claude can't do), not a problem" 'echo "$out" | grep -qF "kit: agents/gerrit.md: tools.only 在 Claude 是把其他內建工具寫進 deny" && ! echo "$out" | grep -qF "kit check: agents/gerrit.md: tools.only"'

finish
