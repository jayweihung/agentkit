#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
cd "$T"
# ---------- kit add / rm / sync tell the open agents what changed for them (kit 0.14.0, kit api 1.19) ----------
# A fake hc (Herdr's): ls and get from files, every call in a log; send --queue answers queued (or, as an older hc,
# refuses the flag: then --if idle, typed only to an idle one). The same steps with unix/kit and kit.ps1.
mj() { python3 -Ic "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
FH="$T/fakehc"; mkdir -p "$FH/bin"
cat > "$FH/bin/hc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FH/log"
case $1 in
  ls) cat "$FH/ls.json";;
  get) cat "$FH/get-$2.json" 2>/dev/null || exit 1;;
  send) case " $* " in
          *" --queue "*) [ -f "$FH/old" ] && { echo '{"error":{"hint":"see `hc --help`","kind":"usage","message":"unexpected argument '"'"'--queue'"'"' found"}}'; exit 2; }
                         echo '{"queued":true,"status":"working","turn":3}';;
          *" --if idle "*) [ "$(cat "$FH/status-$5" 2>/dev/null)" = idle ] || { echo '{"error":{"kind":"status_mismatch"}}'; exit 1; }; echo '{"status":"working"}';;
        esac;;
esac
exit 0
SH
chmod +x "$FH/bin/hc"
export FH PATH="$FH/bin:$PATH"
sleep 300 & SP=$!   # the terminals' process (one of mine: no other account under it)
run() { # run TAG COMMAND
    local tag=$1 k=$2
    S="$T/src-$tag"; H="$T/home-$tag"; D="$H/proj"
    mkdir -p "$S/skills/ts" "$S/rules" "$S/mcp" "$S/plugins/tp/.claude-plugin" "$S/plugins/tp/hooks" "$H/.codex" "$H/.omp/agent" "$D"
    printf -- '---\nname: ts\ndescription: d\n---\nx\n' > "$S/skills/ts/SKILL.md"
    echo "Rule." > "$S/rules/tr.md"; printf 'command: echo\nargs: [x]\n' > "$S/mcp/tm.yaml"
    printf '{"name": "tp", "description": "p"}\n' > "$S/plugins/tp/.claude-plugin/plugin.json"; echo '{"hooks": {}}' > "$S/plugins/tp/hooks/h.json"
    printf '{"terminals":[{"address":"t1","agent":"claude-code","cwd":"%s","state":"live","status":"idle"},{"address":"t2","agent":"codex","cwd":"%s","state":"live","status":"working"},{"address":"t3","agent":"pi","cwd":"%s","state":"live","status":"working"},{"address":"t4","agent":"claude-code","cwd":"%s","state":"live","status":"done"},{"address":"t5","cwd":"%s","state":"live","status":"idle"},{"address":"m/t9","agent":"claude-code","cwd":"%s","state":"live","status":"idle"}]}\n' "$H" "$H" "$H" "$D" "$H" "$H" > "$FH/ls.json"
    for a in t1 t2 t3 t4; do printf '{"address":"%s","pid":%s,"foreground":{"pid":%s,"cwd":"%s"},"status":{"app":"x","state":"idle"},"status_ms":1}\n' "$a" "$SP" "$SP" "$([ $a = t4 ] && echo "$D" || echo "$H")" > "$FH/get-$a.json"; done
    rm -f "$FH/old" "$FH/log"
    (
    export HOME="$H"
    $k init "$S" >/dev/null 2>&1
    check "$tag: kit init: no agent told (kit init is not a change for them)" '[ ! -s "$FH/log" ]'
    $k add skill ts --json > "$T/$tag-a.json" 2>"$T/$tag-a.err"; rc=$?
    check "$tag: kit add skill --json: omp gets /reload-plugins queued, Claude and Codex see it by themselves; t5 (no agent), m/t9 (another machine) not there" '[ $rc -eq 0 ] && mj "$T/$tag-a.json" "a = {x[\"address\"]: x for x in d[\"agents\"]}; assert sorted(a) == [\"t1\", \"t2\", \"t3\", \"t4\"]; assert a[\"t3\"] == {\"address\": \"t3\", \"tool\": \"omp\", \"need\": \"reload\", \"sent\": False, \"queued\": True}; assert a[\"t1\"][\"need\"] == \"none\" and a[\"t2\"][\"need\"] == \"none\" and not a[\"t1\"][\"queued\"]"'
    check "$tag: kit add: hc send --queue --key reload, once, and said on stderr" '[ "$(grep -c "^send" "$FH/log")" = 1 ] && grep -qx "send --json --queue --key reload t3 /reload-plugins" "$FH/log" && grep -q "已排隊告訴 t3" "$T/$tag-a.err"'
    : > "$FH/log"
    $k add rule tr >/dev/null 2>&1
    check "$tag: kit add rule: Claude and omp get a message where it is (no relaunch), Codex nothing (it reads AGENTS.md every turn)" 'grep -q "^send --json --queue --key reload:kit 剛把規則 tr 加到整個帳號（這個對話開始時還沒有）：請先讀 .*tr.md，之後照它做 t1 kit 剛把規則 tr" "$FH/log" && grep -q " t3 kit 剛把規則 tr" "$FH/log" && grep -q " t4 kit 剛把規則 tr" "$FH/log" && ! grep -q "^send .* t2 " "$FH/log" && [ ! -f "$H/.config/agentkit/notes/pending/relaunch" ]'
    : > "$FH/log"
    $k add mcp tm --json > "$T/$tag-m.json" 2>/dev/null
    check "$tag: kit add mcp: Claude (kit-mcp not used here) and Codex need a relaunch: not sent, a kit pending for your OK; omp /reload-plugins" 'mj "$T/$tag-m.json" "a = {x[\"address\"]: x[\"need\"] for x in d[\"agents\"]}; assert a == {\"t1\": \"relaunch\", \"t2\": \"relaunch\", \"t3\": \"reload\", \"t4\": \"relaunch\"}, a" && [ "$(grep -c "^send" "$FH/log")" = 1 ] && grep -q "要你同意：重開 3 個 agent（t1 Claude Code、t2 Codex、t4 Claude Code）才讀得到新的MCP" "$H/.config/agentkit/notes/pending/relaunch"'
    : > "$FH/log"
    $k add plugin tp >/dev/null 2>&1
    # kit places a plugin through the tools' own CLIs (claude/codex/omp plugin install): a machine without them gets none
    if command -v claude >/dev/null && command -v codex >/dev/null && command -v omp >/dev/null; then
        check "$tag: kit add plugin with hooks: Claude /reload-plugins, omp and Codex a relaunch" 'grep -qx "send --json --queue --key reload t1 /reload-plugins" "$FH/log" && grep -qx "send --json --queue --key reload t4 /reload-plugins" "$FH/log" && [ "$(grep -c "^send" "$FH/log")" = 2 ] && grep -q "t2 Codex、t3 omp" "$H/.config/agentkit/notes/pending/relaunch"'
    else echo "skip: $tag: kit add plugin (claude, codex and omp are not all installed here)"; fi
    : > "$FH/log"; echo idle > "$FH/status-t1"; touch "$FH/old"
    $k rm skill ts --json > "$T/$tag-r.json" 2>"$T/$tag-r.err"
    check "$tag: an hc without --queue: typed with --if idle to the idle one (t1), the busy ones left and said" 'grep -qx "send --json --if idle t1 kit 剛從整個帳號拿掉技能 ts：之後不要再用它" "$FH/log" && mj "$T/$tag-r.json" "a = {x[\"address\"]: x for x in d[\"agents\"]}; assert a[\"t1\"][\"sent\"] and not a[\"t1\"][\"queued\"] and not a[\"t3\"][\"sent\"] and a[\"t3\"][\"need\"] == \"reload\"" && grep -q "在忙的沒告訴" "$T/$tag-r.err" && grep -q "t3：kit 剛從整個帳號拿掉技能 ts" "$T/$tag-r.err"'
    rm -f "$FH/old"; : > "$FH/log"
    $k add --dir "$D" skill ts --no-tell >/dev/null 2>&1
    check "$tag: --no-tell: hc not asked" '[ ! -s "$FH/log" ]'
    $k rm --dir "$D" skill ts >/dev/null 2>&1
    check "$tag: kit rm --dir: only the agent in that folder is told (這個資料夾)" 'grep -q "^send .* t4 kit 剛從這個資料夾拿掉技能 ts" "$FH/log" && [ "$(grep -c "^send" "$FH/log")" = 1 ]'
    : > "$FH/log"
    $k sync --json > "$T/$tag-s.json" 2>/dev/null; rc=$?
    check "$tag: kit sync with nothing changed: hc not asked, agents []" '[ $rc -eq 0 ] && [ ! -s "$FH/log" ] && mj "$T/$tag-s.json" "assert d[\"agents\"] == []"'
    echo "$pass $fail" > "$T/sub"
    )
    read pass fail < "$T/sub"
    cp "$T/$tag-a.json" "$T/$tag-a.out"; cp "$T/$tag-m.json" "$T/$tag-m.out"; cp "$T/$tag-r.json" "$T/$tag-r.out"
}
run sh "$KIT"
if [ -n "$PWSH" ]; then
    run ps kps
    check "kit.ps1: the same JSON as unix/kit (add, add mcp, rm with an older hc)" 'cmp -s "$T/sh-a.out" "$T/ps-a.out" && cmp -s "$T/sh-m.out" "$T/ps-m.out" && cmp -s "$T/sh-r.out" "$T/ps-r.out"'
fi
kill $SP 2>/dev/null; wait $SP 2>/dev/null
finish
