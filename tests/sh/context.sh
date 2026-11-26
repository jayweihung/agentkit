#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- how full an agent's context is (kit context, kit statusline) ----------
H7="$T/home7"; P7="$T/ctxproj"; mkdir -p "$H7" "$P7"; P7=$(cd "$P7" && pwd -P)
(
export HOME="$H7"
mkdir -p "$H7/.codex/sessions/2026/11/12" "$H7/.omp/agent/sessions/x" "$H7/.claude/projects/$(printf '%s' "$P7" | sed 's|[^A-Za-z0-9]|-|g')"
RO="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T01-00-00-abc.jsonl"
printf '{"timestamp":"t","type":"session_meta","payload":{"id":"abc","cwd":"%s","originator":"codex-tui"}}\n' "$P7" > "$RO"
printf '{"type":"turn_context","payload":{"cwd":"%s","model":"gpt-6-luna"}}\n' "$P7" >> "$RO"
for u in 13878 48813; do printf '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"total_tokens":412129},"last_token_usage":{"input_tokens":48732,"cached_input_tokens":48512,"output_tokens":81,"total_tokens":%s},"model_context_window":258400}}}\n' "$u" >> "$RO"; done
printf '{"type":"session_meta","payload":{"id":"zzz","cwd":"/elsewhere"}}\n' > "$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T02-00-00-zzz.jsonl"
CX() { kit context "$@" 2>&1; }
out=$(CX --pid 1 --tool codex --dir "$P7")
check "context (codex): the folder's newest rollout, its last turn; % the way Codex counts it (85% left)" '[ "$out" = "{\"tool\": \"codex\", \"used\": 48813, \"window\": 258400, \"pct\": 15, \"source\": \"rollout\", \"model\": \"gpt-6-luna\"}" ]'
# a Codex run with --no-daemon keeps its rollout open: that one, though the folder has a newer one
RO2="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T00-30-00-old.jsonl"
printf '{"type":"session_meta","payload":{"id":"old","cwd":"%s"}}\n{"type":"turn_context","payload":{"cwd":"%s","model":"gpt-6-old"}}\n' "$P7" "$P7" > "$RO2"
printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120000},"model_context_window":258400}}}\n' >> "$RO2"
touch -t 202611120030 "$RO2"
( exec 7<"$RO2"; exec sleep 60 ) & hp=$!
sleep 0.3
out=$(CX --pid "$hp" --tool codex --dir "$P7")
check "context (codex): the rollout that Codex process has open, not the folder's newest" 'echo "$out" | grep -qF "\"used\": 120000, \"window\": 258400" && echo "$out" | grep -qF "gpt-6-old"'
[ -n "$PWSH" ] && { out2=$(kps context --pid "$hp" --tool codex --dir "$P7" 2>&1); check "context (codex) open rollout: kit.ps1 says the same" '[ "$out2" = "$out" ]'; }
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
out=$(CX --pid 1 --tool codex --dir "$P7")
check "context (codex): nothing open -> the folder's newest again" 'echo "$out" | grep -qF "\"used\": 48813"'
# omp with no terminal to go by (Windows under Herdr): the session the process started, not the folder's newest
P7o="$T/ctxomp"; mkdir -p "$P7o" "$H7/.omp/agent/sessions/y"; P7o=$(cd "$P7o" && pwd -P)
sleep 60 & hp=$!
OA="$H7/.omp/agent/sessions/y/$(date -u +%Y-%m-%dT%H-%M-%S)-000Z_sa.jsonl"; OB="$H7/.omp/agent/sessions/y/2026-11-01T01-00-00-000Z_sb.jsonl"
for x in "$OA:5000" "$OB:7000"; do
    printf '{"type":"session","version":3,"id":"s","cwd":"%s"}\n{"type":"model_change","model":"anthropic/claude-opus-5-5"}\n{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":4},"contextSnapshot":{"promptTokens":%s,"compactionEpoch":0},"stopReason":"stop"}}\n' "$P7o" "${x##*:}" > "${x%:*}"
done
sleep 1; touch "$OB"
out=$(CX --pid "$hp" --tool omp --dir "$P7o")
check "context (omp, no terminal): the session that process started, not the folder's newest" 'echo "$out" | grep -qF "\"used\": 5000,"'
[ -n "$PWSH" ] && { out2=$(kps context --pid "$hp" --tool omp --dir "$P7o" 2>&1); check "context (omp, no terminal): kit.ps1 says the same" '[ "$out2" = "$out" ]'; }
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
out=$(CX --pid 1 --tool omp --dir "$P7o")
check "context (omp, no terminal): a process that started none of them -> the folder's newest" 'echo "$out" | grep -qF "\"used\": 7000,"'
OS="$H7/.omp/agent/sessions/x/2026-11-12T01-00-00-000Z_s1.jsonl"
printf '{"type":"title","title":"secret words"}\n{"type":"session","version":3,"id":"s1","cwd":"%s"}\n{"type":"model_change","model":"anthropic/claude-opus-5-5"}\n' "$P7" > "$OS"
printf '{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":4,"output":12,"cacheRead":149319,"cacheWrite":222},"contextSnapshot":{"promptTokens":149545,"compactionEpoch":0},"stopReason":"stop"}}\n' >> "$OS"
printf '{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"0123456789abcdef\\"23"},{"type":"image","data":"%s","mimeType":"image/png"}],"details":{"text":"%s"}}}\n' "$(printf '%0600d' 0)" "$(printf '%0900d' 0)" >> "$OS"
printf '{"type":"message","message":{"role":"assistant","usage":{"input":9,"cacheRead":900000},"stopReason":"aborted"}}\n' >> "$OS"
out=$(CX --pid 1 --tool omp --dir "$P7")
check "context (omp): its last finished reply (not an aborted one), plus what came after it like omp's footer (text / 4, an image 1600)" '[ "$out" = "{\"tool\": \"omp\", \"used\": $((149545 + 20 / 4 + 1600)), \"window\": 1000000, \"pct\": 15, \"source\": \"session\", \"model\": \"anthropic/claude-opus-5-5\"}" ]'
printf '{"type":"compaction","summary":"x","tokensBefore":150000,"tokensAfter":20000}\n' >> "$OS"
out=$(CX --pid 1 --tool omp --dir "$P7")
check "context (omp): compacted since -> the size after it" 'echo "$out" | grep -qF "\"used\": 20000, \"window\": 1000000, \"pct\": 2"'
CT="$H7/.claude/projects/$(printf '%s' "$P7" | sed 's|[^A-Za-z0-9]|-|g')/t1.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1146,"cache_read_input_tokens":241932,"output_tokens":484}}}\n' > "$CT"
printf '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' >> "$CT"
mkdir -p "$H7/.claude"; printf '{\n  "modelSettings": {\n    "claude-opus-5-5": {\n      "autoCompactWindow": 400000\n    }\n  }\n}\n' > "$H7/.claude/settings.json"
out=$(CX --pid 1 --tool claude-code --dir "$P7")
check "context (claude, no status line): the transcript (not a <synthetic> reply), the window from autoCompactWindow" '[ "$out" = "{\"tool\": \"claude\", \"used\": 243080, \"window\": 400000, \"pct\": 61, \"source\": \"transcript\", \"model\": \"claude-opus-5-5\"}" ]'
printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":390000,"postTokens":19421}}\n' >> "$CT"
out=$(CX --pid 1 --tool claude --dir "$P7")
check "context (claude): compacted since -> the size after it" 'echo "$out" | grep -qF "\"used\": 19421, \"window\": 400000, \"pct\": 5"'
# another Claude in the same folder wrote last: each reads its own transcript (~/.claude/sessions/<pid>.json), only
# one kit can't place falls back to the newest
mkdir -p "$H7/.claude/sessions"; printf '{"pid":4242,"sessionId":"t1","cwd":"%s"}\n' "$P7" > "$H7/.claude/sessions/4242.json"
OT="$(dirname "$CT")/other.jsonl"; sleep 1
printf '{"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":48555}}}\n' > "$OT"
out=$(CX --pid 4242 --tool claude --dir "$P7")
check "context (claude, no status line): its own session's transcript, not another Claude's newer one in the folder" 'echo "$out" | grep -qF "\"used\": 19421, \"window\": 400000, \"pct\": 5"'
out=$(CX --pid 1 --tool claude --dir "$P7")
check "context (claude): a process kit can't place: the newest of the folder, as before" 'echo "$out" | grep -qF "\"model\": \"claude-haiku-5-5\""'
rm -f "$OT" "$H7/.claude/sessions/4242.json"
# kit statusline under a "claude" process keeps the numbers for that process; kit context prefers them
printf '{"session_id":"abc","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"total_input_tokens":5,"context_window_size":400000,"current_usage":{"input_tokens":2,"output_tokens":9,"cache_creation_input_tokens":1146,"cache_read_input_tokens":138452},"used_percentage":34.9}}' > "$T/sl.json"
mkdir -p "$T/fb7"; printf '#!/bin/sh\necho $$ > "%s/cpid"\n"%s" statusline < "%s/sl.json"\n' "$T" "$KIT" "$T" > "$T/fb7/claude"; chmod +x "$T/fb7/claude"
out=$("$T/fb7/claude"); cp=$(cat "$T/cpid")
check "statusline: a short line for Claude" '[ "$out" = "Opus 5.5 · context 35%（139k / 400k）" ]'
check "statusline: the numbers kept for that Claude process" '[ -f "$H7/.config/agentkit/ctx/claude-$cp.json" ]'
out=$(CX --pid "$cp" --tool claude --dir "$P7")
check "context (claude): what the status line kept wins" '[ "$out" = "{\"tool\": \"claude\", \"used\": 139600, \"window\": 400000, \"pct\": 35, \"source\": \"statusline\", \"model\": \"claude-opus-5-5\"}" ]'
# the window: what settings.json tells Claude Code (autoCompactWindow), as Claude's own /context shows, not the status line's
SID=0a1b2c3d-1111-2222-3333-444455556666; PD7="$H7/.claude/projects/$(printf '%s' "$P7" | sed 's|[^A-Za-z0-9]|-|g')"; TS7="$PD7/$SID.jsonl"
printf '{"pid": %s, "session": "%s", "used": 130000, "window": 1000000, "pct": 13, "model": "claude-opus-5-5", "transcript": "%s", "cwd": "%s"}\n' "$$" "$SID" "$TS7" "$P7" > "$H7/.config/agentkit/ctx/claude-$$.json"
out=$(CX --pid $$ --tool claude --dir "$P7")
check "context (claude): the window set in settings.json (autoCompactWindow) wins over the status line's" '[ "$out" = "{\"tool\": \"claude\", \"used\": 130000, \"window\": 400000, \"pct\": 33, \"source\": \"statusline\", \"model\": \"claude-opus-5-5\"}" ]'
# compacted since the status line's numbers (they change only with Claude's next reply): what is left after it
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":360000}}}' '{"type":"system","subtype":"compact_boundary","compactMetadata":{"preTokens":366588,"postTokens":63134}}' > "$T/cut.jsonl"
printf '{"pid": 4242, "used": 364000, "window": 400000, "pct": 91, "model": "claude-opus-5-5", "transcript": "%s"}\n' "$T/cut.jsonl" > "$H7/.config/agentkit/ctx/claude-4242.json"
out=$(CX --pid 4242 --tool claude --dir "$P7")
check "context (claude): compacted after the status line's numbers -> what is left after it" '[ "$out" = "{\"tool\": \"claude\", \"used\": 63134, \"window\": 400000, \"pct\": 16, \"source\": \"compacted\", \"model\": \"claude-opus-5-5\"}" ]'
[ -z "$PWSH" ] || { out=$(kps context --pid 4242 --tool claude --dir "$P7" 2>&1)
    check "context (kit.ps1): compacted after the status line's numbers -> the same" '[ "$out" = "{\"tool\": \"claude\", \"used\": 63134, \"window\": 400000, \"pct\": 16, \"source\": \"compacted\", \"model\": \"claude-opus-5-5\"}" ]'; }
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":60000}}}' >> "$T/cut.jsonl"
out=$(CX --pid 4242 --tool claude --dir "$P7")
check "context (claude): a reply after the compaction -> the status line's numbers again" '[ "$out" = "{\"tool\": \"claude\", \"used\": 364000, \"window\": 400000, \"pct\": 91, \"source\": \"statusline\", \"model\": \"claude-opus-5-5\"}" ]'
rm -f "$H7/.config/agentkit/ctx/claude-4242.json"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"/x","workspace":{"current_dir":"/x/sub","project_dir":"%s"},"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1146,"cache_read_input_tokens":138452},"used_percentage":14}}' "$SID" "$TS7" "$P7" > "$T/sl2.json"
mkdir -p "$T/fb9"; printf '#!/bin/sh\necho $$ > "%s/cpid9"\n"%s" statusline < "%s/sl2.json"\n' "$T" "$KIT" "$T" > "$T/fb9/claude"; chmod +x "$T/fb9/claude"
out=$("$T/fb9/claude"); cp9=$(cat "$T/cpid9")
check "statusline: the session, its transcript and folder kept too; the line uses the window from settings.json" '[ "$out" = "Opus 5.5 · context 35%（139k / 400k）" ] && grep -qF "\"session\": \"$SID\"" "$H7/.config/agentkit/ctx/claude-$cp9.json" && grep -qF "\"transcript\": \"$TS7\", \"cwd\": \"$P7\"}" "$H7/.config/agentkit/ctx/claude-$cp9.json"'
# kit context --detail (Claude): a fake claude answers Claude Code's control requests
FC="$T/fakeclaude"; mkdir -p "$FC"
cat > "$FC/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/claude-args"; pwd -P >> "$T/claude-cwd"
[ -z "\${FAKE_SLEEP:-}" ] || sleep "\$FAKE_SLEEP"
while IFS= read -r l; do
    case \$l in
        *'"request_id":"i1"'*) printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"i1","response":{"account":{"email":"secret@example.com"}}}}';;
        *'"request_id":"c1"'*) cat "$T/c1.json";;
    esac
done
EOF
chmod +x "$FC/claude"
cat > "$T/c1.json" <<EOF
{"type":"control_response","response":{"subtype":"success","request_id":"c1","response":{"categories":[{"id":"system_prompt","name":"System prompt","tokens":4000,"color":"promptBorder","kind":"used"},{"id":"system_tools","name":"System tools","tokens":6000,"color":"inactive","kind":"used"},{"id":"system_tools_deferred","name":"System tools (deferred)","tokens":13000,"color":"inactive","isDeferred":true,"kind":"deferred"},{"id":"mcp_tools","name":"MCP tools","tokens":3000,"color":"cyan","kind":"used"},{"id":"memory_files","name":"Memory files","tokens":1200,"color":"claude","kind":"used"},{"id":"skills","name":"Skills","tokens":800,"color":"warning","kind":"used"},{"id":"messages","name":"Messages","tokens":100000,"color":"purple","kind":"used"},{"id":"autocompact_buffer","name":"Autocompact buffer","tokens":33000,"color":"inactive","kind":"buffer"},{"id":"free_space","name":"Free space","tokens":252000,"color":"promptBorder","kind":"free"}],"totalTokens":115000,"maxTokens":400000,"rawMaxTokens":400000,"autocompactSource":"settings","percentage":29,"gridRows":[[{"color":"x","isFilled":true}]],"model":"claude-opus-5-5","memoryFiles":[{"path":"$H7/.claude/CLAUDE.md","type":"User","tokens":200},{"path":"$P7/CLAUDE.md","type":"Project","tokens":1000}],"mcpTools":[{"name":"mcp__gerrit__a","serverName":"gerrit","tokens":1000,"isLoaded":true},{"name":"mcp__gerrit__b","serverName":"gerrit","tokens":1500,"isLoaded":false},{"name":"mcp__kitping__ping","serverName":"kitping","tokens":500,"isLoaded":true}],"mcpInstructions":[],"agents":[{"agentType":"gerrit","source":"userSettings","tokens":120}],"slashCommands":{"totalCommands":5,"includedCommands":5,"tokens":300},"skills":{"totalSkills":2,"includedSkills":2,"tokens":800,"skillFrontmatter":[{"name":"tiny","source":"projectSettings","path":"$P7/.claude/skills/tiny/SKILL.md","tokens":300},{"name":"gerrit-review","source":"userSettings","path":"$H7/.claude/skills/gerrit-review/SKILL.md","tokens":500}]},"autoCompactThreshold":367000,"isAutoCompactEnabled":true,"messageBreakdown":{"toolCallTokens":1,"toolResultTokens":2,"toolCallsByType":[{"name":"Bash","callTokens":1,"resultTokens":2}],"attachmentsByType":[]},"apiUsage":{"input_tokens":2,"output_tokens":3,"cache_creation_input_tokens":4,"cache_read_input_tokens":5}}}}
EOF
# its transcript: what came before the compaction does not count; an image is about 1600, not its bytes
{
    printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_old","name":"Bash","input":{"command":"%s"}}],"stop_reason":"tool_use","usage":{"input_tokens":5}},"uuid":"u1"}\n' "$(printf '%0800d' 0)"
    printf '{"parentUuid":"u1","isSidechain":false,"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":300000,"postTokens":9000},"uuid":"u2"}\n'
    printf '{"parentUuid":"u2","isSidechain":false,"type":"user","message":{"role":"user","content":"%s"},"isCompactSummary":true,"uuid":"u3"}\n' "$(printf '%0400d' 0)"
    printf '{"parentUuid":"u3","isSidechain":false,"type":"user","message":{"role":"user","content":"look at this"},"uuid":"u4","timestamp":"t"}\n'
    printf '{"parentUuid":"u4","isSidechain":false,"type":"attachment","attachment":{"type":"skill_listing","content":"%s"},"rendered":[{"content":"%s"}],"renderedRole":"system","uuid":"u5"}\n' "$(printf '%0400d' 0)" "$(printf '%0400d' 0)"
    printf '{"parentUuid":"u5","isSidechain":false,"type":"attachment","attachment":{"type":"file","filename":"x"},"rendered":[{"content":"%s"}],"renderedRole":"user","uuid":"u6"}\n' "$(printf '%0200d' 0)"
    printf '{"parentUuid":"u6","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"%s","signature":"sig"},{"type":"text","text":"reading it"},{"type":"tool_use","id":"toolu_r1","name":"Read","input":{"file_path":"/x/a.png"}}],"stop_reason":"tool_use","usage":{"input_tokens":5}},"uuid":"u7"}\n' "$(printf '%0900d' 0)"
    printf '{"parentUuid":"u7","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_r1","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"%s"}}]}]},"uuid":"u8","toolUseResult":{"file":"%s"}}\n' "$(printf '%09000d' 0)" "$(printf '%09000d' 0)"
} > "$TS7"
rm -f "$T/claude-args" "$T/claude-cwd"
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail)
dj_claude=$out
check "context --detail (claude): Claude Code asked with every hook off, nothing kept, its session, in its folder" 'grep -qF -- "--resume $SID --no-session-persistence --settings {\"disableAllHooks\":true}" "$T/claude-args" && [ "$(cat "$T/claude-cwd")" = "$P7" ] && ! echo "$out" | grep -q secret@'
check "context --detail (claude): its numbers, the live total wins (the rest is its own row), the window from settings.json" 'echo "$out" | grep -qF "{\"tool\": \"claude\", \"used\": 130000, \"window\": 400000, \"pct\": 33, \"source\": \"get_context_usage\", \"model\": \"claude-opus-5-5\", \"at\": " && echo "$out" | grep -qF "\"exact\": true, \"session\": \"$SID\", \"compact_at\": 367000, \"commands\": {\"compact\": \"/compact\", \"with_text\": true, \"clear\": \"/clear\"}" && echo "$out" | grep -qF "\"error\": null"'
check "context --detail (claude): the categories in Chinese, deferred kept apart, free space what is left" 'echo "$out" | grep -qF "\"categories\": [{\"id\": \"system_prompt\", \"name\": \"系統提示\", \"tokens\": 4000, \"kind\": \"used\", \"est\": false}, {\"id\": \"system_tools\", \"name\": \"系統工具\", \"tokens\": 6000, \"kind\": \"used\", \"est\": false}, {\"id\": \"system_tools_deferred\", \"name\": \"系統工具（延後載入）\", \"tokens\": 13000, \"kind\": \"deferred\", \"est\": false}, {\"id\": \"mcp_tools\", \"name\": \"MCP 工具\", \"tokens\": 3000, \"kind\": \"used\", \"est\": false}, {\"id\": \"memory_files\", \"name\": \"記憶檔\", \"tokens\": 1200, \"kind\": \"used\", \"est\": false}, {\"id\": \"skills\", \"name\": \"Skills\", \"tokens\": 800, \"kind\": \"used\", \"est\": false}, {\"id\": \"messages\", \"name\": \"對話訊息\", \"tokens\": 100000, \"kind\": \"used\", \"est\": false}, {\"id\": \"other\", \"name\": \"其他／自上次更新以來\", \"tokens\": 15000, \"kind\": \"used\", \"est\": false}, {\"id\": \"autocompact_buffer\", \"name\": \"自動壓縮保留區\", \"tokens\": 33000, \"kind\": \"buffer\", \"est\": false}, {\"id\": \"free_space\", \"name\": \"可用空間\", \"tokens\": 237000, \"kind\": \"free\", \"est\": false}]"'
check "context --detail (claude): memory files, skills, MCP by server (its tools inside), agents, commands; most first" 'echo "$out" | grep -qF "{\"id\": \"memory\", \"name\": \"記憶檔\", \"tokens\": 1200, \"est\": false, \"items\": [{\"name\": \"$P7/CLAUDE.md\", \"tokens\": 1000, \"note\": \"Project\", \"path\": \"$P7/CLAUDE.md\"}, {\"name\": \"~/.claude/CLAUDE.md\", \"tokens\": 200, \"note\": \"User\", \"path\": \"$H7/.claude/CLAUDE.md\"}]}" && echo "$out" | grep -qF "{\"id\": \"skills\", \"name\": \"Skills\", \"tokens\": 800, \"est\": false, \"items\": [{\"name\": \"gerrit-review\", \"tokens\": 500," && echo "$out" | grep -qF "{\"id\": \"mcp\", \"name\": \"MCP（依伺服器）\", \"tokens\": 3000, \"est\": false, \"items\": [{\"name\": \"gerrit\", \"tokens\": 2500, \"note\": \"2 個工具\", \"path\": \"\", \"items\": [{\"name\": \"mcp__gerrit__b\", \"tokens\": 1500, \"note\": \"延後載入\", \"path\": \"\"}, {\"name\": \"mcp__gerrit__a\", \"tokens\": 1000, \"note\": \"已載入\", \"path\": \"\"}]}, {\"name\": \"kitping\", \"tokens\": 500," && echo "$out" | grep -qF "{\"id\": \"agents\", \"name\": \"自訂 agents\", \"tokens\": 120," && echo "$out" | grep -qF "{\"name\": \"5 個指令\", \"tokens\": 300,"'
tr_items=$(echo "$out" | sed -n 's/.*"id": "tool_results", "name": "[^"]*", "tokens": [0-9]*, "est": true, "items": \[\([^]]*\)\].*/\1/p')
msg_total=$(echo "$out" | sed -n 's/.*"id": "msgs", "name": "對話內容（依種類）", "tokens": \([0-9]*\),.*/\1/p')
check "context --detail (claude): what was said, estimated after the last compaction and scaled to Claude's own number (thinking and listings not counted)" '[ -n "$msg_total" ] && [ $((msg_total - 100000)) -ge -5 ] && [ $((msg_total - 100000)) -le 5 ] && echo "$tr_items" | grep -qF "\"name\": \"Read\"" && ! echo "$tr_items" | grep -q Bash && echo "$out" | grep -qF "\"name\": \"壓縮後的摘要\"" && echo "$out" | grep -qF "{\"id\": \"attachments\", \"name\": \"附加內容（依種類）\", \"tokens\": " && ! echo "$out" | grep -q skill_listing'
# the image: about 1600 (not its 9000 bytes); the Read result is about 1600 + its bytes / 4, scaled like the rest
n1=$(wc -l < "$T/claude-args")
out2=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail)
check "context --detail: kept a minute (Claude not asked again)" '[ "$(wc -l < "$T/claude-args")" = "$n1" ] && [ "$out2" = "$out" ]'
PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh >/dev/null
check "context --detail --fresh: asked again" '[ "$(wc -l < "$T/claude-args")" -gt "$n1" ]'
# a gateway that sends the keys in another order ("id" before "type"): the tools still found by name
cp "$TS7" "$T/ts7.keep"
{
    printf '{"parentUuid":"u6","isSidechain":false,"type":"assistant","message":{"content":[{"signature":"sig","thinking":"x","type":"thinking"},{"text":"reading it","type":"text"},{"id":"toolu_s1","input":{"file_path":"/x/b.txt","name":"inner","type":"x"},"name":"Read","type":"tool_use"}],"id":"m1","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","type":"message","usage":{"input_tokens":5}},"uuid":"u9"}\n'
    printf '{"parentUuid":"u9","isSidechain":false,"type":"user","message":{"role":"user","content":[{"content":"a \\"quoted\\" {brace} \\\\ %s","is_error":false,"tool_use_id":"toolu_s1","type":"tool_result"}]},"uuid":"u10"}\n' "$(printf '%0900d' 0)"
} >> "$TS7"
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh)
tr_items=$(echo "$out" | sed -n 's/.*"id": "tool_results", "name": "[^"]*", "tokens": [0-9]*, "est": true, "items": \[\([^]]*\)\].*/\1/p')
check "context --detail (claude): keys in another order (a gateway): the tool is still named, not \"?\"" 'echo "$tr_items" | grep -qF "\"name\": \"Read\", \"tokens\": " && echo "$tr_items" | grep -qF "\"note\": \"2 次\"" && ! echo "$tr_items" | grep -qF "\"name\": \"?\"" && ! echo "$tr_items" | grep -q inner'
mv "$T/ts7.keep" "$TS7"
# a long log: read from its last compaction, not its whole tail (a quote of that line, escaped, doesn't count); the
# same answer as reading all of it; Claude Code asked while the log is read
cp "$TS7" "$T/ts7.keep"
{
    i=0; while [ $i -lt 200 ]; do printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"o%s","name":"Bash","input":{"command":"%s"}}]},"uuid":"o"}\n' $i "$(printf '%01000d' 0)"; i=$((i + 1)); done
    cat "$T/ts7.keep"
    printf '{"parentUuid":"u8","isSidechain":false,"type":"user","message":{"role":"user","content":"it wrote \\"subtype\\":\\"compact_boundary\\" once"},"uuid":"u11"}\n'
} > "$TS7"
la=$(PATH="$FC:$PATH" KIT_CTX_DETAIL_TAIL=100000 CX --pid $$ --tool claude --dir "$P7" --detail --fresh | sed 's/"at": [0-9]*/"at": 0/')
lb=$(PATH="$FC:$PATH" KIT_CTX_DETAIL_TAIL=99999999 CX --pid $$ --tool claude --dir "$P7" --detail --fresh | sed 's/"at": [0-9]*/"at": 0/')
check "context --detail (claude): a long log read from its last compaction: the same as reading all of it, nothing before it" '[ -n "$la" ] && [ "$la" = "$lb" ] && echo "$la" | grep -qF "\"exact\": true" && ! echo "$la" | grep -qF "\"name\": \"Bash\"" && echo "$la" | grep -qF "\"name\": \"壓縮後的摘要\""'
t0=$(date +%s); lc=$(FAKE_SLEEP=2 PATH="$FC:$PATH" KIT_CTX_DETAIL_TAIL=100000 CX --pid $$ --tool claude --dir "$P7" --detail --fresh | sed 's/"at": [0-9]*/"at": 0/'); t1=$(date +%s)
check "context --detail (claude): a slow Claude Code (2 s) still answers, the same" '[ "$lc" = "$la" ] && [ $((t1 - t0)) -lt 8 ]'
if [ -n "$PWSH" ]; then
    lp=$(PATH="$FC:$PATH" KIT_CTX_DETAIL_TAIL=100000 kps context --pid $$ --tool claude --dir "$P7" --detail --fresh 2>&1 | sed 's/"at": [0-9]*/"at": 0/')
    check "context --detail (claude) from the last compaction: kit.ps1 says the same" '[ "$lp" = "$la" ]'
fi
mv "$T/ts7.keep" "$TS7"
t0=$(date +%s); out=$(FAKE_SLEEP=20 KIT_CTX_PROBE_TIMEOUT=2 PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh); t1=$(date +%s)
check "context --detail: Claude Code that does not answer is stopped (timeout), the answer says so, still JSON, estimated" '[ $((t1 - t0)) -lt 10 ] && echo "$out" | grep -qF "\"error\": \"Claude Code 沒有回答" && echo "$out" | grep -qF "\"exact\": false" && echo "$out" | grep -qF "\"used\": 130000, \"window\": 400000" && echo "$out" | grep -qF "\"id\": \"msgs\""'
printf '{"pid": %s, "session": "x;rm -rf y", "used": 1, "window": 2, "pct": 50, "model": "m"}\n' "$$" > "$H7/.config/agentkit/ctx/claude-$$.json"
n1=$(wc -l < "$T/claude-args")
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh)
check "context --detail: a session id with other characters is not used (Claude not run)" '[ "$(wc -l < "$T/claude-args")" = "$n1" ] && echo "$out" | grep -qF "\"error\": \"找不到這個 Claude 的 session\""'
rm -f "$H7/.config/agentkit/ctx/claude-$$.json"
# no status line: ~/.claude/sessions/<pid>.json (older Claude Code), then the daemon roster (only pid / replPid / sessionId / cwd)
mkdir -p "$H7/.claude/sessions" "$H7/.claude/daemon"
printf '{"workers":{"w1":{"pid":1,"replPid":%s,"sessionId":"%s","cwd":"%s","token":"sk-secret-1"}}}\n' "$$" "$SID" "$P7" > "$H7/.claude/daemon/roster.json"
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh)
check "context --detail: the session from the daemon roster (its replPid); its token never shown" 'echo "$out" | grep -qF "\"session\": \"$SID\"" && echo "$out" | grep -qF "\"exact\": true" && ! echo "$out" | grep -q sk-secret'
rm -f "$H7/.claude/daemon/roster.json"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","startedAt":1}\n' "$$" "$SID" "$P7" > "$H7/.claude/sessions/$$.json"
out=$(PATH="$FC:$PATH" CX --pid $$ --tool claude --dir "$P7" --detail --fresh)
check "context --detail: the session from ~/.claude/sessions/<pid>.json" 'echo "$out" | grep -qF "\"session\": \"$SID\"" && echo "$out" | grep -qF "\"exact\": true"'
rm -f "$H7/.claude/sessions/$$.json"
# Codex: its rollout, split by what it holds, scaled to its own total
P9="$T/cxproj"; mkdir -p "$P9/.git" "$P9/sub"; P9=$(cd "$P9" && pwd -P); RO9="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T03-00-00-c9.jsonl"
echo "team rules for the repo" > "$P9/AGENTS.md"; echo "only here" > "$P9/sub/AGENTS.md"; printf 'mine\n' > "$H7/.codex/AGENTS.md"
printf '[mcp_servers.kitping]\ncommand = "x"\n[mcp_servers.kitping.env]\nA = "1"\n[mcp_servers."unused"]\ncommand = "y"\n' > "$H7/.codex/config.toml"
{
    printf '{"timestamp":"t","type":"session_meta","payload":{"id":"c9","cwd":"%s/sub","base_instructions":{"text":"You are Codex, %s"}}}\n' "$P9" "$(printf '%0400d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"additional_tools","tools":[{"type":"namespace","name":"functions","description":"core","tools":[{"type":"custom","name":"exec","description":"%s"},{"type":"function","name":"wait","description":"w"}]},{"type":"namespace","name":"mcp__kitping","description":"ping","tools":[{"type":"function","name":"ping","description":"%s"}]}]}}\n' "$(printf '%0800d' 0)" "$(printf '%0200d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are Codex, %s"},{"type":"input_text","text":"<skills_instructions>\\n## Skills\\n### Skill roots\\n- `r0` = `%s/.agents/skills`\\n### Available skills\\n- alpha: does a %s (file: r0/alpha/SKILL.md)\\n- plug:beta: does b (file: r0/beta/SKILL.md)\\n</skills_instructions>"},{"type":"input_text","text":"<tools>\\nDeferred tool namespaces:\\n- mcp__apps__docs: docs %s\\n</tools>"}]}}\n' "$(printf '%0400d' 0)" "$H7" "$(printf '%0100d' 0)" "$(printf '%040d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\\n%s"},{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}\n' "$(printf '%0200d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix it"}]}}\n'
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"%s"}}\n' "$(printf '%02000d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"cmd\\":\\"ls\\"}","call_id":"c1"}}\n'
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"%s"}}\n' "$(printf '%01200d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"%s","call_id":"c2"}}\n' "$(printf '%0300d' 0)"
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":"ok"}}\n'
    printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done %s"}]}}\n' "$(printf '%0100d' 0)"
    printf '{"timestamp":"t","type":"turn_context","payload":{"cwd":"%s/sub","model":"gpt-6-luna"}}\n' "$P9"
    printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":99999},"last_token_usage":{"input_tokens":20000,"cached_input_tokens":18000,"output_tokens":500,"reasoning_output_tokens":100,"total_tokens":20500},"model_context_window":258400}}}\n'
} > "$RO9"
out=$(CX --pid 1 --tool codex --dir "$P9/sub" --detail)
dj_codex=$out
sum=0; for n in $(echo "$out" | sed 's/.*"categories": \[//; s/\], "groups".*//' | grep -o '"tokens": [0-9]*, "kind": "used"' | grep -o '[0-9]*'); do sum=$((sum + n)); done
check "context --detail (codex): Codex's own total and %, its commands (/compact takes no text here, /new)" 'echo "$out" | grep -qF "{\"tool\": \"codex\", \"used\": 20500, \"window\": 258400, \"pct\": 3, \"source\": \"rollout\", \"model\": \"gpt-6-luna\", \"at\": " && echo "$out" | grep -qF "\"exact\": false" && echo "$out" | grep -qF "\"commands\": {\"compact\": \"/compact\", \"with_text\": false, \"clear\": \"/new\"}"'
check "context --detail (codex): the parts add up to its total exactly" '[ "$sum" = 20500 ] && echo "$out" | grep -qF "{\"id\": \"free_space\", \"name\": \"可用空間\", \"tokens\": 237900, \"kind\": \"free\", \"est\": false}"'
check "context --detail (codex): AGENTS.md files from the git root down (and Codex's own), skills with their folder, tools by namespace, MCP (seen, deferred, configured)" 'echo "$out" | grep -qF "\"path\": \"$P9/AGENTS.md\"" && echo "$out" | grep -qF "\"path\": \"$P9/sub/AGENTS.md\"" && echo "$out" | grep -qF "{\"name\": \"~/.codex/AGENTS.md\"" && echo "$out" | grep -qF "{\"name\": \"alpha\", \"tokens\": " && echo "$out" | grep -qF "\"note\": \"~/.agents/skills\", \"path\": \"$H7/.agents/skills/alpha/SKILL.md\"" && echo "$out" | grep -qF "{\"name\": \"plug:beta\"" && echo "$out" | grep -qF "{\"name\": \"functions\", \"tokens\": " && echo "$out" | grep -qF "\"note\": \"2 個工具\"" && echo "$out" | grep -qF "{\"name\": \"mcp__kitping\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"mcp__apps__docs\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"unused\", \"tokens\": null, \"note\": \"設定裡有，這次對話沒看到它的工具\""'
check "context --detail (codex): calls and results by tool (reasoning not counted)" 'echo "$out" | grep -qF "{\"name\": \"shell\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"apply_patch\", \"tokens\": " && echo "$out" | grep -qF "\"note\": \"1 次\""'
printf '{"timestamp":"t","type":"compacted","payload":{"message":"%s","replacement_history":[]}}\n' "$(printf '%0400d' 0)" >> "$RO9"
printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":4000},"model_context_window":258400}}}\n' >> "$RO9"
out=$(CX --pid 1 --tool codex --dir "$P9/sub" --detail --fresh)
check "context --detail (codex): compacted -> what came before is gone, the summary counts" 'echo "$out" | grep -qF "\"used\": 4000," && echo "$out" | grep -qF "{\"id\": \"compaction\", \"name\": \"壓縮後的摘要\"" && ! echo "$out" | grep -qF "{\"name\": \"shell\""'
# omp: its own numbers (the conversation, the tools), the rest estimated and scaled
P10="$T/ompproj"; mkdir -p "$P10/.agents/skills/sk1"; P10=$(cd "$P10" && pwd -P); OS10="$H7/.omp/agent/sessions/y/s10.jsonl"; mkdir -p "$H7/.omp/agent/sessions/y"
printf -- '---\nname: sk1\ndescription: %s\n---\nbody\n' "$(printf '%0200d' 0)" > "$P10/.agents/skills/sk1/SKILL.md"; echo "omp rules" > "$H7/.omp/agent/AGENTS.md"; echo "repo rules" > "$P10/AGENTS.md"
printf '{"mcpServers":{"gerrit":{"command":"x"}}}\n' > "$H7/.omp/agent/mcp.json"
{
    printf '{"type":"session","version":3,"id":"s10","cwd":"%s"}\n{"type":"model_change","id":"m0","model":"anthropic/claude-opus-5-5"}\n' "$P10"
    printf '{"type":"message","id":"e1","message":{"role":"user","content":[{"type":"text","text":"old question %s"}]}}\n' "$(printf '%0800d' 0)"
    printf '{"type":"message","id":"e2","message":{"role":"user","content":[{"type":"text","text":"kept question"}]}}\n'
    printf '{"type":"message","id":"e3","message":{"role":"assistant","content":[{"type":"thinking","thinking":"%s"},{"type":"text","text":"ok"},{"type":"toolCall","id":"tc1","name":"read","arguments":{"path":"/x"}}],"usage":{"input":1},"contextSnapshot":{"promptTokens":50000,"nonMessageTokens":12000,"toolSchemaTokens":8000,"compactionEpoch":0},"stopReason":"toolUse"}}\n' "$(printf '%0500d' 0)"
    printf '{"type":"message","id":"e4","message":{"role":"toolResult","toolCallId":"tc1","toolName":"read","content":[{"type":"text","text":"%s"}],"details":{"x":"%s"}}}\n' "$(printf '%02000d' 0)" "$(printf '%09000d' 0)"
    printf '{"type":"compaction","id":"k1","summary":"%s","firstKeptEntryId":"e2","tokensBefore":60000,"tokensAfter":30000}\n' "$(printf '%0400d' 0)"
    printf '{"type":"custom_message","id":"x1","customType":"todo-nudge","content":"remember %s","display":false}\n' "$(printf '%0100d' 0)"
} > "$OS10"
out=$(CX --pid 1 --tool omp --dir "$P10" --detail)
dj_omp=$out
sum=0; for n in $(echo "$out" | sed 's/.*"categories": \[//; s/\], "groups".*//' | grep -o '"tokens": [0-9]*, "kind": "used"' | grep -o '[0-9]*'); do sum=$((sum + n)); done
check "context --detail (omp): omp's total (after the compaction), its tools exactly, /compact with text, /new" 'echo "$out" | grep -qF "{\"tool\": \"omp\", \"used\": 30000, \"window\": " && echo "$out" | grep -qF "\"source\": \"session\", \"model\": \"anthropic/claude-opus-5-5\"" && echo "$out" | grep -qF "{\"id\": \"system_tools\", \"name\": \"系統工具\", \"tokens\": 8000, \"kind\": \"used\", \"est\": false}" && echo "$out" | grep -qF "\"commands\": {\"compact\": \"/compact\", \"with_text\": true, \"clear\": \"/new\"}"'
check "context --detail (omp): the parts add up to its total; instruction files, skills, MCP from its settings, tools by name, what omp adds" '[ "$sum" = 30000 ] && echo "$out" | grep -qF "{\"name\": \"~/.omp/agent/AGENTS.md\"" && echo "$out" | grep -qF "\"path\": \"$P10/AGENTS.md\"" && echo "$out" | grep -qF "{\"name\": \"sk1\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"gerrit\", \"tokens\": null, \"note\": \"設定的 MCP" && echo "$out" | grep -qF "{\"name\": \"read\", \"tokens\": " && echo "$out" | grep -qF "{\"name\": \"todo-nudge\", \"tokens\": " && echo "$out" | grep -qF "{\"id\": \"compaction\", \"name\": \"壓縮後的摘要\""'
if [ -n "$PWSH" ]; then
    printf '{"pid": %s, "session": "%s", "used": 130000, "window": 1000000, "pct": 13, "model": "claude-opus-5-5", "transcript": "%s", "cwd": "%s"}\n' "$$" "$SID" "$TS7" "$P7" > "$H7/.config/agentkit/ctx/claude-$$.json"
    same=1
    for a in "--pid $$ --tool claude --dir $P7" "--pid 1 --tool codex --dir $P9/sub" "--pid 1 --tool omp --dir $P10" "--pid 1 --tool codex --dir $P10"; do
        x=$(PATH="$FC:$PATH" kit context $a --detail --fresh 2>&1 | sed 's/"at": [0-9]*/"at": 0/')
        y=$(PATH="$FC:$PATH" kps context $a --detail --fresh 2>&1 | sed 's/"at": [0-9]*/"at": 0/')
        [ "$x" = "$y" ] || { same=0; echo "  differs: $a"; printf '%s\n' "$x" | tr ',' '\n' > "$T/dx"; printf '%s\n' "$y" | tr ',' '\n' > "$T/dy"; diff "$T/dx" "$T/dy" | head -n 6; }
    done
    check "context --detail: kit.ps1 says the same (Claude, Codex, omp, nothing found)" '[ $same = 1 ]'
    out=$(kps context --pid $$ --tool claude --dir "$P7" 2>&1); out2=$(kps statusline < "$T/sl2.json" 2>/dev/null)
    check "context, statusline (kit.ps1): the window set in settings.json (autoCompactWindow) too" '[ "$out" = "{\"tool\": \"claude\", \"used\": 130000, \"window\": 400000, \"pct\": 33, \"source\": \"statusline\", \"model\": \"claude-opus-5-5\"}" ] && [ "$out2" = "Opus 5.5 · context 35%（139k / 400k）" ]'
    rm -f "$H7/.config/agentkit/ctx/claude-$$.json"
fi
big=$(printf '%0400d' 0)
printf '{"type":"user","message":{"content":"%s"}}\n' "$big" >> "$CT"
printf '{"type":"event_msg","payload":{"type":"agent_message","message":"%s"}}\n' "$big" >> "$RO"
printf '{"type":"note","text":"%s"}\n' "$big" >> "$OS"
same=1
for a in "--tool codex" "--tool omp" "--tool claude"; do
    [ "$(KIT_CTX_TAIL=100 kit context --pid 1 $a --dir "$P7" 2>&1)" = "$(kit context --pid 1 $a --dir "$P7" 2>&1)" ] || { same=0; echo "  differs: $a"; }
done
check "context: a long log is read from its end; nothing there -> all of it, the same answer" '[ $same = 1 ]'
P8="$T/ctxfull"; mkdir -p "$P8"; P8=$(cd "$P8" && pwd -P); C8="$H7/.claude/projects/$(printf '%s' "$P8" | sed 's|[^A-Za-z0-9]|-|g')"; mkdir -p "$C8"
printf '{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":250000}}}\n' > "$C8/t.jsonl"
out=$(CX --pid 1 --tool claude --dir "$P8")
check "context: past the window -> 100 %" '[ "$out" = "{\"tool\": \"claude\", \"used\": 250000, \"window\": 200000, \"pct\": 100, \"source\": \"transcript\", \"model\": \"claude-sonnet-4-5\"}" ]'
out=$(capped 10 kit context --pid 2>&1); rc=$?
check "context: --pid with nothing after it -> how to use it (not a hang)" '[ $rc -eq 1 ] && echo "$out" | grep -qF "用法：kit context"'
if [ -n "$PWSH" ]; then
    same=1
    for a in "--pid 1 --tool codex --dir $P7" "--pid 1 --tool omp --dir $P7" "--pid 1 --tool claude --dir $P7" "--pid $cp --tool claude --dir $P7" "--pid 1 --tool claude --dir $P8"; do
        [ "$(kit context $a 2>&1)" = "$(kps context $a 2>&1)" ] || { same=0; echo "  differs: $a"; }
        [ "$(KIT_CTX_TAIL=100 kit context $a 2>&1)" = "$(KIT_CTX_TAIL=100 kps context $a 2>&1)" ] || { same=0; echo "  differs (tail): $a"; }
    done
    check "context: kit.ps1 says the same" '[ $same = 1 ]'
    out=$(kps statusline < "$T/sl.json")
    check "statusline: kit.ps1 prints the same line" '[ "$out" = "Opus 5.5 · context 35%（139k / 400k）" ]'
fi
echo '{}' > "$H7/.config/agentkit/ctx/claude-999999.json"
CX --pid 1 --tool claude --dir "$P7" >/dev/null
check "context: numbers of a Claude process that is gone are thrown away" '[ ! -e "$H7/.config/agentkit/ctx/claude-999999.json" ]'
out=$(CX --pid 1)
check "context: not an agent -> nothing" '[ "$out" = "{\"tool\": \"\", \"used\": null, \"window\": null, \"pct\": null, \"source\": \"\", \"model\": \"\"}" ]'
# the plan's usage limits: kit statusline keeps what Claude hands over (rate_limits) for kit usage; Codex's from its
# newest rollout; a Claude stopped at its limit says until when (kit context's "limit"), until it goes on
FO="$T/fakeomp"; mkdir -p "$FO"; export PATH="$FO:$PATH"
printf '#!/bin/sh\n[ "$1 $2" = "usage --json" ] && [ -f "%s/omp-usage.json" ] || exit 1\ncat "%s/omp-usage.json"\n' "$T" "$T" > "$FO/omp"; chmod +x "$FO/omp"
out=$(HOME="$T/nousage" kit usage)
check "usage: nothing seen yet -> null for each" '[ "$out" = "{\"claude\": null, \"codex\": null, \"omp\": null}" ]'
printf '{"session_id":"abc","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"context_window_size":400000,"current_usage":{"input_tokens":2,"cache_read_input_tokens":1000},"used_percentage":1},"rate_limits":{"five_hour":{"used_percentage":40.6,"resets_at":1794700000},"seven_day":{"used_percentage":100,"resets_at":1795000000}}}' > "$T/sl3.json"
mkdir -p "$T/fb11"; printf '#!/bin/sh\n"%s" statusline < "%s/sl3.json"\n' "$KIT" "$T" > "$T/fb11/claude"; chmod +x "$T/fb11/claude"
"$T/fb11/claude" >/dev/null
RL="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T03-00-00-rl.jsonl"
printf '{"type":"session_meta","payload":{"id":"rl","cwd":"/elsewhere"}}\n' > "$RL"
printf '{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":1794690000},"secondary":{"used_percent":61.5,"window_minutes":10080,"resets_at":1795100000},"credits":{"has_credits":false}}}}\n' 1.0 3.4 >> "$RL"
printf '{"type":"event_msg","payload":{"type":"agent_message","message":"done"}}\n' >> "$RL"
USAGE_WANT='{"claude": {"at": 0, "windows": [{"id": "five_hour", "pct": 41, "minutes": 300, "resets_at": 1794700000000}, {"id": "seven_day", "pct": 100, "minutes": 10080, "resets_at": 1795000000000}]}, "codex": {"at": null, "windows": [{"id": "primary", "pct": 3, "minutes": 300, "resets_at": 1794690000000}, {"id": "secondary", "pct": 62, "minutes": 10080, "resets_at": 1795100000000}]}, "omp": null}'
out=$(kit usage | sed 's/"at": [0-9][0-9]*/"at": 0/')
check "usage: Claude's 5-hour and weekly use as the status line last saw it; Codex's last rate_limits (the newest rollout, its last one)" '[ "$out" = "$USAGE_WANT" ]'
printf '{"type":"assistant","apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1794016800,"rateLimitType":"five_hour"}},"message":{"model":"<synthetic>","usage":{"input_tokens":0},"content":[{"type":"text","text":"You hit your limit"}]},"isApiErrorMessage":true}\n{"type":"system","subtype":"stop_hook_summary"}\n{"type":"user","isMeta":true,"message":{"content":"x"}}\n' >> "$C8/t.jsonl"
out=$(CX --pid 1 --tool claude --dir "$P8")
check "context (claude): stopped at the usage limit -> until when and which limit (a system line or a meta line after it doesn't count)" '[ "$out" = "{\"tool\": \"claude\", \"used\": 250000, \"window\": 200000, \"pct\": 100, \"source\": \"transcript\", \"model\": \"claude-sonnet-4-5\", \"limit\": {\"until\": 1794016800000, \"kind\": \"five_hour\"}}" ]'
LIMITED=$(kit context --pid 1 --tool claude --dir "$P8" 2>&1)
if [ -n "$PWSH" ]; then
    out=$(kps usage | sed 's/"at": [0-9][0-9]*/"at": 0/'); out2=$(kps context --pid 1 --tool claude --dir "$P8" 2>&1)
    check "usage, context's limit: kit.ps1 says the same" '[ "$out" = "$USAGE_WANT" ] && [ "$out2" = "$LIMITED" ]'
    UF="$H7/.config/agentkit/ctx/claude-usage.json"; x=$(sed 's/"at": [0-9][0-9]*/"at": 0/' "$UF"); rm -f "$UF"
    kps statusline < "$T/sl3.json" >/dev/null; y=$(sed 's/"at": [0-9][0-9]*/"at": 0/' "$UF" 2>/dev/null)
    check "statusline (kit.ps1): keeps the same usage" '[ -n "$x" ] && [ "$x" = "$y" ]'
fi
printf '{"type":"user","message":{"content":"go on"}}\n' >> "$C8/t.jsonl"
out=$(CX --pid 1 --tool claude --dir "$P8")
check "context (claude): told to go on after the limit -> no limit any more" '[ "$out" = "{\"tool\": \"claude\", \"used\": 250000, \"window\": 200000, \"pct\": 100, \"source\": \"transcript\", \"model\": \"claude-sonnet-4-5\"}" ]'
# a Codex stopped at its limit: its last rate_limits says rate_limit_reached; until the reset of its fullest window
PL="$T/cxlim"; mkdir -p "$PL"; PL=$(cd "$PL" && pwd -P); RLL="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T04-00-00-lim.jsonl"
printf '{"type":"session_meta","payload":{"id":"lim","cwd":"%s"}}\n{"type":"turn_context","payload":{"cwd":"%s","model":"gpt-6-luna"}}\n' "$PL" "$PL" > "$RLL"
CXRL='{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":20000},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":1794690000},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":1795100000},"credits":null,"plan_type":"plus","rate_limit_reached_type":%s}}}\n'
printf "$CXRL" 40.0 61.5 null >> "$RLL"
out=$(CX --pid 1 --tool codex --dir "$PL")
check "context (codex): under its limits -> no limit" '[ "$out" = "{\"tool\": \"codex\", \"used\": 20000, \"window\": 258400, \"pct\": 3, \"source\": \"rollout\", \"model\": \"gpt-6-luna\"}" ]'
printf '{"type":"event_msg","payload":{"type":"task_started"}}\n' >> "$RLL"; printf "$CXRL" 100.0 70.0 '"rate_limit_reached"' >> "$RLL"
printf '{"type":"event_msg","payload":{"type":"task_complete"}}\n' >> "$RLL"
out=$(CX --pid 1 --tool codex --dir "$PL")
check "context (codex): stopped at the 5-hour limit -> until its reset" 'echo "$out" | grep -qF "\"model\": \"gpt-6-luna\", \"limit\": {\"until\": 1794690000000, \"kind\": \"five_hour\"}}"'
LIMITED=$out
printf "$CXRL" 100.0 100.0 '"workspace_member_usage_limit_reached"' >> "$RLL"
out=$(CX --pid 1 --tool codex --dir "$PL")
check "context (codex): both windows full -> the later reset (weekly); the workspace's limit counts too" 'echo "$out" | grep -qF "\"limit\": {\"until\": 1795100000000, \"kind\": \"seven_day\"}}"'
[ -n "$PWSH" ] && { out2=$(kps context --pid 1 --tool codex --dir "$PL" 2>&1); check "context (codex) limit: kit.ps1 says the same" '[ "$out2" = "$out" ]'; }
printf "$CXRL" 0 0 '"workspace_member_credits_depleted"' >> "$RLL"
out=$(CX --pid 1 --tool codex --dir "$PL")
check "context (codex): credits run out has no reset -> no limit" '! echo "$out" | grep -qF "\"limit\""'
printf "$CXRL" 100.0 70.0 '"rate_limit_reached"' >> "$RLL"; printf '{"type":"event_msg","payload":{"type":"user_message","message":"繼續"}}\n' >> "$RLL"
out=$(CX --pid 1 --tool codex --dir "$PL")
check "context (codex): told to go on after the limit -> no limit any more" '! echo "$out" | grep -qF "\"limit\""'
[ -n "$PWSH" ] && { out2=$(kps context --pid 1 --tool codex --dir "$PL" 2>&1); check "context (codex) gone on: kit.ps1 says the same" '[ "$out2" = "$out" ]'; }
# omp: what `omp usage --json` says, only the numbers, asked in the background (kit prints what it kept)
printf '{"generatedAt": 1, "reports": [{"provider": "anthropic", "fetchedAt": 1794682355724, "limits": [{"id": "anthropic:5h", "label": "x", "scope": {"provider": "anthropic", "windowId": "5h"}, "window": {"id": "5h", "durationMs": 18000000, "resetsAt": 1794682799776}, "amount": {"used": 56, "limit": 100, "usedFraction": 0.56, "unit": "percent"}, "status": "ok"}, {"id": "anthropic:7d:fable", "window": {"id": "7d", "durationMs": 604800000, "resetsAt": 1794981600000}, "amount": {"usedFraction": 0.43999999999999995}}], "metadata": {"email": "someone@example.com", "accountId": "a-1"}}, {"provider": "openai-codex", "fetchedAt": 1794682355392, "limits": [{"id": "openai-codex:primary", "window": {"id": "30d", "durationMs": 2592000000, "resetsAt": 1796913312000}, "amount": {"usedFraction": 0.03}}]}, {"provider": "nothing", "limits": []}]}\n' > "$T/omp-usage.json"
OU="$H7/.config/agentkit/ctx/omp-usage.json"; OMP_WANT='"omp": {"anthropic": {"at": 1794682355724, "windows": [{"id": "5h", "pct": 56, "minutes": 300, "resets_at": 1794682799776}, {"id": "7d:fable", "pct": 44, "minutes": 10080, "resets_at": 1794981600000}]}, "openai-codex": {"at": 1794682355392, "windows": [{"id": "primary", "pct": 3, "minutes": 43200, "resets_at": 1796913312000}]}}}'
rm -f "$OU"; kit usage >/dev/null; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$OU" ] && break; sleep 0.5; done
out=$(kit usage)
check "usage (omp): each provider's windows from omp usage, numbers only (no e-mail or account)" 'case $out in *"$OMP_WANT") true;; *) false;; esac && ! grep -q "example.com\|a-1" "$OU"'
# a refresh killed mid-run leaves its lock with raw.json inside: once old, it goes and omp is asked again
ou_lock="${OU%.json}.lock"; rm -f "$OU"; mkdir -p "$ou_lock"; : > "$ou_lock/raw.json"; touch -t 202001010000 "$ou_lock"
kit usage >/dev/null; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$OU" ] && break; sleep 0.5; done
check "usage (omp): an old lock left with raw.json inside goes, omp asked again" '[ -s "$OU" ] && [ ! -d "$ou_lock" ]'
if [ -n "$PWSH" ]; then
    rm -f "$OU"; kps usage >/dev/null; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$OU" ] && break; sleep 0.5; done
    out2=$(kps usage); check "usage (omp): kit.ps1 keeps and says the same" '[ "$out2" = "$out" ]'
fi
out=$(kit usage x 2>&1); rc=$?
check "usage: anything after it -> how to use it" '[ $rc -eq 1 ] && echo "$out" | grep -qF "用法：kit usage"'
# the statusLine in settings.json: kit's when there is none, never over your own, gone again on uninstall
cp "$H7/.claude/settings.json" "$T/s7.orig"
mkdir -p "$T/src7/skills/a"; printf -- '---\nname: a\ndescription: a\n---\nx\n' > "$T/src7/skills/a/SKILL.md"
kit init "$T/src7" >/dev/null 2>&1
check "sync: kit's statusLine in settings.json" 'jget "$H7/.claude/settings.json" statusLine.command | grep -q "statusline" && jget "$H7/.claude/settings.json" modelSettings.claude-opus-5-5.autoCompactWindow | grep -q 400000'
# the context nearly full: kit's UserPromptSubmit hook tells Claude (once at 80 %, once at 90 %) to write HANDOFF.md first
check "sync: kit's UserPromptSubmit hook (handoff-hook) in settings.json, next to SessionStart's" 'jget "$H7/.claude/settings.json" hooks.UserPromptSubmit | grep -q "handoff-hook" && jget "$H7/.claude/settings.json" hooks.SessionStart | grep -q "sync --hook"'
mkdir -p "$T/fbh"; cat > "$T/fbh/claude" <<'FAKE'
#!/bin/sh
echo "{\"pid\": $$, \"session\": \"s-7\", \"used\": $USED, \"window\": 1000000, \"model\": \"claude-opus-5-5\"}" > "$HOME/.config/agentkit/ctx/claude-$$.json"
echo '{"session_id":"s-7","prompt":"hi"}' | sh -c "$HK handoff-hook"
FAKE
chmod +x "$T/fbh/claude"
ho() { USED=$1 HK=$2 "$T/fbh/claude"; }
o1=$(ho 300000 "'$KIT'"); o2=$(ho 330000 "'$KIT'"); o3=$(ho 340000 "'$KIT'"); o4=$(ho 370000 "'$KIT'"); o5=$(ho 100000 "'$KIT'"); o6=$(ho 330000 "'$KIT'")
check "handoff-hook: nothing below 80 % (the window from settings.json, 400k)" '[ -z "$o1" ]'
check "handoff-hook: at 80 % tells Claude to write HANDOFF.md and its kit note (valid JSON), once" 'echo "$o2" | grep -qF "context is 83% full (330k of 400k tokens)" && echo "$o2" | grep -q HANDOFF.md && echo "$o2" | LC_ALL=C awk -f "$JA" >/dev/null && [ "$(jget /dev/stdin hookSpecificOutput.hookEventName <<< "$o2")" = "\"UserPromptSubmit\"" ] && [ -z "$o3" ]'
check "handoff-hook: again at 90 %; fallen below 80 % (a /compact) and full again: told again" 'echo "$o4" | grep -qF "93% full" && [ -z "$o5" ] && echo "$o6" | grep -qF "83% full"'
if [ -n "$PWSH" ]; then
    rm -f "$H7/.config/agentkit/ctx/handoff-s-7"; b=$(ho 330000 "'$PWSH' -NoProfile -File '$HERE/../windows/kit.ps1'")
    check "handoff-hook (kit.ps1): the same JSON" '[ "$b" = "$o2" ]'
fi
# Codex runs the same hook (its hooks.json): its rollout (transcript_path), Codex's own way of counting
ROH="$H7/.codex/sessions/2026/11/12/rollout-2026-11-12T05-00-00-ho.jsonl"
printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":%s},"model_context_window":258400}}}\n' 220000 > "$ROH"
cho() { printf '{"session_id":"cx-1","transcript_path":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$ROH" | sh -c "$1 handoff-hook"; }
c1=$(cho "'$KIT'"); c2=$(cho "'$KIT'")
check "handoff-hook (Codex): its rollout's numbers (84% the way Codex counts), once" 'echo "$c1" | grep -qF "context is 84% full (220k of 258k tokens)" && [ -z "$c2" ]'
if [ -n "$PWSH" ]; then
    rm -f "$H7/.config/agentkit/ctx/handoff-cx-1"; c3=$(cho "'$PWSH' -NoProfile -File '$HERE/../windows/kit.ps1'")
    check "handoff-hook (Codex, kit.ps1): the same JSON" '[ "$c3" = "$c1" ]'
fi
# omp: kit's hook module runs the same hook before each prompt with its session (transcript_path)
OSH="$H7/.omp/agent/sessions/z/2026-11-12T06-00-00-000Z_ho.jsonl"; mkdir -p "${OSH%/*}"
printf '{"type":"session","version":3,"id":"ho","cwd":"/x"}\n{"type":"model_change","model":"anthropic/claude-opus-5-5"}\n{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":4},"contextSnapshot":{"promptTokens":850000,"compactionEpoch":0},"stopReason":"stop"}}\n' > "$OSH"
oho() { printf '{"session_id":"om-1","transcript_path":"%s"}' "$OSH" | sh -c "$1 handoff-hook"; }
d1=$(oho "'$KIT'"); d2=$(oho "'$KIT'")
check "handoff-hook (omp): its session's numbers, once" 'echo "$d1" | grep -qF "context is 85% full (850k of 1000k tokens)" && [ -z "$d2" ]'
if [ -n "$PWSH" ]; then
    rm -f "$H7/.config/agentkit/ctx/handoff-om-1"; d3=$(oho "'$PWSH' -NoProfile -File '$HERE/../windows/kit.ps1'")
    check "handoff-hook (omp, kit.ps1): the same JSON" '[ "$d3" = "$d1" ]'
fi
if command -v node >/dev/null 2>&1 && [ -f "$H7/.omp/agent/hooks/pre/kit.js" ]; then
    rm -f "$H7/.config/agentkit/ctx/handoff-"*; cp "$H7/.omp/agent/hooks/pre/kit.js" "$T/ompacct.mjs"
    printf '%s\n' 'const m = await import(process.argv[2]); const h = {}; m.default({ on: (e, f) => { h[e] = f; } });' \
        'const r = await h.before_agent_start({}, { sessionManager: { getSessionFile: () => process.argv[3] } });' \
        'console.log(r?.message?.customType + " " + String(r?.message?.content ?? "").includes("85% full"));' > "$T/ompho.mjs"
    out=$(HOME="$H7" node "$T/ompho.mjs" "$T/ompacct.mjs" "$OSH" 2>&1)
    check "omp module: before each prompt it runs handoff-hook and tells the model" '[ "$out" = "kit-handoff true" ]'
fi
# you take kit's statusLine out: it stays out (kit says so once); kit sync --force puts it back
printf 'del\tstatusLine\n' > "$T/ops7"; LC_ALL=C awk -f "$JA" -v ops="$T/ops7" "$H7/.claude/settings.json" > "$T/s7.new" && cp "$T/s7.new" "$H7/.claude/settings.json"
out=$(kit sync 2>&1)
check "statusLine taken out by you: not put back, kit says so (once) and how to get it back" '! jget "$H7/.claude/settings.json" statusLine >/dev/null && echo "$out" | grep -qF "kit sync --force" && ! kit sync 2>&1 | grep -q statusLine && ! jget "$H7/.claude/settings.json" statusLine >/dev/null'
kit sync --force >/dev/null 2>&1
check "kit sync --force: kit's statusLine back" 'jget "$H7/.claude/settings.json" statusLine.command | grep -q statusline'
if [ -n "$PWSH" ]; then
    LC_ALL=C awk -f "$JA" -v ops="$T/ops7" "$H7/.claude/settings.json" > "$T/s7.new" && cp "$T/s7.new" "$H7/.claude/settings.json"
    out=$(kps sync 2>&1)
    check "statusLine taken out by you (kit.ps1): not put back, says so; --force puts it back" '! jget "$H7/.claude/settings.json" statusLine >/dev/null && echo "$out" | grep -qF "kit sync --force" && ! kps sync 2>&1 | grep -q statusLine && kps sync --force >/dev/null 2>&1 && jget "$H7/.claude/settings.json" statusLine.command | grep -q statusline'
    kit sync --force >/dev/null 2>&1                         # (kit's own command and hook again, for uninstall below)
fi
kit uninstall >/dev/null 2>&1
check "uninstall: settings.json exactly as before, kit's numbers gone" 'cmp -s "$H7/.claude/settings.json" "$T/s7.orig" && [ ! -e "$H7/.config/agentkit/ctx" ]'
printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "my-line"\n  }\n}\n' > "$H7/.claude/settings.json"; cp "$H7/.claude/settings.json" "$T/s7.own"
out=$(kit init "$T/src7" 2>&1)
check "sync: your own statusLine stays, kit says so once" '[ "$(jget "$H7/.claude/settings.json" statusLine.command)" = "\"my-line\"" ] && echo "$out" | grep -q "statusLine" && ! kit sync 2>&1 | grep -q "statusLine"'
kit uninstall >/dev/null 2>&1
check "uninstall: your own statusLine stays" 'cmp -s "$H7/.claude/settings.json" "$T/s7.own"'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
