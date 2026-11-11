#!/usr/bin/env bash
# Compare json.awk with Python's json on tricky inputs and on edit operations.
# Usage: tests/json_test.sh [awk-binary]   (Python is only needed for this test)
set -u
AWK=${1:-awk}
HERE=$(cd "$(dirname "$0")" && pwd)
JA="$HERE/../unix/json.awk"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

py_fmt() { python3 -c 'import json,sys
s=open(sys.argv[1]).read()
d=json.loads(s) if s.strip() else {}
out=json.dumps(d,indent=2,ensure_ascii=False)
sys.stdout.write(out+("\n" if s.endswith("\n") else ""))' "$1"; }

# 1. formatting: awk output must equal Python's indent=2 output
i=0
while IFS= read -r line; do
  i=$((i+1)); printf '%s' "$line" > "$T/in$i.json"
  LC_ALL=C $AWK -f "$JA" "$T/in$i.json" > "$T/a" 2>/dev/null; rc=$?
  py_fmt "$T/in$i.json" > "$T/p" 2>/dev/null
  if [ $rc -eq 0 ] && cmp -s "$T/a" "$T/p"; then ok; else bad "format case $i: $line"; fi
done <<'CASES'
{}
[]
{"a":1}
{"a":"x\"y","b":"back\\slash\\","c":""}
{"u":"中文 字","e":"é","n":null,"t":true,"f":false}
{"num":[1,-2.5,10,0.0001],"nest":{"x":{"y":[[],{}]}}}
{"s":"a\\\"b","t":"\\\\","w":"tab\there"}
[{"a":[1,{"b":[]}]},"x",[["y"]]]
{"k with space":"v","emoji":"😀"}
CASES

# 1b. numbers are kept exactly as written (Python would rewrite 3e10)
printf '[3e10,1E-5,-0]' > "$T/num.json"
v=$(LC_ALL=C $AWK -f "$JA" "$T/num.json")
[ "$v" = $'[\n  3e10,\n  1E-5,\n  -0\n]' ] && ok || bad "numbers changed: $v"

# 2. bad JSON must fail with status 2 and print nothing
for badjson in '{"a":' '{"a" 1}' '[1,,2]' '{"a":"x' 'nope'; do
  printf '%s' "$badjson" > "$T/bad.json"
  out=$(LC_ALL=C $AWK -f "$JA" "$T/bad.json" 2>/dev/null); rc=$?
  if [ $rc -eq 2 ] && [ -z "$out" ]; then ok; else bad "bad json accepted: $badjson (rc=$rc)"; fi
done

# 3. operations compared with the same edits done in Python
cat > "$T/base.json" <<'J'
{
  "mcpServers": {
    "keep": {
      "command": "x"
    }
  },
  "permissions": {
    "deny": [
      "Bash(rm *)"
    ]
  }
}
J
printf 'set\tmcpServers.gerrit\t{"command":"uvx","args":["--index-url","https://x/simple","gerrit-mcp-server==1.0"],"env":{"GERRIT_CONFIG":"${HOME}/.config/gerrit/gerrit_config.json"}}\n' > "$T/ops"
printf 'addstr\tpermissions.deny\tmcp__gerrit__submit_change\n' >> "$T/ops"
printf 'addstr\tpermissions.deny\tBash(rm *)\n' >> "$T/ops"
printf 'addstr\tnew.list\twith "quote" and \\ back\n' >> "$T/ops"
printf 'del\tmcpServers.keep\n' >> "$T/ops"
printf 'del\tno.such.path\n' >> "$T/ops"
printf 'rmstr\tpermissions.deny\tnot-there\n' >> "$T/ops"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops" "$T/base.json" > "$T/a"; rc=$?
python3 - "$T/base.json" > "$T/p" <<'P'
import json,sys
s=open(sys.argv[1]).read(); d=json.loads(s)
d["mcpServers"]["gerrit"]={"command":"uvx","args":["--index-url","https://x/simple","gerrit-mcp-server==1.0"],"env":{"GERRIT_CONFIG":"${HOME}/.config/gerrit/gerrit_config.json"}}
d["permissions"]["deny"].append("mcp__gerrit__submit_change")
d.setdefault("new",{}).setdefault("list",[]).append('with "quote" and \\ back')
del d["mcpServers"]["keep"]
sys.stdout.write(json.dumps(d,indent=2,ensure_ascii=False)+"\n")
P
if [ $rc -eq 0 ] && cmp -s "$T/a" "$T/p"; then ok; else bad "ops"; diff "$T/a" "$T/p" | head -20; fi

# rmstr then get
printf 'rmstr\tpermissions.deny\tBash(rm *)\n' > "$T/ops2"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops2" "$T/base.json" > "$T/b"
v=$(LC_ALL=C $AWK -f "$JA" -v get=permissions.deny "$T/b")
[ "$v" = "[]" ] && ok || bad "rmstr/get got: $v"
LC_ALL=C $AWK -f "$JA" -v get=no.such "$T/b" >/dev/null 2>&1; [ $? -eq 1 ] && ok || bad "get missing should exit 1"

# addjson / rmjson: objects in an array, deduped by value
cat > "$T/h.json" <<'J'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "mine"
          }
        ]
      }
    ]
  }
}
J
H='{"hooks":[{"type":"command","command":"kit sync --hook"}]}'
printf 'addjson\thooks.SessionStart\t%s\naddjson\thooks.SessionStart\t%s\n' "$H" "$H" > "$T/ops4"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops4" "$T/h.json" > "$T/h2"
v=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d["hooks"]["SessionStart"]),d["hooks"]["SessionStart"][1]["hooks"][0]["command"],d["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$T/h2")
[ "$v" = "2 kit sync --hook mine" ] && ok || bad "addjson got: $v"
printf 'rmjson\thooks.SessionStart\t%s\n' "$H" > "$T/ops5"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops5" "$T/h2" > "$T/h3"
cmp -s "$T/h.json" "$T/h3" && ok || bad "rmjson did not restore"; 

# rmwhere / addnear: find array items by a key anywhere in the tree (Herdr layouts)
cat > "$T/l.json" <<'J'
{"id":"root","type":"row","children":[
  {"id":"bar","type":"row","children":[{"id":"tabs","content":{"mod":"tabs"}},{"id":"x","content":{"mod":"kit"}}]},
  {"id":"body","type":"row","children":[{"id":"main","content":{"tab":"active"}},{"id":"old","children":[{"content":{"mod":"kit"}}]}]},
  {"id":"keep","content":{"mod":"tabsx"}}]}
J
P='{"id":"kit-panel","type":"column","children":[{"id":"kit","type":"block","content":{"mod":"kit"}}],"hidden":true}'
printf 'rmwhere\tcontent.mod\tkit\nrmwhere\tid\told\naddnear\tcontent.mod\ttabs\t{"id":"kit-toggle"}\naddnear\tcontent.tab\tactive\t%s\naddnear\tcontent.mod\ttabs\t{"id":"kit-toggle"}\naddnear\tcontent.mod\tnone\t{"id":"no"}\n' "$P" > "$T/ops6"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops6" "$T/l.json" > "$T/a"; rc=$?
python3 - "$T/l.json" "$P" > "$T/p" <<'P'
import json,sys
d=json.load(open(sys.argv[1])); bar,body,keep=d["children"]
del bar["children"][1]; del body["children"][1]
bar["children"].append({"id":"kit-toggle"}); body["children"].append(json.loads(sys.argv[2]))
sys.stdout.write(json.dumps(d,indent=2,ensure_ascii=False)+"\n")
P
if [ $rc -eq 0 ] && cmp -s "$T/a" "$T/p"; then ok; else bad "rmwhere/addnear"; diff "$T/a" "$T/p" | head -20; fi

# swapwhere: change KEY's value wherever it is STRING (a layout's pane header: "pane" -> "kit-pane"), and back
cat > "$T/s.json" <<'J'
{"children":[{"content":{"tab":"active","pane":{"header":{"content":{"mod":"pane"},"reveal":"always"}}}},{"content":{"mod":"panes"}},{"x":{"content":{"mod":"pane"}}}]}
J
printf 'swapwhere\tcontent.mod\tpane\tkit-pane\n' > "$T/ops7"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops7" "$T/s.json" > "$T/s2"; rc=$?
v=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["children"];print(d[0]["content"]["pane"]["header"]["content"]["mod"],d[1]["content"]["mod"],d[2]["x"]["content"]["mod"])' "$T/s2")
[ $rc -eq 0 ] && [ "$v" = "kit-pane panes kit-pane" ] && ok || bad "swapwhere got: $v"
printf 'swapwhere\tcontent.mod\tkit-pane\tpane\n' > "$T/ops8"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops8" "$T/s2" > "$T/s3"
python3 -c 'import json,sys;sys.stdout.write(json.dumps(json.load(open(sys.argv[1])),indent=2)+"\n")' "$T/s.json" > "$T/s4"
cmp -s "$T/s3" "$T/s4" && ok || bad "swapwhere back"

# empty file counts as {}
: > "$T/empty.json"
printf 'set\ta\t1\n' > "$T/ops3"
v=$(LC_ALL=C $AWK -f "$JA" -v ops="$T/ops3" "$T/empty.json")
[ "$v" = $'{\n  "a": 1\n}' ] && ok || bad "empty file: $v"

# a UTF-8 BOM and CRLF line ends stay as they were (the same as kit.ps1)
printf '\357\273\277{"a": 1}\r\n' > "$T/bom.json"
LC_ALL=C $AWK -f "$JA" -v ops="$T/ops3" "$T/bom.json" > "$T/bom.out"; rc=$?
[ $rc -eq 0 ] && [ "$(od -An -tx1 -N3 "$T/bom.out" | tr -d ' ')" = efbbbf ] && [ "$(tail -c 2 "$T/bom.out" | od -An -tx1 | tr -d ' ')" = 0d0a ] &&
    [ "$(tr -d '\r' < "$T/bom.out" | tail -c +4)" = $'{\n  "a": 1\n}' ] && ok || bad "BOM / CRLF kept"
v=$(LC_ALL=C $AWK -f "$JA" -v get=a "$T/bom.json")
[ "$v" = 1 ] && ok || bad "get through a BOM: $v"

# rmholder: a column holding only blocks with that mod goes, whatever its id; mixed columns stay
printf '{"children":[{"id":"x","children":[{"content":{"mod":"kit"}}]},{"id":"y","children":[{"content":{"mod":"kit"}},{"content":{"mod":"tabs"}}]},{"id":"z","children":[]}]}' > "$T/h.json"
printf 'rmholder\tcontent.mod\tkit\n' > "$T/ops9"
v=$(LC_ALL=C $AWK -f "$JA" -v ops="$T/ops9" "$T/h.json" | python3 -c 'import json,sys;print(" ".join(c["id"] for c in json.load(sys.stdin)["children"]))')
[ "$v" = "y z" ] && ok || bad "rmholder got: $v"

echo "json.awk ($AWK): $pass passed, $fail failed"
[ $fail -eq 0 ]
