. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM; Kit add skill gerrit-review; Kit add mcp gerrit
# ---------- kit_version: tell once when the team wants a newer kit ----------
$teamYaml = ReadT "$TEAM/kit.yaml"
function Team-Version([string]$v) { W "$TEAM/kit.yaml" ($teamYaml.TrimEnd("`n") + "`nkit_version: $v`n") }
function State-Nag { @((ReadT "$H/.config/agentkit/state.tsv") -split "`n" | Where-Object { $_.StartsWith("nag`t") }).Count }
Team-Version '9.9.0'
Kit sync
Check 'old kit: sync tells the user' { $out.Contains('團隊要 kit 9.9.0 以上，你的是 ' + $KitVer + '。請打  kit self-update') }
Kit sync; $o1 = $out; Kit list
Check 'old kit: told only once' { -not ($o1 + $out).Contains('團隊要') }
Team-Version '0.10.1'
Kit list
Check 'team version changed: list tells again (numbers, not text)' { $out.Contains('團隊要 kit 0.10.1 以上') }
$realKit = $Kit; $Kit = Join-Path $T 'dev/windows/kit.ps1'
W $Kit ''; Copy-Item -LiteralPath $realKit -Destination $Kit -Force
Team-Version '9.6.0'
Kit sync
Check 'dev build (no VERSION) is not told' { -not $out.Contains('團隊要') }
W "$T/dev/VERSION" "9.6.0+local`n"; Kit sync
Check '+build part ignored' { -not $out.Contains('團隊要') }
W "$T/dev/VERSION" "9.5.9`n"; Kit sync
Check 'older patch level is told' { $out.Contains('團隊要 kit 9.6.0 以上，你的是 9.5.9') }
W "$T/dev/VERSION" "9.6.0`n"; Kit sync
Check 'new enough: note forgotten' { (State-Nag) -eq 0 }
$Kit = $realKit
# kit_version 9.6.0 stays for the background sync below

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
Check 'codex run: deny -> disabled_tools, env kept' { $srv.Contains('default_tools_approval_mode=\"approve\"') -and $srv.Contains('disabled_tools=[\"submit_change\"]') -and (Untoml $srv).Contains('${HOME}/.config/gerrit') }
Check 'codex run: warns tools.only, keeps user args' { $out.Contains('tools.only') -and ($lines -contains 'exec') }
Remove-Item -Recurse -Force $tmp
$env:KIT_DRY_RUN = '1'; Kit run gerrit --tool omp; Remove-Item env:KIT_DRY_RUN
$lines = $out -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$tmp = Lines-After 'tmp='
Check 'omp run: config overlay points at skills' { (ReadT (Join-Path $tmp 'omp.yml')).Contains((Join-Path $tmp 'skills').Replace('\', '\\')) -and (Test-Path (Join-Path $tmp 'skills/gerrit-review/SKILL.md')) }
Check 'omp run: prompt + tools.only as omp''s tools' { ($lines -contains '--append-system-prompt') -and ($lines -contains 'read,grep,ast_grep,glob,find') }
Check 'omp run: tools.deny through kit''s hook module (--extension)' { ($lines -contains '--extension') -and (ReadT (Join-Path $tmp 'kit-tools.js')).Contains('const DENY = ["mcp__gerrit__submit_change"];') -and (ReadT (Join-Path $tmp 'kit-tools.js')).Contains('const SYNC = null;') }
Check 'omp run: the agent''s MCP in a plugin folder (--plugin-dir)' { ($lines -contains '--plugin-dir') -and (ReadT (Join-Path $tmp 'omp-plugin/.mcp.json')).Contains('"gerrit"') -and (Test-Path (Join-Path $tmp 'omp-plugin/.claude-plugin/plugin.json')) -and -not $out.Contains('kit add mcp') }
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
Check 'hook: kit_version told at the next sync' { $out.Contains('團隊要 kit 9.6.0 以上') }
W "$TEAM/kit.yaml" $teamYaml

} finally { Done }
