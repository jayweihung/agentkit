. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Team-Later
# ---------- how full an agent's context is (kit context, kit statusline) ----------
Set-Home (Join-Path $T 'home7')
$P7 = Join-Path $T 'ctxproj'; [void](New-Item -ItemType Directory -Force -Path $P7); $P7 = (Resolve-Path $P7).ProviderPath
$js = { param($x) $x.Replace('\', '\\') }
$RO = "$H/.codex/sessions/2026/11/12/rollout-2026-11-12T01-00-00-abc.jsonl"
W $RO ("{`"type`":`"session_meta`",`"payload`":{`"id`":`"abc`",`"cwd`":`"$(& $js $P7)`"}}`n{`"type`":`"turn_context`",`"payload`":{`"model`":`"gpt-6-luna`"}}`n" +
    "{`"type`":`"event_msg`",`"payload`":{`"type`":`"token_count`",`"info`":{`"total_token_usage`":{`"total_tokens`":412129},`"last_token_usage`":{`"input_tokens`":48732,`"output_tokens`":81,`"total_tokens`":48813},`"model_context_window`":258400}}}`n")
Kit context --pid 1 --tool codex --dir $P7
Check 'context (codex): the folder''s rollout, % the way Codex counts it' { $out.Trim() -eq '{"tool": "codex", "used": 48813, "window": 258400, "pct": 15, "source": "rollout", "model": "gpt-6-luna"}' }
W "$H/.omp/agent/sessions/x/s1.jsonl" ("{`"type`":`"session`",`"version`":3,`"id`":`"s1`",`"cwd`":`"$(& $js $P7)`"}`n{`"type`":`"model_change`",`"model`":`"anthropic/claude-opus-5-5`"}`n" +
    "{`"type`":`"message`",`"message`":{`"role`":`"assistant`",`"usage`":{`"input`":4,`"cacheRead`":149319,`"cacheWrite`":222},`"contextSnapshot`":{`"promptTokens`":149545},`"stopReason`":`"stop`"}}`n")
Kit context --pid 1 --tool omp --dir $P7
Check 'context (omp): the folder''s session, its last reply' { $out -match '"used": 149545, "window": (1000000|200000), "pct": (15|75), "source": "session", "model": "anthropic/claude-opus-5-5"' }
# what came after that reply, like omp's footer: its text at 4 bytes a token, an image 1600; omp's "details" not
$z6 = '0' * 600; $z9 = '0' * 900
Add-Content -LiteralPath "$H/.omp/agent/sessions/x/s1.jsonl" -Encoding UTF8 -NoNewline -Value ("{`"type`":`"message`",`"message`":{`"role`":`"toolResult`",`"content`":[{`"type`":`"text`",`"text`":`"0123456789abcdef\`"23`"},{`"type`":`"image`",`"data`":`"$z6`",`"mimeType`":`"image/png`"}],`"details`":{`"text`":`"$z9`"}}}`n")
Kit context --pid 1 --tool omp --dir $P7
Check 'context (omp): plus what came after the reply (text / 4, an image 1600, not "details")' { $out -match '"used": 151150, ' }
$cp = [string]$PID
W "$H/.config/agentkit/ctx/claude-$cp.json" "{`"pid`": $cp, `"session`": `"abc`", `"used`": 139600, `"window`": 400000, `"pct`": 35, `"model`": `"claude-opus-5-5`"}`n"
Kit context --pid $cp --tool claude-code --dir $P7
Check 'context (claude): what the status line kept' { $out.Trim() -eq '{"tool": "claude", "used": 139600, "window": 400000, "pct": 35, "source": "statusline", "model": "claude-opus-5-5"}' }
$sl = '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"context_window_size":400000,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1146,"cache_read_input_tokens":138452},"used_percentage":34.9}}'

$o = $sl | & $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit statusline 2>&1
Check 'statusline: a short line for Claude' { "$o".Trim() -eq 'Opus 5.5 · context 35%（139k / 400k）' }
if (-not $OnWindows) {
    # under a "claude" process (one look at every process): the numbers kept for it
    W "$T/sl7.json" $sl; $FB8 = Join-Path $T 'fakebin8'
    W "$FB8/claude" "#!/bin/sh`necho `$`$ > '$T/cpid7'`n'$Exe' -NoProfile -File '$Kit' statusline < '$T/sl7.json'`n"; & chmod +x "$FB8/claude"
    $o = & "$FB8/claude"; $cp7 = "$(ReadT "$T/cpid7")".Trim()
    Check 'statusline: under claude, the numbers kept for that process' { "$o".Trim() -eq 'Opus 5.5 · context 35%（139k / 400k）' -and (Test-Path "$H/.config/agentkit/ctx/claude-$cp7.json") }
}
# Claude: a reply Claude Code made itself ("<synthetic>") does not count; past the window -> 100 %
$PC = Join-Path $T 'ctxclaude'; [void](New-Item -ItemType Directory -Force -Path $PC); $PC = (Resolve-Path $PC).ProviderPath
$CD = Join-Path (Join-Path $H '.claude/projects') ($PC -replace '[^A-Za-z0-9]', '-')
W "$CD/t.jsonl" ("{`"type`":`"assistant`",`"message`":{`"model`":`"claude-sonnet-4-5`",`"usage`":{`"input_tokens`":250000}}}`n" +
    "{`"type`":`"assistant`",`"message`":{`"model`":`"<synthetic>`",`"usage`":{`"input_tokens`":0,`"output_tokens`":0}}}`n")
Kit context --pid 1 --tool claude --dir $PC
Check 'context (claude): not a <synthetic> reply; past the window -> 100 %' { $out.Trim() -eq '{"tool": "claude", "used": 250000, "window": 200000, "pct": 100, "source": "transcript", "model": "claude-sonnet-4-5"}' }
# another Claude in the same folder wrote last: each reads its own transcript (~/.claude/sessions/<pid>.json), only
# one kit can't place falls back to the newest
[void](New-Item -ItemType Directory -Force -Path "$H/.claude/sessions"); W "$H/.claude/sessions/4242.json" ('{"pid":4242,"sessionId":"t","cwd":' + (ConvertTo-Json $PC) + '}')
Start-Sleep -Seconds 1
W "$CD/other.jsonl" "{`"type`":`"assistant`",`"message`":{`"model`":`"claude-haiku-5-5`",`"usage`":{`"input_tokens`":2,`"cache_read_input_tokens`":48555}}}`n"
Kit context --pid 4242 --tool claude --dir $PC
Check "context (claude, no status line): its own session's transcript, not another Claude's newer one in the folder" { $out.Trim() -eq '{"tool": "claude", "used": 250000, "window": 200000, "pct": 100, "source": "transcript", "model": "claude-sonnet-4-5"}' }
Kit context --pid 1 --tool claude --dir $PC
Check "context (claude): a process kit can't place: the newest of the folder, as before" { $out.Contains('"model": "claude-haiku-5-5"') }
Remove-Item -LiteralPath "$CD/other.jsonl", "$H/.claude/sessions/4242.json" -Force
# a long log is read from its end; nothing there -> all of it, the same answer
Add-Content -LiteralPath "$CD/t.jsonl" -Encoding UTF8 -NoNewline -Value ("{`"type`":`"user`",`"message`":{`"content`":`"$('0' * 400)`"}}`n")
Add-Content -LiteralPath $RO -Encoding UTF8 -NoNewline -Value ("{`"type`":`"event_msg`",`"payload`":{`"type`":`"agent_message`",`"message`":`"$('0' * 400)`"}}`n")
Add-Content -LiteralPath "$H/.omp/agent/sessions/x/s1.jsonl" -Encoding UTF8 -NoNewline -Value ("{`"type`":`"note`",`"text`":`"$('0' * 400)`"}`n")
$same = $true
foreach ($a in @(@('claude', $PC), @('codex', $P7), @('omp', $P7))) {
    Kit context --pid 1 --tool $a[0] --dir $a[1]; $whole = $out
    $env:KIT_CTX_TAIL = '100'; Kit context --pid 1 --tool $a[0] --dir $a[1]; Remove-Item env:KIT_CTX_TAIL
    if ($out -ne $whole -or $whole -notmatch '"used": [0-9]') { $same = $false; [Console]::WriteLine("  differs: $($a[0]): $whole / $out") }
}
Check 'context: a long log is read from its end; nothing there -> all of it, the same answer' { $same }
Kit context --pid
Check 'context: --pid with nothing after it -> how to use it' { $rc -eq 1 -and $out.Contains('用法：kit context') }
if (-not $OnWindows) {
    $same = $true
    foreach ($a in @("--pid 1 --tool codex --dir '$P7'", "--pid 1 --tool omp --dir '$P7'", "--pid 1 --tool claude --dir '$PC'")) {
        $u = (& /bin/sh -c "cd '$Repo' && HOME='$H' unix/kit context $a 2>&1") -join "`n"
        $u2 = (& /bin/sh -c "cd '$Repo' && HOME='$H' KIT_CTX_TAIL=100 unix/kit context $a 2>&1") -join "`n"
        Invoke-Expression "Kit context $a"
        if ($u -cne $out -or $u2 -cne $out) { $same = $false; [Console]::WriteLine("  differs: $a") }
    }
    Check 'context: unix/kit says the same' { $same }
}
# kit context --detail: a fake claude answers Claude Code's control requests (Claude), the logs split (Codex, omp)
$FC = Join-Path $T 'fakeclaude'; [void](New-Item -ItemType Directory -Force -Path $FC)
$SID = '0a1b2c3d-1111-2222-3333-444455556666'
$TS7 = Join-Path (Join-Path (Join-Path $H '.claude/projects') ($P7 -creplace '[^A-Za-z0-9]', '-')) "$SID.jsonl"
W "$FC/fake.ps1" @"
`$a = (`$args | ForEach-Object { "`$_" }) -join ' '
[IO.File]::AppendAllText('$T/claude-args', "`$a``n"); [IO.File]::AppendAllText('$T/claude-cwd', (Get-Location).ProviderPath + "``n")
if (`$env:FAKE_SLEEP) { Start-Sleep -Seconds ([int]`$env:FAKE_SLEEP) }
while (`$null -ne (`$l = [Console]::In.ReadLine())) {
    if (`$l.Contains('"request_id":"i1"')) { [Console]::Out.WriteLine('{"type":"control_response","response":{"subtype":"success","request_id":"i1","response":{"account":{"email":"secret@example.com"}}}}') }
    elseif (`$l.Contains('"request_id":"c1"')) { [Console]::Out.WriteLine([IO.File]::ReadAllText('$T/c1.json').Trim()) }
    [Console]::Out.Flush()
}
"@
if ($OnWindows) { W "$FC/claude.cmd" "@`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$FC\fake.ps1`" %*`r`n" }
else { W "$FC/claude" "#!/bin/sh`nexec '$Exe' -NoProfile -File '$FC/fake.ps1' `"`$@`"`n"; & chmod +x "$FC/claude" }
W "$T/c1.json" ('{"type":"control_response","response":{"subtype":"success","request_id":"c1","response":{"categories":[' +
    '{"id":"system_prompt","name":"System prompt","tokens":4000,"kind":"used"},{"id":"system_tools","name":"System tools","tokens":6000,"kind":"used"},' +
    '{"id":"system_tools_deferred","name":"System tools (deferred)","tokens":13000,"isDeferred":true,"kind":"deferred"},{"id":"mcp_tools","name":"MCP tools","tokens":3000,"kind":"used"},' +
    '{"id":"memory_files","name":"Memory files","tokens":1200,"kind":"used"},{"id":"skills","name":"Skills","tokens":800,"kind":"used"},{"id":"messages","name":"Messages","tokens":100000,"kind":"used"},' +
    '{"id":"autocompact_buffer","name":"Autocompact buffer","tokens":33000,"kind":"buffer"},{"id":"free_space","name":"Free space","tokens":252000,"kind":"free"}],' +
    '"totalTokens":115000,"maxTokens":400000,"rawMaxTokens":400000,"percentage":29,"model":"claude-opus-5-5",' +
    '"memoryFiles":[{"path":"' + (& $js "$P7/CLAUDE.md") + '","type":"Project","tokens":1000}],' +
    '"mcpTools":[{"name":"mcp__gerrit__a","serverName":"gerrit","tokens":1000,"isLoaded":true},{"name":"mcp__kitping__ping","serverName":"kitping","tokens":500,"isLoaded":true}],"mcpInstructions":[],"agents":[],' +
    '"slashCommands":{"totalCommands":5,"includedCommands":5,"tokens":300},"skills":{"totalSkills":0,"includedSkills":0,"tokens":800,"skillFrontmatter":[]},' +
    '"autoCompactThreshold":367000,"isAutoCompactEnabled":true,"messageBreakdown":{"toolCallsByType":[],"attachmentsByType":[]}}}}' + "`n")
W $TS7 ("{`"parentUuid`":null,`"type`":`"user`",`"message`":{`"role`":`"user`",`"content`":`"look at this`"},`"uuid`":`"u1`"}`n" +
    "{`"parentUuid`":`"u1`",`"type`":`"assistant`",`"message`":{`"model`":`"claude-opus-5-5`",`"content`":[{`"type`":`"text`",`"text`":`"ok`"},{`"type`":`"tool_use`",`"id`":`"toolu_r1`",`"name`":`"Read`",`"input`":{`"file_path`":`"/x/a`"}}],`"usage`":{`"input_tokens`":5}},`"uuid`":`"u2`"}`n" +
    "{`"parentUuid`":`"u2`",`"type`":`"user`",`"message`":{`"role`":`"user`",`"content`":[{`"tool_use_id`":`"toolu_r1`",`"type`":`"tool_result`",`"content`":`"$('0' * 2000)`"}]},`"uuid`":`"u3`"}`n")
$ctx7 = "{`"pid`": $cp, `"session`": `"$SID`", `"used`": 130000, `"window`": 400000, `"pct`": 33, `"model`": `"claude-opus-5-5`", `"transcript`": `"$(& $js $TS7)`", `"cwd`": `"$(& $js $P7)`"}`n"
W "$H/.config/agentkit/ctx/claude-$cp.json" $ctx7
$pathBefore = $env:PATH; $env:PATH = "$FC$sep$env:PATH"
$nArgs = { if (Test-Path "$T/claude-args") { @([IO.File]::ReadAllLines("$T/claude-args")).Count } else { 0 } }
Kit context --pid $cp --tool claude --dir $P7 --detail; $d1 = $out
Check 'context --detail (claude): Claude Code asked with every hook off, nothing kept, its session, in its folder' {
    (ReadT "$T/claude-args").Contains("--resume $SID --no-session-persistence --settings ") -and @('', '/private') -ccontains ((ReadT "$T/claude-cwd").Trim() -replace ([regex]::Escape($P7) + '$'), '') -and -not $d1.Contains('secret@') }
Check 'context --detail (claude): its numbers, the window, its commands, no error' {
    $d1.Contains('{"tool": "claude", "used": 130000, "window": 400000, "pct": 33, "source": "get_context_usage", "model": "claude-opus-5-5", "at": ') -and
    $d1.Contains("`"exact`": true, `"session`": `"$SID`", `"compact_at`": 367000, `"commands`": {`"compact`": `"/compact`", `"with_text`": true, `"clear`": `"/clear`"}") -and $d1.Contains('"error": null') }
Check 'context --detail (claude): the categories in Chinese, deferred kept apart, MCP by server' {
    $d1.Contains('{"id": "system_prompt", "name": "系統提示", "tokens": 4000, "kind": "used", "est": false}') -and
    $d1.Contains('{"id": "system_tools_deferred", "name": "系統工具（延後載入）", "tokens": 13000, "kind": "deferred", "est": false}') -and
    $d1.Contains('{"id": "mcp", "name": "MCP（依伺服器）", "tokens": 1500, "est": false, "items": [{"name": "gerrit", "tokens": 1000,') -and $d1.Contains('"name": "Read"') }
$n1 = & $nArgs
Kit context --pid $cp --tool claude --dir $P7 --detail
Check 'context --detail: kept a minute (Claude not asked again)' { (& $nArgs) -eq $n1 -and $out -ceq $d1 }
Kit context --pid $cp --tool claude --dir $P7 --detail --fresh
Check 'context --detail --fresh: asked again' { (& $nArgs) -gt $n1 }
# a gateway that sends the keys in another order ("id" before "type"): the tools still found by name
$ts7keep = ReadT $TS7
W $TS7 ($ts7keep +
    '{"parentUuid":"u3","type":"assistant","message":{"content":[{"signature":"sig","thinking":"x","type":"thinking"},{"text":"reading it","type":"text"},{"id":"toolu_s1","input":{"file_path":"/x/b.txt","name":"inner","type":"x"},"name":"Read","type":"tool_use"}],"id":"m1","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","type":"message","usage":{"input_tokens":5}},"uuid":"u4"}' + "`n" +
    '{"parentUuid":"u4","type":"user","message":{"role":"user","content":[{"content":"a \"quoted\" {brace} \\ ' + ('0' * 900) + '","is_error":false,"tool_use_id":"toolu_s1","type":"tool_result"}]},"uuid":"u5"}' + "`n")
Kit context --pid $cp --tool claude --dir $P7 --detail --fresh
$trm = [regex]::Match($out, '"id": "tool_results", "name": "[^"]*", "tokens": [0-9]*, "est": true, "items": \[([^\]]*)\]')
Check 'context --detail (claude): keys in another order (a gateway): the tool is still named, not "?"' {
    $trm.Success -and $trm.Groups[1].Value.Contains('"name": "Read", "tokens": ') -and $trm.Groups[1].Value.Contains('"note": "2 次"') -and -not $trm.Groups[1].Value.Contains('"name": "?"') -and -not $trm.Groups[1].Value.Contains('inner') }
W $TS7 $ts7keep
$env:FAKE_SLEEP = '20'; $env:KIT_CTX_PROBE_TIMEOUT = '2'; $t0 = [DateTime]::UtcNow
Kit context --pid $cp --tool claude --dir $P7 --detail --fresh
$secs = ([DateTime]::UtcNow - $t0).TotalSeconds; Remove-Item env:FAKE_SLEEP, env:KIT_CTX_PROBE_TIMEOUT
Check 'context --detail: Claude Code that does not answer is stopped (timeout), the answer says so, still JSON, estimated' {
    $secs -lt 12 -and $out.Contains('"error": "Claude Code 沒有回答') -and $out.Contains('"exact": false') -and $out.Contains('"used": 130000, "window": 400000') }
W "$H/.config/agentkit/ctx/claude-$cp.json" "{`"pid`": $cp, `"session`": `"x;rm -rf y`", `"used`": 1, `"window`": 2, `"pct`": 50, `"model`": `"m`"}`n"
$n1 = & $nArgs
Kit context --pid $cp --tool claude --dir $P7 --detail --fresh
Check 'context --detail: a session id with other characters is not used (Claude not run)' { (& $nArgs) -eq $n1 -and $out.Contains('"error": "找不到這個 Claude 的 session"') }
Remove-Item "$H/.config/agentkit/ctx/claude-$cp.json"
W "$H/.claude/sessions/$cp.json" "{`"pid`":$cp,`"sessionId`":`"$SID`",`"cwd`":`"$(& $js $P7)`",`"startedAt`":1}`n"
Kit context --pid $cp --tool claude --dir $P7 --detail --fresh
Check 'context --detail: the session from ~/.claude/sessions/<pid>.json' { $out.Contains("`"session`": `"$SID`"") -and $out.Contains('"exact": true') }
Remove-Item "$H/.claude/sessions/$cp.json"
$env:PATH = $pathBefore
# Codex and omp: the parts add up to their own total, their commands
$usedSum = { param($s) $c = $s; $i = $c.IndexOf('"categories": ['); $j = $c.IndexOf('], "groups"'); if ($i -lt 0 -or $j -lt $i) { return -1 }
    $n = 0; foreach ($m in [regex]::Matches($c.Substring($i, $j - $i), '"tokens": ([0-9]+), "kind": "used"')) { $n += [long]$m.Groups[1].Value }; $n }
# Codex writes the folder as the system gives it (macOS: /private/var/...), so its own folder here
$P8 = Join-Path $T 'ctxcodex'; [void](New-Item -ItemType Directory -Force -Path $P8); $P8 = (Resolve-Path $P8).ProviderPath
if (-not $OnWindows) { $P8 = (& /bin/sh -c "cd '$P8' && pwd -P") }
W "$H/.codex/sessions/2026/11/12/rollout-2026-11-12T02-00-00-def.jsonl" ((ReadT $RO).Replace('"cwd":"' + (& $js $P7) + '"', '"cwd":"' + (& $js $P8) + '"').Replace("{`"type`":`"turn_context`"",
    "{`"type`":`"response_item`",`"payload`":{`"type`":`"message`",`"role`":`"user`",`"content`":[{`"type`":`"input_text`",`"text`":`"fix it`"}]}}`n" +
    "{`"type`":`"response_item`",`"payload`":{`"type`":`"function_call`",`"name`":`"shell`",`"arguments`":`"{\`"cmd\`":\`"ls\`"}`",`"call_id`":`"c1`"}}`n" +
    "{`"type`":`"response_item`",`"payload`":{`"type`":`"function_call_output`",`"call_id`":`"c1`",`"output`":`"$('0' * 1200)`"}}`n" +
    "{`"type`":`"response_item`",`"payload`":{`"type`":`"message`",`"role`":`"assistant`",`"content`":[{`"type`":`"output_text`",`"text`":`"done`"}]}}`n{`"type`":`"turn_context`""))
Kit context --pid 1 --tool codex --dir $P8 --detail
Check 'context --detail (codex): its total, /compact without text, /new; the parts add up to it' {
    $out.Contains('{"tool": "codex", "used": 48813, "window": 258400, ') -and $out.Contains('"commands": {"compact": "/compact", "with_text": false, "clear": "/new"}') -and (& $usedSum $out) -eq 48813 }
Kit context --pid 1 --tool omp --dir $P7 --detail
$ou = if ($out -match '"tool": "omp", "used": ([0-9]+),') { [long]$Matches[1] } else { -2 }
Check 'context --detail (omp): /compact with text, /new; the parts add up to its total' {
    $out.Contains('"commands": {"compact": "/compact", "with_text": true, "clear": "/new"}') -and $ou -gt 0 -and (& $usedSum $out) -eq $ou }
Kit context --pid 1 --tool codex --dir $PC --detail
Check 'context --detail: nothing found -> still one JSON answer' { $rc -eq 0 -and $out.TrimStart().StartsWith('{"tool": "codex"') }
# Claude's statusLine: kit's when there is none; taken out by you, it stays out (said once); kit sync --force puts it back
Set-Home (Join-Path $T 'home7b')
Kit init $TEAM
Check 'sync: kit''s statusLine in settings.json' { (JGet "$H/.claude/settings.json" 'statusLine.command') -match 'statusline' }
W "$T/del7.ops" "del`tstatusLine`n"
$sj = ReadT "$H/.claude/settings.json"; $sj2 = [regex]::Replace($sj, ',?\s*"statusLine": \{[^}]*\}', ''); W "$H/.claude/settings.json" $sj2
Kit sync
Check 'statusLine taken out by you: not put back, kit says so and how to get it back' { $null -eq (JGet "$H/.claude/settings.json" 'statusLine') -and $out.Contains('kit sync --force') }
Kit sync
Check 'statusLine taken out by you: said once, still out' { -not $out.Contains('statusLine') -and $null -eq (JGet "$H/.claude/settings.json" 'statusLine') }
Kit sync --force
Check 'kit sync --force: kit''s statusLine back' { (JGet "$H/.claude/settings.json" 'statusLine.command') -match 'statusline' }
Kit uninstall

} finally { Done }
