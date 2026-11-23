. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- collect / outdated (other people's skills; a local repo plays the author) ----------
function FileUrl([string]$p) { $p = $p.Replace('\', '/'); if ($p.StartsWith('/')) { "file://$p" } else { "file:///$p" } }
function G { & git @args 2>&1 | Out-Null }
$UP = Join-Path $T 'upstream'; $CO = Join-Path $T 'collector'; $NL = Join-Path $T 'nolic'
W "$UP/skills/foo/SKILL.md" "---`nname: foo`ndescription: >-`n  Upstream foo.`n---`nfoo v1`n"
W "$UP/skills/foo/scripts/run.sh" "echo hi`n"; W "$UP/skills/foo/.github/ci.yml" "x`n"
[IO.File]::WriteAllBytes("$UP/skills/foo/logo.png", [byte[]](0, 1))
$haveLink = $true; try { [void](New-Item -ItemType SymbolicLink -Path "$UP/skills/foo/link.md" -Target 'SKILL.md' -ErrorAction Stop) } catch { $haveLink = $false }
W "$UP/LICENSE" "MIT License`n`nPermission is hereby granted, free of charge, ...`n"
foreach ($r in $UP, $NL) { if ($r -eq $NL) { W "$NL/skills/bar/SKILL.md" "---`nname: bar`ndescription: b`n---`nb`n" }; G -C $r init -q; G -C $r config user.name a; G -C $r config user.email a@a; G -C $r add -A; G -C $r commit -qm v1 }
W "$CO/kit.yaml" "name: collector`ncollect_sources: [$(FileUrl $UP), $(FileUrl $NL)]`n"
Push-Location $CO
Kit collect (FileUrl $UP) --path skills/foo
Check "collect copies the skill with the repo's LICENSE" { $rc -eq 0 -and (Test-Path "$CO/skills/foo/SKILL.md") -and (ReadT "$CO/skills/foo/LICENSE") -match 'MIT License' -and (Test-Path "$CO/skills/foo/scripts/run.sh") }
Check 'collect skips binaries, links and dot folders' { -not (Test-Path "$CO/skills/foo/logo.png") -and -not (Test-Path "$CO/skills/foo/link.md") -and -not (Test-Path "$CO/skills/foo/.github") }
Check 'collect points at files that run' { $out -match '會執行的檔案' -and $out -match 'scripts/run.sh' }
$v1 = "$(& git -C $UP rev-parse HEAD)".Trim()
Check 'third_party.lock records author, commit, license' { @((ReadT "$CO/third_party.lock") -split "`n" | Where-Object { $f = $_.Split("`t"); $f[0] -eq 'foo' -and $f[1] -eq (FileUrl $UP) -and $f[2] -eq 'skills/foo' -and $f[4] -eq $v1 -and $f[5] -eq 'MIT' }).Count -eq 1 }
$ud = "$(& git -C $UP log -1 --format=%cd --date=short)".Trim()
function Lock-Foo { @((ReadT "$CO/third_party.lock") -split "`n" | Where-Object { $_.StartsWith("foo`t") })[0].Split("`t") }
Check "third_party.lock: the upstream commit's own date (column 9; column 8, skip, is - for a skill)" { $f = Lock-Foo; $f.Count -eq 9 -and $f[7] -ceq '-' -and $f[8] -ceq $ud }
# a line from before kit 0.9.0 (7 columns): kit collect --dates asks the author for that commit's date
$lock7 = ((ReadT "$CO/third_party.lock") -split "`n" | ForEach-Object { if ($_ -and -not $_.StartsWith('#')) { ($_.Split("`t")[0..6]) -join "`t" } else { $_ } }) -join "`n"
W "$CO/third_party.lock" $lock7
Kit collect --dates
Check 'collect --dates: fills in the date from the author''s repo' { $f = Lock-Foo; $rc -eq 0 -and $f.Count -eq 9 -and $f[7] -ceq '-' -and $f[8] -ceq $ud -and $out.Contains('補了 1 個日期') }
Kit collect --dates
Check 'collect --dates: nothing left to ask' { $out.Contains('補了 0 個日期') }
W "$CO/third_party.lock" $lock7; Rename-Item -LiteralPath $UP 'upstream-away'; Kit collect --dates; Rename-Item -LiteralPath (Join-Path $T 'upstream-away') 'upstream'
Check 'collect --dates: an author gone: left empty, said so' { (Lock-Foo).Count -eq 7 -and $out.Contains('foo：問不到') }
Kit collect (FileUrl "$T/elsewhere")
Check 'collect refuses authors not in collect_sources' { $rc -ne 0 -and $out -match '不在 collect_sources' }
Kit collect (FileUrl $NL) --path skills/bar
Check 'collect refuses a repo without a license' { $rc -ne 0 -and $out -match '沒有 LICENSE' -and -not (Test-Path "$CO/skills/bar") }
W "$CO/skills/own/SKILL.md" "---`nname: own`ndescription: mine`n---`nmine`n"
Kit collect (FileUrl $UP) --path skills/foo --name own
Check 'collect will not replace your own skill without --force' { $rc -ne 0 -and (ReadT "$CO/skills/own/SKILL.md") -match 'mine' }
Remove-Item -Recurse -Force "$CO/skills/own"
Kit outdated
Check 'outdated: up to date' { $out -match 'foo：最新' }
Add-Content -LiteralPath "$UP/NOTES.md" 'notes'; G -C $UP add NOTES.md; G -C $UP commit -qm notes
Kit outdated
Check "outdated: a commit elsewhere in the author's repo is not a new foo" { $out -match 'foo：最新（原作者改的是 repo 裡別的地方' }
Kit outdated --json
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'outdated --json: the same, latest (now: the author''s commit)' { $j -and $j.skills[0].commit -eq $v1 -and $j.skills[0].now -eq "$(& git -C $UP rev-parse HEAD)".Trim() -and $j.skills[0].state -eq 'latest' }
$lic0 = [IO.File]::ReadAllText("$UP/LICENSE"); [IO.File]::WriteAllText("$UP/LICENSE", 'MIT, changed'); G -C $UP commit -qam license
Kit outdated
Check "outdated: the author's license changed: a new version" { $out -match 'foo：有新版本' }
[IO.File]::WriteAllText("$UP/LICENSE", $lic0); G -C $UP commit -qam 'license back'
$src = [IO.File]::ReadAllText($Kit); $i = $src.IndexOf('function Web-Repo'); Invoke-Expression $src.Substring($i, $src.IndexOf('function Cmd-Collect') - $i)
Check "a repo page's address: the repo, its branch and folder (GitHub tree / blob, GitLab, Gitea); a repo URL: nothing" { ((Web-Repo 'https://git.example.org/a/r/tree/main/skills/tdd/') -join '|') -eq 'https://git.example.org/a/r|main|skills/tdd' -and ((Web-Repo 'https://git.example.org/a/r/blob/v1/x/SKILL.md?plain=1') -join '|') -eq 'https://git.example.org/a/r|v1|x' -and ((Web-Repo 'https://gitlab.com/a/r/-/tree/dev') -join '|') -eq 'https://gitlab.com/a/r|dev|' -and ((Web-Repo 'https://git.example.org/a/r/src/branch/main/s') -join '|') -eq 'https://git.example.org/a/r|main|s' -and $null -eq (Web-Repo 'https://git.example.org/a/r') }
Add-Content -LiteralPath "$UP/skills/foo/SKILL.md" 'foo v2'; G -C $UP commit -qam v2
Kit outdated
Check 'outdated: new version upstream' { $out -match 'foo：有新版本' -and $out -match 'kit collect foo' }
Kit outdated --json
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'outdated --json: foo new, both commits' { $rc -eq 0 -and $j -and @($j.skills).Count -eq 1 -and $j.skills[0].name -eq 'foo' -and $j.skills[0].source -eq 'collector' -and $j.skills[0].path -eq 'skills/foo' -and $j.skills[0].commit -eq $v1 -and $j.skills[0].now -eq "$(& git -C $UP rev-parse HEAD)".Trim() -and $j.skills[0].state -eq 'new' }
Rename-Item -LiteralPath $UP 'upstream-away'; Kit outdated --json; Rename-Item -LiteralPath (Join-Path $T 'upstream-away') 'upstream'
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'outdated --json: an author gone is unreachable' { $j -and $j.skills[0].state -eq 'unreachable' -and $j.skills[0].now -eq '' }
Add-Content -LiteralPath "$CO/skills/foo/SKILL.md" 'local edit'
Kit collect foo
$v2 = "$(& git -C $UP rev-parse HEAD)".Trim()
Check 'collect <name> replaces the whole copy with the new version' { $l = ReadT "$CO/third_party.lock"; $s = ReadT "$CO/skills/foo/SKILL.md"; $rc -eq 0 -and $s -match 'foo v2' -and $s -notmatch 'local edit' -and $l.Contains($v2) -and @($l -split "`n" | Where-Object { $_ -like "foo`t*" }).Count -eq 1 }
G -C $UP tag -a v1.0 -m rel; Add-Content -LiteralPath "$UP/skills/foo/SKILL.md" 'foo v3'; G -C $UP commit -qam v3
Kit collect foo --ref v1.0
Check 'collect --ref takes a tag' { $rc -eq 0 -and (ReadT "$CO/skills/foo/SKILL.md") -notmatch 'foo v3' }
Kit outdated
Check 'outdated follows the tag, not the branch' { $out -match 'foo：最新' }
Kit outdated --json
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'outdated --json: the tag, latest' { $j -and $j.skills[0].ref -eq 'v1.0' -and $j.skills[0].state -eq 'latest' }
Add-Content -LiteralPath "$CO/kit.yaml" 'maintainers: [someone-else]'
Kit collect foo
Check 'only maintainers may collect' { $rc -ne 0 -and $out -match '維護者' }
Kit outdated --json
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'outdated --json: not a maintainer, nothing listed (no error)' { $rc -eq 0 -and $j -and @($j.skills).Count -eq 0 }
Pop-Location
# no --path: the only SKILL.md in the repo; several: kit lists them; --look says it all as JSON without writing anything
$U2 = Join-Path $T 'up-two'; $U1 = Join-Path $T 'up-one'
foreach ($x in 'a', 'b', '.hidden/c', 'node_modules/d') { $n = Split-Path -Leaf $x; W "$U2/$x/SKILL.md" "---`nname: $n`ndescription: say `"$n`" now`n---`nx`n" }
W "$U2/a/run.sh" "echo`n"; W "$U2/LICENSE" (ReadT "$UP/LICENSE")
W "$U1/deep/one/SKILL.md" "---`nname: one`ndescription: o`n---`nx`n"; W "$U1/LICENSE" (ReadT "$UP/LICENSE")
foreach ($r in $U2, $U1) { G -C $r init -q; G -C $r config user.name a; G -C $r config user.email a@a; G -C $r add -A; G -C $r commit -qm x }
W "$CO/kit.yaml" "name: collector`ncollect_sources: [$(FileUrl $U2), $(FileUrl $U1)]`n"
Remove-Item -Recurse -Force "$CO/skills/foo", "$CO/third_party.lock"
Push-Location $CO
Kit collect (FileUrl $U1)
Check 'collect without --path finds the only SKILL.md' { $rc -eq 0 -and (Test-Path "$CO/skills/one/SKILL.md") -and (ReadT "$CO/third_party.lock") -match "(?m)^one`t[^`t]*`tdeep/one`t" }
Kit collect (FileUrl $U2)
Check 'collect without --path, several skills: lists them, collects nothing' { $rc -ne 0 -and $out -match '(?m)^\s+a\s*$' -and $out -match '(?m)^\s+b\s*$' -and $out -notmatch 'hidden' -and -not (Test-Path "$CO/skills/a") }
$before = @(Get-ChildItem -Recurse -File $CO | ForEach-Object { "$($_.FullName) $($_.Length)" }) -join '|'
Kit collect (FileUrl $U2) --look
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'collect --look: every skill, as JSON' { $rc -eq 0 -and $j.allowed -eq $true -and $j.can_allow -eq $false -and (@($j.skills | ForEach-Object { "$($_.path),$($_.name),$($_.description),$($_.license),$($_.scripts),$($_.exists)" }) -join ';') -eq 'a,a,say "a" now,MIT,run.sh,;b,b,say "b" now,MIT,,' }
Check 'collect --look writes nothing' { $before -eq (@(Get-ChildItem -Recurse -File $CO | ForEach-Object { "$($_.FullName) $($_.Length)" }) -join '|') }
Kit collect (FileUrl $UP) --look
Check 'collect --look on an author not on the list of a team source (no --allow): says so, downloads nothing' { $rc -ne 0 -and $out.Contains('不在 collect_sources') -and $out.Contains('不下載') -and -not $out.Contains('"skills"') }
Kit collect (FileUrl $UP) --path skills/foo --allow
Check 'collect --allow refused in a team source (no push: direct)' { $rc -ne 0 -and $out -match 'push: direct' -and -not (Test-Path "$CO/skills/foo") }
# (allowed_hosts listed: a file:/// folder on this machine has no host, so it is not refused)
W "$CO/kit.yaml" "name: collector`npush: direct`nallowed_hosts: [gitea.example]`ncollect_sources: [$(FileUrl $U2)]   # authors`n"
Kit collect (FileUrl $UP) --look
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'collect --look: your own source can add the author' { $j.can_allow -eq $true }
Kit collect (FileUrl $UP)
Check 'collect without --allow says how to add the author' { $rc -ne 0 -and $out -match '--allow' }
Kit collect (FileUrl $UP) --allow
$id = (FileUrl $UP) -replace '^file://', ''
Check 'collect --allow: collected, the author added to the list on its line' { $rc -eq 0 -and (Test-Path "$CO/skills/foo/SKILL.md") -and (ReadT "$CO/kit.yaml").Contains("collect_sources: [$(FileUrl $U2), $id]   # authors") }
Kit collect foo
Check 'after --allow the author is on the list' { $rc -eq 0 }
W "$CO/kit.yaml" "name: collector`npush: direct`ncollect_sources:`n    - $(FileUrl $U2)`n`n# more`nrecommended:`n  rules: []`n"
Kit collect (FileUrl $U1) --allow
$id1 = (FileUrl $U1) -replace '^file://', ''
Check 'collect --allow: a - list gets a - line' { $l = (ReadT "$CO/kit.yaml") -split "`n"; $rc -eq 0 -and $l[3] -eq "    - $(FileUrl $U2)" -and $l[4] -eq "    - $id1" -and ($l -contains 'recommended:') }
W "$CO/kit.yaml" "name: collector`npush: direct"
Remove-Item -Recurse -Force "$CO/skills/one"
Kit collect (FileUrl $U1) --allow
Check 'collect --allow: no list yet gets one' { $l = @((ReadT "$CO/kit.yaml").TrimEnd("`n") -split "`n"); $rc -eq 0 -and $l[-1] -eq "collect_sources: [$id1]" -and ($l -contains 'push: direct') }
# the host must be in allowed_hosts (the source's own list, else every source's): --look and collect never go elsewhere
W "$CO/kit.yaml" "name: collector`npush: direct`nallowed_hosts: [gitea.example]`ncollect_sources: [https://public-git.example/someone]`n"
Kit collect https://public-git.example/someone/skills --look
Check 'collect --look: a host outside allowed_hosts is refused before anything is downloaded' { $rc -ne 0 -and $out.Contains('public-git.example 不在允許的主機清單') -and -not $out.Contains('沒辦法下載') }
Kit collect https://public-git.example/someone/skills
Check 'collect: a host outside allowed_hosts is refused (the same list)' { $rc -ne 0 -and $out.Contains('public-git.example 不在允許的主機清單') -and -not $out.Contains('沒辦法下載') }
Pop-Location


} finally { Done }
