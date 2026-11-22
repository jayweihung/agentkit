. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Team-Later
function JS([string]$s) { $s.Replace('\', '\\') }   # a path as kit writes it in JSON
function BackupHas([string]$name, [string]$text) { @(Get-ChildItem -Path "$H/.config/agentkit/backups/skills" -Filter "$name-*" -Directory -ErrorAction SilentlyContinue | Where-Object { (ReadT (Join-Path $_.FullName 'SKILL.md')).Contains($text) }).Count -gt 0 }
function FileUrl([string]$p) { $p = $p.Replace('\', '/'); if ($p.StartsWith('/')) { "file://$p" } else { "file:///$p" } }
function G { & git @args 2>&1 | Out-Null }
# ---------- only through kit: what kit did not put there and is not the company's is turned off ----------
$hSave = $H; Set-Home (Join-Path $T 'home-block'); $HB = $H
$PB2 = Join-Path $T 'blockproj'; [void](New-Item -ItemType Directory -Force -Path $PB2); $PB2 = (Resolve-Path $PB2).ProviderPath
function Sk([string]$d) { W "$d/SKILL.md" "---`nname: $(Split-Path -Leaf $d)`ndescription: x`n---`nx`n" }
Sk "$HB/.claude/skills/npxed"; Sk "$HB/.codex/skills/.system/sysskill"; Sk "$HB/.codex/skills/cxown"
W "$HB/.claude/skills/gerrit-review/SKILL.md" "mine`n"   # a team skill's name
Sk "$HB/.claude/skills/synced/org1_u1/vendor1"; Sk "$HB/.claude/skills/synced/org1_u1/mine1"
W "$HB/.claude/skills/synced/org1_u1/manifest.json" ('{"skills": [{"name": "vendor1", "source": "anthropic"}, {"name": "mine1", "source": "user"}]}' + "`n")
W "$HB/.claude/settings.json" "{`n  `"model`": `"opus`",`n  `"skillOverrides`": {`n    `"npxed`": `"on`"`n  }`n}`n"
W "$HB/.claude.json" "{`n  `"mcpServers`": {`n    `"selfmcp`": {`n      `"command`": `"x`"`n    }`n  }`n}`n"
W "$HB/.claude/plugins/installed_plugins.json" ('{"version": 2, "plugins": {"pl@mkt": [{"scope": "user"}]}}' + "`n")
W "$HB/.codex/config.toml" "model = `"gpt-5`"`n`n[mcp_servers.cxmcp]`ncommand = `"x`"`n`n[plugins.`"foo@mkt`"]`nenabled = true`n"; Copy-Item "$HB/.codex/config.toml" "$T/blockcx.orig"
W "$HB/.omp/agent/config.yml" "theme: dark`ndisabledExtensions:`n  - context-file:user:CLAUDE.md`n"; Copy-Item "$HB/.omp/agent/config.yml" "$T/blockomp.orig"
Sk "$PB2/.claude/skills/committed"; Sk "$PB2/.claude/skills/loose"; W "$PB2/.mcp.json" ('{"mcpServers": {"projmcp": {"command": "x"}}}' + "`n")
G -C $PB2 init -q; G -C $PB2 config user.name t; G -C $PB2 config user.email t@t; G -C $PB2 add .claude/skills/committed; G -C $PB2 commit -qm c
$env:KIT_HOOK_DIR = $PB2; Kit init $TEAM; $o1 = $out; Remove-Item env:KIT_HOOK_DIR
Kit add skill gerrit-review; $o1 += $out
$S = "$HB/.claude/settings.json"; $CX = "$HB/.codex/config.toml"; $SLB = "$PB2/.claude/settings.local.json"
Check 'block: a skill kit did not put there is off in Claude, your own setting for it kept to put back' { (JGet $S 'skillOverrides.npxed') -ceq '"off"' -and (JGet $S 'model') -ceq '"opus"' -and $o1.Contains('已經讓工具不載入') }
Check "block: Claude synced: anthropic's left alone, the user's own off" { $null -eq (JGet $S 'skillOverrides.vendor1') -and (JGet $S 'skillOverrides.mine1') -ceq '"off"' }
Check 'block: Claude MCP and plugin off (deniedMcpServers, enabledPlugins); ~/.claude.json untouched' { (Flat (JGet $S 'deniedMcpServers')) -ceq '[{"serverName":"selfmcp"}]' -and (JGet $S 'enabledPlugins.pl@mkt') -ceq 'false' -and $null -ne (JGet "$HB/.claude.json" 'mcpServers.selfmcp') }
Check "block: Codex skills off in kit's block (not Claude's folder), its .system left alone" { $c = (ReadT $CX).Replace("`r", ''); $c.Contains("[[skills.config]]`nname = `"cxown`"`nenabled = false") -and -not $c.Contains('"npxed"') -and -not $c.Contains('"sysskill"') }
Check 'block: Codex MCP and plugin enabled = false in their own tables' { $c = (ReadT $CX).Replace("`r", ''); $c.Contains("[mcp_servers.cxmcp]`ncommand = `"x`"`nenabled = false`n") -and $c.Contains("[plugins.`"foo@mkt`"]`nenabled = false`n") -and -not $c.Contains('enabled = true') }
Check 'block: omp skills in disabledExtensions (yours kept), MCP in disabledServers' { $y = ReadT "$HB/.omp/agent/config.yml"; $y -match '(?m)^  - skill:npxed$' -and $y -match '(?m)^  - context-file:user:CLAUDE\.md$' -and -not $y.Contains('sysskill') -and (Flat (JGet "$HB/.omp/agent/mcp.json" 'disabledServers')).Contains('"selfmcp"') }
Check 'block: the project: what git tracks left alone, the rest off in its settings.local.json' { (JGet $SLB 'skillOverrides.loose') -ceq '"off"' -and $null -eq (JGet $SLB 'skillOverrides.committed') -and $null -eq (JGet $S 'skillOverrides.committed') -and (Flat (JGet $SLB 'disabledMcpjsonServers')).Contains('"projmcp"') }
Check "block: a folder that is not kit's where kit puts a skill: backed up, then kit's (never blocked)" { (BackupHas 'gerrit-review' 'mine') -and (ReadT "$HB/.claude/skills/gerrit-review/SKILL.md").Contains('how to review') -and $null -eq (JGet $S 'skillOverrides.gerrit-review') }
KitJ list --json
Check 'block: kit list --json has blocked' { $out.Contains("{`"kind`": `"skill`", `"name`": `"npxed`", `"tool`": `"claude`", `"path`": `"$(JS (Join-Path "$HB/.claude/skills" 'npxed'))`", `"scope`": `"account`"}") -and $out.Contains("`"name`": `"loose`", `"tool`": `"claude`", `"path`": `"$(JS (Join-Path "$PB2/.claude/skills" 'loose'))`", `"scope`": `"folder`", `"dir`": `"$(JS $PB2)`"}") }
Move-Item -LiteralPath "$HB/.claude/skills/npxed" -Destination "$T/npxed.away"; Move-Item -LiteralPath "$PB2/.claude" -Destination "$T/pbclaude.away"
KitJ list --json
Check "block: kit list --json: blocked from what kit sync kept, less what is gone since (removed by hand)" { -not $out.Contains('"name": "npxed"') -and -not $out.Contains('"name": "loose"') -and $out.Contains('"name": "selfmcp"') -and $out.Contains('"name": "cxown"') }
Move-Item -LiteralPath "$T/npxed.away" -Destination "$HB/.claude/skills/npxed"; Move-Item -LiteralPath "$T/pbclaude.away" -Destination "$PB2/.claude"
W $S ((ReadT $S) -replace '(?m)^.*"npxed": "off".*\r?\n', ''); Kit sync
Check 'block: told once; taken out by hand: back on the next sync (the project too)' { -not $out.Contains('已經讓工具不載入') -and (JGet $S 'skillOverrides.npxed') -ceq '"off"' -and (JGet $SLB 'skillOverrides.loose') -ceq '"off"' }
Sk "$TEAM/skills/npxed"; Kit add skill npxed
Check "block: once kit has it, kit's entry goes and yours is back" { (JGet $S 'skillOverrides.npxed') -ceq '"on"' -and -not (ReadT $CX).Contains('"npxed"') -and -not (ReadT "$HB/.omp/agent/config.yml").Contains('skill:npxed') -and $out.Contains('不再擋') }
Remove-Item -Recurse -Force "$HB/.codex/skills/cxown"; Kit sync
Check "block: removed by hand: kit sync says it is gone (not that it is kit's now)" { $i = $out.IndexOf('已經刪掉了'); $i -ge 0 -and $out.Substring($i).Contains('cxown') -and -not (ReadT $CX).Contains('"cxown"') }
Kit uninstall
Check 'block: uninstall puts everything back' { (JGet $S 'skillOverrides.npxed') -ceq '"on"' -and $null -eq (JGet $S 'skillOverrides.mine1') -and $null -eq (JGet $S 'deniedMcpServers') -and $null -eq (JGet $S 'enabledPlugins') -and (SameBytes $CX "$T/blockcx.orig") -and (SameBytes "$HB/.omp/agent/config.yml" "$T/blockomp.orig") -and -not (Test-Path $SLB) -and -not (Test-Path "$HB/.config/agentkit/blocked.tsv") }
Remove-Item -Recurse -Force "$TEAM/skills/npxed"; Set-Home $hSave

} finally { Done }
