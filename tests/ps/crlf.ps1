. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Team-Later
# ---------- CRLF files from Windows editors ----------
Set-Home (Join-Path $T 'home-crlf')
W "$H/.claude/CLAUDE.md" "# Mine`r`nKeep CRLF.`r`n"
Kit init $TEAM
Check 'CRLF file keeps CRLF' { $t = ReadT "$H/.claude/CLAUDE.md"; $t.Contains("Keep CRLF.`r`n") -and $t.Contains("<!-- agentkit:end -->`r`n") -and -not ($t -match "[^`r]`n") }
Kit uninstall
Check 'CRLF file restored' { (ReadT "$H/.claude/CLAUDE.md") -eq "# Mine`r`nKeep CRLF.`r`n" }

} finally { Done }
