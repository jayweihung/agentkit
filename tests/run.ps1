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
$env:KIT_TRANSCRIPT_CHECK = '0'   # (kit sync --hook does not look at the Claude these tests may run in)
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

# ---------- is Claude saving its transcript? (kit sync --hook under a fake claude started with a chosen environment) ----------
$FC = Join-Path $T 'fake-claude'; $TH = Join-Path $T 'tch'
[void](New-Item -ItemType Directory -Force -Path $FC, (Join-Path $TH '.claude'))
if ($OnWindows) { Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') (Join-Path $FC 'claude.exe') }
elseif ($IsMacOS) {   # ps -E shows no environment of Apple's own programs (bash, sh): a tiny one of our own
    W "$FC/c.c" "#include <stdlib.h>`nint main(int c, char **v) { return system(v[1]) == 0 ? 0 : 1; }`n"
    & xcode-select -p *> $null; if ($LASTEXITCODE -eq 0) { & cc -o "$FC/claude" "$FC/c.c" 2>$null }
} else { & ln -s (Get-Command bash).Source "$FC/claude" }
function TC([hashtable]$envs, [switch]$HookChild) { # kit sync --hook run by the fake claude started with $envs; output in $script:out
    $names = 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE', 'KIT_TRANSCRIPT_CHECK'
    $keep = @{}; foreach ($v in $names + 'HOME', 'USERPROFILE') { $keep[$v] = [Environment]::GetEnvironmentVariable($v) }
    foreach ($v in $names) { [Environment]::SetEnvironmentVariable($v, $null) }
    $env:HOME = $TH; $env:USERPROFILE = $TH
    foreach ($k in $envs.Keys) { [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
    $o = Join-Path $T 'tc.out'; Remove-Item -LiteralPath $o -ErrorAction SilentlyContinue
    try {   # -HookChild: the hook's own environment has CHILD_SESSION=1 (Claude gives it to every hook)
        $kc = if ($HookChild) { "`"$Exe`" -NoProfile -ExecutionPolicy Bypass -Command `"`$env:CLAUDE_CODE_CHILD_SESSION='1'; & '$Kit' sync --hook`"" }
              else { "`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$Kit`" sync --hook" }
        if ($OnWindows) { Start-Process -FilePath (Join-Path $FC 'claude.exe') -ArgumentList "/d /c `"$kc > `"$o`"`"" -Wait -NoNewWindow }
        elseif ($IsMacOS) { & "$FC/claude" ($kc.Replace('$', '\$') + " > '$o'") }
        else { & "$FC/claude" -c ($kc.Replace('$', '\$') + " > '$o'; :") }
    } finally { foreach ($v in $keep.Keys) { [Environment]::SetEnvironmentVariable($v, $keep[$v]) } }
    $script:out = if (Test-Path -LiteralPath $o) { (ReadT $o).Trim() } else { '' }
}
if ((Test-Path (Join-Path $FC 'claude')) -or (Test-Path (Join-Path $FC 'claude.exe'))) {
    TC @{}; Check 'transcript: a normal claude: nothing said' { $out -eq '' }
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1' }; W "$T/tc.json" $out
    Check 'transcript: claude started with CHILD_SESSION=1: warned, as JSON for Claude' { (JGet "$T/tc.json" 'hookSpecificOutput.hookEventName') -eq '"SessionStart"' -and (JGet "$T/tc.json" 'systemMessage').Contains('/resume') }
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1'; CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = '1' }
    Check 'transcript: ... and FORCE_SESSION_PERSISTENCE=1 too: nothing said' { $out -eq '' }
    TC @{} -HookChild; Check "transcript: the hook's own CHILD_SESSION=1 (Claude gives it to every hook) is not looked at" { $out -eq '' }
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1'; KIT_TRANSCRIPT_CHECK = '0' }; Check 'transcript: KIT_TRANSCRIPT_CHECK=0: nothing said' { $out -eq '' }
    W "$TH/.claude/settings.json" '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/transcript-check.sh"}]}]}}'
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1' }; Check 'transcript: your own transcript-check hook: kit says nothing (no second warning)' { $out -eq '' }
} else { [Console]::WriteLine('(transcript check: skipped, no C compiler on this Mac)') }

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
W "$NT/skills/packed/package-lock.json" "{`"lockfileVersion`": 3, `"packages`": {`"`": {`"dependencies`": {`"left-pad`": `"1.3.0`"}}, `"node_modules/left-pad`": {`"version`": `"1.3.0`", `"resolved`": `"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz`", `"integrity`": `"sha512-XI5MPzVNApjAyhQzphX8BkmKsKUxD4LdyK24iZeQEGg9ylg3cs3KHoxHhvlaXRBmtqI9zaxOttfQ9EE5zORWb4w==`"}}}`n"
W "$NT/skills/packed/.npmrc" "registry=http://elsewhere.invalid/`n"
# npm packages kit must not install: a git dependency; a lock with a package from git; a lock on another registry
foreach ($n in 'npmgit', 'npmlock', 'npmreg') { W "$NT/skills/$n/SKILL.md" "---`nname: $n`ndescription: x`n---`nx`n" }
W "$NT/skills/npmgit/package.json" "{`"name`": `"npmgit`", `"dependencies`": {`"left-pad`": `"1.3.0`"}, `"optionalDependencies`": {`"tool`": `"github:someone/tool`"}}`n"
W "$NT/skills/npmlock/package.json" "{`"name`": `"npmlock`", `"dependencies`": {`"tool`": `"^1.0.0`"}}`n"
W "$NT/skills/npmlock/package-lock.json" "{`"lockfileVersion`": 1, `"dependencies`": {`"tool`": {`"version`": `"1.0.0`", `"resolved`": `"https://registry.npmjs.org/tool/-/tool-1.0.0.tgz`", `"integrity`": `"sha512-x`", `"dependencies`": {`"sub`": {`"version`": `"git+ssh://git@github.com/someone/sub.git#abc`", `"resolved`": `"git+ssh://git@github.com/someone/sub.git#abc`"}}}}}`n"
W "$NT/skills/npmreg/package.json" "{`"name`": `"npmreg`", `"dependencies`": {`"tool`": `"^1.0.0`"}}`n"
W "$NT/skills/npmreg/package-lock.json" "{`"lockfileVersion`": 3, `"packages`": {`"`": {}, `"node_modules/tool`": {`"version`": `"1.0.0`", `"resolved`": `"https://npm.example.com/r/tool/-/tool-1.0.0.tgz`", `"integrity`": `"sha512-x`"}}}`n"
W "$NT/skills/asks/SKILL.md" "---`nname: asks`ndescription: x`nrequires: [noprobe]`n---`nx`n"
W "$NT/skills/pyskill/SKILL.md" "---`nname: pyskill`ndescription: python packages`n---`nRun ``python3 scripts/go.py``.`n"
W "$NT/skills/pyskill/requirements.txt" "# what it needs`nrequests==2.32.0`ncertifi ; sys_platform != 'win32' and python_version < `"4`"  # ok`n"
W "$NT/skills/pybad/SKILL.md" "---`nname: pybad`ndescription: b`n---`nx`n"; W "$NT/skills/pybad/requirements.txt" "requests`n-e git+http://elsewhere.invalid/x`n"
W "$NT/skills/pymark/SKILL.md" "---`nname: pymark`ndescription: b`n---`nx`n"; W "$NT/skills/pymark/requirements.txt" "requests ; python_version >= `"3.8`" --config-settings=x=y`n"
Kit init $NT
Kit list --json
$items = @{}; foreach ($m in [regex]::Matches($out, '"name": "(drawer|plain|told)".*?"needs": (\[[^\]]*\])')) { $items[$m.Groups[1].Value] = $m.Groups[2].Value }
Check 'needs: SKILL.md runs node, package.json gives the lowest version' { $items['drawer'] -match '"tool": "node", "title": "Node.js", "min": "18"' }
Check 'needs: a package.json or a .py of the author says nothing; kit.yaml requires does' { $items['plain'] -match '"tool": "git"' -and $items['plain'] -notmatch '"tool": "(node|python)"' }
Check 'needs: SKILL.md requires; an unknown program has no install' { $items['told'] -match '"min": "20"' -and $items['told'] -match '"tool": "frob", "title": "frob", "min": "", "have": "", "ok": false, "install": ""' }
if (-not $OnWindows) {
    $FB = Join-Path $T 'fakebin6'; [void](New-Item -ItemType Directory -Force -Path $FB)
    W "$FB/node" "#!/bin/sh`necho v16.2.0`n"
    W "$FB/brew" "#!/bin/sh`necho `"`$*`" >> '$T/brew6.log'`n[ `"`$1`" = upgrade ] && printf '#!/bin/sh\necho v26.1.0\n' > '$FB/node'`ncase `$2 in bad*) exit 1;; frob) printf '#!/bin/sh\necho frob 1.2.3\n' > '$FB/frob'; chmod +x '$FB/frob';; esac`nexit 0`n"
    W "$FB/apt-get" "#!/bin/sh`nexit 1`n"                       # (a Linux run as root: never the real one)
    W "$FB/noprobe" "#!/bin/sh`necho ran >> '$T/noprobe6.log'`necho noprobe 1.0`n"
    & chmod +x "$FB/node" "$FB/brew" "$FB/apt-get" "$FB/noprobe"
    $savedP = $env:PATH; $env:PATH = "$FB" + [IO.Path]::PathSeparator + '/usr/bin:/bin'
    Kit list --json
    Check 'needs: a program kit has no recipe for is not run to look at it' { $out -match '"tool": "noprobe", "title": "noprobe", "min": "", "have": "", "ok": false, "install": ""' -and -not (Test-Path "$T/noprobe6.log") }
    Check 'needs: too old here, kit says the upgrade' { $out -match '"tool": "node", "title": "Node.js", "min": "18", "have": "16.2.0", "ok": false, "install": "brew upgrade node"' }
    Kit tools
    Check 'tools: what this machine has and how kit would install it' { $out -match '(?m)^node +16\.2\.0 +brew install node$' }
    $env:KIT_DRY_RUN = '1'; Kit install-tool node --min 18; Remove-Item env:KIT_DRY_RUN
    Check 'install-tool --min, dry run: only says the upgrade' { $out.Contains('執行 brew upgrade node') -and -not (Test-Path "$T/brew6.log") }
    Kit install-tool node --min 18
    Check 'install-tool --min: runs kit''s upgrade, then looks again' { $rc -eq 0 -and (ReadT "$T/brew6.log") -eq "upgrade node`n" -and $out.Contains('Node.js 26.1.0 裝好了') }
    Remove-Item "$T/brew6.log"
    $bad = '"sh -c evil", "brew frob;rm", "curl x", "brew user/tap/frob", "brew -frob", "brew ../frob", "brew frob"'
    W "$NT/tools/frob.yaml" "name: frob`ntitle: Frob`ninstall:`n  mac: [$bad]`n  linux: [$bad]`n"
    Kit install-tool frob
    Check 'install-tool: a recipe can only pick a known manager and a plain package name' { (ReadT "$T/brew6.log") -eq "install frob`n" -and $out.Contains('執行 brew install frob') -and $out.Contains('Frob 1.2.3 裝好了') }
    Remove-Item "$T/brew6.log", "$FB/frob"
    W "$NT/tools/frob.yaml" "name: frob`ntitle: Frob`ninstall:`n  mac: [brew badfrob, brew frob]`n  linux: [brew badfrob, brew frob]`n"
    Kit install-tool frob
    Check 'install-tool: one way fails -> the next way in the recipe' { $rc -eq 0 -and (ReadT "$T/brew6.log") -eq "install badfrob`ninstall frob`n" -and $out.Contains('用 brew 裝失敗') -and $out.Contains('Frob 1.2.3 裝好了') }
    W "$NT/tools/frob.yaml" "name: frob`ntitle: Frob`ninstall:`n  mac: [brew badfrob]`n  linux: [brew badfrob]`n"; Remove-Item "$FB/frob"
    Kit install-tool frob
    Check 'install-tool: every way fails -> says so' { $rc -ne 0 -and $out.Contains('每一種裝法都沒有成功（最後是 brew）') }
    W "$NT/tools/pyfrob.yaml" "name: pyfrob`ninstall:`n  mac: [pip pyfrob]`n  linux: [pip pyfrob]`n"
    $env:KIT_DRY_RUN = '1'; Kit install-tool pyfrob; Remove-Item env:KIT_DRY_RUN
    Check 'install-tool (pip): wheels only, for this account' { $out.Contains('執行 python3 -m pip install --user --only-binary=:all: pyfrob') }
    W "$NT/tools/node.yaml" "name: node`ntitle: Node`ninstall:`n  mac: [scoop node]`n  linux: [scoop node]`n"; Remove-Item "$FB/node", "$T/brew6.log" -ErrorAction SilentlyContinue
    Kit install-tool node
    Check 'install-tool: kit''s own recipe wins over a source''s' { (Test-Path /usr/bin/node) -or ($out.Contains('執行 brew install node') -and (ReadT "$T/brew6.log") -eq "install node`n" -and -not $out.Contains('scoop')) }
    Kit tools
    Check 'tools: kit''s own recipe for node, not the source''s' { $out -match '(?m)^node .*(brew install node|apt-get install -y nodejs)$' }
    W "$NT/tools/slowtool.yaml" "name: slowtool`nbin: [slowtool]`ninstall:`n  mac: [brew slowtool]`n  linux: [brew slowtool]`n"; W "$FB/slowtool" "#!/bin/sh`nsleep 30`necho slowtool 1.0`n"
    W "$NT/tools/chatty.yaml" "name: chatty`nbin: [chatty]`ninstall:`n  mac: [brew chatty]`n  linux: [brew chatty]`n"; W "$FB/chatty" "#!/bin/sh`nexec yes 'chatty 2.5'`n"
    & chmod +x "$FB/slowtool" "$FB/chatty"
    $env:KIT_PROBE_WAIT = '1'; $t0 = Get-Date; Kit tools; $took = ((Get-Date) - $t0).TotalSeconds; Remove-Item env:KIT_PROBE_WAIT
    Check 'tools: a --version that hangs is given up, one that never stops is cut' { $took -lt 30 -and $out -match '(?m)^slowtool +（沒有）' -and $out -match '(?m)^chatty +2\.5 ' }
    foreach ($f in "$NT/tools/slowtool.yaml", "$NT/tools/chatty.yaml", "$NT/tools/pyfrob.yaml", "$NT/tools/node.yaml", "$FB/slowtool", "$FB/chatty") { Remove-Item $f -ErrorAction SilentlyContinue }
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
Check 'packages: a lock -> npm ci, no package scripts' { (PkOf 'packed') -eq '{"kind": "npm", "ok": false, "had": false, "install": "npm ci --ignore-scripts --omit=dev --no-audit --no-fund", "bad": ""}' -and $null -eq (PkOf 'drawer') }
Kit add skill packed
$env:KIT_DRY_RUN = '1'; Kit install-deps packed; Remove-Item env:KIT_DRY_RUN
Check 'install-deps, dry run: only says the command' { $out.Contains('執行 npm ci --ignore-scripts --omit=dev --no-audit --no-fund') -and -not (Test-Path "$T/npm7.log") }
$S7 = Join-Path $H '.config/agentkit/deps/packed'; $C7 = Join-Path $H '.claude/skills/packed'
Kit install-deps packed
Check 'install-deps: npm ci in a new folder next to kit''s, not the source, without the skill''s .npmrc' { $rc -eq 0 -and (ReadT "$T/npm7.log").Trim().Replace('\', '/') -match '\.config/agentkit/deps/packed\.new\.[a-z0-9]+ ci --ignore-scripts --omit=dev --no-audit --no-fund$' -and (Test-Path "$S7/node_modules/left-pad/index.js") -and -not (Test-Path "$NT/skills/packed/node_modules") -and -not (Test-Path "$S7/.npmrc") -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $S7) -Filter 'packed.new.*').Count -eq 0 }
Check 'install-deps: the copy kit put gets node_modules linked to it' { (Get-Item -LiteralPath "$C7/node_modules" -Force).LinkType -and (Test-Path "$C7/node_modules/left-pad/index.js") }
Kit list --json
Check 'packages: installed now' { (PkOf 'packed') -eq '{"kind": "npm", "ok": true, "had": true, "install": "npm ci --ignore-scripts --omit=dev --no-audit --no-fund", "bad": ""}' }
Kit sync
Check 'sync: the link is not a change to the skill' { $out -notmatch '手動' -and (Get-Item -LiteralPath "$C7/node_modules" -Force).LinkType }
# kit run: the agent's folder gets the links too, and goes with them (never into kit's store); a dry run has none
W "$NT/agents/packer.md" "---`nname: packer`ndescription: x`nskills: [packed]`n---`nx`n"
$env:KIT_DRY_RUN = '1'; Kit run packer; Remove-Item env:KIT_DRY_RUN
$rt = (@($out -split "`n" | Where-Object { $_.StartsWith('tmp=') })[0]).Substring(4).TrimEnd("`r")
Check 'run, dry run: the agent''s folder to look at, without kit''s links' { (Test-Path "$rt/.claude/skills/packed/SKILL.md") -and -not (Test-Path "$rt/.claude/skills/packed/node_modules") -and -not (Test-Path "$rt/.kit-pid") }
Remove-Item -LiteralPath $rt -Recurse -Force
$SR = Join-Path ([IO.Path]::GetTempPath()) "kit-run.kittest$PID"; [void](New-Item -ItemType Directory -Force -Path "$SR/x"); W "$SR/.kit-pid" "999999`n"
[void](New-Item -ItemType $(if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }) -Path "$SR/x/node_modules" -Target "$S7/node_modules")
if ($OnWindows) { W "$FB7/claude.cmd" "@echo off`r`necho %*> `"$T\claude.args`"`r`nif not exist `"%2\.claude\skills\packed\node_modules\left-pad`" exit /b 4`r`nexit /b 3`r`n" }
else { W "$FB7/claude" "#!/bin/sh`necho `"`$*`" > '$T/claude.args'`n[ -L `"`$2/.claude/skills/packed/node_modules`" ] || exit 4`nexit 3`n"; & chmod +x "$FB7/claude" }
Kit run packer
$rt = ([regex]::Match((ReadT "$T/claude.args"), '--add-dir (\S+)')).Groups[1].Value.Trim('"')
Check 'run: the agent''s folder has kit''s links; its exit code; the folder gone, kit''s packages still there' { $rc -eq 3 -and $rt -and -not (Test-Path -LiteralPath $rt) -and (Test-Path "$S7/node_modules/left-pad/index.js") }
Check 'run: the folder of a run that was killed goes (its links only)' { -not (Test-Path -LiteralPath $SR) -and (Test-Path "$S7/node_modules/left-pad/index.js") }
foreach ($f in "$FB7/claude", "$FB7/claude.cmd", "$NT/agents/packer.md") { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
# what kit does not install: git, a URL, another registry without your ~/.npmrc
Kit list --json
Check 'packages: a git dependency is shown as refused' { (PkOf 'npmgit') -eq '{"kind": "npm", "ok": false, "had": false, "install": "npm install --ignore-scripts --omit=dev --no-audit --no-fund", "bad": "package.json: optionalDependencies.tool = github:someone/tool"}' }
Check 'packages: a lock (v1) with a package from git, or one from another registry, is refused' { (PkOf 'npmlock') -match '"bad": "package-lock.json: node_modules/tool/node_modules/sub: resolved git\+ssh://git@github.com/someone/sub.git#abc"' -and (PkOf 'npmreg') -match '"bad": "package-lock.json: node_modules/tool: resolved https://npm.example.com/r/tool/-/tool-1.0.0.tgz"' }
if (Test-Path "$T/npm7.log") { Remove-Item "$T/npm7.log" }
Kit install-deps npmgit
Check 'install-deps: refuses a git dependency, npm not run' { $rc -ne 0 -and $out.Contains('kit 不裝這些 npm 套件') -and $out.Contains('github:someone/tool') -and -not (Test-Path "$T/npm7.log") -and -not (Test-Path (Join-Path $H '.config/agentkit/deps/npmgit')) }
W "$H/.npmrc" "registry = https://npm.example.com/r`n"
Kit list --json
Check 'packages: your own ~/.npmrc registry is fine' { (PkOf 'npmreg') -match '"bad": ""' }
Remove-Item -Force "$H/.npmrc"
if (-not $OnWindows) {
    $env:HOME = $H; $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' PATH='$FB7':`"`$PATH`" unix/kit list --json 2>&1") -join "`n"; Kit list --json
    Check 'packages (refused): unix/kit says the same' { $bash -ceq $out }
}
# npm fails: nothing half-made
if ($OnWindows) { W "$FB7/npm.cmd" "@echo off`r`nmkdir node_modules\x`r`nexit /b 3`r`n" } else { W "$FB7/npm" "#!/bin/sh`nmkdir -p node_modules/x`nexit 3`n" }
Remove-Item -LiteralPath $S7 -Recurse -Force
Kit install-deps packed
Check 'install-deps: npm fails -> says so, nothing half-made' { $rc -ne 0 -and $out.Contains('裝套件失敗') -and -not (Test-Path $S7) -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $S7) -Filter 'packed.new.*').Count -eq 0 }
if ($OnWindows) { W "$FB7/npm.cmd" "@echo off`r`nmkdir node_modules\left-pad`r`necho x> node_modules\left-pad\index.js`r`n" } else { W "$FB7/npm" "#!/bin/sh`nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js`n" }
Kit install-deps packed
# Python: a venv of the skill's own (fake python here), requirements.txt with names and versions only
Kit list --json
Check 'packages (pip): a requirements.txt with options is shown as refused' { (PkOf 'pybad' 'pip') -match '"bad": "2: -e git\+http://elsewhere.invalid/x"' }
Check 'packages (pip): an option after a marker is refused too' { (PkOf 'pymark' 'pip').Contains('"bad": "1: requests ; python_version >= \"3.8\" --config-settings=x=y"') }
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
    # the python line is the account's (for the account's skills), never in a folder's own files
    $PD = Join-Path $T 'pyproj'; W "$PD/CLAUDE.md" "# mine`n"; Copy-Item "$PD/CLAUDE.md" "$T/pd.orig"
    Kit add --dir $PD skill pyskill
    Check 'add --dir with kit''s venv: the folder''s copy gets .venv, its CLAUDE.md is not touched' { (Get-Item -LiteralPath "$PD/.claude/skills/pyskill/.venv" -Force).LinkType -and (SameBytes "$T/pd.orig" "$PD/CLAUDE.md") -and -not (Test-Path "$PD/AGENTS.md") }
    Kit rm --dir $PD skill pyskill
    Check 'rm --dir with kit''s venv: the folder exactly as before' { (SameBytes "$T/pd.orig" "$PD/CLAUDE.md") -and ((@(Get-ChildItem -LiteralPath $PD -Force | ForEach-Object { $_.Name }) -join ' ') -eq 'CLAUDE.md') }
    Kit rm skill pyskill
    Check 'python line: gone with the skill (kit''s venv stays)' { $cm = Join-Path $H '.claude/CLAUDE.md'; (Test-Path "$S8/venv/bin/python") -and (-not (Test-Path $cm) -or -not (ReadT $cm).Contains('.venv/bin/python')) }
    Kit add skill pyskill
    $env:HOME = $H; $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' PATH='$FB7':`"`$PATH`" unix/kit list --json 2>&1") -join "`n"; Kit list --json
    Check 'packages (pip, installed): unix/kit says the same' { $bash -ceq $out }
    # pip fails: the venv kit had goes back
    W "$NT/skills/pyskill/requirements.txt" "requests==2.33.0`n"
    W "$FB7/python3" "#!/bin/sh`n[ `"`$1 `$2`" = '-m venv' ] || exec '$realPy' `"`$@`"`nmkdir -p `"`$3/bin`" && printf '#!/bin/sh\nexit 4\n' > `"`$3/bin/python`" && chmod +x `"`$3/bin/python`"`n"
    Kit install-deps pyskill pip
    Check 'install-deps (pip): pip fails -> the old venv stays' { $rc -ne 0 -and $out.Contains('裝套件失敗') -and (ReadT "$S8/.kit-src/requirements.txt").Contains('2.32.0') -and (Test-Path "$S8/venv/bin/python") -and -not (Test-Path "$S8.old") }
    Remove-Item "$FB7/python3"
}
Kit rm skill packed
Check 'rm skill: the copy goes, kit''s packages stay (the link only)' { -not (Test-Path $C7) -and (Test-Path "$S7/node_modules/left-pad/index.js") }
Kit uninstall
Check 'uninstall: kit''s packages go too' { -not (Test-Path (Join-Path $H '.config/agentkit/deps')) -and -not (Test-Path (Join-Path $H '.config/agentkit/pydeps')) }
# a skill's hash is its own files, not what a link in it points at (PowerShell 5.1 would follow a junction)
W "$T/hashme/a.txt" "a`n"; W "$T/linked/b.txt" "b`n"
$h1 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __dir-hash "$T/hashme" 2>&1 | ForEach-Object { "$_" }) -join ''
[void](New-Item -ItemType $(if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }) -Path "$T/hashme/node_modules" -Target "$T/linked")
$h2 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __dir-hash "$T/hashme" 2>&1 | ForEach-Object { "$_" }) -join ''
W "$T/hashme/c.txt" "c`n"
$h3 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __dir-hash "$T/hashme" 2>&1 | ForEach-Object { "$_" }) -join ''
Check 'skill hash: a link (junction) in it does not count, its own files do' { $h1 -match '^[0-9A-F]{16}$' -and $h1 -eq $h2 -and $h3 -ne $h1 }
$env:PATH = $savedP

# ---------- how full an agent's context is (kit context, kit statusline) ----------
Set-Home (Join-Path $T 'home7')
$P7 = Join-Path $T 'ctxproj'; [void](New-Item -ItemType Directory -Force -Path $P7); $P7 = (Resolve-Path $P7).ProviderPath
$js = { param($x) $x.Replace('\', '\\') }
$RO = "$H/.codex/sessions/2026/11/12/rollout-2026-11-12T01-00-00-abc.jsonl"
W $RO ("{`"type`":`"session_meta`",`"payload`":{`"id`":`"abc`",`"cwd`":`"$(& $js $P7)`"}}`n{`"type`":`"turn_context`",`"payload`":{`"model`":`"gpt-6-luna`"}}`n" +
    "{`"type`":`"event_msg`",`"payload`":{`"type`":`"token_count`",`"info`":{`"total_token_usage`":{`"total_tokens`":412129},`"last_token_usage`":{`"input_tokens`":48732,`"output_tokens`":81,`"total_tokens`":48813},`"model_context_window`":258400}}}`n")
Kit context --pid 1 --tool codex --dir $P7
Check 'context (codex): the folder''s rollout, % the way Codex counts it' { $out.Trim() -eq '{"tool": "codex", "used": 48813, "window": 258400, "pct": 15, "source": "rollout", "model": "gpt-6-luna"}' }
W "$H/.omp/agent/sessions/x/s1.jsonl" ("{`"type`":`"session`",`"version`":3,`"id`":`"s1`",`"cwd`":`"$(& $js $P7)`"}`n{`"type`":`"model_change`",`"model`":`"anthropic/claude-opus-5-5`"}`n" +
    "{`"type`":`"message`",`"message`":{`"role`":`"assistant`",`"usage`":{`"input`":4,`"cacheRead`":149319,`"cacheWrite`":222},`"contextSnapshot`":{`"promptTokens`":149545},`"stopReason`":`"stop`"}}`n")
Kit context --pid 1 --tool omp --dir $P7
Check 'context (omp): the folder''s session, its last reply' { $out -match '"used": 149545, "window": (1000000|200000), "pct": (15|75), "source": "session", "model": "anthropic/claude-opus-5-5"' }
# what came after that reply, like omp's footer: its text at 4 bytes a token, an image 1600; omp's "details" not
$z6 = '0' * 600; $z9 = '0' * 900
Add-Content -LiteralPath "$H/.omp/agent/sessions/x/s1.jsonl" -Encoding UTF8 -NoNewline -Value ("{`"type`":`"message`",`"message`":{`"role`":`"toolResult`",`"content`":[{`"type`":`"text`",`"text`":`"0123456789abcdef\`"23`"},{`"type`":`"image`",`"data`":`"$z6`",`"mimeType`":`"image/png`"}],`"details`":{`"text`":`"$z9`"}}}`n")
Kit context --pid 1 --tool omp --dir $P7
Check 'context (omp): plus what came after the reply (text / 4, an image 1600, not "details")' { $out -match '"used": 151150, ' }
$cp = [string]$PID
W "$H/.config/agentkit/ctx/claude-$cp.json" "{`"pid`": $cp, `"session`": `"abc`", `"used`": 139600, `"window`": 400000, `"pct`": 35, `"model`": `"claude-opus-5-5`"}`n"
Kit context --pid $cp --tool claude-code --dir $P7
Check 'context (claude): what the status line kept' { $out.Trim() -eq '{"tool": "claude", "used": 139600, "window": 400000, "pct": 35, "source": "statusline", "model": "claude-opus-5-5"}' }
$sl = '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"context_window_size":400000,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1146,"cache_read_input_tokens":138452},"used_percentage":34.9}}'

$o = $sl | & $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit statusline 2>&1
Check 'statusline: a short line for Claude' { "$o".Trim() -eq 'Opus 5.5 · context 35%（139k / 400k）' }
if (-not $OnWindows) {
    # under a "claude" process (one look at every process): the numbers kept for it
    W "$T/sl7.json" $sl; $FB8 = Join-Path $T 'fakebin8'
    W "$FB8/claude" "#!/bin/sh`necho `$`$ > '$T/cpid7'`n'$Exe' -NoProfile -File '$Kit' statusline < '$T/sl7.json'`n"; & chmod +x "$FB8/claude"
    $o = & "$FB8/claude"; $cp7 = "$(ReadT "$T/cpid7")".Trim()
    Check 'statusline: under claude, the numbers kept for that process' { "$o".Trim() -eq 'Opus 5.5 · context 35%（139k / 400k）' -and (Test-Path "$H/.config/agentkit/ctx/claude-$cp7.json") }
}
# Claude: a reply Claude Code made itself ("<synthetic>") does not count; past the window -> 100 %
$PC = Join-Path $T 'ctxclaude'; [void](New-Item -ItemType Directory -Force -Path $PC); $PC = (Resolve-Path $PC).ProviderPath
$CD = Join-Path (Join-Path $H '.claude/projects') ($PC -replace '[^A-Za-z0-9]', '-')
W "$CD/t.jsonl" ("{`"type`":`"assistant`",`"message`":{`"model`":`"claude-sonnet-4-5`",`"usage`":{`"input_tokens`":250000}}}`n" +
    "{`"type`":`"assistant`",`"message`":{`"model`":`"<synthetic>`",`"usage`":{`"input_tokens`":0,`"output_tokens`":0}}}`n")
Kit context --pid 1 --tool claude --dir $PC
Check 'context (claude): not a <synthetic> reply; past the window -> 100 %' { $out.Trim() -eq '{"tool": "claude", "used": 250000, "window": 200000, "pct": 100, "source": "transcript", "model": "claude-sonnet-4-5"}' }
# a long log is read from its end; nothing there -> all of it, the same answer
Add-Content -LiteralPath "$CD/t.jsonl" -Encoding UTF8 -NoNewline -Value ("{`"type`":`"user`",`"message`":{`"content`":`"$('0' * 400)`"}}`n")
Add-Content -LiteralPath $RO -Encoding UTF8 -NoNewline -Value ("{`"type`":`"event_msg`",`"payload`":{`"type`":`"agent_message`",`"message`":`"$('0' * 400)`"}}`n")
Add-Content -LiteralPath "$H/.omp/agent/sessions/x/s1.jsonl" -Encoding UTF8 -NoNewline -Value ("{`"type`":`"note`",`"text`":`"$('0' * 400)`"}`n")
$same = $true
foreach ($a in @(@('claude', $PC), @('codex', $P7), @('omp', $P7))) {
    Kit context --pid 1 --tool $a[0] --dir $a[1]; $whole = $out
    $env:KIT_CTX_TAIL = '100'; Kit context --pid 1 --tool $a[0] --dir $a[1]; Remove-Item env:KIT_CTX_TAIL
    if ($out -ne $whole -or $whole -notmatch '"used": [0-9]') { $same = $false; [Console]::WriteLine("  differs: $($a[0]): $whole / $out") }
}
Check 'context: a long log is read from its end; nothing there -> all of it, the same answer' { $same }
Kit context --pid
Check 'context: --pid with nothing after it -> how to use it' { $rc -eq 1 -and $out.Contains('用法：kit context') }
if (-not $OnWindows) {
    $same = $true
    foreach ($a in @("--pid 1 --tool codex --dir '$P7'", "--pid 1 --tool omp --dir '$P7'", "--pid 1 --tool claude --dir '$PC'")) {
        $u = (& /bin/sh -c "cd '$Repo' && HOME='$H' unix/kit context $a 2>&1") -join "`n"
        $u2 = (& /bin/sh -c "cd '$Repo' && HOME='$H' KIT_CTX_TAIL=100 unix/kit context $a 2>&1") -join "`n"
        Invoke-Expression "Kit context $a"
        if ($u -cne $out -or $u2 -cne $out) { $same = $false; [Console]::WriteLine("  differs: $a") }
    }
    Check 'context: unix/kit says the same' { $same }
}
# Claude's statusLine: kit's when there is none; taken out by you, it stays out (said once); kit sync --force puts it back
Set-Home (Join-Path $T 'home7b')
Kit init $TEAM
Check 'sync: kit''s statusLine in settings.json' { (JGet "$H/.claude/settings.json" 'statusLine.command') -match 'statusline' }
W "$T/del7.ops" "del`tstatusLine`n"
$sj = ReadT "$H/.claude/settings.json"; $sj2 = [regex]::Replace($sj, ',?\s*"statusLine": \{[^}]*\}', ''); W "$H/.claude/settings.json" $sj2
Kit sync
Check 'statusLine taken out by you: not put back, kit says so and how to get it back' { $null -eq (JGet "$H/.claude/settings.json" 'statusLine') -and $out.Contains('kit sync --force') }
Kit sync
Check 'statusLine taken out by you: said once, still out' { -not $out.Contains('statusLine') -and $null -eq (JGet "$H/.claude/settings.json" 'statusLine') }
Kit sync --force
Check 'kit sync --force: kit''s statusLine back' { (JGet "$H/.claude/settings.json" 'statusLine.command') -match 'statusline' }
Kit uninstall

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
