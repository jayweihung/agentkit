. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- kit open --tab, kit add|rm --tab, kit tab (kit 0.17.0, kit api 1.22) ----------
# What Windows does its own way: no exec (kit starts the tool and waits), the tool found as a .cmd, the memory folder
# passed through Windows' quoting. tests/sh/tabs.sh has the rest, with both kits.
Set-Home (Join-Path $T 'home-tabs')
$S = Join-Path $T 'src-tabs'; $Wk = Join-Path $T 'work tabs'; $FB = Join-Path $T 'fake-tabs'
foreach ($n in 'ta', 'tb') { W "$S/skills/$n/SKILL.md" "---`nname: $n`ndescription: skill $n`n---`n$n body`n" }
W "$S/rules/ra.md" "Rule RA.`n"
W "$S/mcp/ma.yaml" "command: echo`nargs:`n  - ma`n"
W "$S/agents/hello.md" "---`nname: hello`ndescription: h`nrules: [ra]`nskills: [ta]`nmcp: [ma]`n---`nYou are hello.`n"
[void](New-Item -ItemType Directory -Force -Path $Wk, "$H/.codex")
# the fake Claude writes its KIT_TAB and every argument on a line of its own
W "$FB/fake.ps1" "[IO.File]::WriteAllText('$FB/args', ((@(`$env:KIT_TAB) + `$args) -join `"``n`"))`nexit 3`n"
if ($OnWindows) { W "$FB/claude.cmd" "@`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$FB\fake.ps1`" %*`r`n" }
else { W "$FB/claude" "#!/bin/sh`nexec '$Exe' -NoProfile -File '$FB/fake.ps1' `"`$@`"`n"; & chmod +x "$FB/claude" }
Kit init $S; Kit add skill tb
$TB = Join-Path $H '.config/agentkit/tabs'
Push-Location $Wk
try {
    $saved = $env:PATH; $env:PATH = $FB + $sep + $env:PATH; $env:MYTAB = 't1'
    Kit open claude --agent hello --tab-env MYTAB -- --resume x1
    $env:PATH = $saved; Remove-Item env:MYTAB
    $a = @((ReadT "$FB/args") -split "`n")
    $i = [array]::IndexOf($a, '--settings')
    Check 'tabs: open: the tool''s exit code; KIT_TAB; the tab''s folder (--add-dir); the tool''s own last' { $rc -eq 3 -and $a[0] -ceq 't1' -and $a -ccontains (Join-Path $TB 't1') -and $a[-2] -ceq '--resume' -and $a[-1] -ceq 'x1' }
    Check 'tabs: Claude''s memory in the tab, the JSON whole through Windows'' quoting' { $i -gt 0 -and (($a[$i + 1] | ConvertFrom-Json).autoMemoryDirectory -ceq (Join-Path $TB 't1/memory')) }
    Check 'tabs: the agent''s skill, rule, MCP copied into the tab' { (Test-Path (Join-Path $TB 't1/.claude/skills/ta/SKILL.md')) -and (Test-Path (Join-Path $TB 't1/rules/ra.md')) -and (Test-Path (Join-Path $TB 't1/mcp/ma.yaml')) }
    Kit add --tab t1 skill tb; $r1 = $rc; $o1 = $out
    Kit add --tab t1 skill ta
    Check 'tabs: add --tab: not one the account has; one it already has: said' { $r1 -ne 0 -and $o1 -match '整個帳號已經有' -and $rc -eq 0 -and $out -match '已經有' }
    KitJ tab show t1 --json
    $d = $out | ConvertFrom-Json
    Check 'tabs: tab show --json: the agent''s items, the account''s; not running' { $rc -eq 0 -and $d.agent -ceq 'hello' -and -not $d.live -and @($d.items).Count -eq 3 -and @($d.account | Where-Object { $_.name -ceq 'tb' }).Count -eq 1 }
    # a pid Windows gave to another process since (here: this test's own) is not the tab's tool: its start time differs
    $tf = Join-Path $TB 't1/tab.tsv'; $own = $(if ($OnWindows) { (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { ("$(& ps -o lstart= -p $PID)" -replace '\s+', ' ').Trim() })   # kit's Proc-Start
    $base = ((ReadT $tf) -split "`n" | Where-Object { $_ -and $_ -notmatch '^(pid|start)\t' }) -join "`n"
    W $tf "$base`npid`t$PID`nstart`t1`n"; KitJ tab show t1 --json; $l1 = ($out | ConvertFrom-Json).live
    W $tf "$base`npid`t$PID`nstart`t$own`n"; KitJ tab show t1 --json; $l2 = ($out | ConvertFrom-Json).live
    W $tf "$base`npid`t$PID`n"; KitJ tab show t1 --json; $l3 = ($out | ConvertFrom-Json).live
    Check 'tabs: live: the pid and its start time (a pid given to a new process is not running; a tab from before 0.18.1, no start: the pid alone)' { -not $l1 -and $l2 -and $l3 }
    W $tf "$base`n"
    Kit tab rm t1
    Check 'tabs: tab rm: its folder goes' { $rc -eq 0 -and -not (Test-Path (Join-Path $TB 't1')) }
} finally { Pop-Location }
} finally { Done }
