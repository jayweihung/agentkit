. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
W "$H/.config/agentkit/private-words.txt" "# mine`nTopSecretName`n"
# ---------- export-self (a fake kit repo; the private word list of this home is still set) ----------
$FK = Join-Path $T 'fakekit'; $EX = Join-Path $T 'export'; $EX2 = Join-Path $T 'export2'
foreach ($f in 'unix/kit', 'unix/json.awk', 'unix/yaml.awk', 'windows/kit.ps1') { [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent "$FK/$f")); Copy-Item (Join-Path $Repo $f) "$FK/$f" }
W "$FK/VERSION" "0.3.0`n"; W "$FK/README.md" "# kit`n"; W "$FK/CHANGELOG.md" "notes`n"; W "$FK/LICENSE" "MIT`n"; W "$FK/.github/workflows/ci.yml" "on: push`n"
W "$FK/tests/t.sh" "echo test`n"; W "$FK/.gitattributes" "* text=auto`n"; W "$FK/.gitignore" "*.tmp`n"; W "$FK/docs/guide.md" "guide`n"
W "$FK/private-words.txt" "repoword`n"
function FkCommit { & git -C $FK add -A 2>$null; & git -C $FK -c user.name=t -c user.email=t@t -c core.autocrlf=false commit -qm x 2>$null | Out-Null }
& git -C $FK init -q; FkCommit
W "$FK/untracked.md" "not tracked`n"
$saveKit = $Kit; $Kit = "$FK/windows/kit.ps1"
Kit export-self $EX --version 0.4.0+gitea.12
Check 'export-self succeeds, says the commit message' { $rc -eq 0 -and $out.Contains('kit 0.4.0+gitea.12') }
Check 'export-self drops CHANGELOG, LICENSE, .github, private-words.txt; keeps README (the manual)' { (Test-Path "$EX/README.md") -and -not (Test-Path "$EX/LICENSE") -and -not (Test-Path "$EX/CHANGELOG.md") -and -not (Test-Path "$EX/.github") -and -not (Test-Path "$EX/private-words.txt") }
Check 'export-self keeps tests, .gitattributes, .gitignore, kit' { (Test-Path "$EX/tests/t.sh") -and (Test-Path "$EX/.gitattributes") -and (Test-Path "$EX/.gitignore") -and (Test-Path "$EX/unix/kit") -and (Test-Path "$EX/windows/kit.ps1") }
Check 'export-self leaves out untracked files' { -not (Test-Path "$EX/untracked.md") }
Check 'export-self writes VERSION' { (ReadT "$EX/VERSION") -eq "0.4.0+gitea.12`n" }
Check 'export-self INSTALL.md, no URL' { $m = ReadT "$EX/INSTALL.md"; $m.Contains('sh unix/install.sh') -and $m.Contains('windows\install.ps1') -and $m -notmatch '://|@[A-Za-z0-9.-]+:' }
Check 'export-self INSTALL.md: first use is docs/company.md, the manual README.md' { $m = ReadT "$EX/INSTALL.md"; $m.Contains('照 docs/company.md 從頭做一次') -and $m.Contains('用法看 README.md') }
Kit export-self $EX
Check 'export-self stops when the folder is not empty' { $rc -ne 0 -and $out.Contains('不是空的') -and (Test-Path "$EX/VERSION") }
$gh = 'github' + '.com'
[void](New-Item -ItemType Directory -Path $EX2); [IO.File]::AppendAllText("$FK/docs/guide.md", "see https://$gh/x`n"); FkCommit
Kit export-self $EX2
Check 'export-self: GitHub word fails, folder deleted' { $rc -ne 0 -and $out.Contains('docs/guide.md:2: 有 GitHub 的字') -and -not (Test-Path $EX2) }
W "$FK/docs/guide.md" "guide`n"; W "$FK/tests/t.sh" "by TopSecretName`n"; W "$FK/docs/my-repoword.md" "x`n"; [IO.File]::WriteAllBytes("$FK/docs/logo.png", [byte[]]@(0, 1)); FkCommit
Kit export-self $EX2
Check "export-self: private words (this machine and the repo's list), file names, binaries" { $rc -ne 0 -and $out.Contains('tests/t.sh:1: 有不該公開的字') -and $out.Contains('docs/<不公開>: 檔名有不該公開的字') -and $out.Contains('docs/logo.png: 只能放文字檔') -and -not (Test-Path $EX2) }
Check 'export-self never prints the private word' { $out -notmatch '(?i)topsecret|repoword' }
& git -C $FK rm -q docs/my-repoword.md docs/logo.png; W "$FK/tests/t.sh" "echo test`n"; FkCommit
W "$T/inst/lib/.repo" $FK; Copy-Item (Join-Path $Repo 'windows/kit.ps1') "$T/inst/lib/kit.ps1"
$Kit = "$T/inst/lib/kit.ps1"
Kit export-self $EX2
Check 'export-self from an installed kit uses the clone in .repo' { $rc -eq 0 -and (ReadT "$EX2/VERSION") -eq "0.3.0`n" -and (Test-Path "$EX2/docs/guide.md") }
$Kit = $saveKit

} finally { Done }
