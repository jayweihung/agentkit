# End-to-end tests for the Windows kit (kit.ps1), in sections (tests/ps/<section>.ps1). Each section runs in a
# throwaway home folder of its own, so your real ~/.claude is never touched and several sections run at once.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1                 every section (-Jobs N: N at once; the default: one per core)
#   ... tests\run.ps1 <section>...       only those (-List: the sections)
#   ... tests\run.ps1 -Changed [<base>]  the sections that test what changed since <base> (default: where this branch
#                                        left master), uncommitted changes too; tests/sections.txt says which
# The last line is always "kit.ps1: N passed, M failed". Works with Windows PowerShell 5.1 and PowerShell 7 (also on macOS/Linux).
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Names = @(), [int]$Jobs = 0, [switch]$List, [switch]$Changed)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$Here = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent $Here
$Exe = (Get-Process -Id $PID).Path
# the slowest first (measured), so the run is not left waiting on one started last
$Slow = @('context', 'tools', 'mcp', 'plugins', 'place', 'files', 'basics', 'list-json', 'dir', 'collect', 'push-direct', 'push')
$All = @(Get-ChildItem -LiteralPath (Join-Path $Here 'ps') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { $_.BaseName })
if ($List) { $All | ForEach-Object { [Console]::WriteLine($_) }; exit 0 }
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

function GitOut { $o = & git -C $Root @args 2>$null; if ($LASTEXITCODE -ne 0) { throw "git $args" }; @($o) }
# the functions of FILE (its text, as lines) at each line: "name() {" or "function Name" to the next "}" at the start of a
# line (or that line alone when its braces close there); "" outside any
function Regions([string[]]$lines) {
    $fn = New-Object System.Collections.Generic.List[string]; $fn.Add(''); $name = ''; $open = $false
    foreach ($l in $lines) {
        if ($l -match '^(function +[A-Za-z][A-Za-z0-9-]*|[A-Za-z_][A-Za-z0-9_]*\(\))') {
            $name = ($l -replace '^function +', '') -replace '[^A-Za-z0-9_-].*$', ''
            $open = ([regex]::Matches($l, '\{').Count -gt [regex]::Matches($l, '\}').Count); $fn.Add($name); continue
        }
        if ($open) { $fn.Add($name); if ($l.StartsWith('}')) { $open = $false } } else { $fn.Add('') }
    }
    , $fn
}
# the sections for what changed since BASE, each with why (said on the screen)
function Changed-Sections([string]$base) {
    if (-not $base) { try { $base = (GitOut merge-base HEAD master)[0] } catch { throw '-Changed: 找不到 master（給一個 <base>）' } }
    try { [void](GitOut rev-parse -q --verify "$base^{commit}") } catch { throw "-Changed: 沒有 $base 這個 commit" }
    $keys = New-Object System.Collections.Generic.List[string]
    $files = @(GitOut diff --name-only $base --) + @(GitOut ls-files --others --exclude-standard) | Where-Object { $_ } | Sort-Object -Unique
    foreach ($f in $files) {
        if ($f -ne 'unix/kit' -and $f -ne 'windows/kit.ps1') { $keys.Add($f); continue }
        $old = @(); try { $old = @(GitOut show "${base}:$f") } catch { }
        $new = @(); $p = Join-Path $Root $f; if (Test-Path -LiteralPath $p) { $new = @([IO.File]::ReadAllText($p).Replace("`r", '') -split "`n") }
        $fo = Regions $old; $fnw = Regions $new
        foreach ($h in @(GitOut diff -U0 $base -- $f) | Where-Object { $_ -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@' }) {
            [void]($h -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
            foreach ($side in @(@([int]$Matches[1], $(if ($Matches[2]) { [int]$Matches[2] } else { 1 }), $fo), @([int]$Matches[3], $(if ($Matches[4]) { [int]$Matches[4] } else { 1 }), $fnw))) {
                for ($i = $side[0]; $i -lt $side[0] + $side[1]; $i++) { $n = ''; if ($i -lt $side[2].Count) { $n = $side[2][$i] }; $keys.Add("${f}:$n") }
            }
        }
    }
    if ($keys.Count -eq 0) { [Console]::WriteLine("-Changed: 跟 $base 比沒有改東西"); return @() }
    # tests/sections.txt: "<sections> : <patterns>", a line starting with a space goes on
    $map = @(); $cur = ''
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $Here 'sections.txt'))) {
        if ($l -match '^\s*(#|$)') { continue }
        if ($l -notmatch '^\s') { $i = $l.IndexOf(' : '); $cur = $l.Substring(0, $i); $l = $l.Substring($i + 3) }
        foreach ($p in ($l.Trim() -split '\s+')) { $map += , @($p, @($cur -split '\s+')) }
    }
    $pick = [ordered]@{}; $every = ''
    foreach ($k in ($keys | Select-Object -Unique)) {
        if ($k -match '^tests/ps/([^/]+)\.ps1$') { if ($All -contains $Matches[1] -and -not $pick.Contains($Matches[1])) { $pick[$Matches[1]] = $k }; continue }
        if ($k -match '^tests/(sh/|lib\.sh$|run\.sh$)') { continue }   # the other suite's
        if ($k -match '^tests/(lib\.ps1|run\.ps1|sections\.txt)$' -or $k.EndsWith(':')) { if (-not $every) { $every = $k }; continue }
        $hit = $false
        foreach ($m in $map) {
            if ($m[0] -eq 'always' -or $k -notlike $m[0]) { continue }
            $hit = $true; foreach ($s in $m[1]) { if ($All -contains $s -and -not $pick.Contains($s)) { $pick[$s] = $k } }
        }
        if (-not $hit -and -not $every) { $every = "$k (not in tests/sections.txt)" }
    }
    if ($every) { [Console]::WriteLine("every section: $every"); return $All }
    foreach ($m in $map) { if ($m[0] -eq 'always') { foreach ($s in $m[1]) { if ($All -contains $s -and -not $pick.Contains($s)) { $pick[$s] = 'every change' } } } }
    foreach ($s in $pick.Keys) { [Console]::WriteLine("$s <- $($pick[$s])") }
    @($pick.Keys)
}

$sel = @(); $base = ''
foreach ($n in $Names) {
    if ($All -contains $n) { $sel += $n }
    elseif ($Changed -and -not $base) { $base = $n }
    else { [Console]::Error.WriteLine("沒有 $n 這個 section（tests\run.ps1 -List）"); exit 2 }
}
if ($Changed) {
    try { $sel += @(Changed-Sections $base) } catch { [Console]::Error.WriteLine("$($_.Exception.Message)"); exit 2 }
    if ($sel.Count -eq 0) { [Console]::WriteLine('kit.ps1: 0 passed, 0 failed'); exit 0 }
}
if ($sel.Count -eq 0) { $sel = $All }
$run = @(@($Slow | Where-Object { $sel -contains $_ }) + @($sel) | Select-Object -Unique)

$O = Join-Path ([IO.Path]::GetTempPath()) ('kit-tests.' + [IO.Path]::GetRandomFileName()); [void](New-Item -ItemType Directory -Path $O)
$start = Get-Date
[Console]::WriteLine("kit.ps1: $($run.Count) 個 section，同時跑 $Jobs 個")
$procs = @{}; $begun = @{}; $secs = @{}; $queue = New-Object System.Collections.Queue; $run | ForEach-Object { $queue.Enqueue($_) }
function Result([string]$s) {
    $t = [IO.File]::ReadAllText("$O/$s.out")
    $m = [regex]::Matches($t, '(?m)^kit\.ps1: (\d+) passed, (\d+) failed\r?$')
    if ($m.Count -eq 0) { return $null }; @([int]$m[$m.Count - 1].Groups[1].Value, [int]$m[$m.Count - 1].Groups[2].Value)
}
try {
    while ($queue.Count -gt 0 -or $procs.Count -gt 0) {
        while ($queue.Count -gt 0 -and $procs.Count -lt $Jobs) {
            $s = $queue.Dequeue(); $begun[$s] = Get-Date
            # each section in its own process (its own home and environment); paths quoted for Windows PowerShell 5.1
            $procs[$s] = Start-Process -FilePath $Exe -PassThru -NoNewWindow -RedirectStandardOutput "$O/$s.out" -RedirectStandardError "$O/$s.err" `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $Here "ps/$s.ps1") + '"'))
        }
        Start-Sleep -Milliseconds 200
        foreach ($s in @($procs.Keys)) {
            if (-not $procs[$s].HasExited) { continue }
            $procs[$s].WaitForExit(); $procs.Remove($s); $secs[$s] = [int]((Get-Date) - $begun[$s]).TotalSeconds
            $r = Result $s; $w = if ($null -eq $r) { 'stopped' } elseif ($r[1] -gt 0) { "$($r[1]) failed" } else { 'ok' }
            [Console]::WriteLine(('  {0,-12} {1,5}s  {2}' -f $s, $secs[$s], $w))
        }
    }
    $pass = 0; $fail = 0
    foreach ($s in $run) {
        $lines = @(([IO.File]::ReadAllText("$O/$s.out") + [IO.File]::ReadAllText("$O/$s.err")).Replace("`r", '') -split "`n" | Where-Object { $_ -ne '' })
        foreach ($l in $lines) {
            if ($l -match '^kit\.ps1: \d+ passed, \d+ failed$') { continue }
            if ($l.StartsWith('FAIL: ')) { [Console]::WriteLine("FAIL: [$s] " + $l.Substring(6)) } else { [Console]::WriteLine("[$s] $l") }
        }
        $r = Result $s
        if ($null -eq $r) { [Console]::WriteLine("FAIL: [$s] the section stopped before its end"); $fail++ } else { $pass += $r[0]; $fail += $r[1] }
    }
    $top = @($run | Sort-Object { $secs[$_] } -Descending | Select-Object -First 5 | ForEach-Object { "$_ $($secs[$_])s" })
    [Console]::WriteLine("slowest: $($top -join ', '); all: $([int]((Get-Date) - $start).TotalSeconds)s")
    [Console]::WriteLine("kit.ps1: $pass passed, $fail failed")
} finally {
    foreach ($p in $procs.Values) { try { $p.Kill() } catch { } }
    Remove-Item -Recurse -Force $O -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { exit 1 }
exit 0
