. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Team-Later
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
Check "codex toml: kit's MCP tools run without asking" { $toml.Contains("default_tools_approval_mode = `"approve`"") }
Check 'codex toml args' { $toml.Contains('args = ["--index-url", "https://pypi.example/simple", "gerrit-mcp-server==1.0"]') }
Check 'codex team deny -> disabled_tools' { $toml.Contains('disabled_tools = ["submit_change"]') }
Check 'codex toml: kit''s notes folder writable in Codex''s sandbox (kit note)' { $toml.Contains("[sandbox_workspace_write]`nwritable_roots = [") -and $toml.Replace('\\', '/').Contains('agentkit/notes') }
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

} finally { Done }
