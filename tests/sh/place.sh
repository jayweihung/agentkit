#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; team_later; printf 'review v2\n' >> "$TEAM/skills/gerrit-review/SKILL.md"
# ---------- kit place: an agent's own folder (a kit panel: drag an agent onto a space) ----------
H6="$T/home6"; mkdir -p "$H6/.codex" "$H6/.omp/agent"
W="$T/spaces"; mkdir -p "$W"; W=$(cd "$W" && pwd -P)
printf -- '---\nname: helper\ndescription: helps\nskills: [gerrit-review, not-there]\n---\n\nYou help.\n' > "$TEAM/agents/helper.md"
snap() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3); }
(
export HOME="$H6"
# a deny rule kit wants that you had already: yours (kit uninstall leaves it)
mkdir -p "$H6/.claude"; printf '{"permissions": {"deny": ["mcp__gerrit__submit_change"]}}\n' > "$H6/.claude/settings.json"
kit init "$TEAM" >/dev/null 2>&1
check "deny you had already: not counted as kit's" '! grep -q "^deny[[:space:]]" "$H6/.config/agentkit/state.tsv" && [ "$(jget "$H6/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"mcp__gerrit__submit_change\"]" ]'
G="$W/gerrit"
out=$(kit place gerrit "$G" --json 2>/dev/null); rc=$?
check "place --json: one line: dir, agent, tool, command, warnings" '[ $rc -eq 0 ] && [ "$out" = "{\"dir\": \"$G\", \"agent\": \"gerrit\", \"tool\": \"claude\", \"command\": [\"claude\"], \"warnings\": []}" ]'
check "place: .agentkit says which agent; the agent's rules, skills, MCP come from the agent file (not listed)" 'grep -qx "agent:gerrit" "$G/.agentkit" && grep -qx "tool:claude" "$G/.agentkit" && ! grep -q "^rule:\|^skill:\|^mcp:" "$G/.agentkit"'
check "place: CLAUDE.md imports the rule, then the agent's prompt" 'grep -q "^@.*rules/gerrit-flow.md" "$G/CLAUDE.md" && grep -qx "<!-- agent: gerrit -->" "$G/CLAUDE.md" && grep -qx "You are the Gerrit helper." "$G/CLAUDE.md"'
check "place: AGENTS.md (Codex, omp): the rule text and the prompt" 'grep -q "Only comment, never submit." "$G/AGENTS.md" && grep -qx "You are the Gerrit helper." "$G/AGENTS.md"'
check "place: skills for Claude and Codex/omp, the MCP in .mcp.json" '[ -f "$G/.claude/skills/gerrit-review/SKILL.md" ] && [ -f "$G/.agents/skills/gerrit-review/SKILL.md" ] && [ "$(jget "$G/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ]'
check "place: Claude's tool limits in settings.local.json (tools.deny, and the built-in tools tools.only leaves out)" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));x=d[\"permissions\"][\"deny\"];assert x[0]==\"mcp__gerrit__submit_change\" and \"Bash\" in x and \"Write\" in x and \"Agent\" in x and \"MultiEdit\" not in x and not set(x)&{\"Read\",\"Grep\",\"Glob\"};assert d[\"enabledMcpjsonServers\"]==[\"gerrit\"]" "$G/.claude/settings.local.json" && [ ! -e "$G/.claude/settings.local.json.kit-backup" ]'
check "place: Codex: the agent's MCP tool deny as disabled_tools in the folder's config" 'grep -q "^\[mcp_servers.gerrit\]" "$G/.codex/config.toml" && grep -qF "disabled_tools = [\"submit_change\"]" "$G/.codex/config.toml"'
check "place: not the account" '[ ! -e "$H6/.claude/skills/gerrit-review" ] && ! grep -q "Gerrit helper" "$H6/.claude/CLAUDE.md" && ! grep -q "\"Write\"" "$H6/.claude/settings.json"'
check "place: kit keeps the folder up to date (kit sync)" 'grep -qxF "$G" "$HOME/.config/agentkit/dirs"'
snap "$G" > "$T/place1"
out=$(kit place gerrit "$G/" --json 2>/dev/null); rc=$?
check "place again (same agent): fine, nothing changes" '[ $rc -eq 0 ] && echo "$out" | grep -qF "\"dir\": \"$G\"" && snap "$G" | cmp -s - "$T/place1"'
kit list --json --dir "$G" > "$T/place.json" 2>/dev/null
check "list --json --dir: here.folder.agent names the placed agent, items has the agent's" 'python3 -c "import json,sys;f=json.load(open(sys.argv[1]))[\"here\"][\"folder\"];assert f[\"agent\"]==\"gerrit\" and f[\"dir\"]==sys.argv[2] and f[\"items\"]==[\"rule:gerrit-flow\",\"skill:gerrit-review\",\"mcp:gerrit\"]" "$T/place.json" "$G"'
kit list --json --dir "$W" > "$T/place0.json" 2>/dev/null
check "list --json --dir: a folder without one: agent null" 'python3 -c "import json,sys;assert json.load(open(sys.argv[1]))[\"here\"][\"folder\"][\"agent\"] is None" "$T/place0.json"'
# refusals: nothing written
out=$(kit place helper "$G" --json 2>/dev/null); rc=$?
check "place: refuses a folder that is another agent (other_agent), untouched" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"code\": \"other_agent\"" && snap "$G" | cmp -s - "$T/place1"'
mkdir -p "$W/busy"; echo mine > "$W/busy/notes.txt"
out=$(kit place helper "$W/busy" --json 2>/dev/null); rc=$?
check "place: refuses a folder with files and no marker (not_empty)" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"code\": \"not_empty\"" && [ ! -e "$W/busy/.agentkit" ]'
out=$(kit place helper "$W/no/such" --json 2>/dev/null); rc=$?
check "place: the parent must be there (no_parent), nothing made" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"code\": \"no_parent\"" && [ ! -e "$W/no" ]'
out=$(kit place nobody "$W/x" --json 2>/dev/null); rc=$?
check "place: an unknown agent (no_agent)" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"code\": \"no_agent\"" && [ ! -e "$W/x" ]'
out=$(kit place helper "$H6" --json 2>/dev/null); rc=$?
check "place: not the home folder (bad_dir)" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"code\": \"bad_dir\"" && [ ! -e "$H6/.agentkit" ]'
out=$(kit place helper --json 2>/dev/null); rc=$?
check "place: usage" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"code\": \"usage\""'
# a second agent in a second folder; an empty folder that is there already is fine
HP="$W/helper"; mkdir "$HP"
out=$(kit place helper "$HP" --json 2>/dev/null); rc=$?
check "place: a second agent in its own folder; a missing item is a warning" '[ $rc -eq 0 ] && echo "$out" | grep -qF "\"warnings\": [\"skill not-there 不在任何來源裡：沒有放進來\"]" && grep -qx "agent:helper" "$HP/.agentkit" && grep -qx "You help." "$HP/CLAUDE.md" && ! grep -q "Gerrit helper" "$HP/CLAUDE.md" && ! grep -q "You help." "$G/CLAUDE.md" && [ ! -e "$HP/.claude/settings.local.json" ]'
# afterwards each folder changes on its own (kit add|rm --dir)
kit add --dir "$HP" rule coding-style >/dev/null 2>&1
check "add --dir after place: only that folder, the prompt stays after the rules" 'grep -q "^@.*rules/coding-style.md" "$HP/CLAUDE.md" && ! grep -q "coding-style" "$G/CLAUDE.md" && [ "$(tail -2 "$HP/CLAUDE.md" | head -1)" = "You help." ] && grep -qx "agent:helper" "$HP/.agentkit"'
kit rm --dir "$G" skill gerrit-review >/dev/null 2>&1
check "rm --dir after place: only that folder" '[ ! -e "$G/.claude/skills/gerrit-review" ] && [ -f "$HP/.claude/skills/gerrit-review/SKILL.md" ]'
check "rm --dir of the agent's: kept in .agentkit as not:" 'grep -qx "not:skill:gerrit-review" "$G/.agentkit"'
kit rm --dir "$G" rule gerrit-flow >/dev/null 2>&1; kit rm --dir "$G" mcp gerrit >/dev/null 2>&1; kit sync >/dev/null 2>&1
check "rm --dir all after place: still that agent (marker, prompt, tool limits), still kept up to date" 'grep -qx "agent:gerrit" "$G/.agentkit" && grep -qx "You are the Gerrit helper." "$G/CLAUDE.md" && jget "$G/.claude/settings.local.json" permissions.deny | grep -q "\"Bash\"" && [ ! -e "$G/.mcp.json" ] && grep -qxF "$G" "$HOME/.config/agentkit/dirs"'
check "rm --dir of the agent's: stays out after kit sync" '[ ! -e "$G/.claude/skills/gerrit-review" ] && ! grep -q "gerrit-flow" "$G/CLAUDE.md"'
kit add --dir "$G" mcp gerrit >/dev/null 2>&1
check "add --dir of the agent's again: the not: line goes, it is the agent's again (no line of yours)" '! grep -q "mcp:gerrit" "$G/.agentkit" && [ "$(jget "$G/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ]'
out=$(kit rm --dir "$G" skill gerrit-review 2>&1); rc=$?
check "rm --dir of one already out: refused" '[ $rc -ne 0 ]'
# the agent file changes: kit sync brings its new rules, skills, MCP and takes out the ones it dropped; yours stay
printf -- '---\nname: helper\ndescription: helps\nmcp: [gerrit]\n---\nYou help, version 2.\n' > "$TEAM/agents/helper.md"; kit sync >/dev/null 2>&1
check "sync: a changed prompt reaches the placed folder" 'grep -qx "You help, version 2." "$HP/CLAUDE.md" && ! grep -qx "You help." "$HP/CLAUDE.md"'
check "sync: the agent's new MCP is added, the skill it dropped taken out, the rule you added kept" '[ "$(jget "$HP/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && [ ! -e "$HP/.claude/skills/gerrit-review" ] && grep -q "^@.*rules/coding-style.md" "$HP/CLAUDE.md" && grep -qx "rule:coding-style" "$HP/.agentkit"'
# a deny rule kit wants in the folder that you had put there already: yours, left when the agent drops it
python3 -c "import json,sys;f=sys.argv[1];d=json.load(open(f));d.setdefault('permissions',{})['deny']=['Bash'];json.dump(d,open(f,'w'))" "$HP/.claude/settings.local.json"
printf -- '---\nname: helper\ndescription: helps\nmcp: [gerrit]\ntools:\n  deny: [Bash, WebFetch]\n---\nYou help, version 2.\n' > "$TEAM/agents/helper.md"; kit sync >/dev/null 2>&1
check "place deny: kit adds the agent's, not the one you had" '[ "$(jget "$HP/.claude/settings.local.json" permissions.deny | tr -d " \n")" = "[\"Bash\",\"WebFetch\"]" ] && ! grep -q "helper:deny[[:space:]]Bash" "$HOME/.config/agentkit/state.tsv"'
printf -- '---\nname: helper\ndescription: helps\nmcp: [gerrit]\n---\nYou help, version 2.\n' > "$TEAM/agents/helper.md"; kit sync >/dev/null 2>&1
check "place deny: the agent drops them: kit's goes, yours stays" '[ "$(jget "$HP/.claude/settings.local.json" permissions.deny | tr -d " \n")" = "[\"Bash\"]" ]'
# the agent cannot be read (renamed, its source gone): the folder stays as it was (prompt, tool limits, MCP), said once
snap "$G" > "$T/place2"
mv "$TEAM/agents/gerrit.md" "$T/gerrit.md.away"
out=$(kit sync 2>&1); out2=$(kit sync 2>&1)
check "agent gone: the placed folder is left as it was (deny, prompt, MCP)" 'snap "$G" | cmp -s - "$T/place2" && jget "$G/.claude/settings.local.json" permissions.deny | grep -q "\"Bash\""'
check "agent gone: said once" 'echo "$out" | grep -qF "agent gerrit 找不到或讀不懂" && ! echo "$out2" | grep -qF "agent gerrit 找不到或讀不懂"'
kit list --json --dir "$G" > "$T/place3.json" 2>/dev/null
check "agent gone: list --json --dir still has the agent's (kit's copy)" 'python3 -c "import json,sys;f=json.load(open(sys.argv[1]))[\"here\"][\"folder\"];assert f[\"items\"]==[\"mcp:gerrit\"]" "$T/place3.json"'
printf -- '---\nname: gerrit\nthis is not yaml\n---\nbroken\n' > "$TEAM/agents/gerrit.md"; kit sync >/dev/null 2>&1
check "agent unreadable (bad header): the folder is left as it was" 'snap "$G" | cmp -s - "$T/place2"'
mv "$T/gerrit.md.away" "$TEAM/agents/gerrit.md"; out=$(kit sync 2>&1)
check "agent back: kit sync as before, nothing to say" 'snap "$G" | cmp -s - "$T/place2" && ! echo "$out" | grep -qF "找不到或讀不懂"'
out=$(kit place gerrit "$W/gx" --tool codex --json 2>/dev/null); rc=$?
check "place --tool codex: the command and what Codex cannot do" '[ $rc -eq 0 ] && echo "$out" | grep -qF "\"tool\": \"codex\", \"command\": [\"codex\"], \"warnings\": [\"Codex 的 tools.only 只管得到 shell（Bash）和改檔（Edit、Write）：Codex 其他的內建工具照樣能用\", \"tools.only 沒有 Bash：Codex 讀檔、找檔也是用 shell，所以在 Codex 裡也不能讀檔\"]" && grep -qx "tool:codex" "$W/gx/.agentkit" && grep -qx "You are the Gerrit helper." "$W/gx/AGENTS.md"'
# Codex: kit codex-guard (its PreToolUse hook) says no to what the agent leaves out, in its folder and below; kit run's
# limits come in its environment; a command a piece at a time
cg() { printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2" "$3"; }
mkdir -p "$W/gx/sub"; CGP='*** Begin Patch\n*** Update File: a.txt\n@@\n-x\n+y\n*** End Patch'; CGA='*** Begin Patch\n*** Add File: b.txt\n+y\n*** End Patch'
cgall() { # the answers, one per line
    cg Bash "ls -la" "$W/gx/sub" | "$@" codex-guard; echo .
    cg apply_patch "$CGP" "$W/gx" | "$@" codex-guard; echo .
    cg Bash "ls" "$T" | "$@" codex-guard; echo .
    cg mcp__gerrit__get_change "" "$W/gx" | "$@" codex-guard; echo .
    cg Bash "cd x \u0026\u0026 git push origin" "$T" | KIT_CODEX_DENY='Bash(git push:*)' "$@" codex-guard; echo .
    cg Bash "x=\$(git push)" "$T" | KIT_CODEX_DENY='Bash(git push:*)' "$@" codex-guard; echo .
    cg Bash "git status; git pushx" "$T" | KIT_CODEX_DENY="Bash(git status)$LF" "$@" codex-guard; echo .
    cg Bash "git log" "$T" | KIT_CODEX_DENY='Bash(git push:*)' "$@" codex-guard; echo .
    cg apply_patch "$CGA" "$T" | KIT_CODEX_ONLY='Read,Bash,Edit' "$@" codex-guard; echo .
    cg apply_patch "$CGP" "$T" | KIT_CODEX_DENY='Write' "$@" codex-guard; echo .
}
LF='
'
out=$(cgall kit)
want='{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "kit: this agent does not use Bash (tools.only)"}}
.
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "kit: this agent does not use Edit (tools.only): no changing files"}}
.
.
.
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "kit: Bash(git push:*) is not allowed (tools.deny)"}}
.
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "kit: Bash(git push:*) is not allowed (tools.deny)"}}
.
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "kit: Bash(git status) is not allowed (tools.deny)"}}
.
.
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "kit: this agent does not use Write (tools.only): no new files"}}
.
.'
check "codex-guard: the placed folder's agent (and below), kit run's limits, a piece at a time, patches as Edit / Write" '[ "$out" = "$want" ]'
[ "$out" = "$want" ] || printf '%s\n' "$out" | diff - <(printf '%s\n' "$want") | head -20
[ -n "$PWSH" ] && { out2=$(cgall kps); check "codex-guard: kit.ps1 says the same" '[ "$out2" = "$out" ]'; }
rmdir "$W/gx/sub"
out=$(kit place gerrit "$W/go" --tool omp --json 2>/dev/null); rc=$?
check "place --tool omp: the folder's .mcp.json is omp's too; tool limits through kit's hook module in the folder" '[ $rc -eq 0 ] && echo "$out" | grep -qF "\"command\": [\"omp\"], \"warnings\": []" && [ "$(jget "$W/go/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && grep -qF "const ONLY = [\"Read\", \"Grep\", \"Glob\"];" "$W/go/.omp/hooks/pre/kit.js" && grep -qF "const DENY = [\"mcp__gerrit__submit_change\"];" "$W/go/.omp/hooks/pre/kit.js"'
if command -v node >/dev/null 2>&1; then   # what kit's omp module blocks: a tool outside tools.only, the denied MCP tool (a plugin's too)
    cp "$W/go/.omp/hooks/pre/kit.js" "$T/ompfolder.mjs"
    printf '%s\n' 'const m = await import(process.argv[2]); const h = {}; m.default({ on: (e, f) => { h[e] = f; } });' \
        'const r = []; for (const t of ["read", "glob", "bash", "write", "mcp__gerrit_submit_change", "mcp__kit_gerrit_submit_change", "mcp__gerrit_get_change", "yield"]) r.push(t + "=" + ((await h.tool_call({ toolName: t, input: {} }))?.block ? "no" : "ok"));' \
        'console.log(Object.keys(h).join(",") + " " + r.join(" "));' > "$T/omprun.mjs"
    out=$(node "$T/omprun.mjs" "$T/ompfolder.mjs" 2>&1)
    check "omp module in the folder: blocks what the agent may not use, nothing else" '[ "$out" = "tool_call read=ok glob=ok bash=no write=no mcp__gerrit_submit_change=no mcp__kit_gerrit_submit_change=no mcp__gerrit_get_change=ok yield=ok" ]'
fi
out=$(kit place gerrit "$W/gv" --tool vim --json 2>/dev/null); rc=$?
check "place --tool: only claude, codex, omp" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"code\": \"usage\"" && [ ! -e "$W/gv" ]'
if [ -n "$PWSH" ]; then
  # kit.ps1: the same JSON and the same files, in a home of its own
  pl() { local w=$1; shift
    export HOME="$w/home"; mkdir -p "$HOME/.codex" "$HOME/.omp/agent" "$w/s"; "$@" init "$TEAM" >/dev/null 2>&1
    for a in "gerrit $w/s/g --tool claude" "gerrit $w/s/g" "gerrit $w/s/c --tool codex" "gerrit $w/s/o --tool omp" "helper $w/s/g" "nobody $w/s/n" "helper $w/s/no/such"; do
      "$@" place $a --json 2>/dev/null; echo "rc=$?"; done
    "$@" rm --dir "$w/s/c" skill gerrit-review >/dev/null 2>&1; "$@" add --dir "$w/s/c" rule coding-style >/dev/null 2>&1
    "$@" list --json --dir "$w/s/g" 2>/dev/null | grep -F '"folder"' | sed 's/, "items": \[$//'
    (cd "$w/s" && for f in $(find . -type f | LC_ALL=C sort); do echo "== $f"; cat "$f"; done); }
  mkdir -p "$T/pl1" "$T/pl2"; P1=$(cd "$T/pl1" && pwd -P); P2=$(cd "$T/pl2" && pwd -P)
  a=$(pl "$P1" kps | sed "s#$P1#W#g"); b=$(pl "$P2" kit | sed "s#$P2#W#g")
  check "kit.ps1 place: the same JSON, errors, here.folder.agent and files as unix/kit" '[ "$a" = "$b" ] && echo "$a" | grep -qF "\"agent\": \"gerrit\", \"plugins\": []}"'
  [ "$a" = "$b" ] || diff <(echo "$a") <(echo "$b") | head -20
fi
kit uninstall >/dev/null 2>&1
check "uninstall: the placed folders are empty again (kit's files out; the deny you put in one stays), kit's copies of the agents gone" '[ -z "$(ls -A "$G")" ] && [ "$(ls -A "$HP")" = .claude ] && [ "$(jget "$HP/.claude/settings.local.json" permissions.deny | tr -d " \n")" = "[\"Bash\"]" ] && [ -z "$(ls -A "$W/gx")" ] && [ ! -e "$HOME/.config/agentkit/placed" ]'
check "uninstall: the deny you had already stays" '[ "$(jget "$H6/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"mcp__gerrit__submit_change\"]" ]'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"
rm -f "$TEAM/agents/helper.md"

finish
