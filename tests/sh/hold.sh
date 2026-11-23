#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
cd "$T"
# ---------- what the tools get changes only when asked (kit 0.13.0, kit api 1.18) ----------
# The automatic sync, kit add / rm and kit run keep the version this machine has; kit sync typed brings everything (held
# ones not), kit sync --only KIND:NAME just that one. Rules and MCP come from kit's copy (store/), Claude's rules too.
# A folder source (as on a computer whose sources are your own folders); the same steps with unix/kit and kit.ps1.
hj() { python3 -Ic 'import json,sys
d = json.load(open(sys.argv[1])); v = [i for i in d["items"] if i["kind"] == sys.argv[2] and i["name"] == sys.argv[3]][0]
for k in sys.argv[4].split("."): v = None if v is None else v.get(k)
print("null" if v is None else json.dumps(v) if isinstance(v, bool) else v)' "$@" 2>/dev/null; }
run() { # run TAG COMMAND
    local tag=$1 k=$2
    S="$T/src-$tag"; H="$T/home-$tag"; ST="$T/home-$tag/.config/agentkit/store"
    mkdir -p "$S/skills/ha" "$S/skills/hb" "$S/skills/hc" "$S/plugins/hp/.claude-plugin" "$S/rules" "$S/mcp" "$H/.codex"
    sk() { printf -- '---\nname: %s\ndescription: d\n---\n%s\n' "$1" "$2" > "$S/skills/$1/SKILL.md"; }
    ver() { sk ha "$1"; sk hb "$1"; printf 'Rule %s.\n' "$1" > "$S/rules/hr.md"; printf 'command: echo\nargs:\n  - %s\n' "$1" > "$S/mcp/hm.yaml"
            printf '{"name": "hp", "description": "%s"}\n' "$1" > "$S/plugins/hp/.claude-plugin/plugin.json"; }
    ver v1; sk hc v1
    (
    export HOME="$H"
    $k init "$S" >/dev/null 2>&1; $k add skill ha hb >/dev/null 2>&1; $k add rule hr >/dev/null 2>&1; $k add mcp hm >/dev/null 2>&1; $k add plugin hp >/dev/null 2>&1
    check "$tag: Claude reads the rule from kit's copy, not the source; Codex gets its text" 'grep -qxF "@$ST/rules/hr.md" "$H/.claude/CLAUDE.md" && ! grep -qF "@$S/" "$H/.claude/CLAUDE.md" && grep -qx "Rule v1." "$ST/rules/hr.md" && grep -qx "Rule v1." "$H/.codex/AGENTS.md"'
    ver v2
    $k add skill hc >/dev/null 2>&1                          # (kit add syncs: in the way the automatic one does)
    check "$tag: kit add (as the automatic sync): the new one comes; what this machine has stays (rule, skills, MCP, plugin)" 'grep -q v1 "$H/.claude/skills/hc/SKILL.md" && grep -qx "Rule v1." "$ST/rules/hr.md" && grep -qx "Rule v1." "$H/.codex/AGENTS.md" && grep -q v1 "$H/.claude/skills/ha/SKILL.md" && grep -q v1 "$H/.agents/skills/hb/SKILL.md" && grep -q "\"v1\"" "$H/.claude.json" && ! grep -q "\"v2\"" "$H/.claude.json" && grep -q v1 "$H/.config/agentkit/plugins/hp/.claude-plugin/plugin.json"'
    $k list --json > "$T/$tag-1.json" 2>/dev/null
    rid=$(git hash-object "$ST/rules/hr.md"); rid=${rid:0:8}
    check "$tag: kit list: installed is kit's copy (Claude's rule too), not the source's newest" '[ "$(hj "$T/$tag-1.json" rule hr installed.claude.id)" = "$rid" ] && [ "$(hj "$T/$tag-1.json" rule hr installed.codex.id)" = "$rid" ] && [ "$(hj "$T/$tag-1.json" rule hr version.id)" != "$rid" ] && [ "$(hj "$T/$tag-1.json" skill ha installed.claude.id)" != "$(hj "$T/$tag-1.json" skill ha version.id)" ] && [ "$(hj "$T/$tag-1.json" mcp hm installed.claude.id)" != "$(hj "$T/$tag-1.json" mcp hm version.id)" ]'
    check "$tag: kit sync --only: wrong ones refused (a kind, not there, another option with it)" '! $k sync --only agent:x >/dev/null 2>&1 && ! $k sync --only skill:nope >/dev/null 2>&1 && ! $k sync --only skill:ha --force >/dev/null 2>&1'
    $k sync --only rule:hr >/dev/null 2>&1
    check "$tag: kit sync --only rule:hr: the rule is the newest (Claude's copy, Codex); the rest stays" 'grep -qx "Rule v2." "$ST/rules/hr.md" && grep -qx "Rule v2." "$H/.codex/AGENTS.md" && grep -q v1 "$H/.claude/skills/ha/SKILL.md" && grep -q "\"v1\"" "$H/.claude.json"'
    $k sync --only mcp:hm >/dev/null 2>&1; $k sync --only skill:ha >/dev/null 2>&1
    check "$tag: kit sync --only mcp:hm, skill:ha: those two; hb and the plugin stay" 'grep -q "\"v2\"" "$H/.claude.json" && grep -q v2 "$H/.claude/skills/ha/SKILL.md" && grep -q v2 "$H/.agents/skills/ha/SKILL.md" && grep -q v1 "$H/.claude/skills/hb/SKILL.md" && grep -q v1 "$H/.config/agentkit/plugins/hp/.claude-plugin/plugin.json"'
    $k hold skill hb >/dev/null 2>&1; $k hold mcp hm >/dev/null 2>&1; ver v3
    $k list --json > "$T/$tag-2.json" 2>/dev/null
    check "$tag: kit list: held true for the held ones (a skill, an MCP), null for the rest" '[ "$(hj "$T/$tag-2.json" skill hb held)" = true ] && [ "$(hj "$T/$tag-2.json" mcp hm held)" = true ] && [ "$(hj "$T/$tag-2.json" skill ha held)" = null ]'
    $k sync --dry-run > "$T/$tag-dry.txt" 2>&1
    check "$tag: kit sync --dry-run: the held one is not changed, the other one is" 'grep -q "hb：固定在這一版" "$T/$tag-dry.txt" && grep -q "ha：更新" "$T/$tag-dry.txt"'
    $k sync >/dev/null 2>&1
    check "$tag: kit sync (typed): everything the newest but the held ones" 'grep -q v3 "$H/.claude/skills/ha/SKILL.md" && grep -qx "Rule v3." "$ST/rules/hr.md" && grep -q p "$H/.config/agentkit/plugins/hp/.claude-plugin/plugin.json" && grep -q v3 "$H/.config/agentkit/plugins/hp/.claude-plugin/plugin.json" && grep -q v1 "$H/.claude/skills/hb/SKILL.md" && grep -q "\"v2\"" "$H/.claude.json"'
    $k sync --only skill:hb >/dev/null 2>&1; $k hold mcp hm --off >/dev/null 2>&1; $k sync >/dev/null 2>&1
    check "$tag: kit sync --only takes a held one too; kit hold --off: kit sync brings it" 'grep -q v3 "$H/.claude/skills/hb/SKILL.md" && grep -q "\"v3\"" "$H/.claude.json" && ! grep -q "^held	mcp:hm	" "$H/.config/agentkit/state.tsv" && grep -q "^held	skill:hb	" "$H/.config/agentkit/state.tsv"'
    $k rm rule hr >/dev/null 2>&1; printf 'Rule v4.\n' > "$S/rules/hr.md"; $k add rule hr >/dev/null 2>&1
    check "$tag: a rule taken away and added again: the source's newest" 'grep -qx "Rule v4." "$ST/rules/hr.md" && grep -qx "Rule v4." "$H/.codex/AGENTS.md"'
    echo "$pass $fail" > "$T/sub"
    )
    read pass fail < "$T/sub"
}
run sh kit
[ -z "$PWSH" ] || run ps kps
finish
