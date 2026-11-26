#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
cd "$T"
# ---------- kit list --json: since when a source has changes kit push would send, and a reminder in Herdr (kit 0.15.0, kit api 1.20) ----------
# A fake hc: hc doc set (the notice, on stdin) kept in a file; as an older hc it doesn't know doc. unix/kit, then kit.ps1
# in the same account (the same unsent.tsv).
mj() { python3 -Ic "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
FH="$T/fakehc"; mkdir -p "$FH/bin"
cat > "$FH/bin/hc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FH/log"
[ "$1" = doc ] || exit 1
[ -f "$FH/old" ] && { echo '{"error":{"kind":"usage","message":"unrecognized subcommand '"'"'doc'"'"'"}}'; exit 2; }
cat >> "$FH/doc"; echo >> "$FH/doc"
SH
chmod +x "$FH/bin/hc"
export FH PATH="$FH/bin:$PATH"
G() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
S="$T/src-u"; mkdir -p "$S/rules"; echo "Rule." > "$S/rules/ur.md"; G -C "$S" init -q; G -C "$S" add -A; G -C "$S" commit -qm v1
UN="$HOME/.config/agentkit/unsent.tsv"
src() { mj "$1" "s = [x for x in d[\"sources\"] if x[\"name\"] == \"src-u\"][0]; print(json.dumps(s[\"dirty_since\"]))"; }
kit init "$S" >/dev/null 2>&1
kit list --json > "$T/l0.json" 2>/dev/null
check "unsent: a source with nothing to send: dirty_since null, nothing kept, hc not asked" '[ "$(src "$T/l0.json")" = null ] && [ ! -f "$UN" ] && [ ! -s "$FH/log" ]'
echo "Rule 2." > "$S/rules/ur.md"
t0=$(( $(date +%s) * 1000 )); kit list --json > "$T/l1.json" 2>/dev/null; t1=$(( $(date +%s) * 1000 + 1000 )); s1=$(src "$T/l1.json")
kit list --json > "$T/l2.json" 2>/dev/null
check "unsent: changed: dirty_since is when kit first saw it (ms), the same next time (kept in unsent.tsv)" '[ "$s1" -ge "$t0" ] && [ "$s1" -le "$t1" ] && [ "$(src "$T/l2.json")" = "$s1" ] && grep -qx "src-u	$s1	0" "$UN" && [ ! -s "$FH/log" ]'
old=$((s1 - 31 * 60000)); printf 'src-u\t%s\t0\n' "$old" > "$UN"
n0=$(( $(date +%s) * 1000 )); kit list --json > "$T/l3.json" 2>/dev/null; now=$(( $(date +%s) * 1000 + 1000 ))
check "unsent: 30 minutes and more: a notice in Herdr (hc doc set notice.kit-unsent, on stdin), reminded again in 2 hours" 'grep -qx "doc set notice.kit-unsent -" "$FH/log" && mj "$FH/doc" "assert d == {\"id\": \"src-u:$old\", \"title\": \"Kit 來源還沒送出\", \"body\": \"src-u 有改動 31 分鐘還沒送出：其他機器拿不到（kit push --to src-u）\"}, d" && u=$(cut -f 3 "$UN") && [ "$u" -ge $((n0 + 7200000)) ] && [ "$u" -le $((now + 7200000)) ]'
: > "$FH/log"; kit list --json > /dev/null 2>&1
check "unsent: within the 2 hours: not again" '[ ! -s "$FH/log" ]'
printf 'src-u\t%s\t0\n' "$old" > "$UN"; touch "$FH/old"; : > "$FH/log"
kit list --json > "$T/l4.json" 2>/dev/null; rc=$?
check "unsent: an hc without doc: nothing said, asked again next time (until stays 0)" '[ $rc -eq 0 ] && grep -q "^doc set" "$FH/log" && grep -qx "src-u	$old	0" "$UN" && [ "$(src "$T/l4.json")" = "$old" ]'
if [ -n "$PWSH" ]; then
    kps list --json > "$T/p4.json" 2>/dev/null
    check "unsent: kit.ps1 reads the same unsent.tsv: the same sources" '[ "$(src "$T/p4.json")" = "$old" ] && grep -qx "src-u	$old	0" "$UN"'
    rm -f "$FH/old"; : > "$FH/log"; : > "$FH/doc"
    kps list --json > /dev/null 2>&1
    check "unsent: kit.ps1 puts the same notice" 'mj "$FH/doc" "assert d[\"id\"] == \"src-u:$old\" and d[\"body\"].startswith(\"src-u 有改動 \")" && [ "$(cut -f 3 "$UN")" -gt "$old" ]'
fi
G -C "$S" commit -qam v2
kit list --json > "$T/l5.json" 2>/dev/null
check "unsent: nothing left for kit push to send (committed): dirty_since null again, forgotten" '[ "$(src "$T/l5.json")" = null ] && [ ! -f "$UN" ]'
finish
