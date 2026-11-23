#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
cd "$T"
# ---------- kit hold, kit sync --only: one skill or plugin kept as it is, or brought alone (kit api 1.17) ----------
# a folder source (as on a computer where the sources are your own folders); the same steps with unix/kit and kit.ps1
hj() { python3 -Ic 'import json,sys
d = json.load(open(sys.argv[1])); v = [i for i in d["items"] if i["kind"] == sys.argv[2] and i["name"] == sys.argv[3]][0]
for k in sys.argv[4].split("."): v = None if v is None else v.get(k)
print("null" if v is None else json.dumps(v) if isinstance(v, bool) else v)' "$@" 2>/dev/null; }
sk() { printf -- '---\nname: %s\ndescription: d\n---\n%s\n' "$1" "$2" > "$S/skills/$1/SKILL.md"; }
run() { # run TAG COMMAND
    local tag=$1 k=$2
    S="$T/src-$tag"; H="$T/home-$tag"; mkdir -p "$S/skills/ha" "$S/skills/hb" "$S/plugins/hp/.claude-plugin" "$S/rules" "$H/.codex"
    sk ha v1; sk hb v1; printf '{"name": "hp", "description": "p1"}\n' > "$S/plugins/hp/.claude-plugin/plugin.json"; echo r > "$S/rules/hr.md"
    (
    export HOME="$H"
    $k init "$S" >/dev/null 2>&1; $k add skill ha hb >/dev/null 2>&1; $k add plugin hp >/dev/null 2>&1
    check "$tag: kit hold rule: refused (rules and MCP are not held)" '! $k hold rule hr >/dev/null 2>&1 && ! $k hold skill nope >/dev/null 2>&1 && ! $k hold skill ha --of >/dev/null 2>&1'
    $k hold skill ha >/dev/null 2>&1; $k hold plugin hp >/dev/null 2>&1
    $k list --json > "$T/$tag-1.json" 2>/dev/null
    check "$tag: kit list: held true for the held ones, null for the rest" '[ "$(hj "$T/$tag-1.json" skill ha held)" = true ] && [ "$(hj "$T/$tag-1.json" plugin hp held)" = true ] && [ "$(hj "$T/$tag-1.json" skill hb held)" = null ]'
    sk ha v2; sk hb v2; printf '{"name": "hp", "description": "p2"}\n' > "$S/plugins/hp/.claude-plugin/plugin.json"
    pl=$(awk -F'\t' '$1 == "plugin" && $2 == "hp" { print $3 }' "$H/.config/agentkit/state.tsv")
    $k sync --dry-run > "$T/$tag-dry.txt" 2>&1
    check "$tag: kit sync --dry-run: the held one is not changed" 'grep -q "ha：固定在這一版" "$T/$tag-dry.txt" && grep -q "hb：更新" "$T/$tag-dry.txt"'
    $k sync >/dev/null 2>&1
    check "$tag: kit sync: the held skill stays (Claude and ~/.agents), the other one is the new one" 'grep -q v1 "$H/.claude/skills/ha/SKILL.md" && grep -q v1 "$H/.agents/skills/ha/SKILL.md" && grep -q v2 "$H/.claude/skills/hb/SKILL.md" && grep -q v2 "$H/.agents/skills/hb/SKILL.md"'
    check "$tag: kit sync: the held plugin: kit's copy stays" '[ "$(awk -F"\t" "\$1 == \"plugin\" && \$2 == \"hp\" { print \$3 }" "$H/.config/agentkit/state.tsv")" = "$pl" ] && grep -q p1 "$H/.config/agentkit/plugins/hp/.claude-plugin/plugin.json"'
    $k list --json > "$T/$tag-2.json" 2>/dev/null
    check "$tag: kit list: the held one: installed is not the source's newest" '[ "$(hj "$T/$tag-2.json" skill ha installed.claude.id)" != "$(hj "$T/$tag-2.json" skill ha version.id)" ] && [ "$(hj "$T/$tag-2.json" skill hb installed.claude.id)" = "$(hj "$T/$tag-2.json" skill hb version.id)" ]'
    sk hb v3
    check "$tag: kit sync --only: wrong ones refused (a rule, not in use, another option with it)" '! $k sync --only rule:hr >/dev/null 2>&1 && ! $k sync --only skill:nope >/dev/null 2>&1 && ! $k sync --only skill:ha --force >/dev/null 2>&1'
    $k sync --only skill:ha >/dev/null 2>&1
    check "$tag: kit sync --only skill:ha: that one is the newest (still held); the other one is not touched" 'grep -q v2 "$H/.claude/skills/ha/SKILL.md" && grep -q v2 "$H/.agents/skills/ha/SKILL.md" && grep -q v2 "$H/.claude/skills/hb/SKILL.md" && [ -d "$H/.claude/skills/hb" ] && [ "$($k list --json 2>/dev/null | python3 -Ic "import json,sys; print([i[\"held\"] for i in json.load(sys.stdin)[\"items\"] if i[\"name\"] == \"ha\"][0])")" = True ]'
    $k sync --only plugin:hp >/dev/null 2>&1
    check "$tag: kit sync --only plugin:hp: kit's copy is the newest" 'grep -q p2 "$H/.config/agentkit/plugins/hp/.claude-plugin/plugin.json"'
    $k hold skill ha --off >/dev/null 2>&1; sk ha v4; $k sync >/dev/null 2>&1
    check "$tag: kit hold --off: kit sync brings it again" 'grep -q v4 "$H/.claude/skills/ha/SKILL.md" && grep -q v3 "$H/.claude/skills/hb/SKILL.md" && ! grep -q "^held	skill:ha	" "$H/.config/agentkit/state.tsv"'
    echo "$pass $fail" > "$T/sub"
    )
    read pass fail < "$T/sub"
}
run sh kit
[ -z "$PWSH" ] || run ps kps
finish
