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

# empty file counts as {}
: > "$T/empty.json"
printf 'set\ta\t1\n' > "$T/ops3"
v=$(LC_ALL=C $AWK -f "$JA" -v ops="$T/ops3" "$T/empty.json")
[ "$v" = $'{\n  "a": 1\n}' ] && ok || bad "empty file: $v"

echo "json.awk ($AWK): $pass passed, $fail failed"
[ $fail -eq 0 ]
