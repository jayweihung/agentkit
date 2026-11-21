#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- kit files: what an agent read or changed (from its own log) ----------
H8="$T/home8"; PF="$T/filesproj"; mkdir -p "$H8" "$PF/sub"; PF=$(cd "$PF" && pwd -P)
(
export HOME="$H8"
KF() { kit files "$@" 2>/dev/null; }
for f in a.txt b.txt sub/c.txt nb.ipynb api.txt r1.txt d.txt; do echo x > "$PF/$f"; done
SID8=0a1b2c3d-8888-4444-3333-444455556666; PD8="$H8/.claude/projects/$(printf '%s' "$PF" | sed 's|[^A-Za-z0-9]|-|g')"; TS8="$PD8/$SID8.jsonl"
mkdir -p "$PD8/$SID8/subagents" "$H8/.claude/sessions"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$$" "$SID8" "$PF" > "$H8/.claude/sessions/$$.json"
{
    printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"content":[{"type":"text","text":"look"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"%s/a.txt"}},{"type":"tool_use","id":"t2","name":"Edit","input":{"replace_all":false,"file_path":"%s/b.txt","old_string":"\\"file_path\\":\\"/evil\\"","new_string":"SECRET"}},{"type":"tool_use","id":"t3","name":"NotebookEdit","input":{"notebook_path":"%s/nb.ipynb","new_source":"x"}}]},"uuid":"u1","timestamp":"2026-11-13T01:00:00.000Z"}\n' "$PF" "$PF" "$PF"
    printf '{"type":"api-request","messages":[{"type":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"%s/api.txt"}}]}]}\n' "$PF"
    printf '{"parentUuid":"u1","type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"SECRET"}]},"timestamp":"2026-11-13T01:00:01.000Z"}\n'
    printf '{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Write","input":{"file_path":"sub/c.txt","content":"SECRET"}},{"type":"tool_use","id":"t5","name":"Read","input":{"file_path":"%s/gone.txt"}},{"type":"tool_use","id":"t6","name":"Write","input":{"file_path":"%s/made.txt","content":"x"}},{"type":"tool_use","id":"t7","name":"Bash","input":{"command":"cat %s/d.txt"}}]},"uuid":"u2","timestamp":"2026-11-13T03:00:00.000Z"}\n' "$PF" "$PF" "$PF"
} > "$TS8"
# a sub-agent read b.txt at 02:00: after the edit at 01:00, before the writes at 03:00
# (its keys in another order, as a gateway may send them)
printf '{"parentUuid":null,"isSidechain":true,"agentId":"x","message":{"content":[{"id":"s1","input":{"file_path":"%s/b.txt"},"name":"Read","type":"tool_use"}]},"type":"assistant","uuid":"s1","timestamp":"2026-11-13T02:00:00.000Z"}\n' "$PF" > "$PD8/$SID8/subagents/agent-x.jsonl"
FL="{\"path\": \"$PF/made.txt\", \"tag\": \"write\", \"exists\": false}, {\"path\": \"$PF/sub/c.txt\", \"tag\": \"write\", \"exists\": true}, {\"path\": \"$PF/b.txt\", \"tag\": \"read\", \"exists\": true}, {\"path\": \"$PF/nb.ipynb\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/a.txt\", \"tag\": \"read\", \"exists\": true}"
T0="\"turns\": [{\"n\": 0, \"at\": \"\", \"text\": \"\", \"files\": [$FL]}]"
out=$(KF --pid $$ --tool claude --dir "$PF" --json); rc=$?
check "files (claude): newest first, one per path, its sub-agent's merged by time; a relative path under the folder; Read/Edit/NotebookEdit/Write" '[ $rc -eq 0 ] && [ "$out" = "{\"tool\": \"claude\", \"log\": \"$TS8\", \"dir\": \"$PF\", \"files\": [$FL], $T0}" ]'
check "files (claude): api-request records skipped, a read that is gone dropped, a write that is gone kept, no content shown" '! echo "$out" | grep -q -e api.txt -e gone.txt -e SECRET -e evil'
out=$(kit files --pid $$ --tool claude --dir "$PF" 2>&1)
check "files: without --json a plain list (path, tag)" '[ "$(echo "$out" | head -n 1)" = "$PF/made.txt  write（已經不在）" ] && [ "$(echo "$out" | sed -n 5p)" = "$PF/a.txt  read" ]'
# --git: what git status shows too (after the log's, not already listed, only files that are there; a rename: its new name)
( cd "$PF" && git init -q && git add -A && git -c user.name=a -c user.email=a@a commit -qm x && git mv r1.txt r2.txt && rm d.txt && echo y >> b.txt && echo n > g.txt )
out=$(KF --pid 1 --tool codex --dir "$PF/sub" --git --json)
check "files --git: git status's files (paths from the repo's top, not the folder), a rename's new name, nothing gone; no log: a note" '[ "$out" = "{\"tool\": \"codex\", \"log\": \"\", \"dir\": \"$PF/sub\", \"files\": [{\"path\": \"$PF/b.txt\", \"tag\": \"git\", \"exists\": true}, {\"path\": \"$PF/r2.txt\", \"tag\": \"git\", \"exists\": true}, {\"path\": \"$PF/g.txt\", \"tag\": \"git\", \"exists\": true}], \"turns\": [], \"note\": \"找不到這個資料夾的 Codex 對話紀錄（~/.codex/sessions）\"}" ]'
out=$(KF --pid $$ --tool claude --dir "$PF" --git --json)
check "files --git: listed by the log first" '[ "$out" = "{\"tool\": \"claude\", \"log\": \"$TS8\", \"dir\": \"$PF\", \"files\": [$FL, {\"path\": \"$PF/r2.txt\", \"tag\": \"git\", \"exists\": true}, {\"path\": \"$PF/g.txt\", \"tag\": \"git\", \"exists\": true}], $T0}" ]'
out=$(KF --pid 1 --tool claude --dir "$T" --git --json)
check "files --git: not a git repo -> nothing added; no log -> [] and a note (not an error)" '[ "$out" = "{\"tool\": \"claude\", \"log\": \"\", \"dir\": \"$T\", \"files\": [], \"turns\": [], \"note\": \"找不到這個 Claude 的對話紀錄（~/.claude/projects）\"}" ]'
out=$(KF --pid 1 --tool vim --dir "$PF" --json); out2=$(KF --pid 1 --dir "$PF" --json)
check "files: an agent kit does not know -> a note" '[ "$out" = "{\"tool\": \"vim\", \"log\": \"\", \"dir\": \"$PF\", \"files\": [], \"turns\": [], \"note\": \"不認得這種 agent：vim（只認得 claude、codex、omp）\"}" ] && echo "$out2" | grep -qF "\"files\": [], \"turns\": [], \"note\": \"看不出是哪種 agent"'
out=$(kit files --json 2>"$T/err8"); rc=$?; out2=$(kit files --pid 2>/dev/null); rc2=$?; out3=$(kit files --pid 1 --what --json 2>/dev/null); rc3=$?
check "files: wrong arguments -> exit 1, error usage on stdout with --json, the words on stderr" '[ $rc -eq 1 ] && [ "$out" = "{\"error\": {\"code\": \"usage\", \"message\": \"用法：kit files --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--git] [--json]\"}}" ] && grep -qF "用法：kit files" "$T/err8" && [ $rc2 -eq 1 ] && [ -z "$out2" ] && [ $rc3 -eq 1 ] && echo "$out3" | grep -qF "\"code\": \"usage\""'
# Codex: what its patches changed (FileChange items, patch_apply events, apply_patch text in its tool calls)
mkdir -p "$H8/.codex/sessions/2026/11/13"; RO8="$H8/.codex/sessions/2026/11/13/rollout-2026-11-13T01-00-00-c8.jsonl"
{
    printf '{"timestamp":"t","type":"session_meta","payload":{"id":"c8","cwd":"%s"}}\n' "$PF"
    printf '{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\\n*** Update File: a.txt\\n@@\\n-x\\n+SECRET\\n*** End Patch\\n","call_id":"c1"}}\n'
    printf '{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"apply_patch\\",\\"*** Begin Patch\\\\n*** Add File: %s/new.txt\\\\n+x\\\\n*** Update File: sub/c.txt\\\\n*** Move to: sub/c2.txt\\\\n*** End Patch\\\\n\\"]}","call_id":"c2"}}\n' "$PF"
    printf '{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"cmd\\":\\"cat %s/b.txt\\"}","call_id":"c3"}}\n' "$PF"
    printf '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"e1","changes":{"%s/nb.ipynb":{"type":"update","unified_diff":"\\"x\\":{\\"type\\":\\"add\\"} SECRET","move_path":null},"%s/g.txt":{"type":"add","content":"SECRET"}},"status":"completed"}}}\n' "$PF" "$PF"
    printf '{"type":"event_msg","payload":{"type":"patch_apply_end","call_id":"c4","changes":{"%s/d.txt":{"delete":{"content":"SECRET"}}}}}\n' "$PF"
} > "$RO8"
out=$(KF --pid 1 --tool codex --dir "$PF" --json)
check "files (codex): what its patches changed (added: write), relative paths under the folder, renamed, deleted; no reads, no content" '[ "$out" = "{\"tool\": \"codex\", \"log\": \"$RO8\", \"dir\": \"$PF\", \"files\": [{\"path\": \"$PF/d.txt\", \"tag\": \"edit\", \"exists\": false}, {\"path\": \"$PF/g.txt\", \"tag\": \"write\", \"exists\": true}, {\"path\": \"$PF/nb.ipynb\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/sub/c2.txt\", \"tag\": \"edit\", \"exists\": false}, {\"path\": \"$PF/sub/c.txt\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/new.txt\", \"tag\": \"write\", \"exists\": false}, {\"path\": \"$PF/a.txt\", \"tag\": \"edit\", \"exists\": true}], \"turns\": [{\"n\": 0, \"at\": \"\", \"text\": \"\", \"files\": [{\"path\": \"$PF/d.txt\", \"tag\": \"edit\", \"exists\": false}, {\"path\": \"$PF/g.txt\", \"tag\": \"write\", \"exists\": true}, {\"path\": \"$PF/nb.ipynb\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/sub/c2.txt\", \"tag\": \"edit\", \"exists\": false}, {\"path\": \"$PF/sub/c.txt\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/new.txt\", \"tag\": \"write\", \"exists\": false}, {\"path\": \"$PF/a.txt\", \"tag\": \"edit\", \"exists\": true}]}]}" ]'
n=$(tail -n 1 "$RO8" | wc -c | tr -d " ")
out=$(KIT_CTX_TAIL=$((n + 5)) KF --pid 1 --tool codex --dir "$PF" --json)
check "files: only the end of a long log (KIT_CTX_TAIL), its first cut line skipped" '[ "$out" = "{\"tool\": \"codex\", \"log\": \"$RO8\", \"dir\": \"$PF\", \"files\": [{\"path\": \"$PF/d.txt\", \"tag\": \"edit\", \"exists\": false}], \"turns\": [{\"n\": 0, \"at\": \"\", \"text\": \"\", \"files\": [{\"path\": \"$PF/d.txt\", \"tag\": \"edit\", \"exists\": false}]}]}" ]'
# omp: its read / edit / write calls (a read's :LINES off; skill:// is not a file; hashline edits name the file in the input)
mkdir -p "$H8/.omp/agent/sessions/z"; OS8="$H8/.omp/agent/sessions/z/s8.jsonl"
{
    printf '{"type":"session","version":3,"id":"s8","cwd":"%s"}\n' "$PF"
    printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"read","arguments":{"path":"%s/a.txt:10-20,30-","i":"r"}},{"type":"toolCall","id":"2","name":"read","arguments":{"path":"skill://x"}},{"type":"toolCall","id":"3","name":"write","arguments":{"i":"w","path":"sub/w.txt","content":"SECRET"}},{"type":"toolCall","id":"4","name":"bash","arguments":{"command":"cat %s/d.txt"}}]}}\n' "$PF" "$PF"
    printf '{"type":"message","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"[%s/r2.txt#AAAA]\\nSECRET"}]}}\n' "$PF"
    printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"5","name":"edit","arguments":{"i":"e","input":"[%s/b.txt#F86E]\\nPUT >1:\\n+SECRET\\n"}},{"type":"toolCall","id":"6","name":"edit","arguments":{"path":"sub/c.txt","oldText":"a","newText":"SECRET"}}]}}\n' "$PF"
    printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"7","name":"write","arguments":{"path":"C:\\\\Work\\\\X.txt","content":"x"}},{"type":"toolCall","id":"8","name":"edit","arguments":{"path":"c:/work/x.txt"}}]}}\n'
} > "$OS8"
out=$(KF --pid 1 --tool pi --dir "$PF" --json)
check "files (omp): its read/edit/write calls; a drive-letter path with / and compared ignoring case" '[ "$out" = "{\"tool\": \"omp\", \"log\": \"$OS8\", \"dir\": \"$PF\", \"files\": [{\"path\": \"c:/work/x.txt\", \"tag\": \"edit\", \"exists\": false}, {\"path\": \"$PF/sub/c.txt\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/b.txt\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/sub/w.txt\", \"tag\": \"write\", \"exists\": false}, {\"path\": \"$PF/a.txt\", \"tag\": \"read\", \"exists\": true}], \"turns\": [{\"n\": 0, \"at\": \"\", \"text\": \"\", \"files\": [{\"path\": \"c:/work/x.txt\", \"tag\": \"edit\", \"exists\": false}, {\"path\": \"$PF/sub/c.txt\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/b.txt\", \"tag\": \"edit\", \"exists\": true}, {\"path\": \"$PF/sub/w.txt\", \"tag\": \"write\", \"exists\": false}, {\"path\": \"$PF/a.txt\", \"tag\": \"read\", \"exists\": true}]}]}" ]'
mkdir -p "$PF/many"; { printf '{"type":"session","version":3,"id":"s9","cwd":"%s/many"}\n' "$PF"; i=0; while [ $i -lt 250 ]; do i=$((i + 1)); printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"%s","name":"write","arguments":{"path":"f%s.txt"}}]}}\n' $i $i; done; } > "$H8/.omp/agent/sessions/z/s9.jsonl"
out=$(KF --pid 1 --tool omp --dir "$PF/many" --json)
check "files: at most 200, the newest" '[ "$(echo "${out%%, \"turns\"*}" | grep -o "\"tag\"" | wc -l | tr -d " ")" = 200 ] && echo "$out" | grep -qF "\"files\": [{\"path\": \"$PF/many/f250.txt\"" && echo "$out" | grep -qF "f51.txt" && ! echo "$out" | grep -qF "/f50.txt"'
mkdir -p "$PF/odd"; printf 'x' > "$PF/odd/q\"u\\o é.txt"
printf '{"type":"session","version":3,"id":"s10","cwd":"%s/odd"}\n{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"edit","arguments":{"path":"q\\"u\\\\o é.txt"}}]}}\n' "$PF" > "$H8/.omp/agent/sessions/z/s10.jsonl"
out=$(KF --pid 1 --tool omp --dir "$PF/odd" --json)
check "files: a path with a quote, a backslash, not ASCII: valid JSON, the path as it is" '[ "$(printf "%s" "$out" | python3 -Ic "import json, sys; print(json.load(sys.stdin)[\"files\"][0][\"path\"])")" = "$PF/odd/q\"u\\o é.txt" ]'
# turns: what was touched after each message the person sent (Claude: the main transcript's; its sub-agents' by time)
PT="$PF/turns"; mkdir -p "$PT"; for f in a b c d e f g old; do echo x > "$PT/$f.txt"; done
SID9=0a1b2c3d-9999-4444-3333-444455556666; PD9="$H8/.claude/projects/$(printf '%s' "$PT" | sed 's|[^A-Za-z0-9]|-|g')"; TS9="$PD9/$SID9.jsonl"
mkdir -p "$PD9/$SID9/subagents"; printf '{"pid":4242,"sessionId":"%s","cwd":"%s"}\n' "$SID9" "$PT" > "$H8/.claude/sessions/4242.json"
cu() { printf '{"parentUuid":"p","isSidechain":false,"promptId":"i","type":"user","message":{"role":"user","content":%s},"uuid":"u","timestamp":"2026-11-13T%s"%s}\n' "$1" "$2" "${3:-}"; }
ca() { printf '{"parentUuid":"p","isSidechain":false,"message":{"content":[%s]},"type":"assistant","uuid":"u","timestamp":"2026-11-13T%s"}\n' "$1" "$2"; }
tu() { printf '{"type":"tool_use","id":"x","name":"%s","input":{"file_path":"%s/%s"}}' "$1" "$PT" "$2"; }
{
    ca "$(tu Read old.txt)" 00:30:00.000Z
    cu '"<system-reminder>\nSECRET\n</system-reminder>\n  第一個  問題\n\n請看 \"q\" 和 \\ 這個"' 01:00:00.500Z
    ca "$(tu Read a.txt),$(tu Edit b.txt)" 01:00:05.000Z
    cu '[{"tool_use_id":"x","type":"tool_result","content":[{"type":"text","text":"SECRET"}]}]' 01:00:06.000Z
    cu '"SECRET meta"' 01:20:00.000Z ',"isMeta":true'
    cu '"<command-name>/model</command-name>\n<command-message>model</command-message>"' 01:25:00.000Z
    cu '[{"type":"text","text":"[Request interrupted by user]"}]' 01:26:00.000Z
    cu '"<local-command-stdout>SECRET</local-command-stdout>"' 01:27:00.000Z
    ca "$(tu Write c.txt)" 01:30:00.000Z
    cu '[{"type":"image","source":{"type":"base64","data":"AAAA"}},{"type":"text","text":"<hc from=\"home/t1p\">一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十</hc>"}]' 02:00:00.000+08:00
    ca "$(tu Edit a.txt),$(tu Write gone.txt),$(tu Read gone2.txt)" 02:00:10.000Z
    cu '"x"' 03:00:00.000Z
    cu '[{"type":"image","source":{"type":"base64","data":"AAAA"}}]' 03:30:00.000Z
    cu '"SECRET summary"' 03:40:00.000Z ',"isCompactSummary":true'
    cu '"<task-notification>\n<task-id>1</task-id>SECRET</task-notification>"' 03:50:00.000Z
    cu '"line1\u0007\n\n\tline2\b   end 第一第二第三第四第五第六第七第八第九第十"' 04:00:00.000Z
    ca "$(tu Read d.txt)" 04:00:30.000Z
} > "$TS9"
{   # a sub-agent: its own prompt is not a turn; its reads go to the main turn that started last at or before them
    printf '{"isSidechain":true,"agentId":"y","type":"user","message":{"role":"user","content":"sub prompt"},"timestamp":"2026-11-13T01:10:00.000Z"}\n'
    printf '{"isSidechain":true,"agentId":"y","message":{"content":[%s]},"type":"assistant","timestamp":"2026-11-13T01:10:00.000Z"}\n' "$(tu Read e.txt)"
    printf '{"isSidechain":true,"agentId":"y","message":{"content":[%s]},"type":"assistant","timestamp":"2026-11-13T02:30:00.000Z"}\n' "$(tu Read g.txt)"
    printf '{"isSidechain":true,"agentId":"y","message":{"content":[%s]},"type":"assistant","timestamp":"2026-11-13T04:00:00.000Z"}\n' "$(tu Read f.txt)"
} > "$PD9/$SID9/subagents/agent-y.jsonl"
fe() { printf '{"path": "%s/%s", "tag": "%s", "exists": %s}' "$PT" "$1" "$2" "${3:-true}"; }
TT4="{\"n\": 4, \"at\": \"2026-11-13T04:00:00Z\", \"text\": \"line1 line2 end 第一第二第三第四第五第六第七…\", \"files\": [$(fe d.txt read), $(fe f.txt read)]}"
TT2="{\"n\": 2, \"at\": \"2026-11-12T18:00:00Z\", \"text\": \"hc home/t1p：一二三四五六七八九十一二三四五六七八…\", \"files\": [$(fe g.txt read), $(fe gone.txt write false), $(fe a.txt edit)]}"
TT1="{\"n\": 1, \"at\": \"2026-11-13T01:00:00Z\", \"text\": \"第一個 問題 請看 \\\"q\\\" 和 \\\\ 這個\", \"files\": [$(fe c.txt write), $(fe e.txt read), $(fe b.txt edit), $(fe a.txt read)]}"
TT0="{\"n\": 0, \"at\": \"\", \"text\": \"\", \"files\": [$(fe old.txt read)]}"
out=$(KF --pid 4242 --tool claude --dir "$PT" --json)
check "files turns (claude): newest first, n 0 (before the first message read) last; a file in two turns in both; a turn without files left out" '[ "${out#*\"turns\": }" = "[$TT4, $TT2, $TT1, $TT0]}" ]'
check "files turns (claude): tool results, isMeta, isCompactSummary, commands, interrupts, task notifications, images alone, a sub-agent's prompt: not turns" '! echo "$out" | grep -q -e SECRET -e "\"n\": 5" -e "sub prompt" -e "model" -e "Request"'
check "files turns: text: system-reminder skipped, white space one space, control characters out, <hc from> -> hc X：, 30 characters (+ …), valid JSON" '[ "$(printf "%s" "$out" | python3 -Ic "import json, sys; print(\"|\".join(t[\"text\"] for t in json.load(sys.stdin)[\"turns\"]))")" = "line1 line2 end 第一第二第三第四第五第六第七…|hc home/t1p：一二三四五六七八九十一二三四五六七八…|第一個 問題 請看 \"q\" 和 \\ 這個|" ]'
n9=$(tail -n 7 "$TS9" | wc -c | tr -d " ")
out=$(KIT_CTX_TAIL=$((n9 + 5)) KF --pid 4242 --tool claude --dir "$PT" --json)
check "files turns: only the end of the log read: n counted from the first message read, what came before it n 0" '[ "${out#*\"turns\": }" = "[${TT4/\"n\": 4/\"n\": 2}, {\"n\": 0, \"at\": \"\", \"text\": \"\", \"files\": [$(fe g.txt read), $(fe gone.txt write false), $(fe a.txt edit), $(fe e.txt read)]}]}" ]'
# Codex: user_message events and UserMessage items (one turn when a version writes both); omp: its user messages
mkdir -p "$PF/cx"; RO9="$H8/.codex/sessions/2026/11/13/rollout-2026-11-13T05-00-00-c9.jsonl"
{
    printf '{"timestamp":"2026-11-13T05:00:00.000Z","type":"session_meta","payload":{"id":"c9","cwd":"%s/cx"}}\n' "$PF"
    printf '{"timestamp":"2026-11-13T05:00:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md SECRET"}]}}\n'
    printf '{"timestamp":"2026-11-13T05:00:00.200Z","type":"event_msg","payload":{"type":"user_message","message":"<environment_context>SECRET</environment_context>","kind":"environment_context"}}\n'
    printf '{"timestamp":"2026-11-13T05:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"fix it","images":[]}}\n'
    printf '{"timestamp":"2026-11-13T05:00:01.001Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"u","item":{"type":"UserMessage","id":"m","content":[{"type":"text","text":"fix it","text_elements":[]}]}}}\n'
    printf '{"timestamp":"2026-11-13T05:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\\n*** Update File: a.txt\\n+x\\n*** End Patch\\n","call_id":"c1"}}\n'
    printf '{"timestamp":"2026-11-13T05:10:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"v","item":{"type":"UserMessage","id":"n","content":[{"type":"text","text":"再來\\n一個","text_elements":[]}]}}}\n'
    printf '{"timestamp":"2026-11-13T05:10:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"e","changes":{"%s/cx/g.txt":{"type":"add","content":"SECRET"}},"status":"completed"}}}\n' "$PF"
} > "$RO9"
out=$(KF --pid 1 --tool codex --dir "$PF/cx" --json)
check "files turns (codex): user_message events and UserMessage items, the same message written both ways one turn; not its instructions or environment" '[ "${out#*\"turns\": }" = "[{\"n\": 2, \"at\": \"2026-11-13T05:10:00Z\", \"text\": \"再來 一個\", \"files\": [{\"path\": \"$PF/cx/g.txt\", \"tag\": \"write\", \"exists\": false}]}, {\"n\": 1, \"at\": \"2026-11-13T05:00:01Z\", \"text\": \"fix it\", \"files\": [{\"path\": \"$PF/cx/a.txt\", \"tag\": \"edit\", \"exists\": false}]}]}" ]'
mkdir -p "$PF/om"; OS9="$H8/.omp/agent/sessions/z/s11.jsonl"
{
    printf '{"type":"session","version":3,"id":"s11","timestamp":"2026-11-13T06:00:00.000Z","cwd":"%s/om"}\n' "$PF"
    printf '{"type":"message","id":"1","parentId":null,"timestamp":"2026-11-13T06:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"看 a"}],"attribution":"user","timestamp":1}}\n'
    printf '{"type":"message","id":"2","parentId":"1","timestamp":"2026-11-13T06:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"read","arguments":{"path":"a.txt"}},{"type":"toolCall","id":"2","name":"write","arguments":{"path":"w.txt"}}]}}\n'
    printf '{"type":"message","id":"3","parentId":"2","timestamp":"2026-11-13T06:00:03.000Z","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"SECRET"}]}}\n'
    printf '{"type":"message","id":"4","parentId":"3","timestamp":"2026-11-13T06:05:00.000Z","message":{"role":"user","content":"<hc from=\\"pc\\">ok</hc>","attribution":"user","timestamp":2}}\n'
    printf '{"type":"message","id":"5","parentId":"4","timestamp":"2026-11-13T06:05:01.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"3","name":"edit","arguments":{"path":"w.txt"}}]}}\n'
} > "$OS9"
out=$(KF --pid 1 --tool omp --dir "$PF/om" --json)
check "files turns (omp): its user messages (text items or a string)" '[ "${out#*\"turns\": }" = "[{\"n\": 2, \"at\": \"2026-11-13T06:05:00Z\", \"text\": \"hc pc：ok\", \"files\": [{\"path\": \"$PF/om/w.txt\", \"tag\": \"edit\", \"exists\": false}]}, {\"n\": 1, \"at\": \"2026-11-13T06:00:01Z\", \"text\": \"看 a\", \"files\": [{\"path\": \"$PF/om/w.txt\", \"tag\": \"write\", \"exists\": false}]}]}" ]'
mkdir -p "$PF/mt"; OS10="$H8/.omp/agent/sessions/z/s12.jsonl"
{
    printf '{"type":"session","version":3,"id":"s12","cwd":"%s/mt"}\n' "$PF"
    i=0; while [ $i -lt 36 ]; do i=$((i + 1))
        printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"m%s"}]}}\n{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"write","arguments":{"path":"f%s.txt"}}]}}\n' $i $i
    done
    i=0; while [ $i -lt 55 ]; do i=$((i + 1)); printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"edit","arguments":{"path":"w%s.txt"}}]}}\n' $i; done
} > "$OS10"
out=$(KF --pid 1 --tool omp --dir "$PF/mt" --json)
check "files turns: at most 30 turns (the newest), 50 files each (the newest); no time in the log: at \"\"" '[ "$(printf "%s" "$out" | python3 -Ic "import json, sys; t = json.load(sys.stdin)[\"turns\"]; print(len(t), t[0][\"n\"], t[-1][\"n\"], len(t[0][\"files\"]), t[0][\"files\"][0][\"path\"].rsplit(\"/\", 1)[1], t[0][\"files\"][-1][\"path\"].rsplit(\"/\", 1)[1], t[0][\"at\"] == \"\", t[1][\"text\"])")" = "30 36 7 50 w55.txt w6.txt True m35" ]'
if [ -n "$PWSH" ]; then
    same=1
    for a in "--pid $$ --tool claude --dir $PF --json" "--pid $$ --tool claude --dir $PF --git --json" "--pid $$ --tool claude --dir $PF" "--pid 1 --tool codex --dir $PF --json" "--pid 1 --tool omp --dir $PF --json" "--pid 1 --tool omp --dir $PF/many --json" "--pid 1 --tool vim --dir $PF --json" "--pid 1 --dir $T --git --json" "--pid 1 --tool codex --dir $PF/sub --git --json" "--pid 1 --tool omp --dir $PF/odd --json" "--json" \
        "--pid 4242 --tool claude --dir $PT --json" "--pid 1 --tool codex --dir $PF/cx --json" "--pid 1 --tool omp --dir $PF/om --json" "--pid 1 --tool omp --dir $PF/mt --json"; do
        x=$(kit files $a 2>&1; echo "rc=$?"); y=$(kps files $a 2>&1; echo "rc=$?")
        [ "$x" = "$y" ] || { same=0; echo "  differs: $a"; printf '%s\n' "$x" | tr ',' '\n' > "$T/dx"; printf '%s\n' "$y" | tr ',' '\n' > "$T/dy"; diff "$T/dx" "$T/dy" | head -n 6; }
    done
    x=$(KIT_CTX_TAIL=$((n + 5)) kit files --pid 1 --tool codex --dir "$PF" --json 2>&1); y=$(KIT_CTX_TAIL=$((n + 5)) kps files --pid 1 --tool codex --dir "$PF" --json 2>&1)
    [ "$x" = "$y" ] || { same=0; echo "  differs: KIT_CTX_TAIL"; }
    x=$(KIT_CTX_TAIL=$((n9 + 5)) kit files --pid 4242 --tool claude --dir "$PT" --json 2>&1); y=$(KIT_CTX_TAIL=$((n9 + 5)) kps files --pid 4242 --tool claude --dir "$PT" --json 2>&1)
    [ "$x" = "$y" ] || { same=0; echo "  differs: KIT_CTX_TAIL (turns)"; }
    check "files: kit.ps1 says the same (Claude, --git, Codex, omp, the end of a log, unknown, no log, usage, turns)" '[ $same = 1 ]'
fi
# ---------- kit used: the skills and MCP servers a conversation used (how many times, the last turn) ----------
KU() { kit used "$@" 2>/dev/null; }
PU="$PF/used"; mkdir -p "$PU"; SIDU=0a1b2c3d-7777-4444-3333-444455556666; PDU="$H8/.claude/projects/$(printf '%s' "$PU" | sed 's|[^A-Za-z0-9]|-|g')"; TSU="$PDU/$SIDU.jsonl"
mkdir -p "$PDU/$SIDU/subagents"; printf '{"pid":5151,"sessionId":"%s","cwd":"%s"}\n' "$SIDU" "$PU" > "$H8/.claude/sessions/5151.json"
mu() { printf '{"type":"tool_use","id":"x","name":"mcp__%s","input":{}}' "$1"; }
{
    cu '"幫我看"' 01:00:00.000Z
    cu '[{"type":"text","text":"Base directory for this skill: /h/.claude/skills/brainstorming\n\n# B\nSECRET"}]' 01:00:01.000Z ',"isMeta":true,"sourceToolUseID":"t"'
    ca "$(mu kit-ping__ping),$(mu plugin_x_srv__go)" 01:00:02.000Z
    cu '"說明裡寫 Base directory for this skill: /evil/skills/fake 和 \"name\":\"mcp__evil__x\""' 02:00:00.000Z
    printf '{"type":"api-request","messages":[{"type":"assistant","content":[%s]}]}\n' "$(mu api__x)"
    printf '{"type":"attachment","attachment":{"tools":[{"name":"mcp__listed__x"}]},"timestamp":"2026-11-13T02:00:01.000Z"}\n'
    ca "$(mu kit-ping__ping)" 02:00:02.000Z
} > "$TSU"
printf '{"isSidechain":true,"agentId":"z","type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /h/.claude/plugins/cache/kit/pt/1.0/skills/pt-review\\n\\nx"}]},"isMeta":true,"timestamp":"2026-11-13T01:30:00.000Z"}\n' > "$PDU/$SIDU/subagents/agent-z.jsonl"
mkdir -p "$T/srcu/plugins/pt/.claude-plugin" "$T/srcu/plugins/pt/skills/pt-review"; printf '{"name":"pt"}\n' > "$T/srcu/plugins/pt/.claude-plugin/plugin.json"
printf -- '---\nname: pt-review\ndescription: r\n---\nx\n' > "$T/srcu/plugins/pt/skills/pt-review/SKILL.md"
kit init "$T/srcu" >/dev/null 2>&1
out=$(KU --pid 5151 --tool claude --dir "$PU" --json); rc=$?
check "used (claude): skills it loaded (also a sub-agent's: the turn it ran in), a plugin's skill names its plugin; MCP servers by their calls; the last turn; newest first" '[ $rc -eq 0 ] && [ "$out" = "{\"tool\": \"claude\", \"log\": \"$TSU\", \"dir\": \"$PU\", \"turn\": 2, \"skills\": [{\"name\": \"pt-review\", \"plugin\": \"pt\", \"count\": 1, \"turn\": 1}, {\"name\": \"brainstorming\", \"count\": 1, \"turn\": 1}], \"mcp\": [{\"name\": \"kit-ping\", \"count\": 2, \"turn\": 2}, {\"name\": \"plugin_x_srv\", \"count\": 1, \"turn\": 1}]}" ]'
check "used (claude): a message that only quotes them, api-request records, a tool list: not uses" '! echo "$out" | grep -q -e fake -e evil -e api -e listed -e SECRET'
out=$(kit used --pid 5151 --tool claude --dir "$PU" 2>&1)
check "used: without --json a plain list, the last used first" '[ "$(echo "$out" | head -n 1)" = "MCP kit-ping  2 次，第 2 輪" ] && [ "$(echo "$out" | sed -n 2p)" = "skill pt-review（外掛 pt）  1 次，第 1 輪" ]'
mkdir -p "$PF/cu"; ROU="$H8/.codex/sessions/2026/11/13/rollout-2026-11-13T07-00-00-cu.jsonl"
{
    printf '{"timestamp":"2026-11-13T07:00:00.000Z","type":"session_meta","payload":{"id":"cu","cwd":"%s/cu"}}\n' "$PF"
    printf '{"timestamp":"2026-11-13T07:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"看一下","images":[]}}\n'
    printf '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd:\\"cat /h/.codex/plugins/cache/kit/pt/1.0/skills/pt-review/SKILL.md; wc -l /h/.codex/plugins/cache/kit/pt/1.0/skills/pt-review/SKILL.md\\"});","call_id":"c1"}}\n'
    printf '{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"cmd\\":\\"sed -n 1,80p /h/.agents/skills/foo/SKILL.md\\"}","call_id":"c2"}}\n'
    printf '{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\\n*** Update File: /h/.agents/skills/bar/SKILL.md\\n+x\\n*** End Patch\\n","call_id":"c3"}}\n'
    printf '{"type":"event_msg","payload":{"type":"item_started","item":{"type":"McpToolCall","id":"m0","server":"kit-ping","tool":"ping","arguments":{}}}}\n'
    printf '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"m1","server":"kit-ping","tool":"ping","arguments":{},"status":"completed"}}}\n'
    printf '{"type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"m2","invocation":{"server":"old-srv","tool":"t","arguments":{}},"result":{}}}\n'
    printf '{"timestamp":"2026-11-13T07:10:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"n","content":[{"type":"text","text":"再一次","text_elements":[]}]}}}\n'
    printf '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"m3","server":"kit-ping","tool":"ping","arguments":{},"status":"failed"}}}\n'
} > "$ROU"
out=$(KU --pid 1 --tool codex --dir "$PF/cu" --json)
check "used (codex): .../skills/<name>/SKILL.md in its tool calls (once a call; a patch is not a use), McpToolCall items and mcp_tool_call_end events" '[ "$out" = "{\"tool\": \"codex\", \"log\": \"$ROU\", \"dir\": \"$PF/cu\", \"turn\": 2, \"skills\": [{\"name\": \"foo\", \"count\": 1, \"turn\": 1}, {\"name\": \"pt-review\", \"plugin\": \"pt\", \"count\": 1, \"turn\": 1}], \"mcp\": [{\"name\": \"kit-ping\", \"count\": 2, \"turn\": 2}, {\"name\": \"old-srv\", \"count\": 1, \"turn\": 1}]}" ]'
mkdir -p "$PF/ou"; printf '{"mcpServers":{"kit-ping":{"command":"x"},"my.srv":{"command":"y"}}}\n' > "$PF/ou/.mcp.json"; OSU="$H8/.omp/agent/sessions/z/s13.jsonl"
{
    printf '{"type":"session","version":3,"id":"s13","cwd":"%s/ou"}\n' "$PF"
    printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"一"}]}}\n'
    printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"read","arguments":{"path":"skill://foo"}},{"type":"toolCall","id":"2","name":"read","arguments":{"path":"skill://foo/ref.md"}},{"type":"toolCall","id":"3","name":"read","arguments":{"path":"/h/.agents/skills/bar/SKILL.md:1-5"}}]}}\n'
    printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"二"}]}}\n'
    printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"4","name":"read","arguments":{"path":"xd://mcp__kit_ping_ping"}},{"type":"toolCall","id":"5","name":"write","arguments":{"path":"xd://mcp__kit_ping_ping","content":"{}"}},{"type":"toolCall","id":"6","name":"mcp__my_srv_do_it","arguments":{}},{"type":"toolCall","id":"7","name":"mcp__other_tool","arguments":{}}]}}\n'
} > "$OSU"
out=$(KU --pid 1 --tool omp --dir "$PF/ou" --json)
check "used (omp): reads of skill://<name> and .../skills/<name>/SKILL.md; mcp__ calls (by name or written to xd://) matched to its MCP servers" '[ "$out" = "{\"tool\": \"omp\", \"log\": \"$OSU\", \"dir\": \"$PF/ou\", \"turn\": 2, \"skills\": [{\"name\": \"bar\", \"count\": 1, \"turn\": 1}, {\"name\": \"foo\", \"count\": 2, \"turn\": 1}], \"mcp\": [{\"name\": \"other\", \"count\": 1, \"turn\": 2}, {\"name\": \"my.srv\", \"count\": 1, \"turn\": 2}, {\"name\": \"kit-ping\", \"count\": 1, \"turn\": 2}]}" ]'
out=$(KU --pid 1 --tool claude --dir "$T" --json); out2=$(kit used --pid 1 --tool omp --dir "$PF/mt" 2>&1)
check "used: no log -> a note; nothing used -> says so" '[ "$out" = "{\"tool\": \"claude\", \"log\": \"\", \"dir\": \"$T\", \"turn\": 0, \"skills\": [], \"mcp\": [], \"note\": \"找不到這個 Claude 的對話紀錄（~/.claude/projects）\"}" ] && [ "$out2" = "kit: 這次對話還沒用到 skill 或 MCP" ]'
out=$(kit used --json 2>/dev/null); rc=$?
check "used: wrong arguments -> exit 1, error usage" '[ $rc -eq 1 ] && [ "$out" = "{\"error\": {\"code\": \"usage\", \"message\": \"用法：kit used --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--json]\"}}" ]'
if [ -n "$PWSH" ]; then
    same=1
    for a in "--pid 5151 --tool claude --dir $PU --json" "--pid 5151 --tool claude --dir $PU" "--pid 1 --tool codex --dir $PF/cu --json" "--pid 1 --tool omp --dir $PF/ou --json" "--pid 1 --tool claude --dir $T --json" "--pid 1 --tool omp --dir $PF/mt" "--json"; do
        x=$(kit used $a 2>&1; echo "rc=$?"); y=$(kps used $a 2>&1; echo "rc=$?")
        [ "$x" = "$y" ] || { same=0; echo "  differs: $a"; printf '%s\n' "$x" | tr ',' '\n' > "$T/dx"; printf '%s\n' "$y" | tr ',' '\n' > "$T/dy"; diff "$T/dx" "$T/dy" | head -n 6; }
    done
    check "used: kit.ps1 says the same (Claude, Codex, omp, no log, nothing used, usage)" '[ $same = 1 ]'
fi
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
