. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
$js = { param($x) $x.Replace('\', '\\') }
# ---------- kit files: what an agent read or changed (from its own log) ----------
$oldH = $H; Set-Home (Join-Path $T 'home8')
$PF = Join-Path $T 'filesproj'; [void](New-Item -ItemType Directory -Force -Path (Join-Path $PF 'sub')); $PF = (Resolve-Path $PF).ProviderPath
$PFs = $PF.Replace('\', '/'); $jPF = & $js $PF   # kit files writes a path with a drive letter with /
foreach ($f in 'a.txt', 'b.txt', 'sub/c.txt', 'nb.ipynb', 'api.txt', 'r1.txt', 'd.txt') { W (Join-Path $PF $f) "x`n" }
$SID8 = '0a1b2c3d-8888-4444-3333-444455556666'; $PD8 = Join-Path (Join-Path $H '.claude/projects') ($PF -replace '[^A-Za-z0-9]', '-')
W (Join-Path $H ".claude/sessions/$PID.json") "{`"pid`":$PID,`"sessionId`":`"$SID8`",`"cwd`":`"$jPF`"}`n"
W (Join-Path $PD8 "$SID8.jsonl") (('{"parentUuid":null,"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"@P/a.txt"}},{"type":"tool_use","id":"t2","name":"Edit","input":{"replace_all":false,"file_path":"@P/b.txt","old_string":"\"file_path\":\"/evil\"","new_string":"SECRET"}},{"type":"tool_use","id":"t3","name":"NotebookEdit","input":{"notebook_path":"@P/nb.ipynb"}}]},"uuid":"u1","timestamp":"2026-11-13T01:00:00.000Z"}' + "`n" +
    '{"type":"api-request","messages":[{"type":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"@P/api.txt"}}]}]}' + "`n" +
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Write","input":{"file_path":"sub/c.txt","content":"SECRET"}},{"type":"tool_use","id":"t5","name":"Read","input":{"file_path":"@P/gone.txt"}},{"type":"tool_use","id":"t6","name":"Write","input":{"file_path":"@P/made.txt","content":"x"}}]},"uuid":"u2","timestamp":"2026-11-13T03:00:00.000Z"}' + "`n").Replace('@P', $jPF))
W (Join-Path $PD8 "$SID8/subagents/agent-x.jsonl") ('{"isSidechain":true,"message":{"content":[{"id":"s1","input":{"file_path":"@P/b.txt"},"name":"Read","type":"tool_use"}]},"type":"assistant","timestamp":"2026-11-13T02:00:00.000Z"}' + "`n").Replace('@P', $jPF)   # (keys in another order, as a gateway may send them)
$FL = '{"path": "@F/made.txt", "tag": "write", "exists": false}, {"path": "@F/sub/c.txt", "tag": "write", "exists": true}, {"path": "@F/b.txt", "tag": "read", "exists": true}, {"path": "@F/nb.ipynb", "tag": "edit", "exists": true}, {"path": "@F/a.txt", "tag": "read", "exists": true}'.Replace('@F', $PFs)
function T0([string]$l) { '"turns": [{"n": 0, "at": "", "text": "", "files": [' + $l + ']}]' }   # (no message in the log: all in turn 0)
KitJ files --pid $PID --tool claude --dir $PF --json
Check 'files (claude): newest first, one per path, its sub-agent''s merged by time, a relative path under the folder; no api-request, no content' {
    $rc -eq 0 -and $out.StartsWith('{"tool": "claude", "log": "') -and $out.EndsWith("$SID8.jsonl`", `"dir`": `"$jPF`", `"files`": [$FL], $(T0 $FL)}") -and -not ($out -match 'api\.txt|gone\.txt|SECRET|evil') }
Kit files --pid $PID --tool claude --dir $PF
Check 'files: without --json a plain list (path, tag)' { $out.Split("`n")[0].Trim() -ceq "$PFs/made.txt  write（已經不在）" }
# --git: what git status shows too (paths from the repo's top, a rename's new name, nothing gone or twice)
Push-Location $PF
& git init -q; & git add -A; & git -c user.name=a -c user.email=a@a -c core.autocrlf=false commit -qm x; & git mv r1.txt r2.txt; Remove-Item d.txt; Add-Content -LiteralPath b.txt -Value y; W (Join-Path $PF 'g.txt') "n`n"
$top = "$(& git rev-parse --show-toplevel)".Trim()
Pop-Location
KitJ files --pid 1 --tool codex --dir (Join-Path $PF 'sub') --git --json
Check 'files --git: git status''s files, a rename''s new name, nothing gone; no log: a note' {
    $out -ceq ('{"tool": "codex", "log": "", "dir": "' + (& $js (Join-Path $PF 'sub')) + '", "files": [{"path": "@T/b.txt", "tag": "git", "exists": true}, {"path": "@T/r2.txt", "tag": "git", "exists": true}, {"path": "@T/g.txt", "tag": "git", "exists": true}], "turns": [], "note": "找不到這個資料夾的 Codex 對話紀錄（~/.codex/sessions）"}').Replace('@T', $top) }
KitJ files --pid $PID --tool claude --dir $PF --git --json
Check 'files --git: after the log''s files' { $out.EndsWith(("[$FL, " + '{"path": "@T/r2.txt", "tag": "git", "exists": true}, {"path": "@T/g.txt", "tag": "git", "exists": true}], ').Replace('@T', $top) + (T0 $FL) + '}') }
KitJ files --pid 1 --tool vim --dir $PF --json
Check 'files: an agent kit does not know -> a note, not an error' { $rc -eq 0 -and $out -ceq "{`"tool`": `"vim`", `"log`": `"`", `"dir`": `"$jPF`", `"files`": [], `"turns`": [], `"note`": `"不認得這種 agent：vim（只認得 claude、codex、omp）`"}" }
KitJ files --json
Check 'files: no --pid -> exit 1, error usage on stdout' { $rc -eq 1 -and $out -ceq '{"error": {"code": "usage", "message": "用法：kit files --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--git] [--json]"}}' }
# Codex: what its patches changed; omp: its read / edit / write calls
W "$H/.codex/sessions/2026/11/13/rollout-2026-11-13T01-00-00-c8.jsonl" (('{"timestamp":"t","type":"session_meta","payload":{"id":"c8","cwd":"@P"}}' + "`n" +
    '{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: a.txt\n+SECRET\n*** End Patch\n","call_id":"c1"}}' + "`n" +
    '{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"apply_patch\",\"*** Begin Patch\\n*** Add File: new.txt\\n+x\\n*** Update File: sub/c.txt\\n*** Move to: sub/c2.txt\\n\"]}","call_id":"c2"}}' + "`n" +
    '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","changes":{"@P/nb.ipynb":{"type":"update","unified_diff":"\"x\":{\"type\":\"add\"}","move_path":null},"@P/g.txt":{"type":"add","content":"SECRET"}},"status":"completed"}}}' + "`n").Replace('@P', $jPF))
KitJ files --pid 1 --tool codex --dir $PF --json
Check 'files (codex): what its patches changed (added: write), relative paths under the folder, renamed; no content' {
    $out.EndsWith(('"files": [{"path": "@F/g.txt", "tag": "write", "exists": true}, {"path": "@F/nb.ipynb", "tag": "edit", "exists": true}, {"path": "@F/sub/c2.txt", "tag": "edit", "exists": false}, {"path": "@F/sub/c.txt", "tag": "edit", "exists": true}, {"path": "@F/new.txt", "tag": "write", "exists": false}, {"path": "@F/a.txt", "tag": "edit", "exists": true}], ' + (T0 '{"path": "@F/g.txt", "tag": "write", "exists": true}, {"path": "@F/nb.ipynb", "tag": "edit", "exists": true}, {"path": "@F/sub/c2.txt", "tag": "edit", "exists": false}, {"path": "@F/sub/c.txt", "tag": "edit", "exists": true}, {"path": "@F/new.txt", "tag": "write", "exists": false}, {"path": "@F/a.txt", "tag": "edit", "exists": true}') + '}').Replace('@F', $PFs)) }
W "$H/.omp/agent/sessions/z/s8.jsonl" (('{"type":"session","version":3,"id":"s8","cwd":"@P"}' + "`n" +
    '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"read","arguments":{"path":"@P/a.txt:10-20"}},{"type":"toolCall","id":"2","name":"read","arguments":{"path":"skill://x"}},{"type":"toolCall","id":"3","name":"write","arguments":{"path":"sub/w.txt","content":"SECRET"}}]}}' + "`n" +
    '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"5","name":"edit","arguments":{"i":"e","input":"[@P/b.txt#F86E]\nPUT >1:\n+SECRET\n"}},{"type":"toolCall","id":"7","name":"write","arguments":{"path":"Q:\\Work\\X.txt"}},{"type":"toolCall","id":"8","name":"edit","arguments":{"path":"q:/work/x.txt"}}]}}' + "`n").Replace('@P', $jPF))
KitJ files --pid 1 --tool pi --dir $PF --json
Check 'files (omp): its read/edit/write calls; a drive-letter path with / and compared ignoring case' {
    $out.EndsWith(('"files": [{"path": "q:/work/x.txt", "tag": "edit", "exists": false}, {"path": "@F/b.txt", "tag": "edit", "exists": true}, {"path": "@F/sub/w.txt", "tag": "write", "exists": false}, {"path": "@F/a.txt", "tag": "read", "exists": true}], ' + (T0 '{"path": "q:/work/x.txt", "tag": "edit", "exists": false}, {"path": "@F/b.txt", "tag": "edit", "exists": true}, {"path": "@F/sub/w.txt", "tag": "write", "exists": false}, {"path": "@F/a.txt", "tag": "read", "exists": true}') + '}').Replace('@F', $PFs)) }
# turns: what was touched after each message the person sent (Claude: the main transcript's; its sub-agents' by time)
$PT = Join-Path $PF 'turns'; foreach ($f in 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'old') { W (Join-Path $PT "$f.txt") "x`n" }
$jPT = & $js $PT; $PTs = $PT.Replace('\', '/')
$SID9 = '0a1b2c3d-9999-4444-3333-444455556666'; $PD9 = Join-Path (Join-Path $H '.claude/projects') ($PT -replace '[^A-Za-z0-9]', '-'); $TS9 = Join-Path $PD9 "$SID9.jsonl"
W (Join-Path $H '.claude/sessions/4242.json') "{`"pid`":4242,`"sessionId`":`"$SID9`",`"cwd`":`"$jPT`"}`n"
function CU([string]$c, [string]$ts, [string]$x = '') { '{"parentUuid":"p","isSidechain":false,"promptId":"i","type":"user","message":{"role":"user","content":' + $c + '},"uuid":"u","timestamp":"2026-11-13T' + $ts + '"' + $x + "}`n" }
function CA([string]$c, [string]$ts) { '{"parentUuid":"p","isSidechain":false,"message":{"content":[' + $c + ']},"type":"assistant","uuid":"u","timestamp":"2026-11-13T' + $ts + "`"}`n" }
function TU([string]$n, [string]$f) { '{"type":"tool_use","id":"x","name":"' + $n + '","input":{"file_path":"' + $jPT + '/' + $f + '"}}' }
W $TS9 ((CA (TU 'Read' 'old.txt') '00:30:00.000Z') +
    (CU '"<system-reminder>\nSECRET\n</system-reminder>\n  第一個  問題\n\n請看 \"q\" 和 \\ 這個"' '01:00:00.500Z') +
    (CA ((TU 'Read' 'a.txt') + ',' + (TU 'Edit' 'b.txt')) '01:00:05.000Z') +
    (CU '[{"tool_use_id":"x","type":"tool_result","content":[{"type":"text","text":"SECRET"}]}]' '01:00:06.000Z') +
    (CU '"SECRET meta"' '01:20:00.000Z' ',"isMeta":true') +
    (CU '"<command-name>/model</command-name>\n<command-message>model</command-message>"' '01:25:00.000Z') +
    (CU '[{"type":"text","text":"[Request interrupted by user]"}]' '01:26:00.000Z') +
    (CU '"<local-command-stdout>SECRET</local-command-stdout>"' '01:27:00.000Z') +
    (CA (TU 'Write' 'c.txt') '01:30:00.000Z') +
    (CU '[{"type":"image","source":{"type":"base64","data":"AAAA"}},{"type":"text","text":"<hc from=\"home/t1p\">一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十</hc>"}]' '02:00:00.000+08:00') +
    (CA ((TU 'Edit' 'a.txt') + ',' + (TU 'Write' 'gone.txt') + ',' + (TU 'Read' 'gone2.txt')) '02:00:10.000Z') +
    (CU '"x"' '03:00:00.000Z') +
    (CU '[{"type":"image","source":{"type":"base64","data":"AAAA"}}]' '03:30:00.000Z') +
    (CU '"SECRET summary"' '03:40:00.000Z' ',"isCompactSummary":true') +
    (CU '"<task-notification>\n<task-id>1</task-id>SECRET</task-notification>"' '03:50:00.000Z') +
    (CU '"line1\u0007\n\n\tline2\b   end 第一第二第三第四第五第六第七第八第九第十"' '04:00:00.000Z') +
    (CA (TU 'Read' 'd.txt') '04:00:30.000Z'))
W (Join-Path $PD9 "$SID9/subagents/agent-y.jsonl") ('{"isSidechain":true,"agentId":"y","type":"user","message":{"role":"user","content":"sub prompt"},"timestamp":"2026-11-13T01:10:00.000Z"}' + "`n" +
    '{"isSidechain":true,"agentId":"y","message":{"content":[' + (TU 'Read' 'e.txt') + ']},"type":"assistant","timestamp":"2026-11-13T01:10:00.000Z"}' + "`n" +
    '{"isSidechain":true,"agentId":"y","message":{"content":[' + (TU 'Read' 'g.txt') + ']},"type":"assistant","timestamp":"2026-11-13T02:30:00.000Z"}' + "`n" +
    '{"isSidechain":true,"agentId":"y","message":{"content":[' + (TU 'Read' 'f.txt') + ']},"type":"assistant","timestamp":"2026-11-13T04:00:00.000Z"}' + "`n")
function FE([string]$f, [string]$t, [string]$e = 'true') { '{"path": "' + $PTs + '/' + $f + '", "tag": "' + $t + '", "exists": ' + $e + '}' }
$TT4 = '{"n": 4, "at": "2026-11-13T04:00:00Z", "text": "line1 line2 end 第一第二第三第四第五第六第七…", "files": [' + (FE 'd.txt' 'read') + ', ' + (FE 'f.txt' 'read') + ']}'
$TT2 = '{"n": 2, "at": "2026-11-12T18:00:00Z", "text": "hc home/t1p：一二三四五六七八九十一二三四五六七八…", "files": [' + (FE 'g.txt' 'read') + ', ' + (FE 'gone.txt' 'write' 'false') + ', ' + (FE 'a.txt' 'edit') + ']}'
$TT1 = '{"n": 1, "at": "2026-11-13T01:00:00Z", "text": "第一個 問題 請看 \"q\" 和 \\ 這個", "files": [' + (FE 'c.txt' 'write') + ', ' + (FE 'e.txt' 'read') + ', ' + (FE 'b.txt' 'edit') + ', ' + (FE 'a.txt' 'read') + ']}'
$TT0 = '{"n": 0, "at": "", "text": "", "files": [' + (FE 'old.txt' 'read') + ']}'
KitJ files --pid 4242 --tool claude --dir $PT --json
Check 'files turns (claude): newest first, n 0 last; a file in two turns in both; a turn without files left out; text: reminder skipped, white space, control characters, hc, 30 characters' {
    $out.EndsWith(', "turns": [' + $TT4 + ', ' + $TT2 + ', ' + $TT1 + ', ' + $TT0 + ']}') }
Check 'files turns (claude): tool results, isMeta, isCompactSummary, commands, interrupts, task notifications, images alone, a sub-agent''s prompt: not turns' { -not ($out -match 'SECRET|"n": 5|sub prompt|model|Request') }
$ls = (ReadT $TS9).Split("`n"); $n9 = $U8.GetByteCount((($ls[($ls.Count - 8)..($ls.Count - 1)]) -join "`n"))
$env:KIT_CTX_TAIL = [string]($n9 + 5); KitJ files --pid 4242 --tool claude --dir $PT --json; Remove-Item env:KIT_CTX_TAIL
Check 'files turns: only the end of the log read: n counted from the first message read, what came before it n 0' {
    $out.EndsWith(', "turns": [' + $TT4.Replace('"n": 4', '"n": 2') + ', {"n": 0, "at": "", "text": "", "files": [' + (FE 'g.txt' 'read') + ', ' + (FE 'gone.txt' 'write' 'false') + ', ' + (FE 'a.txt' 'edit') + ', ' + (FE 'e.txt' 'read') + ']}]}') }
# Codex: user_message events and UserMessage items (one turn when a version writes both); omp: its user messages
$CX = Join-Path $PF 'cx'; [void](New-Item -ItemType Directory -Force -Path $CX); $CXs = $CX.Replace('\', '/')
W "$H/.codex/sessions/2026/11/13/rollout-2026-11-13T05-00-00-c9.jsonl" (('{"timestamp":"2026-11-13T05:00:00.000Z","type":"session_meta","payload":{"id":"c9","cwd":"@P"}}' + "`n" +
    '{"timestamp":"2026-11-13T05:00:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md SECRET"}]}}' + "`n" +
    '{"timestamp":"2026-11-13T05:00:00.200Z","type":"event_msg","payload":{"type":"user_message","message":"<environment_context>SECRET</environment_context>","kind":"environment_context"}}' + "`n" +
    '{"timestamp":"2026-11-13T05:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"fix it","images":[]}}' + "`n" +
    '{"timestamp":"2026-11-13T05:00:01.001Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"u","item":{"type":"UserMessage","id":"m","content":[{"type":"text","text":"fix it","text_elements":[]}]}}}' + "`n" +
    '{"timestamp":"2026-11-13T05:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: a.txt\n+x\n*** End Patch\n","call_id":"c1"}}' + "`n" +
    '{"timestamp":"2026-11-13T05:10:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"v","item":{"type":"UserMessage","id":"n","content":[{"type":"text","text":"再來\n一個","text_elements":[]}]}}}' + "`n" +
    '{"timestamp":"2026-11-13T05:10:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"e","changes":{"@P/g.txt":{"type":"add","content":"SECRET"}},"status":"completed"}}}' + "`n").Replace('@P', (& $js $CX)))
KitJ files --pid 1 --tool codex --dir $CX --json
Check 'files turns (codex): user_message events and UserMessage items, the same message written both ways one turn; not its instructions or environment' {
    $out.EndsWith(', "turns": [{"n": 2, "at": "2026-11-13T05:10:00Z", "text": "再來 一個", "files": [{"path": "@C/g.txt", "tag": "write", "exists": false}]}, {"n": 1, "at": "2026-11-13T05:00:01Z", "text": "fix it", "files": [{"path": "@C/a.txt", "tag": "edit", "exists": false}]}]}'.Replace('@C', $CXs)) }
$OM = Join-Path $PF 'om'; [void](New-Item -ItemType Directory -Force -Path $OM); $OMs = $OM.Replace('\', '/')
W "$H/.omp/agent/sessions/z/s11.jsonl" (('{"type":"session","version":3,"id":"s11","timestamp":"2026-11-13T06:00:00.000Z","cwd":"@P"}' + "`n" +
    '{"type":"message","id":"1","parentId":null,"timestamp":"2026-11-13T06:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"看 a"}],"attribution":"user","timestamp":1}}' + "`n" +
    '{"type":"message","id":"2","parentId":"1","timestamp":"2026-11-13T06:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"read","arguments":{"path":"a.txt"}},{"type":"toolCall","id":"2","name":"write","arguments":{"path":"w.txt"}}]}}' + "`n" +
    '{"type":"message","id":"3","parentId":"2","timestamp":"2026-11-13T06:00:03.000Z","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"SECRET"}]}}' + "`n" +
    '{"type":"message","id":"4","parentId":"3","timestamp":"2026-11-13T06:05:00.000Z","message":{"role":"user","content":"<hc from=\"pc\">ok</hc>","attribution":"user","timestamp":2}}' + "`n" +
    '{"type":"message","id":"5","parentId":"4","timestamp":"2026-11-13T06:05:01.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"3","name":"edit","arguments":{"path":"w.txt"}}]}}' + "`n").Replace('@P', (& $js $OM)))
KitJ files --pid 1 --tool omp --dir $OM --json
Check 'files turns (omp): its user messages (text items or a string)' {
    $out.EndsWith(', "turns": [{"n": 2, "at": "2026-11-13T06:05:00Z", "text": "hc pc：ok", "files": [{"path": "@O/w.txt", "tag": "edit", "exists": false}]}, {"n": 1, "at": "2026-11-13T06:00:01Z", "text": "看 a", "files": [{"path": "@O/w.txt", "tag": "write", "exists": false}]}]}'.Replace('@O', $OMs)) }
$MT = Join-Path $PF 'mt'; [void](New-Item -ItemType Directory -Force -Path $MT)
$sb = New-Object Text.StringBuilder; [void]$sb.Append('{"type":"session","version":3,"id":"s12","cwd":"' + (& $js $MT) + "`"}`n")
for ($i = 1; $i -le 36; $i++) { [void]$sb.Append('{"type":"message","message":{"role":"user","content":[{"type":"text","text":"m' + $i + '"}]}}' + "`n" + '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"write","arguments":{"path":"f' + $i + '.txt"}}]}}' + "`n") }
for ($i = 1; $i -le 55; $i++) { [void]$sb.Append('{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"edit","arguments":{"path":"w' + $i + '.txt"}}]}}' + "`n") }
W "$H/.omp/agent/sessions/z/s12.jsonl" $sb.ToString()
KitJ files --pid 1 --tool omp --dir $MT --json
$tj = $out.Substring($out.IndexOf(', "turns": ', [StringComparison]::Ordinal))
Check 'files turns: at most 30 turns (the newest), 50 files each (the newest); no time in the log: at ""' {
    ([regex]::Matches($tj, '"n": ')).Count -eq 30 -and $tj.StartsWith(', "turns": [{"n": 36, "at": "", "text": "m36", "files": [{"path": "' + $MT.Replace('\', '/') + '/w55.txt"') -and $tj.Contains('/w6.txt"') -and -not $tj.Contains('/w5.txt"') -and $tj.Contains('"n": 7,') -and -not $tj.Contains('"n": 6,') -and ([regex]::Matches($tj, '"tag"')).Count -eq 50 + 29 }
if (-not $OnWindows) {
    $same = $true
    foreach ($a in @("--pid $PID --tool claude --dir '$PF' --json", "--pid $PID --tool claude --dir '$PF' --git --json", "--pid 1 --tool codex --dir '$PF' --json", "--pid 1 --tool omp --dir '$PF' --json", "--pid 1 --tool vim --dir '$PF' --json", "--json",
            "--pid 4242 --tool claude --dir '$PT' --json", "--pid 1 --tool codex --dir '$CX' --json", "--pid 1 --tool omp --dir '$OM' --json", "--pid 1 --tool omp --dir '$MT' --json")) {
        $u = (& /bin/sh -c "cd '$Repo' && HOME='$H' unix/kit files $a 2>/dev/null") -join "`n"
        Invoke-Expression "KitJ files $a"
        if ($u -cne $out) { $same = $false; [Console]::WriteLine("  differs: $a") }
    }
    Check 'files: unix/kit says the same' { $same }
}
Set-Home $oldH

} finally { Done }
