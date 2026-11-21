. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Team-Later
# ---------- a folder's own (kit add --dir): only agents started there get it ----------
Set-Home (Join-Path $T 'home5')
W "$H/.codex/config.toml" "model = `"gpt-5`"`n`n[mcp_servers.mine]`ncommand = `"x`"`n"; W "$H/.omp/agent/x" ''
Copy-Item "$H/.codex/config.toml" "$T/codex5.orig"
$FP = Join-Path $T 'fproj'; [void](New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $FP 'sub') 'deeper'))
W "$FP/CLAUDE.md" "# my notes`n"; W "$FP/.mcp.json" "{`n  `"mcpServers`": {`n    `"own`": {`n      `"command`": `"y`"`n    }`n  }`n}`n"
Copy-Item "$FP/CLAUDE.md" "$T/fp.claude"; Copy-Item "$FP/.mcp.json" "$T/fp.mcp"
Kit init $TEAM
Copy-Item "$H/.codex/config.toml" "$T/codex5.init"
$FR = & { $script:OnWindows = $OnWindows; if ($OnWindows) { (Get-Item -LiteralPath $FP).FullName } else { "$(& /bin/sh -c 'cd "$1" && pwd -P' sh $FP)".Trim() } }
Kit add --dir $FP skill gerrit-review
Check 'add --dir: done, says where' { $rc -eq 0 -and $out.Contains($FR) }
Check 'add --dir: .agentkit lists it, Claude and Codex/omp skill folders' { (ReadT "$FP/.agentkit").Contains("skill:gerrit-review`n") -and (Test-Path "$FP/.claude/skills/gerrit-review/SKILL.md") -and (Test-Path "$FP/.agents/skills/gerrit-review/SKILL.md") }
Check 'add --dir: not the account' { -not (Test-Path "$H/.claude/skills/gerrit-review") -and -not (Test-Path "$H/.agents/skills/gerrit-review") }
Kit add --dir (Join-Path (Join-Path $FP 'sub') 'deeper') rule gerrit-flow
Check 'add --dir from a sub-folder goes to the folder that has .agentkit' { -not (Test-Path "$FP/sub/deeper/.agentkit") -and (ReadT "$FP/.agentkit").Contains("rule:gerrit-flow") }
Check 'add --dir rule: CLAUDE.md keeps the user text and imports it; AGENTS.md has the text' { $c = ReadT "$FP/CLAUDE.md"; $c.StartsWith("# my notes`n") -and $c.Contains('rules/gerrit-flow.md') -and (ReadT "$FP/AGENTS.md").Contains('Only comment, never submit.') }
Check 'codex: project_root_markers at the top, user part kept' { $c = ReadT "$H/.codex/config.toml"; $c.StartsWith('# agentkit:top:begin') -and $c.Contains('project_root_markers = [".git", ".agentkit"]') -and $c.Contains("model = `"gpt-5`"") }
if (-not (Test-Path "$H/.claude.json")) { W "$H/.claude.json" "{`n  `"numStartups`": 1`n}`n" }
Copy-Item "$H/.claude.json" "$T/cj5.before"
$CK = $FR.Replace('\', '/')   # Claude names a folder with /
function CProj { (ConvertFrom-Json (ReadT "$H/.claude.json")).projects.PSObject.Properties[$CK].Value }
Kit add --dir $FP mcp gerrit
Check 'add --dir mcp: Claude trusts the folder (~/.claude.json projects[DIR]; else Claude asks about the MCP at every start), said' { $e = CProj; @($e.PSObject.Properties).Count -eq 1 -and $e.hasTrustDialogAccepted -eq $true -and $out.Contains("$FR：Claude 信任這個資料夾了") }
Check 'add --dir mcp: .mcp.json has it and the own; Claude does not ask' { (JGet "$FP/.mcp.json" 'mcpServers.gerrit.command') -eq '"uvx"' -and (JGet "$FP/.mcp.json" 'mcpServers.own.command') -eq '"y"' -and (Flat (JGet "$FP/.claude/settings.local.json" 'enabledMcpjsonServers')) -eq '["gerrit"]' }
Check 'add --dir mcp: the folder Codex config, and Codex trusts the folder' { (ReadT "$FP/.codex/config.toml").Contains('[mcp_servers.gerrit]') -and (ReadT "$H/.codex/config.toml").Contains("[projects.`"$($FR.Replace('\', '\\'))`"]`ntrust_level = `"trusted`"") }
# ${HOME} in an MCP's command and args: this machine's home in every tool's file (omp and Codex do not expand it); other ${VAR} stay
$gy = ReadT "$TEAM/mcp/gerrit.yaml"
W "$TEAM/mcp/gerrit.yaml" @'
name: gerrit
command: ${HOME}/bin/uv
args: [run, --directory, "${HOME}/src/gerrit-mcp-server", "${GERRIT_PROFILE}", gerrit-mcp-server]
env:
  GERRIT_CONFIG: ${HOME}/.config/gerrit/gerrit_config.json
'@
Kit add mcp gerrit; Kit sync
$hm = (@('run', '--directory', "$H/src/gerrit-mcp-server", '${GERRIT_PROFILE}', 'gerrit-mcp-server')) -join "`n"
Check '${HOME} in command and args: the home in Claude''s and omp''s files (the account''s, the folder''s .mcp.json), other ${VAR} and env kept' { @(foreach ($f in "$H/.claude.json", "$H/.omp/agent/mcp.json", "$FP/.mcp.json") { $s = (ConvertFrom-Json (ReadT $f)).mcpServers.gerrit; $s.command -ceq "$H/bin/uv" -and (@($s.args) -join "`n") -ceq $hm -and $s.env.GERRIT_CONFIG -ceq '${HOME}/.config/gerrit/gerrit_config.json' }) -notcontains $false }
$hq = { param($s) '"' + $s.Replace('\', '\\') + '"' }
Check '${HOME} in command and args: the home in Codex''s (the account''s and the folder''s config.toml)' { @(foreach ($f in "$H/.codex/config.toml", "$FP/.codex/config.toml") { $c = ReadT $f; $c.Contains("command = $(& $hq "$H/bin/uv")`n") -and $c.Contains("args = [`"run`", `"--directory`", $(& $hq "$H/src/gerrit-mcp-server"), `"`${GERRIT_PROFILE}`", `"gerrit-mcp-server`"]`n") }) -notcontains $false }
# turned off in Claude's /mcp (disabledMcpjsonServers wins over enabledMcpjsonServers): kit turns its own MCP on again
$SL = "$FP/.claude/settings.local.json"
W $SL "{`"enabledMcpjsonServers`": [`"gerrit`"], `"disabledMcpjsonServers`": [`"mine`", `"gerrit`"]}`n"
Kit sync
Check 'a folder''s Claude settings turned kit''s MCP off: on again, said; the user''s other one stays off (and the one not kit''s)' { $out.Contains("$FR 的 Claude 設定把 MCP gerrit 關掉了，kit 已經重新打開") -and (Flat (JGet $SL 'disabledMcpjsonServers')) -ceq '["mine","own"]' -and (Flat (JGet $SL 'enabledMcpjsonServers')) -ceq '["gerrit"]' }
Kit sync
Check 'turned on again: not said again' { -not $out.Contains('重新打開') }
W $SL "{`"enabledMcpjsonServers`": [`"gerrit`"], `"disabledMcpjsonServers`": [`"gerrit`"]}`n"
Kit sync
Check 'the only one turned off: out of disabledMcpjsonServers (the one not kit''s stays)' { (Flat (JGet $SL 'disabledMcpjsonServers')) -ceq '["own"]' -and (Flat (JGet $SL 'enabledMcpjsonServers')) -ceq '["gerrit"]' }
W "$TEAM/mcp/gerrit.yaml" $gy; Kit rm mcp gerrit; Kit sync
Kit list --json --dir (Join-Path $FP 'sub')
Check 'list --json: the folder with .agentkit, its items' { $out.Contains("`"folder`": {`"dir`": $(& { '"' + $FR.Replace('\', '\\') + '"' }), `"why`": `"`", `"items`": [`"skill:gerrit-review`", `"rule:gerrit-flow`", `"mcp:gerrit`"], `"agent`": null, `"plugins`": []}") }
if (-not $OnWindows) {
    $env:HOME = $H; $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' unix/kit list --json --dir '$FP/sub' 2>&1") -join "`n"
    Check 'list --json --dir with a folder of its own: unix/kit prints the same' { $bash -ceq $out }
}
Kit add --dir $H skill gerrit-review
Check 'add --dir: refuses the home folder' { $rc -ne 0 -and $out.Contains('家目錄') -and -not (Test-Path "$H/.agentkit") }
Kit rm --dir $FP skill gerrit-workflow
Check 'rm --dir: only what the folder added' { $rc -ne 0 -and $out.Contains('沒有加') }
Kit rm rule gerrit-flow
Check "rm: the account hasn't it, a folder has: says which folder and --dir" { $rc -ne 0 -and $out.Contains($FP) -and $out.Contains('kit rm --dir') }
Kit rm --dir $FP skill gerrit-review; Kit rm --dir $FP rule gerrit-flow; Kit rm --dir $FP mcp gerrit
Check 'rm --dir all: the folder as before, but its .mcp.json server (not kit''s, not in git) still off' { (SameBytes "$T/fp.claude" "$FP/CLAUDE.md") -and (SameBytes "$T/fp.mcp" "$FP/.mcp.json") -and ((@(Get-ChildItem -LiteralPath $FP -Force | ForEach-Object { $_.Name } | Sort-Object) -join ' ') -eq '.claude .mcp.json CLAUDE.md sub') -and (Flat (JGet "$FP/.claude/settings.local.json" 'disabledMcpjsonServers')) -ceq '["own"]' }
Check 'rm --dir all: Codex config byte-identical to after init, kit forgets the folder' { (SameBytes "$T/codex5.init" "$H/.codex/config.toml") -and -not (Test-Path "$H/.config/agentkit/dirs") }
Check 'rm --dir all: ~/.claude.json byte-identical (kit''s trust entry gone)' { SameBytes "$T/cj5.before" "$H/.claude.json" }
# Claude's own entry for the folder (not trusted): kit trusts it and puts back false when its MCP goes
$cj = ReadT "$H/.claude.json"; W "$H/.claude.json" ($cj.Substring(0, $cj.LastIndexOf('}')).TrimEnd() + ",`n  `"projects`": {`n    $(& { '"' + $CK.Replace('\', '\\') + '"' }): {`n      `"allowedTools`": [],`n      `"hasTrustDialogAccepted`": false,`n      `"lastCost`": 1`n    }`n  }`n}`n")
Copy-Item "$H/.claude.json" "$T/cj5.claude"
Kit add --dir $FP mcp gerrit
Check 'Claude''s entry for the folder: trusted, the rest kept' { $e = CProj; (@($e.PSObject.Properties | ForEach-Object { $_.Name }) -join ' ') -ceq 'allowedTools hasTrustDialogAccepted lastCost' -and $e.hasTrustDialogAccepted -eq $true -and $e.lastCost -eq 1 }
W "$H/.claude.json" ((ReadT "$H/.claude.json").Replace('"hasTrustDialogAccepted": true', '"hasTrustDialogAccepted": false'))
Kit sync
Check 'trust turned off while kit''s MCP is there: on again' { (CProj).hasTrustDialogAccepted -eq $true }
Kit rm --dir $FP mcp gerrit
Check 'rm --dir mcp: Claude''s entry as it was (false)' { SameBytes "$T/cj5.claude" "$H/.claude.json" }
Kit add --dir $FP skill gerrit-review; Kit add --dir $FP mcp gerrit
Kit uninstall
Check 'uninstall: the folder and Codex config exactly as before' { (SameBytes "$T/fp.claude" "$FP/CLAUDE.md") -and (SameBytes "$T/fp.mcp" "$FP/.mcp.json") -and -not (Test-Path "$FP/.agentkit") -and (SameBytes "$T/codex5.orig" "$H/.codex/config.toml") }

} finally { Done }
