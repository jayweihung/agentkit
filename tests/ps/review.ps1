. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
$Py = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
$DAY = Get-Date -Format yyyyMMdd
# ---------- review fixes: the user's own MCP, state only after writing, CRLF / links / markers, URLs, push ----------
function Imp([string]$p) { '@' + $p.Replace('\', '/').Replace(' ', '\ ') }
$oldH = $H; Set-Home (Join-Path $T 'home rf')   # a space: kit's copy of the rule is under it
$RS = Join-Path $T 'rf/src dir'; $CJ = "$H/.claude.json"; $ST = "$H/.config/agentkit/state.tsv"
W "$RS/kit.yaml" "name: rfsrc`nrequired:`n  rules: [r1]`n"; W "$RS/rules/r1.md" "Rule one.`n"
W "$RS/mcp/m1.yaml" "command: theirs`n"; W "$RS/mcp/m2.yaml" "command: kits`n"
$cjOrig = "{`n  `"mcpServers`": {`n    `"m1`": {`n      `"command`": `"mine`"`n    }`n  }`n}`n"; W $CJ $cjOrig
$crlf = "My line one`r`nMy line two`r`n"; W "$H/.claude/CLAUDE.md" $crlf
Kit init $RS
Check "@import: forward slashes, a space escaped (Claude's @path stops at a backslash or space)" { $rc -eq 0 -and (ReadT "$H/.claude/CLAUDE.md").Contains((Imp (Join-Path $H '.config/agentkit/store/rules/r1.md')) + "`r`n") }
Kit sync
Check 'CLAUDE.md with CRLF: one kit block after another sync' { ([regex]::Matches((ReadT "$H/.claude/CLAUDE.md"), 'agentkit:begin')).Count -eq 1 -and -not ((ReadT "$H/.claude/CLAUDE.md") -match "[^`r]`n") }
Kit add mcp m1
Check "the user's own MCP with the same name is not replaced (warned)" { $rc -eq 0 -and (JGet $CJ 'mcpServers.m1.command') -eq '"mine"' -and $out.Contains('已經有自己的 MCP m1') }
Kit add mcp m2; Kit rm mcp m2
Check 'the backup is the file before kit first changed it' { (ReadT "$CJ.kit-backup") -ceq $cjOrig }
$cjGood = ReadT $CJ; W $CJ '{"mcpServers": {'
Kit add mcp m2
Check 'a file kit cannot write stops kit, and state.tsv does not say it was done' { $rc -ne 0 -and -not ((ReadT $ST) -match "(?m)^mcp`tm2`t") }
[IO.File]::WriteAllText($CJ, $cjGood.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding $true))
Kit sync
Check 'the next sync adds it; a BOM and CRLF in .claude.json are kept' { $b = [IO.File]::ReadAllBytes($CJ); $t = ReadT $CJ; $rc -eq 0 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $t.Contains('"kits"') -and -not ($t -match "[^`r]`n") }
Kit uninstall
Check "uninstall leaves the user's own MCP" { (ReadT $CJ).Contains('"mine"') -and -not (ReadT $CJ).Contains('"kits"') }
Check 'uninstall gives the CRLF CLAUDE.md back byte for byte' { (ReadT "$H/.claude/CLAUDE.md") -ceq $crlf }
if (-not $OnWindows) {   # making a link needs admin rights or developer mode on Windows
    Move-Item "$H/.claude/CLAUDE.md" "$T/rf/dot-claude.md"; [void](New-Item -ItemType SymbolicLink -Path "$H/.claude/CLAUDE.md" -Target "$T/rf/dot-claude.md")
    Kit init $RS
    Check 'a linked CLAUDE.md stays a link; the file it points to gets the block' { ((Get-Item "$H/.claude/CLAUDE.md").Attributes -band [IO.FileAttributes]::ReparsePoint) -and (ReadT "$T/rf/dot-claude.md").Contains('agentkit:begin') }
    Kit uninstall; Remove-Item "$H/.claude/CLAUDE.md"
}
$half = "Mine`n<!-- agentkit:begin (managed by kit, do not edit) -->`nkeep me`n"; W "$H/.claude/CLAUDE.md" $half
Kit init $RS
Check 'a begin marker without an end: the file is not touched, kit says so' { (ReadT "$H/.claude/CLAUDE.md") -ceq $half -and $out.Contains('找不到結束標記') }
Kit uninstall
Check 'uninstall with such a file: stops, state kept for another try' { $rc -ne 0 -and (Test-Path $ST) }
W "$H/.claude/CLAUDE.md" $crlf; Kit uninstall
[void](New-Item -ItemType Directory -Force -Path "$H/.config/agentkit/sync.lock"); $env:KIT_LOCK_WAIT = '1'
Kit add mcp m2
Check 'another kit running (the lock): waits, then stops' { $rc -ne 0 -and $out.Contains('另一個 kit 正在跑') }
Remove-Item env:KIT_LOCK_WAIT; Remove-Item -Recurse -Force "$H/.config/agentkit/sync.lock"
Kit init 'https://me:s3cr3t-tok@gitea.example/acme/team.git'
Check 'init: a URL with a password or token is refused, the token never printed' { $rc -ne 0 -and $out.Contains('https://gitea.example/acme/team.git') -and -not $out.Contains('s3cr3t') }
W "$RS/mcp/m3.yaml" "command: uvx`nargs: [--index-url, `"https://PyPI.corp.example/simple`", srv]`n"
Kit check $RS
Check 'check: an MCP package index not in allowed_hosts / content_hosts is a problem' { $rc -ne 0 -and $out.Contains('pypi.corp.example 不在 allowed_hosts') }
W "$RS/kit.yaml" "name: rfsrc`ncontent_hosts: [pypi.corp.example]`n"
Kit check $RS
Check 'check: a listed package index is fine' { $rc -eq 0 }
if ($Py) {
    # origin is read over plain http from a local folder (so it is a URL, host 127.0.0.1) and pushed to that folder directly
    $PR = Join-Path $T 'rf/pr'; $PO = Join-Path $PR 'srv/acme/team.git'; $PW = Join-Path $PR 'w'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $PR 'srv/acme'))
    & git -c init.defaultBranch=master init -q --bare $PO; & git -c init.defaultBranch=master init -q $PW
    W "$PW/kit.yaml" "name: prsrc`nauthor_domains: [corp.example]`n"; W "$PW/rules/b.md" "base`n"
    & git -C $PW config user.name t; & git -C $PW config user.email me@CORP.example; & git -C $PW config core.autocrlf false
    & git -C $PW add -A; & git -C $PW commit -qm init; & git -C $PW push -q $PO master 2>$null; & git --git-dir=$PO update-server-info
    W "$PR/serve" @'
import functools, http.server, sys
s = http.server.HTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]))
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
'@
    $httpd = Start-Process -FilePath $Py -ArgumentList @('-I', "`"$PR/serve`"", "`"$PR/srv`"", "`"$PR/port`"") -PassThru -NoNewWindow
    for ($i = 0; $i -lt 120 -and -not ((Test-Path "$PR/port") -and (Get-Item "$PR/port").Length -gt 0); $i++) { Start-Sleep -Milliseconds 500 }
    & git -C $PW remote add origin "http://127.0.0.1:$((ReadT "$PR/port").Trim())/acme/team.git"; & git -C $PW config remote.origin.pushurl $PO
    W "$PW/skills/sp/SKILL.md" "---`nname: sp`ndescription: s`n---`nx`n"; W "$PW/skills/sp/my file.md" "y`n"
    Push-Location $PW
    $env:GIT_AUTHOR_EMAIL = 'x@home.example'; Kit push --dry-run; Remove-Item env:GIT_AUTHOR_EMAIL
    Check 'push: the author email git really uses (GIT_AUTHOR_EMAIL) is checked' { $rc -ne 0 -and $out.Contains('x@home.example 不是公司網域') }
    $saveApi = $env:KIT_GITEA_API; Remove-Item env:KIT_GITEA_API -ErrorAction SilentlyContinue; $env:KIT_GITEA_TOKEN = 'tok-777'
    Kit push
    Remove-Item env:KIT_GITEA_TOKEN; if ($saveApi) { $env:KIT_GITEA_API = $saveApi }
    Pop-Location
    Check "push: the PR goes to origin's default branch (master), asked from origin" { $rc -eq 0 -and $out.Contains('PR 到 master') }
    Check 'push: a file name with a space is sent' { @(& git --git-dir=$PO ls-tree -r --name-only "kit/sp-$DAY") -contains 'skills/sp/my file.md' }
    Check 'push: no token to a host this source does not list in allowed_hosts' { $out.Contains('不把 Gitea token 送過去') -and $out.Contains("開 PR：https://127.0.0.1/acme/team/compare/master...kit/sp-$DAY") -and -not $out.Contains('tok-777') }
    Check 'push: the kit branch does not track origin' { -not (& git -C $PW config "branch.kit/sp-$DAY.remote") }
    Stop-Process -Id $httpd.Id -ErrorAction SilentlyContinue
}
Set-Home $oldH

} finally { Done }
