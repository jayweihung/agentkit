. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Team-Later
# ---------- kit place: an agent's own folder (a kit panel: drag an agent onto a space) ----------
Set-Home (Join-Path $T 'home6')
W "$H/.codex/config.toml" "model = `"gpt-5`"`n"; W "$H/.omp/agent/x" ''
W "$TEAM/agents/helper.md" "---`nname: helper`ndescription: helps`nskills: [gerrit-review, not-there]`n---`n`nYou help.`n"
$SP = Join-Path $T 'spaces'; [void](New-Item -ItemType Directory -Force -Path $SP)
$SR = if ($OnWindows) { (Get-Item -LiteralPath $SP).FullName } else { "$(& /bin/sh -c 'cd "$1" && pwd -P' sh $SP)".Trim() }
function JS([string]$s) { $s.Replace('\', '\\') }   # a path as kit writes it in JSON
function Snap([string]$d) { (@(Get-ChildItem -LiteralPath $d -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName + ' ' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) })) -join "`n" }
# a deny rule kit wants that you had already: yours (kit uninstall leaves it)
W "$H/.claude/settings.json" "{`"permissions`": {`"deny`": [`"mcp__gerrit__submit_change`"]}}`n"
Kit init $TEAM
Check 'deny you had already: not counted as kit''s' { -not ((ReadT "$H/.config/agentkit/state.tsv") -match "(?m)^deny`t") -and (Flat (JGet "$H/.claude/settings.json" 'permissions.deny')) -ceq '["mcp__gerrit__submit_change"]' }
$G = Join-Path $SP 'gerrit'; $GR = Join-Path $SR 'gerrit'
KitJ place gerrit $G --json
Check 'place --json: one line: dir, agent, tool, command, warnings' { $rc -eq 0 -and $out -ceq "{`"dir`": `"$(JS $GR)`", `"agent`": `"gerrit`", `"tool`": `"claude`", `"command`": [`"claude`"], `"warnings`": []}" }
Check 'place: .agentkit says which agent; the agent''s rules, skills, MCP come from the agent file (not listed)' { $a = ReadT "$G/.agentkit"; $a.Contains("agent:gerrit`ntool:claude`n") -and -not ($a -cmatch '(?m)^(rule|skill|mcp):') }
Check 'place: CLAUDE.md imports the rule, then the prompt; AGENTS.md has both as text' { $c = ReadT "$G/CLAUDE.md"; $c.Contains('rules/gerrit-flow.md') -and $c.Contains("<!-- agent: gerrit -->`nYou are the Gerrit helper.`n") -and (ReadT "$G/AGENTS.md").Contains('Only comment, never submit.') -and (ReadT "$G/AGENTS.md").Contains('You are the Gerrit helper.') }
Check 'place: skills, the MCP, Claude''s tool limits in settings.local.json' { (Test-Path "$G/.claude/skills/gerrit-review/SKILL.md") -and (Test-Path "$G/.agents/skills/gerrit-review/SKILL.md") -and (JGet "$G/.mcp.json" 'mcpServers.gerrit.command') -eq '"uvx"' -and (Flat (JGet "$G/.claude/settings.local.json" 'permissions.deny')) -ceq '["mcp__gerrit__submit_change","Agent","Bash","Edit","NotebookEdit","Task","TodoWrite","WebFetch","WebSearch","Write"]' -and -not (Test-Path "$G/.claude/settings.local.json.kit-backup") }
Check 'place: Codex: the MCP tool deny as disabled_tools in the folder''s config' { (ReadT "$G/.codex/config.toml").Contains("[mcp_servers.gerrit]") -and (ReadT "$G/.codex/config.toml").Contains('disabled_tools = ["submit_change"]') }
Check 'place: not the account' { -not (Test-Path "$H/.claude/skills/gerrit-review") -and -not ((ReadT "$H/.claude/CLAUDE.md").Contains('Gerrit helper')) }
$s1 = Snap $G
KitJ place gerrit "$G/" --json
Check 'place again (same agent): fine, nothing changes' { $rc -eq 0 -and (Snap $G) -ceq $s1 }
KitJ list --json --dir $G
Check 'list --json --dir: here.folder.agent names the placed agent' { $out.Contains("`"items`": [`"rule:gerrit-flow`", `"skill:gerrit-review`", `"mcp:gerrit`"], `"agent`": `"gerrit`", `"plugins`": []}") }
KitJ place helper $G --json
Check 'place: refuses a folder that is another agent (other_agent), untouched' { $rc -ne 0 -and $out.Contains('"code": "other_agent"') -and (Snap $G) -ceq $s1 }
W "$SP/busy/notes.txt" "mine`n"
KitJ place helper (Join-Path $SP 'busy') --json
Check 'place: refuses a folder with files and no marker (not_empty)' { $rc -ne 0 -and $out.Contains('"code": "not_empty"') -and -not (Test-Path "$SP/busy/.agentkit") }
KitJ place helper (Join-Path (Join-Path $SP 'no') 'such') --json
Check 'place: the parent must be there (no_parent), nothing made' { $rc -ne 0 -and $out.Contains('"code": "no_parent"') -and -not (Test-Path "$SP/no") }
KitJ place nobody (Join-Path $SP 'x') --json
Check 'place: an unknown agent (no_agent)' { $rc -ne 0 -and $out.Contains('"code": "no_agent"') -and -not (Test-Path "$SP/x") }
KitJ place helper $H --json
Check 'place: not the home folder (bad_dir)' { $rc -ne 0 -and $out.Contains('"code": "bad_dir"') -and -not (Test-Path "$H/.agentkit") }
KitJ place gerrit (Join-Path $SP 'v') --tool vim --json
Check 'place --tool: only claude, codex, omp (usage)' { $rc -ne 0 -and $out.Contains('"code": "usage"') -and -not (Test-Path "$SP/v") }
$HP = Join-Path $SP 'helper'; [void](New-Item -ItemType Directory -Path $HP)
KitJ place helper $HP --json
Check 'place: a second agent in its own folder; a missing item is a warning' { $rc -eq 0 -and $out.Contains('"warnings": ["skill not-there 不在任何來源裡：沒有放進來"]') -and (ReadT "$HP/CLAUDE.md").Contains("You help.`n") -and -not (ReadT "$HP/CLAUDE.md").Contains('Gerrit') -and -not (ReadT "$G/CLAUDE.md").Contains('You help.') -and -not (Test-Path "$HP/.claude/settings.local.json") }
Kit add --dir $HP rule coding-style
Check 'add --dir after place: only that folder, the prompt stays after the rules' { $c = ReadT "$HP/CLAUDE.md"; $c.Contains('rules/coding-style.md') -and $c.EndsWith("You help.`n<!-- agentkit:end -->`n") -and -not (ReadT "$G/CLAUDE.md").Contains('coding-style') }
Kit rm --dir $G skill gerrit-review
Check 'rm --dir after place: only that folder' { -not (Test-Path "$G/.claude/skills/gerrit-review") -and (Test-Path "$HP/.claude/skills/gerrit-review/SKILL.md") }
Check 'rm --dir of the agent''s: kept in .agentkit as not:' { (ReadT "$G/.agentkit").Contains("not:skill:gerrit-review`n") }
Kit rm --dir $G rule gerrit-flow; Kit rm --dir $G mcp gerrit; Kit sync
Check 'rm --dir all after place: still that agent, still kept up to date' { (ReadT "$G/.agentkit").Contains("agent:gerrit`n") -and (ReadT "$G/CLAUDE.md").Contains('You are the Gerrit helper.') -and -not (Test-Path "$G/.mcp.json") -and (ReadT "$H/.config/agentkit/dirs").Contains($GR) }
Check 'rm --dir of the agent''s: stays out after kit sync' { -not (Test-Path "$G/.claude/skills/gerrit-review") -and -not (ReadT "$G/CLAUDE.md").Contains('gerrit-flow') }
Kit add --dir $G mcp gerrit
Check 'add --dir of the agent''s again: the not: line goes, it is the agent''s again' { -not (ReadT "$G/.agentkit").Contains('mcp:gerrit') -and (JGet "$G/.mcp.json" 'mcpServers.gerrit.command') -eq '"uvx"' }
Kit rm --dir $G skill gerrit-review
Check 'rm --dir of one already out: refused' { $rc -ne 0 }
# the agent file changes: kit sync brings its new rules, skills, MCP and takes out the ones it dropped; yours stay
W "$TEAM/agents/helper.md" "---`nname: helper`ndescription: helps`nmcp: [gerrit]`n---`nYou help, version 2.`n"; Kit sync
Check 'sync: a changed prompt reaches the placed folder' { (ReadT "$HP/CLAUDE.md").Contains("You help, version 2.`n") -and -not (ReadT "$HP/CLAUDE.md").Contains("You help.`n") }
Check 'sync: the agent''s new MCP is added, the skill it dropped taken out, the rule you added kept' { (JGet "$HP/.mcp.json" 'mcpServers.gerrit.command') -eq '"uvx"' -and -not (Test-Path "$HP/.claude/skills/gerrit-review") -and (ReadT "$HP/CLAUDE.md").Contains('rules/coding-style.md') -and (ReadT "$HP/.agentkit").Contains("rule:coding-style`n") }
# a deny rule kit wants in the folder that you had put there already: yours, left when the agent drops it
$sl = "$HP/.claude/settings.local.json"; W $sl ((ReadT $sl).TrimEnd("`n").TrimEnd('}').TrimEnd() + ",`n  `"permissions`": {`"deny`": [`"Bash`"]}`n}`n")
W "$TEAM/agents/helper.md" "---`nname: helper`ndescription: helps`nmcp: [gerrit]`ntools:`n  deny: [Bash, WebFetch]`n---`nYou help, version 2.`n"; Kit sync
Check 'place deny: kit adds the agent''s, not the one you had' { (Flat (JGet $sl 'permissions.deny')) -ceq '["Bash","WebFetch"]' -and -not ((ReadT "$H/.config/agentkit/state.tsv").Contains("helper:deny`tBash`t")) }
W "$TEAM/agents/helper.md" "---`nname: helper`ndescription: helps`nmcp: [gerrit]`n---`nYou help, version 2.`n"; Kit sync
Check 'place deny: the agent drops them: kit''s goes, yours stays' { (Flat (JGet $sl 'permissions.deny')) -ceq '["Bash"]' }
# the agent cannot be read (renamed, its source gone): the folder stays as it was (prompt, tool limits, MCP), said once
$s2 = Snap $G
Move-Item -LiteralPath "$TEAM/agents/gerrit.md" -Destination "$T/gerrit.md.away"
Kit sync; $o1 = $out; Kit sync; $o2 = $out
Check 'agent gone: the placed folder is left as it was (deny, prompt, MCP)' { (Snap $G) -ceq $s2 -and (JGet "$G/.claude/settings.local.json" 'permissions.deny').Contains('"Bash"') }
Check 'agent gone: said once' { $o1.Contains('agent gerrit 找不到或讀不懂') -and -not $o2.Contains('agent gerrit 找不到或讀不懂') }
KitJ list --json --dir $G
Check 'agent gone: list --json --dir still has the agent''s (kit''s copy)' { $out.Contains('"items": ["mcp:gerrit"], "agent": "gerrit", "plugins": []}') }
W "$TEAM/agents/gerrit.md" "---`nname: gerrit`nthis is not yaml`n---`nbroken`n"; Kit sync
Check 'agent unreadable (bad header): the folder is left as it was' { (Snap $G) -ceq $s2 }
Move-Item -LiteralPath "$T/gerrit.md.away" -Destination "$TEAM/agents/gerrit.md" -Force; Kit sync
Check 'agent back: kit sync as before, nothing to say' { (Snap $G) -ceq $s2 -and -not $out.Contains('找不到或讀不懂') }
KitJ place gerrit (Join-Path $SP 'gx') --tool codex --json
Check 'place --tool codex: the command and what Codex cannot do' { $rc -eq 0 -and $out.Contains('"tool": "codex", "command": ["codex"], "warnings": ["Codex 的 tools.only 只管得到 shell（Bash）和改檔（Edit、Write）：Codex 其他的內建工具照樣能用", "tools.only 沒有 Bash：Codex 讀檔、找檔也是用 shell，所以在 Codex 裡也不能讀檔"]') -and (ReadT "$SP/gx/AGENTS.md").Contains('You are the Gerrit helper.') }
KitJ place gerrit (Join-Path $SP 'go') --tool omp --json
Check 'place --tool omp: the folder''s .mcp.json is omp''s too; tool limits through kit''s hook module' { $rc -eq 0 -and $out.Contains('"command": ["omp"], "warnings": []') }
Kit uninstall
Check 'uninstall: the placed folders are empty again (the deny you put in one stays), kit''s copies of the agents gone' { @(Get-ChildItem -LiteralPath $G -Force).Count -eq 0 -and (@(Get-ChildItem -LiteralPath $HP -Force | ForEach-Object { $_.Name }) -join ' ') -ceq '.claude' -and (Flat (JGet $sl 'permissions.deny')) -ceq '["Bash"]' -and @(Get-ChildItem -LiteralPath "$SP/gx" -Force).Count -eq 0 -and -not (Test-Path "$H/.config/agentkit/placed") }
Check 'uninstall: the deny you had already stays' { (Flat (JGet "$H/.claude/settings.json" 'permissions.deny')) -ceq '["mcp__gerrit__submit_change"]' }
Remove-Item -LiteralPath "$TEAM/agents/helper.md" -Force

} finally { Done }
