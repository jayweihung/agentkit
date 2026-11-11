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
Check 'CLAUDE.md imports required rule (forward slashes: Claude reads @C:/... not @C:\...)' { (ReadT "$H/.claude/CLAUDE.md").Contains('@' + (Join-Path $TEAM 'rules/security.md').Replace('\', '/').Replace(' ', '\ ')) }
Check 'CLAUDE.md imports recommended rule' { (ReadT "$H/.claude/CLAUDE.md").Contains('@' + (Join-Path $TEAM 'rules/coding-style.md').Replace('\', '/').Replace(' ', '\ ')) }
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

# ---------- a skill folder that is not kit's ----------
W "$TEAM/skills/clash/SKILL.md" "---`nname: clash`ndescription: team`n---`nteam clash`n"; W "$H/.claude/skills/clash/SKILL.md" "mine`n"
Kit add skill clash
Check "someone else's skill folder: warned, not overwritten" { $out.Contains('不是 kit 放的') -and (ReadT "$H/.claude/skills/clash/SKILL.md") -eq "mine`n" }
Kit sync
Check '... and warned only once' { -not $out.Contains('不是 kit 放的') }
Remove-Item -Recurse -Force "$H/.claude/skills/clash"; Kit sync
Check '... kit puts it there once the folder is gone' { (ReadT "$H/.claude/skills/clash/SKILL.md").Contains('team clash') }
Kit rm skill clash; Remove-Item -Recurse -Force "$TEAM/skills/clash"

# ---------- list ----------
Kit list
Check 'list marks required' { $out -match '(?m)^R  rule:security' }
Check 'list marks in use' { $out -match '(?m)^\*  skill:gerrit-review' }
Check 'list shows unused' { $out -match '(?m)^   skill:gerrit-workflow' }
Check 'list shows agent' { $out.Contains('agent:gerrit') }
Check 'list shows targets (Claude only here)' { $out -match '(?m)^寫到：Claude$' }

# ---------- list --json (for the Herdr panel) ----------
W "$TEAM/skills/quote/SKILL.md" "---`nname: quote`ndescription: 中文 `"引號`" \ 和`ttab`n---`nx`n"
Kit list --json; $lj = $out; $ljrc = $rc
W "$T/list.json" "$lj`n"
$teamJ = (Resolve-Path -LiteralPath $TEAM).ProviderPath.Replace('\', '\\')
Check 'list --json: exit 0, valid JSON' { $ljrc -eq 0 -and $null -ne (JGet "$T/list.json" 'kit') }
Check 'list --json: version and source' { (JGet "$T/list.json" 'kit') -eq '"0.1.0"' -and $lj.Contains("{`"name`": `"team`", `"source`": `"$teamJ`", `"dir`": `"$teamJ`", `"push`": `"pr`"}") }
Check 'list --json: required, used, unused' {
    $lj.Contains('{"kind": "rule", "name": "security", "status": "required", "new": false, "source": "team", "description": "", "path": ') -and
    $lj.Contains('{"kind": "skill", "name": "gerrit-review", "status": "used", "new": false, "source": "team", "description": "review a change", "path": ') -and
    $lj.Contains('{"kind": "skill", "name": "gerrit-workflow", "status": "unused", "new": false, "source": "third-party", "description": "upstream", "path": ') }
Check 'list --json: agent with its description' { $lj.Contains('{"kind": "agent", "name": "gerrit", "status": "agent", "new": false, "source": "team", "description": "Gerrit helper", "path": ') }
Check 'list --json: new item, text escaped (UTF-8 kept)' { $lj.Contains('{"kind": "skill", "name": "quote", "status": "unused", "new": true, "source": "team", "description": "中文 \"引號\" \\ 和\ttab", "path": ') }
Check 'list --json: tools (Claude only here), no version wanted' { $lj.Contains("`n  `"tools`": [`"claude`"],`n") -and (JGet "$T/list.json" 'kit_version_wanted') -eq '""' }
Kit list --json
Check 'list --json does not mark items seen' { ([regex]::Matches($out, '"new": true')).Count -eq 1 }
Kit list --bad
Check 'list with a wrong option: usage' { $rc -ne 0 -and $out.Contains('kit list [--json') }
Remove-Item -Recurse -Force "$TEAM/skills/quote"

# ---------- agent add|rm, here.agent (kit.ps1) ----------
$gBak = ReadT "$TEAM/agents/gerrit.md"
W "$TEAM/agents/gerrit.md" "---`nname: gerrit`ndescription: Gerrit helper`nskills:`n  - gerrit-review`n`n  # the team one`n  - team-build`n`n# next`nrules: [gerrit-flow]`n---`nbody`n"
Kit agent gerrit rm skill team-build
Check 'agent rm: a block list with blank and comment lines in it is replaced whole' { $rc -eq 0 -and (ReadT "$TEAM/agents/gerrit.md") -ceq "---`nname: gerrit`ndescription: Gerrit helper`nskills: [gerrit-review]`n`n# next`nrules: [gerrit-flow]`n---`nbody`n" -and $out.Contains('kit push --to team') }
W "$TEAM/agents/gerrit.md" "---`r`nname: gerrit`r`ndescription: Gerrit helper`r`nskills: [gerrit-review]`r`nrules: [gerrit-flow]`r`n---`r`nYou are the Gerrit helper.`r`n"
Kit agent gerrit add skill gerrit-workflow; $rc1 = $rc
Kit agent gerrit add mcp gerrit
Check 'agent add: a CRLF file is read and stays CRLF' { $rc1 -eq 0 -and $rc -eq 0 -and (ReadT "$TEAM/agents/gerrit.md") -ceq "---`r`nname: gerrit`r`ndescription: Gerrit helper`r`nskills: [gerrit-review, gerrit-workflow]`r`nrules: [gerrit-flow]`r`nmcp: [gerrit]`r`n---`r`nYou are the Gerrit helper.`r`n" }
Kit agents --json
Check "agents --json: a CRLF agent's prompt without CR" { $out.Contains('"prompt": "You are the Gerrit helper."}') }
Kit check $TEAM
Check "check: a CRLF agent's header is read" { -not $out.Contains('agents/gerrit.md: 開頭要有') }
$bad = "---`nname: gerrit`ndescription: Gerrit helper`njust words`nskills: [gerrit-review]`n---`nbody`n"
W "$TEAM/agents/gerrit.md" $bad
Kit agent gerrit add skill gerrit-workflow
Check 'agent add: a header kit cannot read stops it, the file is not changed' { $rc -ne 0 -and $out.Contains('讀不懂') -and (ReadT "$TEAM/agents/gerrit.md") -ceq $bad }
W "$TEAM/agents/gerrit.md" "---`nname: gerrit`ndescription: Gerrit helper`nmcp: [nope]`n---`nbody`n"
Kit check $TEAM
Check "check: an agent's missing MCP is reported" { $out.Contains('agents/gerrit.md: 找不到 mcp:nope') }
W "$TEAM/agents/gerrit.md" $gBak
# kit run leaves a marker (process -> agent): kit list --json --pid tells the pane's agent
$rund = Join-Path $H '.config/agentkit/run'; W (Join-Path $rund "$PID") "gerrit`n"
$sp = @{ FilePath = $Exe; ArgumentList = @('-NoProfile', '-Command', 'exit 0'); PassThru = $true }; if ($OnWindows) { $sp['WindowStyle'] = 'Hidden' }
$dead = Start-Process @sp
$dead.WaitForExit(); W (Join-Path $rund "$($dead.Id)") "gone`n"
Kit list --json --dir $T --pid $PID
Check 'list --json --pid: the agent kit run started there' { $out.Contains('"agent": {"name": "gerrit", "source": "team", "rules": ["gerrit-flow"], "skills": ["gerrit-review"], "mcp": ["gerrit"]}, "folder": {') }
Check 'list --json --pid: the marker of a kit run that ended is dropped' { -not (Test-Path (Join-Path $rund "$($dead.Id)")) -and (Test-Path (Join-Path $rund "$PID")) }
Remove-Item -LiteralPath (Join-Path $rund "$PID")
Kit list --json --dir $T --pid $PID
Check 'list --json --pid: no agent there' { $out.Contains('"user": null, "agent": null, "folder": {') }
if (-not $OnWindows) {
    W "$T/fakebin/claude" "#!/bin/sh`n`"`$FAKE_EXE`" -NoProfile -File `"`$FAKE_KIT`" list --json --dir `"`$PWD`" --pid `$PPID > `"`$FAKE_OUT`" 2>&1`n"
    & chmod +x "$T/fakebin/claude"
    $env:FAKE_EXE = $Exe; $env:FAKE_KIT = $Kit; $env:FAKE_OUT = "$T/fake.json"; $oldPath = $env:PATH; $env:PATH = "$T/fakebin" + [IO.Path]::PathSeparator + $env:PATH
    Kit run gerrit
    $env:PATH = $oldPath; Remove-Item env:FAKE_EXE, env:FAKE_KIT, env:FAKE_OUT
    Check 'kit run: the agent in the pane is known while it runs, the marker goes after' { $rc -eq 0 -and (ReadT "$T/fake.json").Contains('"agent": {"name": "gerrit", "source": "team",') -and @(Get-ChildItem -LiteralPath $rund).Count -eq 0 }
}
Kit help
Check 'help: --json --dir is under kit list' { $out -match "(?m)^  kit list .*`n     --json --dir" -and $out -notmatch "(?m)^  kit agent .*`n     --json --dir" }

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
for ($i = 0; $i -lt 120 -and -not ((Test-Path "$P/port") -and (Get-Item "$P/port").Length -gt 0); $i++) { Start-Sleep -Milliseconds 500 }
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
Check 'push: author domain must be company' { $rc -ne 0 -and $out.Contains('不是公司網域') -and (RemoteHeads) -eq 'main' }
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

# ---------- push: direct (kit.yaml): your own source, straight to every remote, no PR ----------
$D = Join-Path $T 'pushdirect'; $DW = Join-Path $D 'work'; $R1 = Join-Path $D 'one.git'; $R2 = Join-Path $D 'two.git'
& git -c init.defaultBranch=main init -q --bare $R1; & git -c init.defaultBranch=main init -q --bare $R2
& git -c init.defaultBranch=main init -q $DW
W "$DW/kit.yaml" "name: mine`npush: direct`nallowed_hosts: [gitea.example]`n"; W "$DW/rules/mine.md" "Mine.`n"
& git -C $DW config user.name tester; & git -C $DW config user.email me@home.example; & git -C $DW config core.autocrlf false
& git -C $DW add -A; & git -C $DW commit -qm init
& git -C $DW remote add one $R1; & git -C $DW remote add two $R2
& git -C $DW push -q one main 2>$null; & git -C $DW push -q two main 2>$null; & git -C $DW fetch -q one 2>$null; & git -C $DW fetch -q two 2>$null
Push-Location $DW
W "$DW/rules/mine.md" "Mine, changed.`n"; W "$DW/notes.txt" "not an item`n"
$dh0 = & git -C $DW rev-parse HEAD
W "$DW/kit.yaml" "name: mine`n"
Kit push --dry-run
Check 'push (pr, the default) without origin: stops and says to write push: direct' { $rc -ne 0 -and $out.Contains('沒有 origin') -and $out.Contains('push: direct') -and (& git -C $DW rev-parse HEAD) -eq $dh0 }
W "$DW/kit.yaml" "name: mine`npush: maybe`n"
Kit check .
Check 'check: push is pr or direct' { $rc -ne 0 -and $out.Contains('kit.yaml: push 只能是 pr 或 direct') }
& git -C $DW checkout -q -- kit.yaml
& git -C $DW config remote.one.pushurl https://evil.example/one.git
Kit push --dry-run
Check 'push direct: a push URL to a host not allowed stops it' { $rc -ne 0 -and $out.Contains('evil.example 不在允許的主機清單') }
& git -C $DW config --unset remote.one.pushurl
& git -C $DW config 'url.https://evil.example/.pushInsteadOf' ($D + [IO.Path]::DirectorySeparatorChar)
Kit push --dry-run
Check 'push direct: pushInsteadOf to a host not allowed stops it' { $rc -ne 0 -and $out.Contains('evil.example 不在允許的主機清單') }
& git -C $DW config --remove-section 'url.https://evil.example/'
& git -C $DW config 'url.evil.example:.pushInsteadOf' ($D + [IO.Path]::DirectorySeparatorChar)
Kit push --dry-run
Check 'push direct: pushInsteadOf to host:path (no user@) is a host too' { $rc -ne 0 -and $out.Contains('evil.example 不在允許的主機清單') }
& git -C $DW config --remove-section 'url.evil.example:'
Kit push --dry-run
Check 'push direct --dry-run: straight to the remotes, nothing sent' { $rc -eq 0 -and $out.Contains('push: direct') -and $out.Contains('one two') -and $out.Contains('rules/mine.md') -and (& git -C $DW rev-parse HEAD) -eq $dh0 -and (& git --git-dir=$R1 rev-parse main) -eq $dh0 }
Kit push
$dh1 = & git -C $DW rev-parse HEAD
Check 'push direct: commit on main, pushed to every remote' { $rc -eq 0 -and (& git --git-dir=$R1 rev-parse main) -eq $dh1 -and (& git --git-dir=$R2 rev-parse main) -eq $dh1 -and (& git -C $DW log -1 --format=%s) -eq 'kit: update rule:mine' -and (& git -C $DW symbolic-ref --short HEAD) -eq 'main' }
Check 'push direct: only the item is committed' { (& git -C $DW show --name-only --format= HEAD | Where-Object { $_ }) -eq 'rules/mine.md' -and "$(& git -C $DW status --porcelain)" -eq '?? notes.txt' }
& git -C $DW commit -q --allow-empty -m unpushed; W "$DW/rules/mine.md" "Mine, again.`n"; $dh2 = & git -C $DW rev-parse HEAD
Kit push
Check 'push direct: a commit not on a remote yet stops it, nothing committed' { $rc -ne 0 -and $out.Contains('還沒推到 one') -and (& git -C $DW rev-parse HEAD) -eq $dh2 -and (& git --git-dir=$R1 rev-parse main) -eq $dh1 }
& git -C $DW reset -q --soft HEAD~1
& git -c init.defaultBranch=main init -q --bare (Join-Path $D 'three.git'); & git -C $DW remote add three (Join-Path $D 'three.git')
Kit push
Check 'push direct: a remote without this branch stops it' { $rc -ne 0 -and $out.Contains('three 上沒有 main') -and (& git -C $DW rev-parse HEAD) -eq $dh1 }
& git -C $DW remote remove three
& git clone -q $R1 (Join-Path $D 'other') 2>$null; & git -C (Join-Path $D 'other') -c user.name=t -c user.email=t@t commit -q --allow-empty -m theirs; & git -C (Join-Path $D 'other') push -q origin HEAD:main 2>$null
Kit push
Check 'push direct: new commits on a remote stop it (pull first)' { $rc -ne 0 -and $out.Contains('git pull one main') -and "$(& git -C $DW status --porcelain rules)" -eq ' M rules/mine.md' }
& git -C $DW pull -q --no-rebase one main 2>&1 | Out-Null; & git -C $DW push -q two main 2>&1 | Out-Null; & git -C $DW fetch -q two 2>&1 | Out-Null
# kit.yaml goes along only when all that changed in it is collect_sources (kit collect --allow)
Add-Content -LiteralPath "$DW/kit.yaml" 'collect_sources: [example.com/a/b]'
Kit push
Check 'push direct: kit.yaml with only collect_sources changed goes along' { $rc -eq 0 -and ((@(& git -C $DW show --name-only --format= HEAD | Where-Object { $_ }) | Sort-Object) -join ' ') -eq 'kit.yaml rules/mine.md' }
W "$DW/rules/mine.md" "Mine, once more.`n"; Add-Content -LiteralPath "$DW/kit.yaml" 'maintainers: [me]'
Kit push
Check 'push direct: kit.yaml with other changes stays behind' { $rc -eq 0 -and "$(& git -C $DW show --name-only --format= HEAD)".Trim() -eq 'rules/mine.md' -and $out -match '不會送：kit.yaml' }
& git -C $DW checkout -q -- kit.yaml
# a commit hook says no: git's words are shown, and nothing is left staged
W "$DW/.git/hooks/pre-commit" "#!/bin/sh`necho 'hook: no thanks' >&2`nexit 1`n"; if (-not $IsWindows) { & chmod +x "$DW/.git/hooks/pre-commit" }
W "$DW/rules/mine.md" "Mine, blocked.`n"; $headBefore = "$(& git -C $DW rev-parse HEAD)".Trim()
Kit push
Check "push direct: a commit hook refusing: its words shown, nothing committed or left staged" { $rc -ne 0 -and $out -match 'hook: no thanks' -and "$(& git -C $DW rev-parse HEAD)".Trim() -eq $headBefore -and -not "$(& git -C $DW diff --cached --name-only)" -and "$(& git -C $DW status --porcelain rules)" -eq ' M rules/mine.md' }
Remove-Item -Force "$DW/.git/hooks/pre-commit"
Pop-Location

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

# ---------- a folder's own (kit add --dir): only agents started there get it ----------
Set-Home (Join-Path $T 'home5')
W "$H/.codex/config.toml" "model = `"gpt-5`"`n`n[mcp_servers.mine]`ncommand = `"x`"`n"; W "$H/.omp/agent/x" ''
Copy-Item "$H/.codex/config.toml" "$T/codex5.orig"
$FP = Join-Path $T 'fproj'; [void](New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $FP 'sub') 'deeper'))
W "$FP/CLAUDE.md" "# my notes`n"; W "$FP/.mcp.json" "{`n  `"mcpServers`": {`n    `"own`": {`n      `"command`": `"y`"`n    }`n  }`n}`n"
Copy-Item "$FP/CLAUDE.md" "$T/fp.claude"; Copy-Item "$FP/.mcp.json" "$T/fp.mcp"
Kit init $TEAM
$FR = & { $script:OnWindows = $OnWindows; if ($OnWindows) { (Get-Item -LiteralPath $FP).FullName } else { "$(& /bin/sh -c 'cd "$1" && pwd -P' sh $FP)".Trim() } }
Kit add --dir $FP skill gerrit-review
Check 'add --dir: done, says where' { $rc -eq 0 -and $out.Contains($FR) }
Check 'add --dir: .agentkit lists it, Claude and Codex/omp skill folders' { (ReadT "$FP/.agentkit").Contains("skill:gerrit-review`n") -and (Test-Path "$FP/.claude/skills/gerrit-review/SKILL.md") -and (Test-Path "$FP/.agents/skills/gerrit-review/SKILL.md") }
Check 'add --dir: not the account' { -not (Test-Path "$H/.claude/skills/gerrit-review") -and -not (Test-Path "$H/.agents/skills/gerrit-review") }
Kit add --dir (Join-Path (Join-Path $FP 'sub') 'deeper') rule gerrit-flow
Check 'add --dir from a sub-folder goes to the folder that has .agentkit' { -not (Test-Path "$FP/sub/deeper/.agentkit") -and (ReadT "$FP/.agentkit").Contains("rule:gerrit-flow") }
Check 'add --dir rule: CLAUDE.md keeps the user text and imports it; AGENTS.md has the text' { $c = ReadT "$FP/CLAUDE.md"; $c.StartsWith("# my notes`n") -and $c.Contains('rules/gerrit-flow.md') -and (ReadT "$FP/AGENTS.md").Contains('Only comment, never submit.') }
Check 'codex: project_root_markers at the top, user part kept' { $c = ReadT "$H/.codex/config.toml"; $c.StartsWith('# agentkit:top:begin') -and $c.Contains('project_root_markers = [".git", ".agentkit"]') -and $c.Contains("model = `"gpt-5`"") }
Kit add --dir $FP mcp gerrit
Check 'add --dir mcp: .mcp.json has it and the own; Claude does not ask' { (JGet "$FP/.mcp.json" 'mcpServers.gerrit.command') -eq '"uvx"' -and (JGet "$FP/.mcp.json" 'mcpServers.own.command') -eq '"y"' -and (Flat (JGet "$FP/.claude/settings.local.json" 'enabledMcpjsonServers')) -eq '["gerrit"]' }
Check 'add --dir mcp: the folder Codex config, and Codex trusts the folder' { (ReadT "$FP/.codex/config.toml").Contains('[mcp_servers.gerrit]') -and (ReadT "$H/.codex/config.toml").Contains("[projects.`"$($FR.Replace('\', '\\'))`"]`ntrust_level = `"trusted`"") }
Kit list --json --dir (Join-Path $FP 'sub')
Check 'list --json: the folder with .agentkit, its items' { $out.Contains("`"folder`": {`"dir`": $(& { '"' + $FR.Replace('\', '\\') + '"' }), `"why`": `"`", `"items`": [`"skill:gerrit-review`", `"rule:gerrit-flow`", `"mcp:gerrit`"]}") }
if (-not $OnWindows) {
    $env:HOME = $H; $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' unix/kit list --json --dir '$FP/sub' 2>&1") -join "`n"
    Check 'list --json --dir with a folder of its own: unix/kit prints the same' { $bash -ceq $out }
}
Kit add --dir $H skill gerrit-review
Check 'add --dir: refuses the home folder' { $rc -ne 0 -and $out.Contains('家目錄') -and -not (Test-Path "$H/.agentkit") }
Kit rm --dir $FP skill gerrit-workflow
Check 'rm --dir: only what the folder added' { $rc -ne 0 -and $out.Contains('沒有加') }
Kit rm --dir $FP skill gerrit-review; Kit rm --dir $FP rule gerrit-flow; Kit rm --dir $FP mcp gerrit
Check 'rm --dir all: the folder exactly as before' { (SameBytes "$T/fp.claude" "$FP/CLAUDE.md") -and (SameBytes "$T/fp.mcp" "$FP/.mcp.json") -and ((@(Get-ChildItem -LiteralPath $FP -Force | ForEach-Object { $_.Name } | Sort-Object) -join ' ') -eq '.mcp.json CLAUDE.md sub') }
Check 'rm --dir all: Codex config byte-identical, kit forgets the folder' { (SameBytes "$T/codex5.orig" "$H/.codex/config.toml") -and -not (Test-Path "$H/.config/agentkit/dirs") }
Kit add --dir $FP skill gerrit-review; Kit add --dir $FP mcp gerrit
Kit uninstall
Check 'uninstall: the folder and Codex config exactly as before' { (SameBytes "$T/fp.claude" "$FP/CLAUDE.md") -and (SameBytes "$T/fp.mcp" "$FP/.mcp.json") -and -not (Test-Path "$FP/.agentkit") -and (SameBytes "$T/codex5.orig" "$H/.codex/config.toml") }

# ---------- the programs a skill needs (kit tools / install-tool, "needs" in list --json) ----------
Set-Home (Join-Path $T 'home6')
$NT = Join-Path $T 'needteam'
W "$NT/skills/drawer/SKILL.md" "---`nname: drawer`ndescription: draws`n---`nRun ``node bin/draw.mjs <in>`` to draw.`n"
W "$NT/skills/drawer/package.json" "{`"name`": `"drawer`", `"engines`": {`"node`": `">=18`"}}`n"
W "$NT/skills/plain/SKILL.md" "---`nname: plain`ndescription: only text`n---`nNo node, no python here.`n"
W "$NT/skills/plain/package.json" "{`"name`": `"plain`"}`n"; W "$NT/skills/plain/scripts/check.py" "print(1)`n"
W "$NT/skills/told/SKILL.md" "---`nname: told`ndescription: says`nrequires: [node>=20, frob]`n---`nx`n"
W "$NT/kit.yaml" "name: needteam`nrequires:`n  plain: [git]`n"
W "$NT/skills/packed/SKILL.md" "---`nname: packed`ndescription: has npm packages`n---`nRun ``node scripts/run.mjs``.`n"
W "$NT/skills/packed/scripts/run.mjs" "x`n"; W "$NT/skills/packed/package.json" "{`"name`": `"packed`", `"dependencies`": {`"left-pad`": `"1.3.0`"}}`n"
W "$NT/skills/packed/package-lock.json" "{`"lockfileVersion`": 3}`n"; W "$NT/skills/packed/.npmrc" "registry=http://elsewhere.invalid/`n"
W "$NT/skills/pyskill/SKILL.md" "---`nname: pyskill`ndescription: python packages`n---`nRun ``python3 scripts/go.py``.`n"
W "$NT/skills/pyskill/requirements.txt" "# what it needs`nrequests==2.32.0`n"
W "$NT/skills/pybad/SKILL.md" "---`nname: pybad`ndescription: b`n---`nx`n"; W "$NT/skills/pybad/requirements.txt" "requests`n-e git+http://elsewhere.invalid/x`n"
Kit init $NT
Kit list --json
$items = @{}; foreach ($m in [regex]::Matches($out, '"name": "(drawer|plain|told)".*?"needs": (\[[^\]]*\])')) { $items[$m.Groups[1].Value] = $m.Groups[2].Value }
Check 'needs: SKILL.md runs node, package.json gives the lowest version' { $items['drawer'] -match '"tool": "node", "title": "Node.js", "min": "18"' }
Check 'needs: a package.json or a .py of the author says nothing; kit.yaml requires does' { $items['plain'] -match '"tool": "git"' -and $items['plain'] -notmatch '"tool": "(node|python)"' }
Check 'needs: SKILL.md requires; an unknown program has no install' { $items['told'] -match '"min": "20"' -and $items['told'] -match '"tool": "frob", "title": "frob", "min": "", "have": "", "ok": false, "install": ""' }
if (-not $OnWindows) {
    $FB = Join-Path $T 'fakebin6'; [void](New-Item -ItemType Directory -Force -Path $FB)
    W "$FB/node" "#!/bin/sh`necho v16.2.0`n"
    W "$FB/brew" "#!/bin/sh`necho `"`$*`" >> '$T/brew6.log'`n[ `"`$1`" = upgrade ] && printf '#!/bin/sh\necho v26.1.0\n' > '$FB/node'`nexit 0`n"
    & chmod +x "$FB/node" "$FB/brew"
    $savedP = $env:PATH; $env:PATH = "$FB" + [IO.Path]::PathSeparator + '/usr/bin:/bin'
    Kit list --json
    Check 'needs: too old here, kit says the upgrade' { $out -match '"tool": "node", "title": "Node.js", "min": "18", "have": "16.2.0", "ok": false, "install": "brew upgrade node"' }
    Kit tools
    Check 'tools: what this machine has and how kit would install it' { $out -match '(?m)^node +16\.2\.0 +brew install node$' }
    $env:KIT_DRY_RUN = '1'; Kit install-tool node --min 18; Remove-Item env:KIT_DRY_RUN
    Check 'install-tool --min, dry run: only says the upgrade' { $out.Contains('執行 brew upgrade node') -and -not (Test-Path "$T/brew6.log") }
    Kit install-tool node --min 18
    Check 'install-tool --min: runs kit''s upgrade, then looks again' { $rc -eq 0 -and (ReadT "$T/brew6.log") -eq "upgrade node`n" -and $out.Contains('Node.js 26.1.0 裝好了') }
    Remove-Item "$T/brew6.log"
    W "$NT/tools/frob.yaml" "name: frob`ntitle: Frob`ninstall:`n  mac: [`"sh -c evil`", `"brew frob;rm`", `"curl x`", `"brew frob`"]`n  linux: [`"sh -c evil`", `"brew frob;rm`", `"curl x`", `"brew frob`"]`n"
    Kit install-tool frob
    Check 'install-tool: a recipe can only pick a known manager and a plain package name' { (ReadT "$T/brew6.log") -eq "install frob`n" -and $out.Contains('執行 brew install frob') }
    $env:PATH = $savedP
}
Kit install-tool nope
Check 'install-tool: no recipe, says how to add one' { $rc -ne 0 -and $out.Contains('tools/nope.yaml') }
# a skill's own npm packages (kit install-deps): only when asked, in kit's folder, no package scripts, linked into each copy
$FB7 = Join-Path $T 'fakebin7'; [void](New-Item -ItemType Directory -Force -Path $FB7)
if ($OnWindows) {
    W "$FB7/npm.cmd" "@echo off`r`necho %CD% %*>> `"$T\npm7.log`"`r`nif exist .npmrc exit /b 9`r`nmkdir node_modules\left-pad`r`necho x> node_modules\left-pad\index.js`r`n"
} else {
    W "$FB7/npm" "#!/bin/sh`necho `"`$PWD `$*`" >> '$T/npm7.log'`n[ -f .npmrc ] && exit 9`nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js`n"; & chmod +x "$FB7/npm"
}
$savedP = $env:PATH; $env:PATH = "$FB7" + [IO.Path]::PathSeparator + $env:PATH
function PkOf([string]$n, [string]$k = 'npm') { $m = [regex]::Match($out, '"name": "' + $n + '"[^\n]*?"packages": \[[^\n]*?(\{"kind": "' + $k + '"[^}]*\})'); if ($m.Success) { $m.Groups[1].Value } else { $null } }
Kit list --json
Check 'packages: a lock -> npm ci, no package scripts' { (PkOf 'packed') -eq '{"kind": "npm", "ok": false, "had": false, "install": "npm ci --ignore-scripts --no-audit --no-fund", "bad": ""}' -and $null -eq (PkOf 'drawer') }
Kit add skill packed
$env:KIT_DRY_RUN = '1'; Kit install-deps packed; Remove-Item env:KIT_DRY_RUN
Check 'install-deps, dry run: only says the command' { $out.Contains('執行 npm ci --ignore-scripts --no-audit --no-fund') -and -not (Test-Path "$T/npm7.log") }
$S7 = Join-Path $H '.config/agentkit/deps/packed'; $C7 = Join-Path $H '.claude/skills/packed'
Kit install-deps packed
Check 'install-deps: npm ci in kit''s folder, not the source, without the skill''s .npmrc' { $rc -eq 0 -and (ReadT "$T/npm7.log").Trim().Replace('\', '/').EndsWith('.config/agentkit/deps/packed.new ci --ignore-scripts --no-audit --no-fund') -and (Test-Path "$S7/node_modules/left-pad/index.js") -and -not (Test-Path "$NT/skills/packed/node_modules") -and -not (Test-Path "$S7/.npmrc") }
Check 'install-deps: the copy kit put gets node_modules linked to it' { (Get-Item -LiteralPath "$C7/node_modules" -Force).LinkType -and (Test-Path "$C7/node_modules/left-pad/index.js") }
Kit list --json
Check 'packages: installed now' { (PkOf 'packed') -eq '{"kind": "npm", "ok": true, "had": true, "install": "npm ci --ignore-scripts --no-audit --no-fund", "bad": ""}' }
Kit sync
Check 'sync: the link is not a change to the skill' { $out -notmatch '手動' -and (Get-Item -LiteralPath "$C7/node_modules" -Force).LinkType }
# Python: a venv of the skill's own (fake python here), requirements.txt with names and versions only
Kit list --json
Check 'packages (pip): a requirements.txt with options is shown as refused' { (PkOf 'pybad' 'pip') -match '"bad": "2: -e git\+http://elsewhere.invalid/x"' }
Kit install-deps pybad
Check 'install-deps (pip): refuses options in requirements.txt' { $rc -ne 0 -and $out.Contains('第 2: -e') -and -not (Test-Path (Join-Path $H '.config/agentkit/pydeps/pybad')) }
if (-not $OnWindows) {
    $realPy = (Get-Command python3 -CommandType Application | Select-Object -First 1).Source
    W "$FB7/python3" "#!/bin/sh`n[ `"`$1 `$2`" = '-m venv' ] || exec '$realPy' `"`$@`"`nmkdir -p `"`$3/bin`" && printf '#!/bin/sh\necho `"`$PWD `$*`" >> $T/pip7.log\n' > `"`$3/bin/python`" && chmod +x `"`$3/bin/python`"`n"; & chmod +x "$FB7/python3"
    Kit list --json
    Check 'packages (pip): a venv and pip with wheels only' { (PkOf 'pyskill' 'pip') -eq '{"kind": "pip", "ok": false, "had": false, "install": "python3 -m venv venv; venv/bin/python -m pip install --only-binary=:all: --no-input --disable-pip-version-check -r requirements.txt", "bad": ""}' }
    Kit add skill pyskill
    Kit install-deps pyskill pip
    $S8 = Join-Path $H '.config/agentkit/pydeps/pyskill'; $C8 = Join-Path $H '.claude/skills/pyskill'
    Check 'install-deps (pip): a venv in kit''s folder, pip run there with wheels only' { $rc -eq 0 -and (ReadT "$T/pip7.log").Trim().EndsWith('pydeps/pyskill -m pip install --only-binary=:all: --no-input --disable-pip-version-check -r requirements.txt') -and (Test-Path "$S8/venv/bin/python") -and -not (Test-Path "$NT/skills/pyskill/.venv") }
    Check 'install-deps (pip): the copy gets .venv linked, the instructions say to use it' { (Get-Item -LiteralPath "$C8/.venv" -Force).LinkType -and (ReadT (Join-Path $H '.claude/CLAUDE.md')).Contains('.venv/bin/python') }
    Remove-Item "$FB7/python3"
}
Kit rm skill packed
Check 'rm skill: the copy goes, kit''s packages stay (the link only)' { -not (Test-Path $C7) -and (Test-Path "$S7/node_modules/left-pad/index.js") }
Kit uninstall
Check 'uninstall: kit''s packages go too' { -not (Test-Path (Join-Path $H '.config/agentkit/deps')) -and -not (Test-Path (Join-Path $H '.config/agentkit/pydeps')) }
$env:PATH = $savedP

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
Add-Content -LiteralPath "$UP/skills/foo/SKILL.md" 'foo v2'; G -C $UP commit -qam v2
Kit outdated
Check 'outdated: new version upstream' { $out -match 'foo：有新版本' -and $out -match 'kit collect foo' }
Add-Content -LiteralPath "$CO/skills/foo/SKILL.md" 'local edit'
Kit collect foo
$v2 = "$(& git -C $UP rev-parse HEAD)".Trim()
Check 'collect <name> replaces the whole copy with the new version' { $l = ReadT "$CO/third_party.lock"; $s = ReadT "$CO/skills/foo/SKILL.md"; $rc -eq 0 -and $s -match 'foo v2' -and $s -notmatch 'local edit' -and $l.Contains($v2) -and @($l -split "`n" | Where-Object { $_ -like "foo`t*" }).Count -eq 1 }
G -C $UP tag -a v1.0 -m rel; Add-Content -LiteralPath "$UP/skills/foo/SKILL.md" 'foo v3'; G -C $UP commit -qam v3
Kit collect foo --ref v1.0
Check 'collect --ref takes a tag' { $rc -eq 0 -and (ReadT "$CO/skills/foo/SKILL.md") -notmatch 'foo v3' }
Kit outdated
Check 'outdated follows the tag, not the branch' { $out -match 'foo：最新' }
Add-Content -LiteralPath "$CO/kit.yaml" 'maintainers: [someone-else]'
Kit collect foo
Check 'only maintainers may collect' { $rc -ne 0 -and $out -match '維護者' }
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
$j = $null; try { $j = $out | ConvertFrom-Json } catch { }
Check 'collect --look on an author not on the list: says so (a team source: no --allow)' { $rc -eq 0 -and $j.allowed -eq $false -and $j.can_allow -eq $false -and $j.skills[0].path -eq 'skills/foo' }
Kit collect (FileUrl $UP) --path skills/foo --allow
Check 'collect --allow refused in a team source (no push: direct)' { $rc -ne 0 -and $out -match 'push: direct' -and -not (Test-Path "$CO/skills/foo") }
W "$CO/kit.yaml" "name: collector`npush: direct`ncollect_sources: [$(FileUrl $U2)]   # authors`n"
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
Pop-Location


# ---------- herdr-panel: the kit panel as a Herdr mod ----------
$HH = Join-Path $T 'herdr-app'
W "$HH/mods/.keep" ''
W "$HH/layouts/mine.json" "{`"id`":`"root`",`"type`":`"row`",`"children`":[{`"id`":`"bar`",`"type`":`"row`",`"children`":[{`"id`":`"tabs`",`"type`":`"block`",`"content`":{`"mod`":`"tabs`"}}]},{`"id`":`"body`",`"type`":`"row`",`"children`":[{`"id`":`"main`",`"type`":`"block`",`"content`":{`"tab`":`"active`",`"pane`":{`"header`":{`"content`":{`"mod`":`"pane`"},`"reveal`":`"always`"}}}}]}]}`n"
$mineOrig = ReadT "$HH/layouts/mine.json"
W "$HH/layouts/main.json" "{`"main`":1}`n"
W "$HH/shared.json" "{`n  `"layout`": `"mine`"`n}`n"
$env:HERDR_APP_HOME = $HH
function Backups { @(Get-ChildItem -LiteralPath "$HH/layouts" -File | Where-Object { $_.Name -like 'mine.json.kit-backup-*' }) }
Kit herdr-panel install
$cfg = if (Test-Path "$HH/mods/kit/config.json") { ReadT "$HH/mods/kit/config.json" } else { '' }
$kitJ = if ($OnWindows) { '"kit.cmd"' } else { '"' + $Exe.Replace('\', '\\') + '", "-NoProfile", "-File", "' + $Kit.Replace('\', '\\') + '"' }
Check 'herdr-panel install: mod files, config with the kit command' { $rc -eq 0 -and (Test-Path "$HH/mods/kit/main.js") -and (Test-Path "$HH/mods/kit/.kit-panel") -and $cfg.Contains("`"kit`": [$kitJ]") -and $cfg.Contains('"env": {}') }
$ml = ReadT "$HH/layouts/mine.json"
Check 'herdr-panel install: button in the tab bar, panel beside the work area' { ([regex]::Matches($ml, '"kit-toggle"')).Count -eq 1 -and $ml.Contains('"kit-panel"') -and (ReadT "$HH/mods/kit/mod.json").Contains('"place": "none"') }
$flat = $ml -replace '\s', ''
Check "herdr-panel install: an Agents button before Kit's, its panel hidden beside Kit's" { $flat -match '"kit-agents-toggle".*"kit-toggle"' -and $flat -match '"kit-panel".*"kit-agents-panel".*"hidden":true' }
Check 'herdr-panel install: the Agents window (mods/kit-agents)' { (Test-Path "$HH/mods/kit-agents/main.js") -and (Test-Path "$HH/mods/kit-agents/.kit-panel") -and (ReadT "$HH/mods/kit-agents/mod.json").Contains('"kind": "window"') }
Check "herdr-panel install: each pane's header is kit's (mods/kit-pane)" { $ml.Contains('"mod": "kit-pane"') -and -not $ml.Contains('"mod": "pane"') -and (Test-Path "$HH/mods/kit-pane/main.js") -and (Test-Path "$HH/mods/kit-pane/.kit-panel") -and (ReadT "$HH/mods/kit-pane/mod.json").Contains('"place": "none"') }
Check 'herdr-panel install: layout backed up first' { @(Backups).Count -eq 1 -and (ReadT @(Backups)[0].FullName) -ceq $mineOrig }
Kit herdr-panel install
Check 'herdr-panel install again: layout not changed twice' { $rc -eq 0 -and ([regex]::Matches((ReadT "$HH/layouts/mine.json"), '"kit-toggle"')).Count -eq 1 -and @(Backups).Count -eq 1 }
$moved = (ReadT "$HH/layouts/mine.json").Replace('"px": 56', '"px": 42'); W "$HH/layouts/mine.json" $moved
Kit herdr-panel install
Check 'herdr-panel install again: a hand-arranged layout is kept' { $rc -eq 0 -and (ReadT "$HH/layouts/mine.json") -ceq $moved }
W "$HH/mods/kit/main.js" 'old'; W "$HH/mods/kit-pane/main.js" 'old'; $pcfg = ReadT "$HH/mods/kit/config.json"
$env:AGENTKIT_HOME = Join-Path $T 'inst-p'; & $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'windows/install.ps1') -Quiet; Remove-Item env:AGENTKIT_HOME
Check 'reinstall / self-update refreshes an installed panel, keeps its settings' { (SameBytes "$HH/mods/kit/main.js" (Join-Path $Repo 'herdr/kit-panel/main.js')) -and (ReadT "$HH/mods/kit/config.json") -ceq $pcfg }
Check 'reinstall / self-update refreshes the pane header too' { SameBytes "$HH/mods/kit-pane/main.js" (Join-Path $Repo 'herdr/kit-pane/main.js') }
if (-not $OnWindows) {
    Kit herdr-panel install --keep-env
    Check 'herdr-panel --keep-env: the panel runs kit with this HOME' { (ReadT "$HH/mods/kit/config.json").Contains("`"HOME`": `"$H`"") }
}
Kit herdr-panel uninstall
$ml = ReadT "$HH/layouts/mine.json"
Check 'herdr-panel uninstall: mod and layout blocks gone' { $rc -eq 0 -and -not (Test-Path "$HH/mods/kit") -and -not $ml.Contains('kit') -and $ml.Contains('"tabs"') }
Check "herdr-panel uninstall: Herdr's own pane header is back, Agents window gone" { -not (Test-Path "$HH/mods/kit-pane") -and -not (Test-Path "$HH/mods/kit-agents") -and $ml.Contains('"mod": "pane"') }
W "$HH/shared.json" "{`n  `"layout`": `"main`"`n}`n"
Kit herdr-panel install
Check 'herdr-panel on a Herdr layout: not edited, panel docks on the right' { $rc -eq 0 -and (ReadT "$HH/layouts/main.json") -eq "{`"main`":1}`n" -and (ReadT "$HH/mods/kit/mod.json").Contains('"place": "right"') -and $out.Contains('放進上排') }
Kit herdr-panel uninstall
W "$HH/mods/kit/main.js" 'mine'
Kit herdr-panel install
Check "herdr-panel: someone else's mods/kit is left alone" { $rc -ne 0 -and $out.Contains('不是 kit 放的') -and (ReadT "$HH/mods/kit/main.js") -eq 'mine' }
Kit herdr-panel uninstall
Check "herdr-panel uninstall: someone else's mods/kit is left alone" { $rc -ne 0 -and (Test-Path "$HH/mods/kit/main.js") }
Remove-Item -Recurse -Force "$HH/mods/kit"; W "$HH/mods/kit-agents/main.js" 'theirs'
W "$HH/shared.json" "{`n  `"layout`": `"mine`"`n}`n"; $mineBefore = ReadT "$HH/layouts/mine.json"
Kit herdr-panel install
Check "herdr-panel: someone else's mods/kit-agents stops it before anything is written" { $rc -ne 0 -and $out.Contains('kit-agents 已經有東西') -and -not (Test-Path "$HH/mods/kit") -and -not (Test-Path "$HH/mods/kit-pane") -and (ReadT "$HH/layouts/mine.json") -ceq $mineBefore -and (ReadT "$HH/mods/kit-agents/main.js") -eq 'theirs' }
Remove-Item -Recurse -Force "$HH/mods/kit-agents"
W "$HH/layouts/compact.json" "{`"id`":`"root`",`"children`":[{`"id`":`"main`",`"content`":{`"tab`":`"active`",`"pane`":{`"header`":{`"content`":{`"mod`":`"kit-pane`"}}}}}]}`n"
$plain = "{`"id`":`"root`",`"children`":[{`"id`":`"tabs`",`"content`":{`"mod`":`"tabs`"}}]}`n"; W "$HH/layouts/plain.json" $plain
Kit herdr-panel uninstall
Check "herdr-panel uninstall: kit's parts go however the layout is written" { $rc -eq 0 -and -not (ReadT "$HH/layouts/compact.json").Contains('kit-pane') -and (ReadT "$HH/layouts/compact.json").Contains('"mod": "pane"') }
Check "herdr-panel uninstall: a layout without kit's parts is not touched" { (ReadT "$HH/layouts/plain.json") -ceq $plain -and @(Get-ChildItem -LiteralPath "$HH/layouts" -File | Where-Object { $_.Name -like 'plain.json.kit-backup-*' }).Count -eq 0 }
$env:HERDR_APP_HOME = Join-Path $T 'no-herdr'
Kit herdr-panel install
Check 'herdr-panel without Herdr: says so' { $rc -ne 0 -and $out.Contains('找不到 Herdr') }
Remove-Item env:HERDR_APP_HOME

# ---------- install.ps1 ----------
$env:AGENTKIT_HOME = Join-Path $T 'inst'
& $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'windows/install.ps1') -Quiet
Remove-Item env:AGENTKIT_HOME
$Kit = Join-Path $T 'inst/lib/kit.ps1'
Kit ci-template
Check 'installed kit has the ci template' { $rc -eq 0 -and $out -ceq $tmpl }
Check 'installed kit has the Herdr panel' { (Test-Path (Join-Path $T 'inst/lib/herdr/kit-panel/main.js')) -and (Test-Path (Join-Path $T 'inst/lib/herdr/kit-pane/main.js')) }
$Kit = $realKit

# ---------- sync: why a source could not be updated ----------
$SY = Join-Path $T 'syncwhy'; $SW = Join-Path $SY 'w'
& git -c init.defaultBranch=main init -q $SW
W "$SW/kit.yaml" "name: s`n"; W "$SW/rules/a.md" "v1`n"
G -C $SW add -A; G -C $SW -c user.name=t -c user.email=t@t commit -qm v1; G clone -q --bare $SW (Join-Path $SY 's.git')
$oldH = $H; Set-Home (Join-Path $SY 'home')
Kit init (FileUrl (Join-Path $SY 's.git'))
$C = Join-Path $H 'agentkit/s'
W "$SW/rules/a.md" "v2`n"; G -C $SW -c user.name=t -c user.email=t@t commit -qam v2; G -C $SW push -q (Join-Path $SY 's.git') HEAD:main
W "$C/rules/a.md" "mine`n"
Kit sync
Check 'sync: a source with your own changes in the way says so' { $out -match '沒辦法更新 s（.*自己改過' }
G -C $C checkout -q -- rules/a.md; G -C $C -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
Kit sync
Check 'sync: a source with its own commits says it went its own way' { $out -match '沒辦法更新 s（.*分岔' }
G -C $C remote set-url origin (FileUrl (Join-Path $SY 'gone.git'))
Kit sync
Check 'sync: no network is told apart' { $out.Contains('沒辦法更新 s（沒網路？）') }
Set-Home $oldH

# ---------- review fixes: the user's own MCP, state only after writing, CRLF / links / markers, URLs, push ----------
function Imp([string]$p) { '@' + $p.Replace('\', '/').Replace(' ', '\ ') }
$oldH = $H; Set-Home (Join-Path $T 'home-rf')
$RS = Join-Path $T 'rf/src dir'; $CJ = "$H/.claude.json"; $ST = "$H/.config/agentkit/state.tsv"
W "$RS/kit.yaml" "name: rfsrc`nrequired:`n  rules: [r1]`n"; W "$RS/rules/r1.md" "Rule one.`n"
W "$RS/mcp/m1.yaml" "command: theirs`n"; W "$RS/mcp/m2.yaml" "command: kits`n"
$cjOrig = "{`n  `"mcpServers`": {`n    `"m1`": {`n      `"command`": `"mine`"`n    }`n  }`n}`n"; W $CJ $cjOrig
$crlf = "My line one`r`nMy line two`r`n"; W "$H/.claude/CLAUDE.md" $crlf
Kit init $RS
Check "@import: forward slashes, a space escaped (Claude's @path stops at a backslash or space)" { $rc -eq 0 -and (ReadT "$H/.claude/CLAUDE.md").Contains((Imp (Join-Path $RS 'rules/r1.md')) + "`r`n") }
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
$RH = Join-Path $T 'rf/herdr'; W "$RH/mods/.keep" ''; W "$RH/shared.json" "{`n  `"layout`": `"x`"`n}`n"
W "$RH/layouts/x.json" "{`"id`":`"root`",`"type`":`"row`",`"title`":`"kit-toggle`",`"note`":`"kit-panel`",`"children`":[{`"id`":`"bar`",`"type`":`"row`",`"children`":[{`"id`":`"tabs`",`"type`":`"block`",`"content`":{`"mod`":`"tabs`"}}]},{`"id`":`"body`",`"type`":`"row`",`"children`":[{`"id`":`"main`",`"type`":`"block`",`"content`":{`"tab`":`"active`"}}]}]}`n"
$env:HERDR_APP_HOME = $RH
Kit herdr-panel install
Check "herdr-panel: the words in a title are not kit's nodes (they get added)" { $x = ReadT "$RH/layouts/x.json"; $x.Contains('"id": "kit-toggle"') -and $x.Contains('"id": "kit-panel"') }
W "$RH/layouts/x.json" ((ReadT "$RH/layouts/x.json").Replace('"id": "kit-panel"', '"id": "my-col"'))
Kit herdr-panel uninstall
Check "herdr-panel uninstall: a renamed column with only kit's block is gone too" { $x = ReadT "$RH/layouts/x.json"; -not $x.Contains('my-col') -and -not $x.Contains('"mod": "kit') }
Remove-Item env:HERDR_APP_HOME
Set-Home $oldH

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
