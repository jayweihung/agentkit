#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
cd "$T"
# ---------- kit agents --open --json: this machine's open agents, who waits for you, what still runs (kit 0.16.0, kit api 1.21) ----------
# A fake hc (ls, get from files); the agents are sleeps (one with a background shell under it, as Claude Code's and
# Codex's look in ps); what they said in the reply hook's files (Claude Code) or their own (omp's session, Codex's
# rollouts). unix/kit, then kit.ps1: the same JSON.
mj() { python3 -Ic "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
FH="$T/fakehc"; mkdir -p "$FH/bin"
cat > "$FH/bin/hc" <<'SH'
#!/bin/sh
case $1 in
  ls) cat "$FH/ls.json";;
  get) cat "$FH/get-$2.json" 2>/dev/null || exit 1;;
  *) exit 1;;
esac
SH
chmod +x "$FH/bin/hc"
export FH PATH="$FH/bin:$PATH"
printf '#!/bin/bash\nexec -a "$1" sleep "$2"\n' > "$T/bg"; chmod +x "$T/bg"
now=$(( $(date +%s) * 1000 ))
sleep 300 & P1=$!
bash -c '"$0" "$1" 301 & wait' "$T/bg" "/bin/zsh -c source $HOME/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'npm run dev' < /dev/null" 2>/dev/null & P2=$!
sleep 300 & P3=$!; sleep 300 & P4=$!; sleep 300 & P5=$!
bash -c '"$0" "$1" 302 & wait' "$T/bg" "/bin/zsh -lc npm test --watch" 2>/dev/null & P6=$!
sleep 300 & P7=$!; sleep 300 & P8=$!
D="$T/w"; mkdir -p "$D"/{1,2,3,4,5,6,7,8}
m1=$((now - 60000)); m3=$((now - 11 * 60000))
term() { printf '{"address":"%s","agent":"%s","cwd":"%s","state":"live","status":"%s"}' "$1" "$2" "$3" "$4"; }
printf '{"terminals":[%s,%s,%s,%s,%s,%s,%s,%s,%s,%s]}\n' "$(term t1 claude-code "$D/1" done)" "$(term t2 claude-code "$D/2" done)" "$(term t3 claude-code "$D/3" blocked)" \
    "$(term t4 claude-code "$D/4" idle)" "$(term t5 codex "$D/5" done)" "$(term t6 codex "$D/6" done)" "$(term t7 pi "$D/7" done)" "$(term t8 claude-code "$D/8" idle)" \
    "$(term m/t9 claude-code /x blocked)" '{"address":"t10","cwd":"/x","state":"live","status":"idle"}' > "$FH/ls.json"
get() { printf '{"address":"%s","pid":%s,"foreground":{"pid":%s,"cwd":"%s"},"status":{"app":"x","state":"%s","msg":"%s"},"status_ms":%s}\n' "$1" "$2" "$2" "$3" "$4" "${6:-}" "$5" > "$FH/get-$1.json"; }
get t1 $P1 "$D/1" done $m1; get t2 $P2 "$D/2" done $m1; get t3 $P3 "$D/3" blocked $m3; get t4 $P4 "$D/4" idle $m1
get t5 $P5 "$D/5" done $m1; get t6 $P6 "$D/6" done $m1 "要我繼續嗎？"; get t7 $P7 "$D/7" done $m1; get t8 $P8 "$D/8" idle $m1
C="$HOME/.cache/nvim-jay"; mkdir -p "$C/said" "$C/subs"
printf '{"text":"要推上去嗎？","at":%s}' $((m1 + 1000)) > "$C/said/t1"
printf '{"at":%s,"list":[{"id":"a1","type":"general-purpose","done":false},{"id":"a2","done":true}]}' "$now" > "$C/subs/t1"
printf '{"text":"要推上去嗎？","at":%s}' $((m1 + 1000)) > "$C/said/t2"
printf '{"text":"好了。機器到了跟我說。之後有需要再告訴我。","at":%s}' $((m1 + 1000)) > "$C/said/t4"
printf '{"text":"要不要我順便改 README","at":%s}' $((now - 20 * 60000)) > "$C/said/t8"
R="$HOME/.codex/sessions/2026/11/26"; mkdir -p "$R"
printf '{"type":"session_meta","payload":{"id":"r5","cwd":"%s"}}\n{"type":"event_msg","payload":{"type":"task_started"}}\n{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"**改好了**。\\n\\n1. 要我推上去嗎"}}\n' "$D/5" > "$R/rollout-2026-11-26T00-00-00-r5.jsonl"
printf '{"type":"session_meta","payload":{"id":"s5","parent_thread_id":"r5","cwd":"%s","agent_nickname":"Ada"}}\n{"type":"event_msg","payload":{"type":"task_started"}}\n' "$D/5" > "$R/rollout-2026-11-26T00-00-01-s5.jsonl"
O="$HOME/.omp/agent/sessions/-w-7"; mkdir -p "$O/2026-11-26T00-00-00_s7"
printf '{"type":"session","version":3,"id":"s7","timestamp":"2026-11-26T00:00:00.000Z","cwd":"%s"}\n' "$D/7" > "$O/2026-11-26T00-00-00_s7.jsonl"
printf '{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"c1","toolName":"bash","startedAt":1,"args":{"command":"npm run build\\nx"}}}\n{"type":"message","message":{"role":"toolResult","toolCallId":"c1","details":{"async":{"state":"running","jobId":"j1","type":"bash"},"timeoutSeconds":0},"timestamp":"%s"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$O/2026-11-26T00-00-00_s7.jsonl"
printf '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"建好了，要我部署嗎？"}]}}\n' >> "$O/2026-11-26T00-00-00_s7.jsonl"
printf '{"type":"session_init","task":"x","agent":"task"}\n' > "$O/2026-11-26T00-00-00_s7/sub1.jsonl"
kit pending add "要你同意：上線" --id deploy --pid $P4 >/dev/null 2>&1
check "open: kit pending add for t4's agent" '[ -f "$HOME/.config/agentkit/notes/pending/deploy" ]'
kit agents --open --json > "$T/o.json" 2>"$T/o.err"; rc=$?
check "open: kit agents --open --json: every open agent here (not m/t9 on another machine, not t10 with no agent)" '[ $rc -eq 0 ] && mj "$T/o.json" "assert [a[\"address\"] for a in d[\"agents\"]] == [\"t1\", \"t2\", \"t3\", \"t4\", \"t5\", \"t6\", \"t7\", \"t8\"], d; assert [a[\"tool\"] for a in d[\"agents\"]] == [\"claude\"] * 4 + [\"codex\"] * 2 + [\"omp\", \"claude\"]"'
a() { mj "$T/o.json" "a = {x[\"address\"]: x for x in d[\"agents\"]}[\"$1\"]; $2"; }
check "open: done, its last words ask (the reply hook's said file): waiting since it stopped; its sub-agent running: busy" 'a t1 "assert a[\"waiting\"] == {\"since\": $m1, \"hot\": False, \"why\": \"要推上去嗎？\"} and a[\"busy\"] == \"子 agent 1 個\", a"'
check "open: done but its background shell still runs (Claude Code: sh -c of its shell-snapshots): not waiting, busy says what runs" 'a t2 "assert a[\"waiting\"] is None and a[\"busy\"] == \"npm run dev\", a"'
check "open: blocked 10 minutes and more: hot" 'a t3 "assert a[\"waiting\"] == {\"since\": $m3, \"hot\": True, \"why\": \"在等你允許或回答它（畫面上的提問）\"} and a[\"busy\"] is None, a"'
check "open: idle with words that don't ask (機器到了跟我說, 之後有需要再告訴我); its kit pending waits" 'a t4 "w = a[\"waiting\"]; assert w[\"why\"] == \"要你同意：上線\" and w[\"since\"] > 0 and w[\"hot\"] is False and a[\"busy\"] is None, a"'
check "open: Codex: its rollout's last words (by its folder), its sub-agent (parent_thread_id) running" 'a t5 "assert a[\"waiting\"] == {\"since\": $m1, \"hot\": False, \"why\": \"要我推上去嗎\"} and a[\"busy\"] == \"子 agent 1 個\", a"'
check "open: Codex: a -lc shell still running: busy, not waiting (Herdr's message asks, but it isn't your turn)" 'a t6 "assert a[\"waiting\"] is None and a[\"busy\"] == \"npm test --watch 302\", a"'
check "open: omp: its bash job (async) from its session: busy, not waiting" 'a t7 "assert a[\"waiting\"] is None and a[\"busy\"] == \"npm run build\", a"'
check "open: idle, its words ask (要不要…) 20 minutes ago: hot, since then" 'a t8 "assert a[\"waiting\"] == {\"since\": $((now - 20 * 60000)), \"hot\": True, \"why\": \"要不要我順便改 README\"}, a"'
kit agents --open > /dev/null 2>&1; rc=$?
check "open: without --json: usage" '[ $rc -ne 0 ]'
if [ -n "$PWSH" ]; then
    kps agents --open --json > "$T/p.json" 2>"$T/p.err"
    check "open: kit.ps1: the same JSON" 'cmp -s "$T/o.json" "$T/p.json" || { diff "$T/o.json" "$T/p.json" >&2; false; }'
fi
rm "$FH/ls.json"; kit agents --open --json > "$T/e.json" 2>/dev/null
check "open: hc lists nothing: agents []" 'mj "$T/e.json" "assert d[\"agents\"] == []"'
pkill -P $P2 2>/dev/null; pkill -P $P6 2>/dev/null; kill $P1 $P2 $P3 $P4 $P5 $P6 $P7 $P8 2>/dev/null; wait 2>/dev/null
finish
