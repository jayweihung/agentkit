#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; team_later
# ---------- kit place is gone (0.18.0): a folder it made becomes a plain one, keeping what it had ----------
H6="$T/home6"; mkdir -p "$H6/.codex" "$H6/.omp/agent"
W="$T/spaces"; mkdir -p "$W"; W=$(cd "$W" && pwd -P)
LF='
'
(
export HOME="$H6"
kit init "$TEAM" >/dev/null 2>&1
out=$(kit place gerrit "$W/new" 2>&1); rc=$?
check "place: gone, says what to use instead, makes nothing" '[ $rc -ne 0 ] && echo "$out" | grep -qF "kit open <工具> --agent <名字>" && [ ! -e "$W/new" ]'
# a folder as kit place left it: agent:/tool: lines, one of the agent's taken out (not:), one you added, and the
# agent's prompt in kit's part of CLAUDE.md (kit add --dir makes the rest: the folder in kit's list, kit's part)
upl() { # upl DIR KIT... : make DIR such a folder, then kit sync
    local g=$1; shift; mkdir -p "$g"; "$@" add --dir "$g" rule coding-style >/dev/null 2>&1
    printf '# kit place：這個資料夾就是下面這個 agent。\nagent:gerrit\ntool:claude\nnot:skill:gerrit-review\nrule:coding-style\n' > "$g/.agentkit"
    awk -v e='<!-- agentkit:end -->' '$0 == e { print "<!-- agent: gerrit -->"; print "You are the Gerrit helper." } { print }' "$g/CLAUDE.md" > "$g/c" && mv "$g/c" "$g/CLAUDE.md"
    "$@" sync 2>&1; }
G="$W/gerrit"; out=$(upl "$G" kit); out2=$(kit sync 2>&1)
check "unplace: said once" 'echo "$out" | grep -qF "$G 不再是 agent gerrit" && ! echo "$out2" | grep -qF "不再是 agent"'
check "unplace: .agentkit lists what it had (the agent's less the one taken out, then yours), no agent line" '[ "$(grep -v "^#" "$G/.agentkit")" = "rule:gerrit-flow${LF}mcp:gerrit${LF}rule:coding-style" ]'
check "unplace: the files follow it; the prompt is gone" 'grep -q "^@.*rules/gerrit-flow.md" "$G/CLAUDE.md" && grep -q "^@.*rules/coding-style.md" "$G/CLAUDE.md" && ! grep -q "Gerrit helper" "$G/CLAUDE.md" && [ ! -e "$G/.claude/skills/gerrit-review" ] && [ "$(jget "$G/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ]'
check "unplace: still kept up to date (kit sync)" 'grep -qxF "$G" "$HOME/.config/agentkit/dirs"'
kit list --json --dir "$G" > "$T/place.json" 2>/dev/null
check "list --json --dir: here.folder.agent null, items the folder's" 'python3 -c "import json,sys;f=json.load(open(sys.argv[1]))[\"here\"][\"folder\"];assert f[\"agent\"] is None and f[\"items\"]==[\"rule:gerrit-flow\",\"mcp:gerrit\",\"rule:coding-style\"]" "$T/place.json"'
# kit add|rm --dir before any kit sync turns it into a plain folder first
HP="$W/helper"; mkdir -p "$HP"; printf 'agent:gerrit\ntool:codex\nnot:mcp:gerrit\n' > "$HP/.agentkit"
kit rm --dir "$HP" rule gerrit-flow >/dev/null 2>&1
check "rm --dir on such a folder: plain first, then the one taken out" '[ "$(grep -v "^#" "$HP/.agentkit")" = "skill:gerrit-review" ] && [ -f "$HP/.claude/skills/gerrit-review/SKILL.md" ]'
# Codex: kit codex-guard (its PreToolUse hook): kit run's limits come in its environment; a command a piece at a time
cg() { printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2" "$3"; }
CGP='*** Begin Patch\n*** Update File: a.txt\n@@\n-x\n+y\n*** End Patch'; CGA='*** Begin Patch\n*** Add File: b.txt\n+y\n*** End Patch'
cgall() { # the answers, one per line
    cg Bash "ls" "$G" | "$@" codex-guard; echo .
    cg mcp__gerrit__get_change "" "$T" | KIT_CODEX_ONLY='Read' "$@" codex-guard; echo .
    cg Bash "cd x && git push origin" "$T" | KIT_CODEX_DENY='Bash(git push:*)' "$@" codex-guard; echo .
    cg Bash "x=\$(git push)" "$T" | KIT_CODEX_DENY='Bash(git push:*)' "$@" codex-guard; echo .
    cg Bash "git status; git pushx" "$T" | KIT_CODEX_DENY="Bash(git status)$LF" "$@" codex-guard; echo .
    cg Bash "git log" "$T" | KIT_CODEX_DENY='Bash(git push:*)' "$@" codex-guard; echo .
    cg Bash "ls" "$T" | KIT_CODEX_ONLY='Read,Edit' "$@" codex-guard; echo .
    cg apply_patch "$CGP" "$T" | KIT_CODEX_ONLY='Read,Bash' "$@" codex-guard; echo .
    cg apply_patch "$CGA" "$T" | KIT_CODEX_ONLY='Read,Bash,Edit' "$@" codex-guard; echo .
    cg apply_patch "$CGP" "$T" | KIT_CODEX_DENY='Write' "$@" codex-guard; echo .
}
d() { printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "kit: %s"}}\n.\n' "$1"; }
out=$(cgall kit)
want=$(printf '.\n.\n'; d 'Bash(git push:*) is not allowed (tools.deny)'; d 'Bash(git push:*) is not allowed (tools.deny)'; d 'Bash(git status) is not allowed (tools.deny)'
       printf '.\n'; d 'this agent does not use Bash (tools.only)'; d 'this agent does not use Edit (tools.only): no changing files'; d 'this agent does not use Write (tools.only): no new files'; printf '.')
check "codex-guard: kit run's limits, a piece at a time, patches as Edit / Write; a folder kit place made limits nothing now" '[ "$out" = "$want" ]'
[ "$out" = "$want" ] || printf '%s\n' "$out" | diff - <(printf '%s\n' "$want") | head -20
[ -n "$PWSH" ] && { out2=$(cgall kps); check "codex-guard: kit.ps1 says the same" '[ "$out2" = "$out" ]'; }
if [ -n "$PWSH" ]; then   # kit.ps1: the same files from such a folder, in a home of its own
  pl() { export HOME="$1/home"; mkdir -p "$HOME/.codex" "$HOME/.omp/agent"; "$2" init "$TEAM" >/dev/null 2>&1
    upl "$1/s/g" "$2" >/dev/null; "$2" list --json --dir "$1/s/g" 2>/dev/null | grep -F '"folder"' | sed 's/, "items": \[$//'
    (cd "$1/s" && for f in $(find . -type f | LC_ALL=C sort); do echo "== $f"; cat "$f"; done); }
  mkdir -p "$T/pl1" "$T/pl2"; P1=$(cd "$T/pl1" && pwd -P); P2=$(cd "$T/pl2" && pwd -P)
  a=$(pl "$P1" kps | sed "s#$P1#W#g"); b=$(pl "$P2" kit | sed "s#$P2#W#g")
  check "kit.ps1 unplace: the same .agentkit, files and here.folder as unix/kit" '[ "$a" = "$b" ] && echo "$a" | grep -qF "\"agent\": null, \"plugins\": []}"'
  [ "$a" = "$b" ] || diff <(echo "$a") <(echo "$b") | head -20
fi
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
