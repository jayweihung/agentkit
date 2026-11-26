#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
cd "$T"
# ---------- kit open --tab, kit add|rm --tab, kit tab: each terminal its own rules, skills, MCP, plugins (kit 0.17.0, kit api 1.22) ----------
# A program that shows terminals starts each through kit open with the terminal's id: the tab has its own copy of what
# its agent had (--agent) and what was added to it (kit add --tab); what the account or the folder already has is left
# out. unix/kit, then kit.ps1: the same files and JSON.
pj() { python3 -Ic "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
run() { # run TAG COMMAND
    local tag=$1 k=$2
    S="$T/src-$tag"; H="$T/home-$tag"; W="$T/work-$tag"; FB="$T/fake-$tag"
    mkdir -p "$S/skills/ta" "$S/skills/tb" "$S/skills/tc" "$S/rules" "$S/mcp" "$S/agents" "$S/plugins/pa/.claude-plugin" "$H/.codex" "$W" "$FB"
    for n in ta tb tc; do printf -- '---\nname: %s\ndescription: skill %s\n---\n%s body\n' "$n" "$n" "$n" > "$S/skills/$n/SKILL.md"; done
    echo "Rule RA." > "$S/rules/ra.md"
    printf 'command: echo\nargs:\n  - ma\n' > "$S/mcp/ma.yaml"
    printf '{"name": "pa", "description": "p"}\n' > "$S/plugins/pa/.claude-plugin/plugin.json"
    printf -- '---\nname: hello\ndescription: h\nrules: [ra]\nskills: [ta]\nmcp: [ma]\ntools:\n  only: [Read]\n---\nYou are hello.\n' > "$S/agents/hello.md"
    printf '#!/bin/sh\nprintf "%%s|%%s|%%s\\n" "$KIT_TAB" "$$" "$*" > "%s/args"\n' "$FB" > "$FB/claude"; chmod +x "$FB/claude"
    (
    export HOME="$H"; TB="$H/.config/agentkit/tabs"
    $k init "$S" >/dev/null 2>&1; $k add skill tb >/dev/null 2>&1; $k add --dir "$W" skill tc >/dev/null 2>&1
    cd "$W"
    out=$(KIT_DRY_RUN=1 $k open claude --agent hello --tab t1 2>&1)
    check "$tag: open --agent --tab: the tab gets the agent's skill, rule, MCP; Claude reads them from it, memory in it" '[ -f "$TB/t1/.claude/skills/ta/SKILL.md" ] && grep -qx "Rule RA." "$TB/t1/rules/ra.md" && [ -f "$TB/t1/mcp/ma.yaml" ] && [ -f "$TB/t1/agent.md" ] && echo "$out" | grep -qx -- --add-dir && echo "$out" | grep -qxF "$TB/t1" && grep -q "Rule RA." "$TB/t1/run/prompt.md" && grep -q "You are hello." "$TB/t1/run/prompt.md" && echo "$out" | grep -qF "autoMemoryDirectory" && echo "$out" | grep -qF "$TB/t1/memory" && echo "$out" | grep -qx Read && grep -q "\"ma\"" "$TB/t1/run/mcp.json"'
    check "$tag: tab.tsv: the agent, the tool, the folder, what came from the agent" 'grep -qx "agent	hello" "$TB/t1/tab.tsv" && grep -qx "tool	claude" "$TB/t1/tab.tsv" && grep -q "^dir	" "$TB/t1/tab.tsv" && grep -qx "item	skill	ta	agent" "$TB/t1/tab.tsv" && grep -qx "item	mcp	ma	agent" "$TB/t1/tab.tsv"'
    a1=$($k add --tab t1 skill tb 2>&1); r1=$?; a2=$($k add --tab t1 skill tc 2>&1); r2=$?
    check "$tag: add --tab: not what the account has, nor the folder" '[ $r1 -ne 0 ] && echo "$a1" | grep -q "整個帳號已經有" && [ $r2 -ne 0 ] && echo "$a2" | grep -q "已經有 skill:tc" && ! grep -q "item	skill	tb" "$TB/t1/tab.tsv"'
    a3=$($k add --tab t1 plugin pa 2>&1)
    out=$(KIT_DRY_RUN=1 $k open claude --tab t1 2>&1)
    check "$tag: add --tab plugin: the tab's copy, --plugin-dir; said it needs a restart" '[ -f "$TB/t1/plugins/pa/.claude-plugin/plugin.json" ] && grep -qx "item	plugin	pa	tab" "$TB/t1/tab.tsv" && echo "$out" | grep -qx -- --plugin-dir && echo "$out" | grep -qxF "$TB/t1/plugins/pa" && echo "$a3" | grep -q "重開"'
    $k tab show t1 --json > "$T/$tag-show.json" 2>/dev/null
    check "$tag: tab show --json: the tab's (from, restart), the folder's, the account's" 'pj "$T/$tag-show.json" "
i={(x[\"kind\"],x[\"name\"]):x for x in d[\"items\"]}
assert d[\"tab\"]==\"t1\" and d[\"tool\"]==\"claude\" and d[\"agent\"]==\"hello\" and d[\"live\"] is False
assert i[(\"skill\",\"ta\")][\"from\"]==\"agent\" and i[(\"skill\",\"ta\")][\"restart\"] is False and i[(\"plugin\",\"pa\")][\"from\"]==\"tab\" and i[(\"plugin\",\"pa\")][\"restart\"] is True
assert d[\"folder\"][\"items\"]==[{\"kind\":\"skill\",\"name\":\"tc\"}] and {\"kind\":\"skill\",\"name\":\"tb\"} in d[\"account\"]"'
    $k add skill ta >/dev/null 2>&1; KIT_DRY_RUN=1 $k open claude --tab t1 >/dev/null 2>&1; $k tab show t1 --json > "$T/$tag-show2.json" 2>/dev/null
    check "$tag: the account gets the tab's skill too: the tab leaves its copy out (hidden/), says so" '[ ! -e "$TB/t1/.claude/skills/ta" ] && [ -f "$TB/t1/hidden/ta/SKILL.md" ] && pj "$T/$tag-show2.json" "assert [x[\"below\"] for x in d[\"items\"] if x[\"name\"]==\"ta\"]==[\"account\"]"'
    $k rm skill ta >/dev/null 2>&1; KIT_DRY_RUN=1 $k open claude --tab t1 >/dev/null 2>&1
    check "$tag: ... and takes it back when the account no longer has it" '[ -f "$TB/t1/.claude/skills/ta/SKILL.md" ] && [ ! -e "$TB/t1/hidden/ta" ]'
    $k rm --tab t1 plugin pa >/dev/null 2>&1
    check "$tag: rm --tab: the copy and the line go" '[ ! -e "$TB/t1/plugins/pa" ] && ! grep -q "item	plugin	pa" "$TB/t1/tab.tsv"'
    out=$(MYTAB=t2 KIT_DRY_RUN=1 $k open codex --tab-env MYTAB 2>&1)
    $k add --tab t2 skill ta >/dev/null 2>&1; out=$(MYTAB=t2 KIT_DRY_RUN=1 $k open codex --tab-env MYTAB -- resume x1 2>&1)
    check "$tag: a plain tab (--tab-env): starts empty; Codex gets its skill listed, the tool's own arguments after" 'grep -qx "agent	" "$TB/t2/tab.tsv" && grep -qx "item	skill	ta	tab" "$TB/t2/tab.tsv" && grep -qF "$TB/t2/.claude/skills/ta/SKILL.md" "$TB/t2/run/prompt.md" && echo "$out" | grep -q "^developer_instructions=" && [ "$(echo "$out" | grep -v "^tab=" | tail -2 | paste -sd " " -)" = "resume x1" ]'
    out=$(KIT_DRY_RUN=1 $k open omp --agent hello --tab t3 2>&1)
    check "$tag: omp: its skills folder is the tab's, the agent's tools" 'grep -qF "$TB/t3/.claude/skills" "$TB/t3/run/omp.yml" && echo "$out" | grep -qx -- --append-system-prompt && echo "$out" | grep -qx read'
    $k tab list --json > "$T/$tag-list.json" 2>/dev/null
    check "$tag: tab list --json: every tab, its agent, not running" 'pj "$T/$tag-list.json" "t={x[\"tab\"]:x for x in d[\"tabs\"]}; assert sorted(t)==[\"t1\",\"t2\",\"t3\"] and t[\"t1\"][\"agent\"]==\"hello\" and t[\"t2\"][\"agent\"] is None and t[\"t3\"][\"tool\"]==\"omp\" and not t[\"t1\"][\"live\"]"'
    PATH="$FB:$PATH" $k open claude --tab t9 -- --resume x2 >/dev/null 2>&1
    check "$tag: open runs the tool with KIT_TAB, the tab's arguments, its own last" 'IFS="|" read -r kt kp ka < "$FB/args" && [ "$kt" = t9 ] && case "$ka" in *"--add-dir $TB/t9 "*"--resume x2") true;; *) false;; esac'
    [ "$tag" = ps ] || check "$tag: the tool is kit's own process (exec): the tab's pid is the tool's" '[ "$(awk -F"\t" "\$1 == \"pid\" { print \$2 }" "$TB/t9/tab.tsv")" = "$(cut -d"|" -f2 "$FB/args")" ]'
    b1=$($k open claude --tab ../x 2>&1); r1=$?; b2=$($k open vim --tab t1 2>&1); r2=$?; b3=$($k add --tab nope skill ta 2>&1); r3=$?
    check "$tag: refused: a tab id with / or .., another tool, a tab that is not there" '[ $r1 -ne 0 ] && [ $r2 -ne 0 ] && [ $r3 -ne 0 ] && echo "$b3" | grep -q "沒有分頁 nope" && [ ! -e "$H/.config/agentkit/x" ]'
    $k tab rm t2 >/dev/null 2>&1; $k tab keep t1 >/dev/null 2>&1
    check "$tag: tab rm: that one; tab keep: the others not running go" '[ ! -e "$TB/t2" ] && [ ! -e "$TB/t3" ] && [ ! -e "$TB/t9" ] && [ -f "$TB/t1/tab.tsv" ]'
    echo "$pass $fail" > "$T/sub"
    )
    read pass fail < "$T/sub"
}
run sh kit
[ -z "$PWSH" ] || run ps kps
finish
