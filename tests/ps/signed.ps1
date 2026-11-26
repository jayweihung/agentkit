. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
function FileUrl([string]$p) { $p = $p.Replace('\', '/'); if ($p.StartsWith('/')) { "file://$p" } else { "file:///$p" } }
function G { & git @args 2>&1 | Out-Null }
# ---------- signed approvals (root uses only versions signed on the Mac): kit.ps1 reads them too ----------
function SshK([string]$a) { # ssh-keygen with that command line (an empty "" stays an argument); its exit code
    $c = @(Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue); if ($c.Count -eq 0) { return 1 }
    $psi = New-Object Diagnostics.ProcessStartInfo ([string]$c[0].Path), $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close(); $e = $p.StandardError.ReadToEndAsync(); $o = $p.StandardOutput.ReadToEndAsync()
    # Windows' ssh-keygen that writes to stderr through a pipe can wait there for minutes; like kit.ps1, 30 s and it counts as missing
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; return 1 }; $p.WaitForExit(); [void]$e.Result; [void]$o.Result; $p.ExitCode
}
function ApprSign([string]$dir, [string]$key, [string]$text) { # approved.txt with TEXT, signed by KEY (what kit approve writes)
    W "$dir/approved.txt" $text; Remove-Item -LiteralPath "$dir/approved.txt.sig" -Force -ErrorAction SilentlyContinue
    SshK "-Y sign -q -f `"$key`" -n agentkit `"$dir/approved.txt`""
}
$SA = Join-Path $T 'signed'; [void](New-Item -ItemType Directory -Force -Path $SA)
$sshOk = (SshK "-q -t ed25519 -N `"`" -C approver -f `"$SA/key`"") -eq 0 -and (SshK "-q -t ed25519 -N `"`" -C mallory -f `"$SA/badkey`"") -eq 0
if ($sshOk) { W "$SA/try.txt" "x`n"; $sshOk = (SshK "-Y sign -q -f `"$SA/key`" -n agentkit `"$SA/try.txt`"") -eq 0 -and (Test-Path "$SA/try.txt.sig") }
$SAs = "$SA/allowed_signers"
if (-not $sshOk) { [Console]::WriteLine('skipped: signed approvals (no ssh-keygen -Y sign here)') }
else {
$savedHome = $H
W $SAs ('jay namespaces="agentkit" ' + (ReadT "$SA/key.pub").Trim() + "`n")
$SW = "$SA/work/srcA"
W "$SW/rules/ar.md" "Approved rule v1.`n"; W "$SW/kit.yaml" "name: srcA`nrequired:`n  rules: [ar]`n"
G -C $SW init -q; G -C $SW config user.name t; G -C $SW config user.email t@t; G -C $SW add -A; G -C $SW commit -qm v1
G clone -q --bare $SW "$SA/srcA.git"; G -C $SW remote add origin "$SA/srcA.git"; G -C $SW fetch -q origin
$v1 = "$(& git -C $SW rev-parse HEAD)".Trim()
$AW = "$SA/appr-work"; [void](New-Item -ItemType Directory -Force -Path $AW)
G -C $AW init -q; G -C $AW config user.name t; G -C $AW config user.email t@t
[void](ApprSign $AW "$SA/key" "serial: 1`nsrcA $v1`n"); G -C $AW add -A; G -C $AW commit -qm s1
G clone -q --bare $AW "$SA/approvals.git"; G -C $AW remote add origin "$SA/approvals.git"
Copy-Item "$AW/approved.txt" "$SA/old.txt"; Copy-Item "$AW/approved.txt.sig" "$SA/old.sig"
function APush([string]$m) { G -C $AW add -A; G -C $AW commit -qm $m; G -C $AW push -q origin HEAD }
$RH = Join-Path $T 'roothome'; Set-Home $RH
Kit init (FileUrl "$SA/srcA.git") --approvals (FileUrl "$SA/approvals.git") --signers $SAs
Check 'signed: init uses the approved commit' { $rc -eq 0 -and "$(& git -C "$RH/agentkit/srcA" rev-parse HEAD)".Trim() -eq $v1 -and (ReadT "$RH/.claude/CLAUDE.md").Contains('ar.md') }
Check 'signed: machine.yaml keeps approvals and signers' { $m = ReadT "$RH/.config/agentkit/machine.yaml"; $m -match '(?m)^approvals: file://' -and $m -match '(?m)^signers: .' }
W "$SW/rules/ar.md" "Unapproved v2.`n"; G -C $SW commit -qam v2; G -C $SW push -q origin HEAD
$v2 = "$(& git -C $SW rev-parse HEAD)".Trim()
Kit sync
Check 'signed: an unapproved new commit is not used' { "$(& git -C "$RH/agentkit/srcA" rev-parse HEAD)".Trim() -eq $v1 -and (ReadT "$RH/agentkit/srcA/rules/ar.md").Contains('v1') }
Kit add skill nothing
Check 'signed: add/rm keep the approvals setting' { (ReadT "$RH/.config/agentkit/machine.yaml") -match '(?m)^approvals: ' }
[void](ApprSign $AW "$SA/key" "serial: 2`nsrcA $v2`n"); APush s2
Copy-Item "$AW/approved.txt" "$SA/v2.txt"; Copy-Item "$AW/approved.txt.sig" "$SA/v2.sig"
Kit sync
Check 'signed: approved v2 is used after approve' { "$(& git -C "$RH/agentkit/srcA" rev-parse HEAD)".Trim() -eq $v2 -and $out.Contains('換到核准的版本') }
W "$AW/approved.txt" "# x`nserial: 9`nsrcA $v1`n"; APush forged       # write access to the approvals repo, but not the key
Kit sync
Check 'signed: an edited list without a new signature is refused' { $out.Contains('簽章不對') -and (ReadT "$RH/agentkit/srcA/rules/ar.md").Contains('Unapproved v2') }
[void](ApprSign $AW "$SA/badkey" "# x`nserial: 9`nsrcA $v1`n"); APush forged2
Kit sync
Check 'signed: a list signed by another key is refused' { $out.Contains('簽章不對') -and (ReadT "$RH/agentkit/srcA/rules/ar.md").Contains('Unapproved v2') }
Copy-Item "$SA/old.txt" "$AW/approved.txt" -Force; Copy-Item "$SA/old.sig" "$AW/approved.txt.sig" -Force; APush replay
Kit sync
Check 'signed: an older signed list (serial 1) cannot roll back' { $out.Contains('比上次用的舊') -and (ReadT "$RH/agentkit/srcA/rules/ar.md").Contains('Unapproved v2') }
[IO.File]::AppendAllText("$RH/agentkit/srcA/rules/ar.md", "local edit`n")
Copy-Item "$SA/v2.txt" "$AW/approved.txt" -Force; Copy-Item "$SA/v2.sig" "$AW/approved.txt.sig" -Force; APush restore
Kit sync
Check 'signed: local edits in the clone are reset to the approved commit' { -not (ReadT "$RH/agentkit/srcA/rules/ar.md").Contains('local edit') }
# status --json with approvals: only the approvals clone that is here already (never pulled), nothing written
[void](ApprSign $AW "$SA/key" "serial: 3`nsrcA $v2`n"); APush s3        # not pulled here
function SnapS([string]$d) { # every file (not PowerShell's own cache, which each kit.ps1 run may touch) with its size and time
    (@(Get-ChildItem -LiteralPath $d -Recurse -Force -File | Where-Object { $_.FullName -notmatch '[\\/](\.cache|\.local)[\\/]' } | Sort-Object FullName |
        ForEach-Object { "$($_.FullName) $($_.Length) $($_.LastWriteTimeUtc.Ticks)" })) -join "`n" }
$snapR = SnapS $RH
KitJ status --json; $sjA = $out
$srcJ = "{`"name`": `"srcA`", `"source`": `"$(FileUrl "$SA/srcA.git")`", `"dir`": $((ConvertTo-Json ((Resolve-Path "$RH/agentkit/srcA").ProviderPath)))"
Check 'signed: status --json: serial, used, valid; the approved commit next to the one in use' { $rc -eq 0 -and $out.Contains("`n  `"approvals`": {`"serial`": 2, `"used`": 2, `"valid`": true},`n") -and $out.Contains("`n    $srcJ, `"commit`": `"$v2`", `"approved`": `"$v2`"}") }
Check 'signed: status --json: nothing fetched or written' { (SnapS $RH) -ceq $snapR }
Check 'signed: status --json: nothing waits for the signer (the remote is at the approved commit)' { $out.Contains("`n  `"pending`": [],`n") }
if (-not $OnWindows) {
    $bash = (& /bin/sh -c "cd '$Repo' && HOME='$RH' unix/kit status --json 2>/dev/null") -join "`n"
    Check 'signed: status --json: unix/kit prints the same' { ($bash -replace '"at": [0-9]+,', '"at": 0,') -ceq ($sjA -replace '"at": [0-9]+,', '"at": 0,') }
}
[IO.File]::AppendAllText("$RH/agentkit/.approvals/approved.txt", "srcB 0123456789012345678901234567890123456789`n")
KitJ status --json
Check 'signed: status --json: an edited approved.txt is not valid, no approved commits' { $rc -eq 0 -and $out.Contains("`n  `"approvals`": {`"serial`": 2, `"used`": 2, `"valid`": false},`n") -and $out.Contains("`n    $srcJ, `"commit`": `"$v2`", `"approved`": null}") }
G -C "$RH/agentkit/.approvals" checkout -q -- approved.txt
$NC = Join-Path $T 'noclone'; [void](New-Item -ItemType Directory -Force -Path "$NC/conf"); Copy-Item "$RH/.config/agentkit/machine.yaml" "$NC/conf/"
$env:AGENTKIT_CONFIG = "$NC/conf"; $env:AGENTKIT_SOURCES = Join-Path $NC 'src'
KitJ status --json
Remove-Item env:AGENTKIT_CONFIG, env:AGENTKIT_SOURCES
Check 'signed: status --json: no approvals clone yet: not valid, none made' { $rc -eq 0 -and $out.Contains("`n  `"approvals`": {`"serial`": null, `"used`": null, `"valid`": false},`n") -and
    $out.Contains("`"dir`": $(ConvertTo-Json (Join-Path (Join-Path $NC 'src') 'srcA')), `"commit`": null, `"approved`": null}") -and -not (Test-Path "$NC/src") -and @(Get-ChildItem "$NC/conf").Count -eq 1 }
# a new commit on the source, fetched by kit sync but not approved: kit status says it waits for the signer
W "$SW/rules/ar.md" "v3, not approved yet.`n"; G -C $SW commit -qam v3; G -C $SW push -q origin HEAD
$v3 = "$(& git -C $SW rev-parse HEAD)".Trim()
Kit sync
KitJ status --json
Check 'signed: status --json: a new commit kit sync fetched but nobody approved waits for the signer (pending, kind sign)' {
    $p = @(($out | ConvertFrom-Json).pending)
    "$(& git -C "$RH/agentkit/srcA" rev-parse HEAD)".Trim() -eq $v2 -and $p.Count -eq 1 -and $p[0].kind -eq 'sign' -and $p[0].name -eq 'srcA' -and $p[0].commits -eq 1 -and $p[0].head -eq $v3 -and
        $p[0].what -eq 'srcA 有 1 個新 commit 等核准' -and $p[0].since -gt 1e12 -and $p[0].machine }
[void](ApprSign $AW "$SA/key" "serial: 4`nsrcA $v3`n"); APush s4
Kit sync
KitJ status --json
Check 'signed: status --json: approved and synced: nothing pending' { $out.Contains("`n  `"pending`": [],`n") -and "$(& git -C "$RH/agentkit/srcA" rev-parse HEAD)".Trim() -eq $v3 }
$env:AGENTKIT_SOURCES = "$RH/agentkit2"
Kit init (FileUrl "$SA/srcA.git") --approvals "$SA/nowhere" --signers $SAs
Remove-Item env:AGENTKIT_SOURCES
Check 'signed: init without a valid list stops' { $rc -ne 0 -and -not (Test-Path "$RH/agentkit2/srcA/rules") }
Kit init (FileUrl "$SA/srcA.git") --approvals (FileUrl "$SA/approvals.git")
Check 'signed: --approvals without --signers refused' { $rc -ne 0 -and $out.Contains('要一起給') }
Set-Home $savedHome
}

} finally { Done }
