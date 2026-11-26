. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- kit add / rm / sync tell the open agents what changed for them (kit 0.14.0, kit api 1.19) ----------
# A fake hc: ls and get from files, every call in a log; send --queue answers queued (or, as an older hc, refuses the
# flag: then --if idle, typed only to an idle one). tests/sh/tell.sh has the rest, with both kits.
$FH = Join-Path $T 'fakehc'; $S = Join-Path $T 'src-tell'; $D = Join-Path $H 'proj'
W "$FH/fake.ps1" @'
$log = Join-Path $env:FH 'log'; [IO.File]::AppendAllText($log, ($args -join ' ') + "`n")
switch ($args[0]) {
    'ls' { [Console]::Out.WriteLine([IO.File]::ReadAllText((Join-Path $env:FH 'ls.json'))) }
    'get' { $f = Join-Path $env:FH "get-$($args[1]).json"; if (-not (Test-Path -LiteralPath $f)) { exit 1 }; [Console]::Out.WriteLine([IO.File]::ReadAllText($f)) }
    'send' {
        if ($args -contains '--queue') {
            if (Test-Path -LiteralPath (Join-Path $env:FH 'old')) { [Console]::Out.WriteLine('{"error":{"kind":"usage","message":"unexpected argument ''--queue'' found"}}'); exit 2 }
            [Console]::Out.WriteLine('{"queued":true,"status":"working"}')
        } else { $s = Join-Path $env:FH "status-$($args[4])"; if (-not (Test-Path -LiteralPath $s) -or ([IO.File]::ReadAllText($s)).Trim() -ne 'idle') { exit 1 } }
    }
}
exit 0
'@
if ($OnWindows) { W "$FH/bin/hc.cmd" "@`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$FH\fake.ps1`" %*`r`n" }
else { W "$FH/bin/hc" "#!/bin/sh`nexec '$Exe' -NoProfile -File '$FH/fake.ps1' `"`$@`"`n"; & chmod +x "$FH/bin/hc" }
$env:FH = $FH; $env:PATH = (Join-Path $FH 'bin') + $sep + $env:PATH
W "$S/skills/ts/SKILL.md" "---`nname: ts`ndescription: d`n---`nx`n"
W "$S/mcp/tm.yaml" "command: echo`nargs: [x]`n"
foreach ($x in "$H/.codex", "$H/.omp/agent", $D) { [void](New-Item -ItemType Directory -Force -Path $x) }
$j = { param($s) $s.Replace('\', '\\') }
W "$FH/ls.json" ('{"terminals":[{"address":"t1","agent":"claude-code","cwd":"' + (& $j $H) + '","state":"live","status":"idle"},{"address":"t2","agent":"codex","cwd":"' + (& $j $H) + '","state":"live","status":"working"},{"address":"t3","agent":"pi","cwd":"' + (& $j $H) + '","state":"live","status":"working"},{"address":"m/t9","agent":"claude-code","cwd":"/x","state":"live","status":"idle"}]}')
foreach ($a in 't1', 't2', 't3') { W "$FH/get-$a.json" ('{"address":"' + $a + '","pid":' + $PID + ',"foreground":{"pid":' + $PID + ',"cwd":"' + (& $j $H) + '"},"status":{"app":"x","state":"idle"},"status_ms":1}') }
function Log { $f = Join-Path $FH 'log'; if (Test-Path -LiteralPath $f) { @((ReadT $f) -split "`n" | Where-Object { $_ }) } else { @() } }
function Agents { $a = @{}; foreach ($x in @(($out | ConvertFrom-Json).agents)) { $a[$x.address] = $x }; $a }
Kit init $S
Check 'tell: kit init tells no one' { @(Log).Count -eq 0 }
KitJ add skill ts --json
Check 'tell: kit add skill --json: omp /reload-plugins queued, Claude and Codex see it by themselves; m/t9 (another machine) not there' {
    $a = Agents; $rc -eq 0 -and @($a.Keys).Count -eq 3 -and $a['t3'].need -ceq 'reload' -and $a['t3'].queued -and -not $a['t3'].sent -and $a['t1'].need -ceq 'none' -and $a['t2'].need -ceq 'none' }
Check 'tell: hc send --queue --key reload, once' { @(Log | Where-Object { $_.StartsWith('send') }).Count -eq 1 -and (Log) -ccontains 'send --json --queue --key reload t3 /reload-plugins' }
Remove-Item -LiteralPath (Join-Path $FH 'log')
KitJ add mcp tm --json
Check 'tell: kit add mcp: Claude and Codex need a relaunch (a kit pending for your OK), omp /reload-plugins' {
    $a = Agents; $a['t1'].need -ceq 'relaunch' -and $a['t2'].need -ceq 'relaunch' -and $a['t3'].need -ceq 'reload' -and @(Log | Where-Object { $_.StartsWith('send') }).Count -eq 1 -and
    (ReadT "$H/.config/agentkit/notes/pending/relaunch").Contains('要你同意：重開 2 個 agent（t1 Claude Code、t2 Codex）才讀得到新的MCP') }
Remove-Item -LiteralPath (Join-Path $FH 'log'); W "$FH/old" ''; W "$FH/status-t3" "idle`n"
KitJ rm mcp tm --json
Check 'tell: an hc without --queue: --if idle to the idle one' { $a = Agents; $a['t3'].sent -and -not $a['t3'].queued -and @(Log | Where-Object { $_.StartsWith('send --json --if idle t3 ') }).Count -eq 1 }
Remove-Item -LiteralPath (Join-Path $FH 'log')
KitJ rm skill ts --no-tell --json
Check 'tell: --no-tell: hc not asked, agents []' { $rc -eq 0 -and @(Log).Count -eq 0 -and @(($out | ConvertFrom-Json).agents).Count -eq 0 }
} finally { Done }
