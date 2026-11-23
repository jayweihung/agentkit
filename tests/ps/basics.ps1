. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- init ----------
Kit init $TEAM
Check 'init exit 0' { $rc -eq 0 }
Check 'include pulled third-party' { (ReadT "$H/.config/agentkit/machine.yaml").Contains($TP) }
Check 'recommended added' { (ReadT "$H/.config/agentkit/machine.yaml").Contains('added: [rule:coding-style, skill:gerrit-workflow]') }
Check 'CLAUDE.md keeps user text' { (ReadT "$H/.claude/CLAUDE.md").StartsWith("# My notes`nBe brief.`n") }
Check 'CLAUDE.md imports required rule, kit''s copy of it (forward slashes: Claude reads @C:/... not @C:\...)' { (ReadT "$H/.claude/CLAUDE.md").Contains('@' + (Join-Path $H '.config/agentkit/store/rules/security.md').Replace('\', '/').Replace(' ', '\ ')) -and (ReadT "$H/.config/agentkit/store/rules/security.md") -ceq (ReadT "$TEAM/rules/security.md") }
Check 'CLAUDE.md imports recommended rule' { (ReadT "$H/.claude/CLAUDE.md").Contains('@' + (Join-Path $H '.config/agentkit/store/rules/coding-style.md').Replace('\', '/').Replace(' ', '\ ')) }
Check 'no BOM written' { $b = [IO.File]::ReadAllBytes("$H/.claude/CLAUDE.md"); $b[0] -ne 0xEF }
Check 'third-party skill copied with LICENSE' { Test-Path "$H/.claude/skills/gerrit-workflow/LICENSE" }
Check 'own skill untouched' { (ReadT "$H/.claude/skills/my-own/SKILL.md") -eq "my own skill`n" }
Check 'deny added, user deny kept' { (Flat (JGet $settings 'permissions.deny')) -eq '["Bash(rm-rf:*)","mcp__gerrit__submit_change"]' }
Check 'settings other keys kept' { (JGet $settings 'model') -eq '"opus"' }
Check 'claude.json untouched (no mcp yet)' { SameBytes "$H/.claude.json" "$T/claude.json.orig" }
Check 'SessionStart hook added once' { $v = JGet $settings 'hooks.SessionStart'; $v.Contains('sync --hook') -and ([regex]::Matches($v, 'sync --hook')).Count -eq 1 }

# ---------- add ----------
Kit add skill gerrit-review
Check 'add skill' { Test-Path "$H/.claude/skills/gerrit-review/SKILL.md" }
Kit add mcp gerrit
Check 'mcp written' { (JGet "$H/.claude.json" 'mcpServers.gerrit.command') -eq '"uvx"' }
Check 'mcp env not expanded' { (JGet "$H/.claude.json" 'mcpServers.gerrit.env').Contains('${HOME}/.config/gerrit') }
Check 'claude.json other data kept byte for byte' { (ReadT "$H/.claude.json").Contains('"note": "中文 \"q\" <a&b>"') }
Check 'no temp files left' { @(Get-ChildItem -Force $H | Where-Object { $_.Name -like '*kit.tmp*' }).Count -eq 0 }
Kit add skill nope
Check 'add unknown fails with a message' { $rc -ne 0 -and $out.Contains('找不到 skill:nope') }

# ---------- rm ----------
Kit rm rule security
Check 'required cannot be removed' { $rc -ne 0 -and $out.Contains('團隊必備') }
Kit rm skill gerrit-workflow
Check 'rm skill deletes copy' { -not (Test-Path "$H/.claude/skills/gerrit-workflow") }
Kit sync
Check 'removed stays removed after sync' { -not (Test-Path "$H/.claude/skills/gerrit-workflow") }

# ---------- hand edits and new items ----------
[IO.File]::AppendAllText("$H/.claude/skills/gerrit-review/SKILL.md", "my change`n")
[IO.File]::AppendAllText("$TEAM/skills/gerrit-review/SKILL.md", "team change`n")
Kit sync
Check 'hand-edited skill not overwritten' { (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('my change') -and $out.Contains('手動改過') }
# look first: kit sync --dry-run lists what it would do with skills and a hash; --expect HASH does it only while that list holds
function HashOf([string]$o) { if ($o -match '--expect (\d+)') { $Matches[1] } else { '' } }
$st0 = ReadT "$H/.config/agentkit/state.tsv"
Kit sync --force --dry-run; $ph = HashOf $out
Check 'sync --force --dry-run: your edited skill backed up then replaced, a hash, nothing changed' { $rc -eq 0 -and $out.Contains('/gerrit-review：你改過的先備份，再換新的') -and $ph -and $out.Contains("kit sync --force --expect $ph") -and (ReadT "$H/.config/agentkit/state.tsv") -ceq $st0 -and -not (Test-Path "$H/.config/agentkit/backups") }
Kit sync --dry-run
Check 'sync --dry-run without --force: your edited skill skipped, another hash' { $out.Contains('/gerrit-review：你改過：跳過') -and (HashOf $out) -ne $ph }
[IO.File]::AppendAllText("$H/.claude/skills/gerrit-review/SKILL.md", "my change 2`n")
Kit sync --force --expect $ph
Check 'sync --expect: you changed the skill after --dry-run: nothing changed, says look again' { $rc -ne 0 -and $out.Contains('清單跟 --dry-run') -and (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('my change 2') -and -not (Test-Path "$H/.config/agentkit/backups") }
Kit sync --dry-run --expect 1
Check 'sync: --dry-run with --expect: usage' { $rc -ne 0 -and $out.Contains('不能一起用') }
Kit sync --force --dry-run; $ph = HashOf $out
Kit sync --force --expect $ph
Check '--force overwrites' { (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('team change') }
function BackupHas([string]$name, [string]$text) { @(Get-ChildItem -Path "$H/.config/agentkit/backups/skills" -Filter "$name-*" -Directory -ErrorAction SilentlyContinue | Where-Object { (ReadT (Join-Path $_.FullName 'SKILL.md')).Contains($text) }).Count -gt 0 }
Check '--force keeps your edit as a backup (outside the skills folder)' { BackupHas 'gerrit-review' 'my change' }
# Python's caches (written next to a skill's scripts when they run) are not part of the skill: not a hand edit, not copied
$G = "$H/.claude/skills/gerrit-review"
[void](New-Item -ItemType Directory -Force -Path "$G/scripts/__pycache__", "$TEAM/skills/gerrit-review/scripts/__pycache__")
[IO.File]::WriteAllBytes("$G/scripts/__pycache__/x.cpython-314.pyc", [byte[]]@(0, 1, 2)); [IO.File]::WriteAllBytes("$G/y.pyc", [byte[]]@(0, 1, 2))
[IO.File]::WriteAllBytes("$TEAM/skills/gerrit-review/scripts/__pycache__/x.cpython-314.pyc", [byte[]]@(0, 1, 2))
Kit sync
Check 'python caches in a skill''s copy: not a hand edit' { -not $out.Contains('手動改過') }
[IO.File]::AppendAllText("$TEAM/skills/gerrit-review/SKILL.md", "team change 2`n")
Kit sync
Check '... the skill still updates; the source''s caches are not copied' { (ReadT "$G/SKILL.md").Contains('team change 2') -and -not (Test-Path "$G/scripts/__pycache__") -and -not $out.Contains('手動改過') }
Remove-Item -LiteralPath "$TEAM/skills/gerrit-review/scripts" -Recurse -Force
# the copy already became the source's new version some other way: not a hand edit, kit's again
[IO.File]::AppendAllText("$TEAM/skills/gerrit-review/SKILL.md", "team change 3`n"); Copy-Item -LiteralPath "$TEAM/skills/gerrit-review/SKILL.md" -Destination "$G/SKILL.md" -Force
Kit sync
Check 'a copy that already equals the source''s new version: not a hand edit, kit''s again' { -not $out.Contains('手動改過') -and (ReadT "$G/SKILL.md").Contains('team change 3') }
Kit sync
Check '... and the next sync is quiet about it too' { -not $out.Contains('手動改過') }
W "$TEAM/skills/team-build/SKILL.md" "---`nname: team-build`ndescription: b`n---`nx`n"
Kit sync
Check 'new item announced' { $out.Contains('新： skill:team-build') }
Kit sync
Check 'announced only once' { -not $out.Contains('新：') }
# a skill you changed is never deleted: kit rm keeps it (yours from then on), sync --force backs it up first
Kit add skill team-build
[IO.File]::AppendAllText("$H/.claude/skills/team-build/SKILL.md", "my build`n")
Kit rm skill team-build
Check 'rm of a hand-edited skill: kept, kit says so' { (ReadT "$H/.claude/skills/team-build/SKILL.md").Contains('my build') -and $out.Contains('沒有刪') }
Kit sync --force
Check '... yours from then on: sync --force leaves it, says nothing' { (ReadT "$H/.claude/skills/team-build/SKILL.md").Contains('my build') -and -not $out.Contains('team-build') }
Remove-Item -LiteralPath "$H/.claude/skills/team-build" -Recurse -Force
Kit add skill team-build
[IO.File]::AppendAllText("$H/.claude/skills/team-build/SKILL.md", "my build 2`n")
$M = "$H/.config/agentkit/machine.yaml"
W $M (((ReadT $M) -split "`n" | ForEach-Object { if ($_ -like 'added:*') { $_ -replace ', skill:team-build|skill:team-build, |skill:team-build', '' } else { $_ } }) -join "`n")
Kit sync --force
Check 'taken out + sync --force: the copy goes, your edit kept as a backup' { -not (Test-Path "$H/.claude/skills/team-build") -and (BackupHas 'team-build' 'my build 2') -and $out.Contains('備份在') }

# ---------- a skill folder that is not kit's ----------
W "$TEAM/skills/clash/SKILL.md" "---`nname: clash`ndescription: team`n---`nteam clash`n"; W "$H/.claude/skills/clash/SKILL.md" "mine`n"
Kit add skill clash
Check "someone else's skill folder: backed up, then kit's" { $out.Contains('不是 kit 放的：備份在') -and (BackupHas 'clash' 'mine') -and (ReadT "$H/.claude/skills/clash/SKILL.md").Contains('team clash') }
Kit sync
Check "... once: kit's from then on" { -not $out.Contains('不是 kit 放的') }
Remove-Item -Recurse -Force "$TEAM/skills/clash"; Kit rm skill clash
Check 'rm: one the account has, though no source has it any more' { $rc -eq 0 -and -not $out.Contains('找不到') }

# ---------- list ----------
Kit list
Check 'list marks required' { $out -match '(?m)^R  rule:security' }
Check 'list marks in use' { $out -match '(?m)^\*  skill:gerrit-review' }
Check 'list shows unused' { $out -match '(?m)^   skill:gerrit-workflow' }
Check 'list shows agent' { $out.Contains('agent:gerrit') }
Check 'list shows targets (Claude only here)' { $out -match '(?m)^寫到：Claude$' }

} finally { Done }
