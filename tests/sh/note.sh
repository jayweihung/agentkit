#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
mj() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
snap() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3); }
at0() { sed -E 's/^  "at": [0-9]+,$/  "at": 0,/'; }
# ---------- kit note: an agent's one or two lines about where it is ----------
NT="$T/note"; mkdir -p "$NT/bin" "$NT/w"
printf '#!/bin/sh\n"$@"\n' > "$NT/bin/claude"; printf '#!/bin/sh\n"$@"\n' > "$NT/bin/codex"; chmod +x "$NT/bin/claude" "$NT/bin/codex"
note_sh() { ( cd "$NT/w" && AGENTKIT_CONFIG="$NT/conf" "$@" ); }
out=$(note_sh "$NT/bin/claude" "$KIT" note "改好 parser；下一步跑測試" 2>&1); rc=$?
check "note: written under the claude above it" '[ $rc -eq 0 ] && echo "$out" | grep -q 進度記下了 && [ -n "$(ls "$NT/conf/notes" | grep -E "^[0-9]+$")" ]'
out=$(note_sh "$NT/bin/codex" "$KIT" note --json "第一行
目標：修 #12" 2>/dev/null)
check "note --json: the codex above, its folder, two lines" 'printf "%s" "$out" | mj /dev/stdin "assert d[\"tool\"]==\"codex\" and d[\"text\"]==\"第一行\\n目標：修 #12\" and d[\"dir\"].endswith(\"/note/w\") and d[\"at\"]>0"'
out=$(note_sh "$NT/bin/claude" sh -c "\"$KIT\" note \"一\" >/dev/null && \"$KIT\" note && \"$KIT\" note --pid \$PPID --json" 2>&1)
check "note: the agent reads its own back (text and --pid --json)" 'echo "$out" | grep -qx 一 && echo "$out" | grep -q "（剛剛）" && echo "$out" | tail -n 1 | mj /dev/stdin "assert d[\"text\"]==\"一\" and d[\"tool\"]==\"claude\""'
out=$(note_sh "$KIT" note --pid 1 --json 2>/dev/null)
check "note --pid --json: none -> text null" 'printf "%s" "$out" | mj /dev/stdin "assert d[\"text\"] is None and d[\"pid\"]==1"'
out=$(note_sh "$KIT" note --history --json --dir "$NT/w" 2>/dev/null)
check "note --history --json: that folder, newest first, gone agents too" 'printf "%s" "$out" | mj /dev/stdin "n=d[\"notes\"]; assert len(n)==3 and n[0][\"text\"]==\"一\" and n[2][\"text\"].startswith(\"改好\")"'
out=$(note_sh "$KIT" note --history --dir "$NT/w" 2>&1)
check "note --history: for people, two lines indented" 'echo "$out" | grep -qx "  目標：修 #12"'
out=$(note_sh "$KIT" note --history --dir /nowhere 2>&1)
check "note --history: nothing there said so" 'echo "$out" | grep -q 還沒有人寫過進度'
out=$(note_sh "$NT/bin/claude" "$KIT" note "a
b
c" 2>&1); rc=$?
check "note: three lines refused" '[ $rc -ne 0 ] && echo "$out" | grep -q 最多兩行'
out=$(note_sh "$NT/bin/claude" "$KIT" note --json "$(printf "%01100d" 0)" 2>/dev/null); rc=$?
check "note: too long refused (code too-long)" '[ $rc -ne 0 ] && printf "%s" "$out" | mj /dev/stdin "assert d[\"error\"][\"code\"]==\"too-long\""'
rm -f "$NT/na"; (cd "$NT/w" && AGENTKIT_CONFIG="$NT/conf" "$KIT" note x --json > "$NT/na" 2>/dev/null &)   # parent gone: nothing above
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$NT/na" ] && break; sleep 0.25; done
check "note: no agent above -> no-agent" 'mj "$NT/na" "assert d[\"error\"][\"code\"]==\"no-agent\""'
sleep 30 & SP=$!
note_sh "$KIT" note --pid $SP "睡著的" >/dev/null 2>&1
printf 'old start\nclaude\n/x\n1\nold text\n' > "$NT/conf/notes/$SP"
out=$(note_sh "$KIT" note --pid $SP --json 2>/dev/null)
check "note: a reused pid (other start) is not shown" 'printf "%s" "$out" | mj /dev/stdin "assert d[\"text\"] is None"'
kill $SP 2>/dev/null; wait $SP 2>/dev/null
note_sh "$NT/bin/claude" "$KIT" note "z" >/dev/null 2>&1
check "note: notes of gone processes cleared on the next write" '[ ! -e "$NT/conf/notes/$SP" ]'
# Codex's sandbox: no ps, so the note goes under its thread; found for the Codex's pid through its newest rollout
TID=01a1d92c-3657-7dc0-8a16-10aed8cdcde4; mkdir -p "$NT/w2" "$HOME/.codex/sessions/2026/11/14"
rm -f "$NT/cx"; (cd "$NT/w2" && CODEX_THREAD_ID=$TID AGENTKIT_CONFIG="$NT/conf" "$KIT" note --json "沙箱裡寫的" > "$NT/cx" 2>/dev/null &)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$NT/cx" ] && break; sleep 0.25; done
check "note in Codex's sandbox (no agent found, CODEX_THREAD_ID): kept under its thread" 'mj "$NT/cx" "assert d[\"pid\"] is None and d[\"session\"]==\"$TID\" and d[\"tool\"]==\"codex\" and d[\"text\"]==\"沙箱裡寫的\"" && [ -f "$NT/conf/notes/codex-$TID" ]'
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"},"cwd":"%s"}\n' "$TID" "$NT/w2" "$NT/w2" > "$HOME/.codex/sessions/2026/11/14/rollout-2026-11-14T16-25-03-$TID.jsonl"
(cd "$NT/w2" && exec "$NT/bin/codex" sleep 30) & CXP=$!
sleep 0.5
cxo=$(note_sh "$KIT" note --pid $CXP --json 2>/dev/null)
check "note --pid of that Codex: its thread's note (newest rollout in its folder)" 'printf "%s" "$cxo" | mj /dev/stdin "assert d[\"pid\"]==$CXP and d[\"session\"]==\"$TID\" and d[\"text\"]==\"沙箱裡寫的\""'
out=$(note_sh "$KIT" note --history --json --dir "$NT/w2" 2>/dev/null)
check "note --history: a Codex thread's note has pid null and its session" 'printf "%s" "$out" | mj /dev/stdin "n=d[\"notes\"][0]; assert n[\"pid\"] is None and n[\"session\"]==\"$TID\""'
if [ -n "$PWSH" ]; then
    b=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" note --pid $CXP --json 2>/dev/null)
    check "kit.ps1 note --pid of that Codex: the same JSON" '[ "$cxo" = "$b" ] && printf "%s" "$b" | mj /dev/stdin "assert d[\"session\"]==\"$TID\" and d[\"text\"]==\"沙箱裡寫的\""'
    a=$(note_sh "$KIT" note --history --json --dir "$NT/w2" 2>/dev/null); b=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" note --history --json --dir "$NT/w2" 2>/dev/null)
    check "kit.ps1 note --history with a Codex thread: the same JSON" '[ "$a" = "$b" ]'
    rm -f "$NT/cx"; (cd "$NT/w2" && CODEX_THREAD_ID=$TID AGENTKIT_CONFIG="$NT/conf" "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" note --json > "$NT/cx" 2>/dev/null &)
    for i in $(seq 1 40); do [ -s "$NT/cx" ] && break; sleep 0.25; done
    check "kit.ps1 in Codex's sandbox: reads its thread's note" 'mj "$NT/cx" "assert d[\"session\"]==\"$TID\" and d[\"text\"]==\"沙箱裡寫的\""'
fi
kill $CXP 2>/dev/null; wait $CXP 2>/dev/null
if [ -n "$PWSH" ]; then
    out=$(note_sh "$NT/bin/claude" "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" note --json "PS 寫的
第二行" 2>/dev/null)
    check "kit.ps1 note --json: the same fields" 'printf "%s" "$out" | mj /dev/stdin "assert d[\"tool\"]==\"claude\" and d[\"text\"]==\"PS 寫的\\n第二行\" and d[\"dir\"].endswith(\"/note/w\")"'
    a=$(note_sh "$KIT" note --history --json --dir "$NT/w" 2>/dev/null); b=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" note --history --json --dir "$NT/w" 2>/dev/null)
    check "kit.ps1 note --history --json: the same JSON as kit" '[ -n "$a" ] && [ "$a" = "$b" ]'
    a=$(note_sh "$KIT" note --pid 1 --json 2>/dev/null); b=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" note --pid 1 --json 2>/dev/null)
    check "kit.ps1 note --pid --json: the same when there is none" '[ "$a" = "$b" ]'
    out=$(note_sh "$NT/bin/claude" "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" note "a
b
c" 2>&1); rc=$?
    check "kit.ps1 note: three lines refused" '[ $rc -ne 0 ] && echo "$out" | grep -q 最多兩行'
fi

# ---------- kit pending: what an agent or a service waits on its owner for (kind owner in status --json) ----------
PD="$NT/conf/notes/pending"
(cd "$NT/w" && exec "$NT/bin/claude" sleep 30) & CP=$!
sleep 0.5
out=$(note_sh "$KIT" pending add --pid $CP --id core-0001 "要你同意：裝伺服器的 core 0001" 2>&1); rc=$?
check "pending add --pid: kept under its id, tied to that agent" '[ $rc -eq 0 ] && echo "$out" | grep -qF "記下了：core-0001（等到了跑 kit pending done core-0001）" && [ "$(sed -n 2p "$PD/core-0001")" = "$CP" ]'
check "pending add: the agent's process and the ones above it (for finding its terminal)" '[ "$(sed -n 6p "$PD/core-0001" | cut -d" " -f1)" = "$CP" ] && [ "$(sed -n 6p "$PD/core-0001" | wc -w | tr -d " ")" -ge 2 ]'
note_sh "$KIT" pending add --keep --id svc "服務在等你：換金鑰" >/dev/null 2>&1
check "pending add --keep: no agent (until kit pending done)" '[ -f "$PD/svc" ] && [ -z "$(sed -n 2p "$PD/svc")" ] && [ "$(sed -n 5p "$PD/svc")" = "服務在等你：換金鑰" ]'
note_sh "$NT/bin/claude" "$KIT" pending add --id auto "等一下" >/dev/null 2>&1
check "pending add: tied to the agent above it (the claude that ran it)" 'case "$(sed -n 2p "$PD/auto")" in ""|*[!0-9]*) false;; esac'
sed -i.bak '4s/.*/1000/' "$PD/svc"; rm -f "$PD/svc.bak"
note_sh "$KIT" pending add --keep --id svc "服務在等你：換金鑰（第二次）" >/dev/null 2>&1
snap "$NT/conf" > "$T/pd.snap"
out=$(AGENTKIT_CONFIG="$NT/conf" "$KIT" status --json 2>/dev/null); rc=$?
check "status --json: owner items, the agent's gone one not listed, the same id again waits since the first time" '[ $rc -eq 0 ] && printf "%s" "$out" | mj /dev/stdin "p=d[\"pending\"]; assert [x[\"id\"] for x in p]==[\"core-0001\",\"svc\"], p; a,b=p; assert a[\"kind\"]==\"owner\" and a[\"pid\"]==$CP and a[\"what\"]==\"要你同意：裝伺服器的 core 0001\" and a[\"dir\"].endswith(\"/note/w\") and a[\"since\"]>1e12 and a[\"machine\"]; assert b[\"pid\"] is None and b[\"since\"]==1000000 and b[\"what\"].endswith(\"（第二次）\")"'
check "status --json: still writes nothing (the gone agent's item is left for kit pending)" 'snap "$NT/conf" | cmp -s - "$T/pd.snap"'
if [ -n "$PWSH" ]; then
    a=$(AGENTKIT_CONFIG="$NT/conf" "$KIT" status --json 2>/dev/null | at0); b=$(AGENTKIT_CONFIG="$NT/conf" kps status --json 2>/dev/null | at0)
    check "kit.ps1 status --json: the same owner items" '[ -n "$a" ] && [ "$a" = "$b" ]'
    a=$(note_sh "$KIT" pending 2>&1); b=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" pending 2>&1)
    check "kit.ps1 pending: the same list" '[ "$a" = "$b" ]'
    out=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" pending add --keep --id ps1 "PS 記的" 2>&1); rc=$?
    check "kit.ps1 pending add: the same file kit reads" '[ $rc -eq 0 ] && echo "$out" | grep -qF "記下了：ps1" && AGENTKIT_CONFIG="$NT/conf" "$KIT" status --json 2>/dev/null | mj /dev/stdin "assert [x[\"what\"] for x in d[\"pending\"] if x[\"id\"]==\"ps1\"]==[\"PS 記的\"]"'
    out=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" pending done ps1 2>&1)
    check "kit.ps1 pending done" 'echo "$out" | grep -qF "拿掉了：ps1" && [ ! -e "$PD/ps1" ]'
    out=$(note_sh "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" pending add --id ../x y 2>&1); rc=$?
    check "kit.ps1 pending add: a bad id refused" '[ $rc -ne 0 ] && echo "$out" | grep -q 用法'
fi
out=$(note_sh "$KIT" pending 2>&1)
check "pending: lists what waits; the gone agent's item removed" 'echo "$out" | grep -F "core-0001：要你同意：裝伺服器的 core 0001（剛剛，" | grep -qF "/note/w）" && echo "$out" | grep -qF "svc：服務在等你：換金鑰（第二次）" && [ ! -e "$PD/auto" ]'
out=$(note_sh "$KIT" pending done svc 2>&1); o2=$(note_sh "$KIT" pending done svc 2>&1); rc=$?
check "pending done: removed; again: says there is none (not an error)" 'echo "$out" | grep -qF "拿掉了：svc" && [ ! -e "$PD/svc" ] && [ $rc -eq 0 ] && echo "$o2" | grep -qF "沒有 svc 這一項"'
out=$(note_sh "$KIT" pending add --id ../x y 2>&1); rc=$?; o2=$(note_sh "$KIT" pending add --keep --pid 1 y 2>&1); r2=$?
o3=$(note_sh "$KIT" pending add --keep "$(printf "%0301d" 0)" 2>&1); r3=$?
check "pending add: a bad id, --keep with --pid, too long: refused" '[ $rc -ne 0 ] && echo "$out" | grep -q 用法 && [ $r2 -ne 0 ] && echo "$o2" | grep -q 用法 && [ $r3 -ne 0 ] && echo "$o3" | grep -q 太長'
kill $CP 2>/dev/null; wait $CP 2>/dev/null
out=$(AGENTKIT_CONFIG="$NT/conf" "$KIT" status --json 2>/dev/null)
check "status --json: the agent gone, its item not listed" 'echo "$out" | grep -qxF "  \"pending\": [],"'
out=$(note_sh "$KIT" pending 2>&1)
check "pending: nothing waits, said so" 'echo "$out" | grep -qF "沒有在等你的事" && [ -z "$(ls "$PD")" ]'

finish
