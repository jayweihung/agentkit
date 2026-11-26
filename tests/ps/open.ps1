. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- kit agents --open --json: who waits for you, what still runs (kit 0.16.0, kit api 1.21) ----------
# A fake hc (ls, get from files); what the agents said in the reply hook's files. tests/sh/open.sh has the rest
# (background shells, omp, Codex), with both kits.
$FH = Join-Path $T 'fakehc'
W "$FH/fake.ps1" @'
switch ($args[0]) {
    'ls' { [Console]::Out.WriteLine([IO.File]::ReadAllText((Join-Path $env:FH 'ls.json'))) }
    'get' { $f = Join-Path $env:FH "get-$($args[1]).json"; if (-not (Test-Path -LiteralPath $f)) { exit 1 }; [Console]::Out.WriteLine([IO.File]::ReadAllText($f)) }
    default { exit 1 }
}
exit 0
'@
if ($OnWindows) { W "$FH/bin/hc.cmd" "@`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$FH\fake.ps1`" %*`r`n" }
else { W "$FH/bin/hc" "#!/bin/sh`nexec '$Exe' -NoProfile -File '$FH/fake.ps1' `"`$@`"`n"; & chmod +x "$FH/bin/hc" }
$env:FH = $FH; $env:PATH = (Join-Path $FH 'bin') + $sep + $env:PATH
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $m1 = $now - 60000; $m3 = $now - 11 * 60000
W "$FH/ls.json" '{"terminals":[{"address":"t1","agent":"claude-code","cwd":"/x","state":"live","status":"done"},{"address":"t3","agent":"claude-code","cwd":"/x","state":"live","status":"blocked"},{"address":"t4","agent":"claude-code","cwd":"/x","state":"live","status":"idle"},{"address":"m/t9","agent":"claude-code","cwd":"/x","state":"live","status":"blocked"}]}'
foreach ($a in @(@('t1', $m1), @('t3', $m3), @('t4', $m1))) { W "$FH/get-$($a[0]).json" ('{"address":"' + $a[0] + '","pid":1,"foreground":{"pid":1,"cwd":"/x"},"status":{"app":"x","state":"x"},"status_ms":' + $a[1] + '}') }
W "$H/.cache/nvim-jay/said/t1" ('{"text":"要推上去嗎？","at":' + ($m1 + 1000) + '}')
W "$H/.cache/nvim-jay/subs/t1" ('{"at":' + $now + ',"list":[{"id":"a1","done":false}]}')
W "$H/.cache/nvim-jay/said/t4" ('{"text":"好了。機器到了跟我說。","at":' + ($m1 + 1000) + '}')
KitJ agents --open --json
$a = @{}; foreach ($x in @(($out | ConvertFrom-Json).agents)) { $a[$x.address] = $x }
Check 'open: kit agents --open --json: this machine''s agents (not m/t9)' { $rc -eq 0 -and (@($a.Keys) | Sort-Object) -join ',' -ceq 't1,t3,t4' }
Check 'open: done and its last words ask: waiting; its sub-agent runs: busy' { $a['t1'].waiting.since -eq $m1 -and -not $a['t1'].waiting.hot -and $a['t1'].waiting.why -ceq '要推上去嗎？' -and $a['t1'].busy -ceq '子 agent 1 個' }
Check 'open: blocked 10 minutes: hot; idle with words that do not ask: not waiting' { $a['t3'].waiting.hot -and $a['t3'].waiting.why -ceq '在等你允許或回答它（畫面上的提問）' -and $null -eq $a['t4'].waiting -and $null -eq $a['t4'].busy }
} finally { Done }
