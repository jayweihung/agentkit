. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM
# ---------- a source starts including another one ----------
W "$T/extra-src/rules/extra-rule.md" "Extra rule.`n"
$mf = "$H/.config/agentkit/machine.yaml"
$before = @((ReadT $mf) -split "`n" | Where-Object { $_.StartsWith('added') })[0]
$ky = ReadT "$TEAM/kit.yaml"; W "$TEAM/kit.yaml" ($ky -replace '(?m)^include: \[(.*)\]', 'include: [$1, ../extra-src]')
Kit sync
$extra = (Resolve-Path -LiteralPath "$T/extra-src").ProviderPath
Check 'sync adds a new include (relative to the source)' { (ReadT $mf).Contains("  - $extra") -and $out.Contains('加了來源') }
Check 'sync keeps what you added' { @((ReadT $mf) -split "`n" | Where-Object { $_.StartsWith('added') })[0] -eq $before }
Check 'items of the new source are announced' { $out.Contains('rule:extra-rule') }
Kit sync
Check 'include added only once' { @([regex]::Matches((ReadT $mf), 'extra-src')).Count -eq 1 }
# a clone of a URL source sits in ~/agentkit/<name>; an include pointing at that folder is the same source
W "$T/lc/rules/lc.md" "x`n"
& git -C "$T/lc" init -q; & git -C "$T/lc" add -A; & git -C "$T/lc" -c user.name=t -c user.email=t@t commit -qm x; & git clone -q --bare "$T/lc" "$T/lc.git" 2>$null
& git clone -q "$T/lc.git" "$H/agentkit/lib-clone" 2>$null
$mback = ReadT $mf
W $mf ($mback -replace '(?m)^sources:.*$', "`$0`n  - https://gitea.example/team/lib-clone.git")
$kback = ReadT "$TEAM/kit.yaml"
$lc = (Resolve-Path -LiteralPath "$H/agentkit/lib-clone").ProviderPath
W "$TEAM/kit.yaml" ($kback -replace '(?m)^include: \[(.*)\]', "include: [`$1, $lc]")
Kit sync
Check "include of a cloned source's folder is not added twice" { $rc -eq 0 -and @([regex]::Matches((ReadT $mf), 'lib-clone')).Count -eq 1 -and $out.Contains('rule:lc') }
W "$TEAM/kit.yaml" $kback; W $mf $mback; Remove-Item -Recurse -Force "$H/agentkit/lib-clone"

# ---------- allowed_hosts ----------
Kit init $TEAM 'https://public-git.example/someone/agentkit-library.git'
Check 'host outside allowed_hosts refused' { $rc -ne 0 -and $out.Contains('public-git.example 不在允許的主機清單') }
Kit init $TEAM

} finally { Done }
