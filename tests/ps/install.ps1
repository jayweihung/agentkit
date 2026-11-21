. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
$realKit = $Kit
$tmpl = (ReadT (Join-Path $Repo 'templates/gitea-kit-check.yaml')).Replace("`r", '').TrimEnd("`n")   # output lines are joined with LF
# ---------- install.ps1 ----------
$env:AGENTKIT_HOME = Join-Path $T 'inst'
& $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'windows/install.ps1') -Quiet
Remove-Item env:AGENTKIT_HOME
$Kit = Join-Path $T 'inst/lib/kit.ps1'
Kit ci-template
Check 'installed kit has the ci template' { $rc -eq 0 -and $out -ceq $tmpl }
# kit 0.2 kept panel files in its own lib: a new install takes them out; a panel installed in a screen program stays
W (Join-Path $T 'inst/lib/herdr/kit-panel/main.js') 'old'
$HA = Join-Path $T 'herdr-app'; W "$HA/mods/kit/main.js" 'old'; W "$HA/mods/kit/.kit-panel" ''
$env:AGENTKIT_HOME = Join-Path $T 'inst'; $env:HERDR_APP_HOME = $HA
& $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'windows/install.ps1') -Quiet
Remove-Item env:AGENTKIT_HOME, env:HERDR_APP_HOME
Check "reinstall removes the panel files kit 0.2 left in its own folder" { -not (Test-Path (Join-Path $T 'inst/lib/herdr')) -and (Test-Path (Join-Path $T 'inst/lib/kit.ps1')) }
Check 'reinstall leaves a panel installed in a screen program alone' { (ReadT "$HA/mods/kit/main.js") -eq 'old' -and (Test-Path "$HA/mods/kit/.kit-panel") }
$Kit = $realKit

} finally { Done }
