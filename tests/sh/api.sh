#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- api: the output format programs read ----------
out=$(kit api 2>&1); rc=$?
check "api: one line, major.minor (1.22)" '[ $rc -eq 0 ] && [ "$out" = 1.22 ]'
if [ -n "$PWSH" ]; then
    out=$(kps api 2>&1); rc=$?
    check "api: kit.ps1 says the same" '[ $rc -eq 0 ] && [ "$out" = 1.22 ]'
fi
# errors of the commands programs read: JSON on stdout, the words on stderr, exit not 0
out=$(AGENTKIT_CONFIG="$T/noconf" kit list --json 2>"$T/err"); rc=$?
check "list --json before kit init: error not_init on stdout, the words on stderr" '[ $rc -ne 0 ] && [ "$out" = "{\"error\": {\"code\": \"not_init\", \"message\": \"還沒設定：先打  kit init <網址或資料夾>\"}}" ] && grep -q "還沒設定" "$T/err"'
out2=$(AGENTKIT_CONFIG="$T/noconf" kit agents --json 2>/dev/null)
out3=$(kit list --json --bad 2>/dev/null)
check "agents --json before kit init: not_init; a wrong option: usage" '[ "$out2" = "$out" ] && echo "$out3" | grep -q "^{\"error\": {\"code\": \"usage\", "'
if [ -n "$PWSH" ]; then
    check "errors as JSON: kit.ps1 prints the same" '[ "$(AGENTKIT_CONFIG="$T/noconf" kps list --json 2>/dev/null)" = "$out" ] && [ "$(AGENTKIT_CONFIG="$T/noconf" kps agents --json 2>/dev/null)" = "$out" ] && [ "$(kps list --json --bad 2>/dev/null)" = "$out3" ]'
fi

# ---------- help ----------
out=$(kit help 2>&1)
check "help: kit api is there" 'echo "$out" | grep -q "^  kit api  "'
check "help: --json --dir is under kit list" 'echo "$out" | grep -A1 "^  kit list" | grep -q -- "--json --dir" && ! echo "$out" | grep -A1 "^  kit agent " | grep -q -- "--json --dir"'

finish
