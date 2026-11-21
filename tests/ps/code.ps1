. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- the script files themselves ----------
Check 'kit.ps1 and install.ps1 start with a UTF-8 BOM (needed by PowerShell 5.1)' {
    $ok = $true; foreach ($f in 'windows/kit.ps1', 'windows/install.ps1', 'tests/run.ps1') { $b = [IO.File]::ReadAllBytes((Join-Path $Repo $f)); if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $ok = $false } }; $ok }
Check 'no PowerShell 7-only syntax (?? ?. && ||)' {
    $bad = Select-String -Path $Kit, (Join-Path $Repo 'windows/install.ps1') -Pattern '\?\?|\?\.|\s&&\s|\s\|\|\s' | Where-Object { $_.Line -notmatch '^\s*#' }
    @($bad).Count -eq 0 }
} finally { Done }
