# End-to-end tests for the Windows kit (kit.ps1). Everything runs in a
# throwaway home folder, so your real ~/.claude is never touched.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
# Works with Windows PowerShell 5.1 and PowerShell 7 (also on macOS/Linux).
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path variable:IsWindows) -and $IsWindows)
$Here = Split-Path -Parent $PSCommandPath
$Repo = Split-Path -Parent $Here
$Kit = Join-Path $Repo 'windows/kit.ps1'
$Exe = (Get-Process -Id $PID).Path
$U8 = New-Object System.Text.UTF8Encoding $false
$T = Join-Path ([IO.Path]::GetTempPath()) ('kit-test.' + [IO.Path]::GetRandomFileName())
$script:pass = 0; $script:fail = 0

function W([string]$path, [string]$text) { [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)); [IO.File]::WriteAllText($path, $text, $U8) }
function ReadT([string]$path) { [IO.File]::ReadAllText($path, $U8) }
function Check([string]$name, [scriptblock]$test) {
    $ok = $false; try { $ok = [bool](& $test) } catch { $ok = $false }
    if ($ok) { $script:pass++ } else { $script:fail++; [Console]::WriteLine("FAIL: $name") }
}
function Set-Home([string]$h) {
    [void](New-Item -ItemType Directory -Force -Path $h)
    $env:HOME = $h; $env:USERPROFILE = $h; $script:H = $h
}
function Kit {   # run kit in a new process; output (stdout+stderr) in $script:out, exit code in $script:rc
    $script:out = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit @args 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $script:rc = $LASTEXITCODE
}
function JGet([string]$file, [string]$path) {
    $o = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __json-get $file $path 2>$null | ForEach-Object { "$_" }) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $null }; $o
}
function Flat([string]$s) { if ($null -eq $s) { return $null }; ($s -replace '\s', '') }
function SameBytes([string]$a, [string]$b) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($a)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($b)) }

foreach ($v in 'CLAUDE_CONFIG_DIR', 'AGENTKIT_CONFIG', 'AGENTKIT_SOURCES', 'CODEX_HOME', 'PI_CODING_AGENT_DIR', 'KIT_DRY_RUN') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
# Codex/omp are only written when found; hide installed ones for the Claude-only part
$savedPath = $env:PATH
$sep = [IO.Path]::PathSeparator
$env:PATH = (@($env:PATH.Split($sep) | Where-Object { -not ((Test-Path (Join-Path $_ 'codex')) -or (Test-Path (Join-Path $_ 'codex.cmd')) -or (Test-Path (Join-Path $_ 'codex.exe')) -or (Test-Path (Join-Path $_ 'omp')) -or (Test-Path (Join-Path $_ 'omp.exe'))) })) -join $sep

try {
# ---------- fixture sources ----------
$TP = Join-Path $T 'third-party'; $TEAM = Join-Path $T 'team'
W "$TP/skills/gerrit-workflow/SKILL.md" "---`nname: gerrit-workflow`ndescription: upstream`n---`nupstream body`n"
W "$TP/skills/gerrit-workflow/LICENSE" "Apache-2.0`n"
W "$TEAM/kit.yaml" @"
name: team
include: [$TP]
allowed_hosts: [gitea.example]
required:
  rules: [security]
  tools:
    deny: [mcp__gerrit__submit_change]
recommended:
  rules:  [coding-style]
  skills: [gerrit-workflow]
"@
W "$TEAM/rules/security.md" "Never paste secrets.`n"
W "$TEAM/rules/coding-style.md" "Use 4 spaces.`n"
W "$TEAM/rules/gerrit-flow.md" "Only comment, never submit.`n"
W "$TEAM/skills/gerrit-review/SKILL.md" "---`nname: gerrit-review`ndescription: review a change`n---`nhow to review`n"
W "$TEAM/mcp/gerrit.yaml" @'
name: gerrit
command: uvx
args: [--index-url, "https://pypi.example/simple", gerrit-mcp-server==1.0]
env:
  GERRIT_CONFIG: ${HOME}/.config/gerrit/gerrit_config.json   # expanded by Claude, not kit
'@
W "$TEAM/agents/gerrit.md" @'
---
name: gerrit
description: Gerrit helper
rules:  [gerrit-flow]
skills: [gerrit-review]
mcp:    [gerrit]
tools:
  only: [Read, Grep, Glob]
  deny: [mcp__gerrit__submit_change]
---
You are the Gerrit helper.
'@

# ---------- the user's own files, which kit must keep ----------
Set-Home (Join-Path $T 'home')
W "$H/.claude/skills/my-own/SKILL.md" "my own skill`n"
W "$H/.claude/CLAUDE.md" "# My notes`nBe brief.`n"
W "$H/.claude/settings.json" "{`n  `"model`": `"opus`",`n  `"permissions`": {`n    `"deny`": [`n      `"Bash(rm -rf:*)`"`n    ]`n  }`n}`n"
W "$H/.claude.json" "{`n  `"numStartups`": 5,`n  `"projects`": {`n    `"/x`": {`n      `"note`": `"中文 \`"q\`" <a&b>`"`n    }`n  }`n}"
Copy-Item "$H/.claude.json" "$T/claude.json.orig"
$settings = "$H/.claude/settings.json"

# ---------- init ----------
Kit init $TEAM
Check 'init exit 0' { $rc -eq 0 }
Check 'include pulled third-party' { (ReadT "$H/.config/agentkit/machine.yaml").Contains($TP) }
Check 'recommended added' { (ReadT "$H/.config/agentkit/machine.yaml").Contains('added: [rule:coding-style, skill:gerrit-workflow]') }
Check 'CLAUDE.md keeps user text' { (ReadT "$H/.claude/CLAUDE.md").StartsWith("# My notes`nBe brief.`n") }
Check 'CLAUDE.md imports required rule' { (ReadT "$H/.claude/CLAUDE.md").Contains("@$(Join-Path $TEAM 'rules/security.md')") }
Check 'CLAUDE.md imports recommended rule' { (ReadT "$H/.claude/CLAUDE.md").Contains("@$(Join-Path $TEAM 'rules/coding-style.md')") }
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
Kit sync --force
Check '--force overwrites' { (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('team change') }
W "$TEAM/skills/team-build/SKILL.md" "---`nname: team-build`ndescription: b`n---`nx`n"
Kit sync
Check 'new item announced' { $out.Contains('新： skill:team-build') }
Kit sync
Check 'announced only once' { -not $out.Contains('新：') }

# ---------- list ----------
Kit list
Check 'list marks required' { $out -match '(?m)^R  rule:security' }
Check 'list marks in use' { $out -match '(?m)^\*  skill:gerrit-review' }
Check 'list shows unused' { $out -match '(?m)^   skill:gerrit-workflow' }
Check 'list shows agent' { $out.Contains('agent:gerrit') }
Check 'list shows targets (Claude only here)' { $out -match '(?m)^寫到：Claude$' }

# ---------- kit_version: tell once when the team wants a newer kit ----------
$teamYaml = ReadT "$TEAM/kit.yaml"
function Team-Version([string]$v) { W "$TEAM/kit.yaml" ($teamYaml.TrimEnd("`n") + "`nkit_version: $v`n") }
function State-Nag { @((ReadT "$H/.config/agentkit/state.tsv") -split "`n" | Where-Object { $_.StartsWith("nag`t") }).Count }
Team-Version '0.4.0'
Kit sync
Check 'old kit: sync tells the user' { $out.Contains('團隊要 kit 0.4.0 以上，你的是 0.1.0。請打  kit self-update') }
Kit sync; $o1 = $out; Kit list
Check 'old kit: told only once' { -not ($o1 + $out).Contains('團隊要') }
Team-Version '0.10.0'
Kit list
Check 'team version changed: list tells again (numbers, not text)' { $out.Contains('團隊要 kit 0.10.0 以上') }
$realKit = $Kit; $Kit = Join-Path $T 'dev/windows/kit.ps1'
W $Kit ''; Copy-Item -LiteralPath $realKit -Destination $Kit -Force
Team-Version '0.6.0'
Kit sync
Check 'dev build (no VERSION) is not told' { -not $out.Contains('團隊要') }
W "$T/dev/VERSION" "0.6.0+local`n"; Kit sync
Check '+build part ignored' { -not $out.Contains('團隊要') }
W "$T/dev/VERSION" "0.5.9`n"; Kit sync
Check 'older patch level is told' { $out.Contains('團隊要 kit 0.6.0 以上，你的是 0.5.9') }
W "$T/dev/VERSION" "0.6.0`n"; Kit sync
Check 'new enough: note forgotten' { (State-Nag) -eq 0 }
$Kit = $realKit
# kit_version 0.6.0 stays for the background sync below

# ---------- ci-template ----------
Kit ci-template
$tmpl = (ReadT (Join-Path $Repo 'templates/gitea-kit-check.yaml')).Replace("`r", '').TrimEnd("`n")   # output lines are joined with LF
Check 'ci-template prints the template' { $rc -eq 0 -and $out -ceq $tmpl }
Kit ci-template "$T/ci/.gitea/workflows/kit-check.yaml"
Check 'ci-template writes a file (no BOM)' { SameBytes "$T/ci/.gitea/workflows/kit-check.yaml" (Join-Path $Repo 'templates/gitea-kit-check.yaml') }

# ---------- run (dry run: show the claude command) ----------
$env:KIT_DRY_RUN = '1'; Kit run gerrit --model sonnet; Remove-Item env:KIT_DRY_RUN
$lines = $out -split "`n"
$tmp = ($lines | Where-Object { $_.StartsWith('tmp=') } | Select-Object -First 1).Substring(4)
Check 'run passes --tools' { $lines -contains 'Read,Grep,Glob' }
Check 'run passes deny' { $lines -contains 'mcp__gerrit__submit_change' }
Check 'run keeps user args' { $lines -contains 'sonnet' }
Check 'run skill in temp dir' { Test-Path (Join-Path $tmp '.claude/skills/gerrit-review/SKILL.md') }
Check 'run prompt has rule and body' { $p = ReadT (Join-Path $tmp 'prompt.md'); $p.Contains('Only comment') -and $p.Contains('Gerrit helper') -and -not ($p -match '(?m)^name:') }
Check 'run mcp json valid' { (JGet (Join-Path $tmp 'mcp.json') 'mcpServers.gerrit.command') -eq '"uvx"' }
Remove-Item -Recurse -Force $tmp

function Lines-After($key) { $script:lines | Where-Object { $_.StartsWith($key) } | Select-Object -First 1 | ForEach-Object { $_.Substring($key.Length) } }
function Untoml([string]$v) { [regex]::Replace($v.Replace('\"', '"').Trim('"'), '\\u([0-9A-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) }) }
$env:KIT_DRY_RUN = '1'; Kit run gerrit --tool codex exec; Remove-Item env:KIT_DRY_RUN
$lines = $out -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$tmp = Lines-After 'tmp='
$dev = Lines-After 'developer_instructions='; $srv = Lines-After 'mcp_servers.gerrit='
Check 'codex run: one safe argument (no space or bare quote)' { $dev -and -not ($dev -match '\s') -and -not ($dev.Replace('\"', '') -match '"') -and -not ($srv -match '\s') }
Check 'codex run: instructions decode to the prompt' { (Untoml $dev) -eq (ReadT (Join-Path $tmp 'prompt.md')) }
Check 'codex run: instructions list skill path' { (Untoml $dev).Contains((Join-Path (Join-Path (Join-Path $tmp 'skills') 'gerrit-review') 'SKILL.md')) }
Check 'codex run: deny -> disabled_tools, env kept' { $srv.Contains('disabled_tools=[\"submit_change\"]') -and (Untoml $srv).Contains('${HOME}/.config/gerrit') }
Check 'codex run: warns tools.only, keeps user args' { $out.Contains('tools.only') -and ($lines -contains 'exec') }
Remove-Item -Recurse -Force $tmp
$env:KIT_DRY_RUN = '1'; Kit run gerrit --tool omp; Remove-Item env:KIT_DRY_RUN
$lines = $out -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$tmp = Lines-After 'tmp='
Check 'omp run: config overlay points at skills' { (ReadT (Join-Path $tmp 'omp.yml')).Contains((Join-Path $tmp 'skills').Replace('\', '\\')) -and (Test-Path (Join-Path $tmp 'skills/gerrit-review/SKILL.md')) }
Check 'omp run: prompt + lowercase tools' { ($lines -contains '--append-system-prompt') -and ($lines -contains 'read,grep,glob') }
Check 'omp run: warns no per-agent mcp' { $out.Contains('kit add mcp') }
Remove-Item -Recurse -Force $tmp
Kit run gerrit --tool vim
Check 'run rejects unknown tool' { $rc -ne 0 }

# ---------- auto sync when Claude starts ----------
[IO.File]::AppendAllText("$TEAM/skills/gerrit-review/SKILL.md", "hook change`n")
$sw = [Diagnostics.Stopwatch]::StartNew(); Kit sync --hook; $sw.Stop()
Check 'hook returns quickly, exit 0' { $rc -eq 0 -and $sw.Elapsed.TotalSeconds -lt 8 }
for ($i = 0; $i -lt 30; $i++) { if (-not (Test-Path "$H/.config/agentkit/sync.lock")) { break }; Start-Sleep -Milliseconds 500 }
Start-Sleep -Milliseconds 300
Check 'hook synced in the background' { (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('hook change') }
Check 'hook logs' { (ReadT "$H/.config/agentkit/sync.log") -match '(?m)^== ' }
Check 'hook: kit_version not told in the background' { -not (ReadT "$H/.config/agentkit/sync.log").Contains('團隊要') -and (State-Nag) -eq 0 }
[IO.File]::AppendAllText("$TEAM/skills/gerrit-review/SKILL.md", "second change`n")
Kit sync --hook; Start-Sleep -Seconds 2
Check 'hook runs at most every 10 minutes' { -not (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('second change') }
Kit sync
Check 'hook: kit_version told at the next sync' { $out.Contains('團隊要 kit 0.6.0 以上') }
W "$TEAM/kit.yaml" $teamYaml

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

# ---------- new / diff / update / check (authoring, local only) ----------
$AU = Join-Path $T 'authoring'; $LIB = Join-Path $T 'lib'
W "$AU/kit.yaml" "name: authoring`ncontent_hosts: [gitea.example]`nrequired:`n  rules: [sec]`n"
W "$LIB/skills/foo/SKILL.md" "---`nname: foo`ndescription: foo skill`n---`nRun scripts/x.sh, see https://gitea.example/doc`n"
W "$LIB/skills/foo/scripts/x.sh" "echo hi`n"; W "$LIB/skills/foo/LICENSE" "MIT`n"; W "$LIB/skills/foo/README.md" "readme`n"
[IO.File]::WriteAllBytes("$LIB/skills/foo/logo.png", [byte[]]@(0, 1, 2)); W "$LIB/skills/foo/.git/config" "x`n"
W "$LIB/skills/bar/SKILL.md" "---`nname: bar`ndescription: >-`n  Use for bar.`n  Two lines # not a comment`n`nlicense: MIT`n---`nbar`n"; W "$LIB/skills/bar/run.sh" "echo no`n"
Push-Location $AU
Kit new rule sec
Check 'new rule skeleton in the folder with kit.yaml' { $rc -eq 0 -and (Get-Item "$AU/rules/sec.md").Length -gt 0 }
Kit new agent bot
Check 'new agent skeleton has frontmatter' { (ReadT "$AU/agents/bot.md").Contains("`nname: bot`n") }
Kit new skill foo --from "$LIB/skills/foo"
Check 'new --from copies md and declared scripts' { $rc -eq 0 -and (Test-Path "$AU/skills/foo/SKILL.md") -and (Test-Path "$AU/skills/foo/scripts/x.sh") }
Check 'new --from skips LICENSE, README, binaries, .git' { -not (Test-Path "$AU/skills/foo/LICENSE") -and -not (Test-Path "$AU/skills/foo/README.md") -and -not (Test-Path "$AU/skills/foo/logo.png") -and -not (Test-Path "$AU/skills/foo/.git") }
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
Check 'check: private word found, never printed' { $out -match 'rules/sec\.md:\d+: 有不該公開的字' -and $out -notmatch '(?i)topsecret' }
Check 'check: counts every problem' { $out.Contains($(if ($linkOk) { 'kit check：9 個問題' } else { 'kit check：8 個問題' })) }
W "$AU/skills/gerrit-review/SKILL.md" "---`nname: gerrit-review`ndescription: x`n---`nx`n"
Kit check $AU
Check 'check: duplicate name across sources' { $out.Contains('名字重複：skill:gerrit-review') }
foreach ($x in 'skills/gerrit-review', 'skills/foo/.git', '.gitmodules', 'rules/link.md', 'skills/foo/logo.png', 'skills/baz', 'mcp') { Remove-Item -LiteralPath (Join-Path $AU $x) -Recurse -Force }
W "$AU/agents/bot.md" "---`nname: bot`ndescription: b`nskills: [foo]`n---`nhi`n"; W "$AU/rules/sec.md" "Be safe.`n"
[IO.File]::AppendAllText("$AU/kit.yaml", "author_domains: [corp.example]`n")
& git -C $AU init -q; & git -C $AU add -A; & git -C $AU -c user.name=a -c user.email=me@home.example commit -qm x
Kit check --ci
Check 'check --ci: author email must be company' { $rc -ne 0 -and $out.Contains('作者 email 不是公司網域') }
& git -C $AU -c user.name=a -c user.email=me@corp.example commit -q --amend --reset-author -m x
Kit check --ci
Check 'check --ci passes' { $rc -eq 0 }
Pop-Location

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
Check 'export-self drops README, CHANGELOG, LICENSE, .github, private-words.txt' { -not (Test-Path "$EX/README.md") -and -not (Test-Path "$EX/LICENSE") -and -not (Test-Path "$EX/CHANGELOG.md") -and -not (Test-Path "$EX/.github") -and -not (Test-Path "$EX/private-words.txt") }
Check 'export-self keeps tests, .gitattributes, .gitignore, kit' { (Test-Path "$EX/tests/t.sh") -and (Test-Path "$EX/.gitattributes") -and (Test-Path "$EX/.gitignore") -and (Test-Path "$EX/unix/kit") -and (Test-Path "$EX/windows/kit.ps1") }
Check 'export-self leaves out untracked files' { -not (Test-Path "$EX/untracked.md") }
Check 'export-self writes VERSION' { (ReadT "$EX/VERSION") -eq "0.4.0+gitea.12`n" }
Check 'export-self INSTALL.md, no URL' { $m = ReadT "$EX/INSTALL.md"; $m.Contains('sh unix/install.sh') -and $m.Contains('windows\install.ps1') -and $m -notmatch '://|@[A-Za-z0-9.-]+:' }
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

# ---------- push (local bare repo as origin, fake Gitea on localhost) ----------
$Py = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $Py) { [Console]::WriteLine('skip: push tests need python for the fake Gitea') } else {
$P = Join-Path $T 'push'; $W = Join-Path $P 'work'; $ORIGIN = Join-Path $P 'remote/acme/team.git'; $DAY = Get-Date -Format yyyyMMdd
[void](New-Item -ItemType Directory -Force -Path (Join-Path $P 'remote/acme'))
& git -c init.defaultBranch=main init -q --bare $ORIGIN
& git -c init.defaultBranch=main init -q $W
W "$W/kit.yaml" "name: team`nallowed_hosts: [gitea.example, 127.0.0.1]`nauthor_domains: [corp.example]`n"
W "$W/rules/base.md" "Be kind.`n"
& git -C $W config user.name tester; & git -C $W config user.email me@corp.example
& git -C $W add -A; & git -C $W commit -qm init; & git -C $W remote add origin $ORIGIN
& git -C $W push -q origin main 2>$null; & git -C $W fetch -q origin 2>$null; & git -C $W remote set-head origin main
W "$P/fake-gitea" @'
import http.server, json, sys
port_file, log_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(log_file, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": json.loads(body.decode("utf-8"))}) + "\n")
        out = json.dumps({"number": 1, "html_url": "http://127.0.0.1/acme/team/pulls/1"}).encode()
        self.send_response(201); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
'@
W "$P/req.log" ''
$fake = Start-Process -FilePath $Py -ArgumentList @('-I', "`"$P/fake-gitea`"", "`"$P/port`"", "`"$P/req.log`"") -PassThru -NoNewWindow
for ($i = 0; $i -lt 20 -and -not ((Test-Path "$P/port") -and (Get-Item "$P/port").Length -gt 0); $i++) { Start-Sleep -Milliseconds 500 }
$env:KIT_GITEA_API = "http://127.0.0.1:$((ReadT "$P/port").Trim())/api/v1"; Remove-Item env:KIT_GITEA_TOKEN -ErrorAction SilentlyContinue
$WebBase = $env:KIT_GITEA_API -replace '/api/v1$', ''
function RemoteHeads { (@(& git --git-dir=$ORIGIN for-each-ref '--format=%(refname:short)' refs/heads) | Sort-Object) -join ' ' }
function LastReq { $l = @((ReadT "$P/req.log").Split("`n") | Where-Object { $_ }); if ($l.Count -eq 0) { return $null }; $l[$l.Count - 1] | ConvertFrom-Json }
function KitBranches { @(& git -C $W branch --list 'kit/*').Count }
try {
Push-Location $W
Kit push
Check 'push: nothing to send' { $rc -eq 0 -and $out.Contains('沒有要送的') }
Kit new skill pfoo
$head0 = (& git -C $W rev-parse HEAD)
Kit push --dry-run
Check 'push --dry-run lists files and branch, sends nothing' { $rc -eq 0 -and $out.Contains('skills/pfoo/SKILL.md') -and $out.Contains("kit/pfoo-$DAY") -and (& git -C $W rev-parse HEAD) -eq $head0 -and (KitBranches) -eq 0 -and (RemoteHeads) -eq 'main' }
[IO.File]::AppendAllText("$W/skills/pfoo/SKILL.md", "TopSecretName here`n")
Kit push
Check 'push: check problem stops, nothing sent' { $rc -ne 0 -and $out.Contains('什麼都沒送') -and (KitBranches) -eq 0 -and (RemoteHeads) -eq 'main' }
W "$W/skills/pfoo/SKILL.md" "---`nname: pfoo`ndescription: p`n---`nok`n"
& git -C $W config user.email me@home.example
Kit push
Check 'push: author domain must be company' { $rc -ne 0 -and $out.Contains('user.email 不是公司網域') -and (RemoteHeads) -eq 'main' }
& git -C $W config user.email me@corp.example
& git -C $W remote set-url origin https://public-git.example/acme/team.git
Kit push
Check 'push: origin host not allowed' { $rc -ne 0 -and $out.Contains('public-git.example 不在允許的主機清單') -and (RemoteHeads) -eq 'main' }
& git -C $W remote set-url origin $ORIGIN
W "$W/notes.txt" "local only`n"; & git -C $W add notes.txt; & git -C $W commit -qm 'local only'   # an unpushed commit on main
Kit push
Check 'push: no token -> compare URL' { $rc -eq 0 -and $out.Contains("開 PR：$WebBase/acme/team/compare/main...kit/pfoo-$DAY") }
Check 'push: only the kit branch is pushed' { (RemoteHeads) -eq "kit/pfoo-$DAY main" -and (& git --git-dir=$ORIGIN rev-parse main) -eq $head0 }
Check 'push: commit has only the item, message' { (& git --git-dir=$ORIGIN log -1 '--format=%s' "kit/pfoo-$DAY") -eq 'kit: add skill:pfoo' -and "$(& git --git-dir=$ORIGIN diff --name-only main "kit/pfoo-$DAY")" -eq 'skills/pfoo/SKILL.md' }
Check 'push: back on main, no PR request' { (& git -C $W symbolic-ref --short HEAD) -eq 'main' -and $null -eq (LastReq) }
W "$W/rules/base.md" "Be kinder.`n"; Kit new rule pnew; W "$W/rules/pnew.md" "x`n"
$env:KIT_GITEA_TOKEN = 'fake-tok-123'; Kit push; Remove-Item env:KIT_GITEA_TOKEN
$req = LastReq
Check 'push: PR opened, URL printed' { $rc -eq 0 -and $out.Contains('已開 PR：http://127.0.0.1/acme/team/pulls/1') }
Check 'push: PR request path, token header, head/base' { $req.path -eq '/api/v1/repos/acme/team/pulls' -and $req.auth -eq 'token fake-tok-123' -and $req.body.head -eq "kit/base-pnew-$DAY" -and $req.body.base -eq 'main' }
Check 'push: PR title is the commit message, body in UTF-8' { $req.body.title -eq 'kit: add rule:pnew; update rule:base' -and $req.body.body.Contains('由 kit push 送出') }
Check 'push: token never printed' { -not $out.Contains('fake-tok') }
W "$H/.config/agentkit/gitea-token" "file-tok-456`n"
if (-not $OnWindows) { & chmod 644 "$H/.config/agentkit/gitea-token" }
Kit new skill pfoo; W "$W/skills/pfoo/SKILL.md" "---`nname: pfoo`ndescription: p`n---`nagain`n"
Kit push
Check 'push: same branch name taken -> -2' { $rc -eq 0 -and (RemoteHeads).Contains("kit/pfoo-$DAY-2") }
Check 'push: token file used, never printed' { (LastReq).auth -eq 'token file-tok-456' -and -not $out.Contains('file-tok') }
if (-not $OnWindows) { Check 'push: loose token file permission warned' { $out.Contains('chmod 600') } }
Remove-Item -LiteralPath "$H/.config/agentkit/gitea-token" -Force
Pop-Location
} finally {
    Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
    Remove-Item env:KIT_GITEA_API, env:KIT_GITEA_TOKEN -ErrorAction SilentlyContinue
}
}

# ---------- uninstall ----------
Kit add skill gerrit-review; Kit add mcp gerrit
Kit uninstall
Check 'uninstall restores CLAUDE.md' { (ReadT "$H/.claude/CLAUDE.md") -eq "# My notes`nBe brief.`n" }
Check 'uninstall removes kit skills' { -not (Test-Path "$H/.claude/skills/gerrit-review") -and (Test-Path "$H/.claude/skills/my-own/SKILL.md") }
Check 'uninstall removes only kit deny' { (Flat (JGet $settings 'permissions.deny')) -eq '["Bash(rm-rf:*)"]' }
Check 'uninstall removes hook' { -not (ReadT $settings).Contains('sync --hook') }
Check 'uninstall: claude.json byte-identical' { SameBytes "$H/.claude.json" "$T/claude.json.orig" }
W "$T/s.orig" "{`n  `"model`": `"opus`",`n  `"hooks`": {`n    `"SessionStart`": [`n      {`n        `"hooks`": [`n          {`n            `"type`": `"command`",`n            `"command`": `"my-hook`"`n          }`n        ]`n      }`n    ]`n  }`n}`n"
Copy-Item "$T/s.orig" $settings -Force
Kit init $TEAM
Check 'user hook kept next to kit hook' { $v = JGet $settings 'hooks.SessionStart'; $v.Contains('my-hook') -and $v.Contains('sync --hook') }
Kit uninstall
Check 'settings.json byte-identical after init+uninstall' { SameBytes "$T/s.orig" $settings }

# ---------- CRLF files from Windows editors ----------
Set-Home (Join-Path $T 'home-crlf')
W "$H/.claude/CLAUDE.md" "# Mine`r`nKeep CRLF.`r`n"
Kit init $TEAM
Check 'CRLF file keeps CRLF' { $t = ReadT "$H/.claude/CLAUDE.md"; $t.Contains("Keep CRLF.`r`n") -and $t.Contains("<!-- agentkit:end -->`r`n") -and -not ($t -match "[^`r]`n") }
Kit uninstall
Check 'CRLF file restored' { (ReadT "$H/.claude/CLAUDE.md") -eq "# Mine`r`nKeep CRLF.`r`n" }

# ---------- Codex and omp ----------
Set-Home (Join-Path $T 'home4')
W "$H/.codex/AGENTS.md" "# my codex notes`n"
W "$H/.codex/config.toml" "model = `"gpt-5`"`n`n[mcp_servers.mine]`ncommand = `"x`"`n"
Copy-Item "$H/.codex/config.toml" "$T/codex.orig"
W "$H/.omp/agent/mcp.json" "{`n  `"mcpServers`": {`n    `"own`": {`n      `"command`": `"y`"`n    }`n  }`n}`n"
Copy-Item "$H/.omp/agent/mcp.json" "$T/omp.orig"
Kit init $TEAM; Kit add mcp gerrit; Kit add skill gerrit-review
Kit list
Check 'list shows targets' { $out.Contains('寫到：Claude、Codex、omp') }
$toml = ReadT "$H/.codex/config.toml"
Check 'codex AGENTS.md keeps user text' { (ReadT "$H/.codex/AGENTS.md").StartsWith('# my codex notes') }
Check 'codex AGENTS.md has rule text inline' { $a = ReadT "$H/.codex/AGENTS.md"; $a.Contains('Never paste secrets.') -and $a.Contains('Use 4 spaces.') }
Check 'omp AGENTS.md has rule text' { (ReadT "$H/.omp/agent/AGENTS.md").Contains('Never paste secrets.') }
Check 'skills in ~/.agents/skills' { (Test-Path "$H/.agents/skills/gerrit-review/SKILL.md") -and (Test-Path "$H/.agents/skills/gerrit-workflow/LICENSE") }
Check 'codex toml keeps user part' { $toml.StartsWith("model = `"gpt-5`"`n`n[mcp_servers.mine]") }
Check 'codex toml has kit server' { $toml.Contains("[mcp_servers.gerrit]`ncommand = `"uvx`"") }
Check 'codex toml args' { $toml.Contains('args = ["--index-url", "https://pypi.example/simple", "gerrit-mcp-server==1.0"]') }
Check 'codex team deny -> disabled_tools' { $toml.Contains('disabled_tools = ["submit_change"]') }
Check 'codex env table, not expanded' { $toml.Contains("[mcp_servers.gerrit.env]`nGERRIT_CONFIG = `"`${HOME}/.config") }
Check 'omp mcp.json has kit server and own' { (JGet "$H/.omp/agent/mcp.json" 'mcpServers.gerrit.command') -eq '"uvx"' -and (JGet "$H/.omp/agent/mcp.json" 'mcpServers.own.command') -eq '"y"' }
Check 'no backup for a file kit created' { -not (Test-Path "$H/.omp/agent/AGENTS.md.kit-backup") }
Kit rm mcp gerrit
Check 'rm mcp clears codex and omp' { -not (ReadT "$H/.codex/config.toml").Contains('mcp_servers.gerrit') -and $null -eq (JGet "$H/.omp/agent/mcp.json" 'mcpServers.gerrit') }
Kit uninstall
Check 'uninstall: codex AGENTS.md back' { (ReadT "$H/.codex/AGENTS.md") -eq "# my codex notes`n" }
Check 'uninstall: codex toml byte-identical' { SameBytes "$T/codex.orig" "$H/.codex/config.toml" }
Check 'uninstall: omp mcp.json byte-identical' { SameBytes "$T/omp.orig" "$H/.omp/agent/mcp.json" }
Check 'uninstall: omp AGENTS.md (made by kit) gone' { -not (Test-Path "$H/.omp/agent/AGENTS.md") }
Check 'uninstall: ~/.agents/skills emptied' { @(Get-ChildItem -Force "$H/.agents/skills" -ErrorAction SilentlyContinue).Count -eq 0 }

# ---------- install.ps1 ----------
$env:AGENTKIT_HOME = Join-Path $T 'inst'
& $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'windows/install.ps1') -Quiet
Remove-Item env:AGENTKIT_HOME
$Kit = Join-Path $T 'inst/lib/kit.ps1'
Kit ci-template
Check 'installed kit has the ci template' { $rc -eq 0 -and $out -ceq $tmpl }
$Kit = $realKit

# ---------- the script files themselves ----------
Check 'kit.ps1 and install.ps1 start with a UTF-8 BOM (needed by PowerShell 5.1)' {
    $ok = $true; foreach ($f in 'windows/kit.ps1', 'windows/install.ps1', 'tests/run.ps1') { $b = [IO.File]::ReadAllBytes((Join-Path $Repo $f)); if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $ok = $false } }; $ok }
Check 'no PowerShell 7-only syntax (?? ?. && ||)' {
    $bad = Select-String -Path $Kit, (Join-Path $Repo 'windows/install.ps1') -Pattern '\?\?|\?\.|\s&&\s|\s\|\|\s' | Where-Object { $_.Line -notmatch '^\s*#' }
    @($bad).Count -eq 0 }
}
finally {
    $env:PATH = $savedPath
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
}
[Console]::WriteLine("kit.ps1: $($script:pass) passed, $($script:fail) failed")
if ($script:fail -gt 0) { exit 1 }
exit 0
