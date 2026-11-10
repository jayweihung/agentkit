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

# ---------- auto sync when Claude starts ----------
[IO.File]::AppendAllText("$TEAM/skills/gerrit-review/SKILL.md", "hook change`n")
$sw = [Diagnostics.Stopwatch]::StartNew(); Kit sync --hook; $sw.Stop()
Check 'hook returns quickly, exit 0' { $rc -eq 0 -and $sw.Elapsed.TotalSeconds -lt 8 }
for ($i = 0; $i -lt 30; $i++) { if (-not (Test-Path "$H/.config/agentkit/sync.lock")) { break }; Start-Sleep -Milliseconds 500 }
Start-Sleep -Milliseconds 300
Check 'hook synced in the background' { (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('hook change') }
Check 'hook logs' { (ReadT "$H/.config/agentkit/sync.log") -match '(?m)^== ' }
[IO.File]::AppendAllText("$TEAM/skills/gerrit-review/SKILL.md", "second change`n")
Kit sync --hook; Start-Sleep -Seconds 2
Check 'hook runs at most every 10 minutes' { -not (ReadT "$H/.claude/skills/gerrit-review/SKILL.md").Contains('second change') }
Kit sync

# ---------- allowed_hosts ----------
Kit init $TEAM 'https://github.com/someone/agentkit-library.git'
Check 'host outside allowed_hosts refused' { $rc -ne 0 -and $out.Contains('github.com 不在允許的主機清單') }
Kit init $TEAM

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
