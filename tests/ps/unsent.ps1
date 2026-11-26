. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- kit list --json: since when a source has changes to send, and a reminder in Herdr (kit 0.15.0, kit api 1.20) ----------
# A fake hc that keeps hc doc set's document (on stdin). tests/sh/unsent.sh has the rest, with both kits.
$FH = Join-Path $T 'fakehc'; $S = Join-Path $T 'src-u'; $UN = Join-Path $H '.config/agentkit/unsent.tsv'
W "$FH/fake.ps1" @'
if ($args[0] -ne 'doc') { exit 1 }
[IO.File]::WriteAllText((Join-Path $env:FH 'doc'), [Console]::In.ReadToEnd())
exit 0
'@
# (Windows: only its first word; Windows PowerShell's -File takes the last one, "-", for a parameter's name and stops)
if ($OnWindows) { W "$FH/bin/hc.cmd" "@`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$FH\fake.ps1`" %1`r`n" }
else { W "$FH/bin/hc" "#!/bin/sh`nexec '$Exe' -NoProfile -File '$FH/fake.ps1' `"`$@`"`n"; & chmod +x "$FH/bin/hc" }
$env:FH = $FH; $env:PATH = (Join-Path $FH 'bin') + $sep + $env:PATH
W "$S/rules/ur.md" "Rule.`n"
& git -C $S init -q; & git -C $S add -A; & git -C $S -c user.name=t -c user.email=t@t commit -qm v1
Kit init $S
W "$S/rules/ur.md" "Rule 2.`n"
$t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 1000
KitJ list --json
$src = @(($out | ConvertFrom-Json).sources | Where-Object { $_.name -ceq 'src-u' })[0]
Check 'unsent: a source with changes to send: dirty_since (ms), kept in unsent.tsv' { $src.dirty_since -ge $t0 -and (ReadT $UN).StartsWith("src-u`t$($src.dirty_since)`t0") }
$old = $src.dirty_since - 31 * 60000; W $UN "src-u`t$old`t0`n"
KitJ list --json
Check 'unsent: 30 minutes and more: hc doc set notice/kit-unsent, as the Kit panel words it' {
    $d = (ReadT "$FH/doc") | ConvertFrom-Json
    $d.id -ceq "src-u:$old" -and $d.title -ceq 'Kit 來源還沒送出' -and $d.body -ceq 'src-u 有改動 31 分鐘還沒送出：其他機器拿不到（kit push --to src-u）' -and [long]((ReadT $UN).Trim().Split("`t")[2]) -gt $old }
} finally { Done }
