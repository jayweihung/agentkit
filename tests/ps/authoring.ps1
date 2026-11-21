. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM
# ---------- new / diff / update / check (authoring, local only) ----------
$AU = Join-Path $T 'authoring'; $LIB = Join-Path $T 'lib'
W "$AU/kit.yaml" "name: authoring`ncontent_hosts: [gitea.example]`nrequired:`n  rules: [sec]`n"
W "$LIB/skills/foo/SKILL.md" "---`nname: foo`ndescription: foo skill`n---`nRun scripts/x.sh, see https://gitea.example/doc`n"
W "$LIB/skills/foo/scripts/x.sh" "echo hi`n"; W "$LIB/skills/foo/LICENSE" "MIT`n"; W "$LIB/skills/foo/README.md" "readme`n"
[IO.File]::WriteAllBytes("$LIB/skills/foo/logo.png", [byte[]]@(0, 1, 2)); W "$LIB/skills/foo/.git/config" "x`n"
[void](New-Item -ItemType Directory -Force -Path "$LIB/skills/foo/scripts/__pycache__"); [IO.File]::WriteAllBytes("$LIB/skills/foo/scripts/__pycache__/x.cpython-314.pyc", [byte[]]@(0, 1, 2))
W "$LIB/skills/bar/SKILL.md" "---`nname: bar`ndescription: >-`n  Use for bar.`n  Two lines # not a comment`n`nlicense: MIT`n---`nbar`n"; W "$LIB/skills/bar/run.sh" "echo no`n"
Push-Location $AU
Kit new rule sec
Check 'new rule skeleton in the folder with kit.yaml' { $rc -eq 0 -and (Get-Item "$AU/rules/sec.md").Length -gt 0 }
Kit new agent bot
Check 'new agent skeleton has frontmatter' { (ReadT "$AU/agents/bot.md").Contains("`nname: bot`n") }
Kit new skill foo --from "$LIB/skills/foo"
Check 'new --from copies md and declared scripts' { $rc -eq 0 -and (Test-Path "$AU/skills/foo/SKILL.md") -and (Test-Path "$AU/skills/foo/scripts/x.sh") }
Check 'new --from skips LICENSE, README, binaries, .git, Python caches' { -not (Test-Path "$AU/skills/foo/LICENSE") -and -not (Test-Path "$AU/skills/foo/README.md") -and -not (Test-Path "$AU/skills/foo/logo.png") -and -not (Test-Path "$AU/skills/foo/.git") -and -not (Test-Path "$AU/skills/foo/scripts/__pycache__") }
Check 'new --from reminds to delete the temp folder' { $out.Contains('記得刪掉') }
Kit new skill bar --from "$LIB/skills/bar"
Check 'undeclared extra files not copied' { -not (Test-Path "$AU/skills/bar/run.sh") }
Kit new skill foo
Check 'new refuses an existing name' { $rc -ne 0 }
Kit new skill gerrit-review
Check 'new refuses a name another source has' { $rc -ne 0 -and $out.Contains('名字重複') }
Kit new skill Bad_Name
Check 'new refuses bad names' { $rc -ne 0 }
foreach ($u in 'https://public-git.example/x/y', 'git@public-git.example:x/y.git') {
    Kit new skill zz --from $u
    Check "--from refuses $u" { $rc -ne 0 -and $out.Contains('本機') }
}
[IO.File]::AppendAllText("$LIB/skills/foo/SKILL.md", "new line`n")
Kit diff foo --from "$LIB/skills/foo"
Check 'diff shows the change' { ($out -split "`n") -contains '+new line' }
Kit update foo --from "$LIB/skills/foo"
Check 'update applies it' { $rc -eq 0 -and (ReadT "$AU/skills/foo/SKILL.md").Contains('new line') }
[IO.File]::AppendAllText("$AU/skills/foo/SKILL.md", "colleague edit`n"); [IO.File]::AppendAllText("$LIB/skills/foo/SKILL.md", "second`n")
Kit update foo --from "$LIB/skills/foo"
Check 'update stops when someone changed it' { $rc -ne 0 -and (ReadT "$AU/skills/foo/SKILL.md").Contains('colleague edit') -and $out.Contains('被改過') }
Kit update skill foo --from "$LIB/skills/foo" --force
Check 'update --force overwrites' { $rc -eq 0 -and -not (ReadT "$AU/skills/foo/SKILL.md").Contains('colleague edit') -and (ReadT "$AU/skills/foo/SKILL.md").Contains('second') }
W "$AU/agents/bot.md" "---`nname: bot`ndescription: b`nskills: [foo]`n---`nhi`n"
Kit check
Check 'check passes on clean content' { $rc -eq 0 }
[void](New-Item -ItemType Directory -Force -Path "$AU/skills/foo/scripts/__pycache__"); [IO.File]::WriteAllBytes("$AU/skills/foo/scripts/__pycache__/x.cpython-314.pyc", [byte[]]@(0, 1, 2)); [IO.File]::WriteAllBytes("$AU/skills/foo/z.pyo", [byte[]]@(0, 1, 2))
Kit check
Check 'check: Python caches (__pycache__, .pyc) are not part of a skill' { $rc -eq 0 -and -not $out.Contains('只能放文字檔') }
W "$AU/agents/bot.md" "---`nname: bot`ndescription: b`nskills: [foo, nope]`n---`nsee https://evil.example/x`n"
W "$AU/mcp/m.yaml" "command: uvx`nargs: [git+https://gitea.example/x.git]`n"
W "$AU/skills/baz/SKILL.md" "no header`n"
Copy-Item "$LIB/skills/foo/logo.png" "$AU/skills/foo/"
$linkOk = $true; try { [void](New-Item -ItemType SymbolicLink -Path "$AU/rules/link.md" -Target "$AU/kit.yaml" -ErrorAction Stop) } catch { $linkOk = $false; W "$AU/rules/link.md" "stand-in`n" }
W "$AU/skills/foo/.git/x" "x`n"; W "$AU/.gitmodules" "[submodule]`n"
W "$H/.config/agentkit/private-words.txt" "# mine`nTopSecretName`n"
[IO.File]::AppendAllText("$AU/rules/sec.md", "by topsecretname`n")
Kit check
Check 'check fails' { $rc -ne 0 }
Check 'check: missing reference' { $out.Contains('agents/bot.md: 找不到 skill:nope') }
Check 'check: url not in content_hosts' { $out.Contains('agents/bot.md:6: 網址 evil.example') }
Check 'check: mcp from git' { $out.Contains('mcp/m.yaml: MCP 只能') }
Check 'check: skill header' { $out.Contains('skills/baz/SKILL.md: 開頭要有') }
Check 'check: binary, symlink, submodule, nested git' { $out.Contains('logo.png: 只能放文字檔') -and (-not $linkOk -or $out.Contains('link.md: 不能放捷徑')) -and $out.Contains('.gitmodules: 不能用') -and $out.Contains('skills/foo/.git: 裡面不能有') }
Check 'check: private word found, never printed' { $out -match 'rules/sec\.md:\d+: 有不該公開的字' -and -not $out.Contains('runs here') }
Check 'check: counts every problem' { $out.Contains($(if ($linkOk) { 'kit check：9 個問題' } else { 'kit check：8 個問題' })) }
W "$AU/skills/gerrit-review/SKILL.md" "---`nname: gerrit-review`ndescription: x`n---`nx`n"
Kit check $AU
Check 'check: duplicate name across sources' { $out.Contains('名字重複：skill:gerrit-review') }
# a source its kit.yaml calls private (never made public): its own private words are not problems
$PV = Join-Path $T 'private-src'; New-Item -ItemType Directory -Force -Path (Join-Path $PV 'rules/topsecretname-notes') | Out-Null
W "$PV/kit.yaml" "name: pv`nprivate: true`n"; W "$PV/rules/pvr.md" "---`nname: pvr`ndescription: x`n---`nTopSecretName runs here`n"
Kit check $PV
Check 'check: private: true, its private words (content, file names) are not problems' { $rc -eq 0 -and -not $out.Contains('不該公開') }
W "$PV/kit.yaml" "name: pv`n"
Kit check $PV
Check 'check: without private: true they are' { $rc -ne 0 -and $out.Contains('rules/pvr.md:5: 有不該公開的字') -and $out.Contains('rules/topsecretname-notes: 檔名有不該公開的字') -and -not $out.Contains('runs here') }
Remove-Item -LiteralPath $PV -Recurse -Force
foreach ($x in 'skills/gerrit-review', 'skills/foo/.git', '.gitmodules', 'rules/link.md', 'skills/foo/logo.png', 'skills/baz', 'mcp', 'skills/foo/scripts/__pycache__', 'skills/foo/z.pyo') { Remove-Item -LiteralPath (Join-Path $AU $x) -Recurse -Force }
W "$AU/agents/bot.md" "---`nname: bot`ndescription: b`nskills: [foo]`n---`nhi`n"; W "$AU/rules/sec.md" "Be safe.`n"
[IO.File]::AppendAllText("$AU/kit.yaml", "author_domains: [corp.example]`n")
& git -C $AU init -q; & git -C $AU add -A; & git -C $AU -c user.name=a -c user.email=me@home.example commit -qm x
Kit check --ci
Check 'check --ci: author email must be company' { $rc -ne 0 -and $out.Contains('作者 email 不是公司網域') }
& git -C $AU -c user.name=a -c user.email=me@corp.example commit -q --amend --reset-author -m x
Kit check --ci
Check 'check --ci passes' { $rc -eq 0 }
Pop-Location

} finally { Done }
