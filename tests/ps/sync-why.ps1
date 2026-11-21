. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
function FileUrl([string]$p) { $p = $p.Replace('\', '/'); if ($p.StartsWith('/')) { "file://$p" } else { "file:///$p" } }
function G { & git @args 2>&1 | Out-Null }
# ---------- sync: why a source could not be updated ----------
$SY = Join-Path $T 'syncwhy'; $SW = Join-Path $SY 'w'
& git -c init.defaultBranch=main init -q $SW
W "$SW/kit.yaml" "name: s`n"; W "$SW/rules/a.md" "v1`n"
G -C $SW add -A; G -C $SW -c user.name=t -c user.email=t@t commit -qm v1; G clone -q --bare $SW (Join-Path $SY 's.git')
$oldH = $H; Set-Home (Join-Path $SY 'home')
Kit init (FileUrl (Join-Path $SY 's.git'))
$C = Join-Path $H 'agentkit/s'
W "$SW/rules/a.md" "v2`n"; G -C $SW -c user.name=t -c user.email=t@t commit -qam v2; G -C $SW push -q (Join-Path $SY 's.git') HEAD:main
W "$C/rules/a.md" "mine`n"
Kit sync
Check 'sync: a source with your own changes in the way says so' { $out -match '沒辦法更新 s（.*自己改過' }
G -C $C checkout -q -- rules/a.md; G -C $C -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
Kit sync
Check 'sync: a source with its own commits says it went its own way' { $out -match '沒辦法更新 s（.*分岔' }
G -C $C remote set-url origin (FileUrl (Join-Path $SY 'gone.git'))
Kit sync
Check 'sync: no network is told apart' { $out.Contains('沒辦法更新 s（沒網路？）') }
Set-Home $oldH

} finally { Done }
