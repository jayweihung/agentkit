. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Team-Later
# ---------- kit place is gone (0.18.0): a folder it made becomes a plain one, keeping what it had ----------
Set-Home (Join-Path $T 'home6')
W "$H/.codex/config.toml" "model = `"gpt-5`"`n"; W "$H/.omp/agent/x" ''
$SP = Join-Path $T 'spaces'; [void](New-Item -ItemType Directory -Force -Path $SP)
Kit init $TEAM
Kit place gerrit (Join-Path $SP 'new')
Check 'place: gone, says what to use instead, makes nothing' { $rc -ne 0 -and $out.Contains('kit open <工具> --agent <名字>') -and -not (Test-Path "$SP/new") }
# a folder as kit place left it: agent:/tool: lines, one of the agent's taken out (not:), one you added, and the
# agent's prompt in kit's part of CLAUDE.md (kit add --dir makes the rest: the folder in kit's list, kit's part)
$G = Join-Path $SP 'gerrit'; [void](New-Item -ItemType Directory -Path $G)
Kit add --dir $G rule coding-style
W "$G/.agentkit" "# kit place：這個資料夾就是下面這個 agent。`nagent:gerrit`ntool:claude`nnot:skill:gerrit-review`nrule:coding-style`n"
W "$G/CLAUDE.md" ((ReadT "$G/CLAUDE.md").Replace('<!-- agentkit:end -->', "<!-- agent: gerrit -->`nYou are the Gerrit helper.`n<!-- agentkit:end -->"))
Kit sync; $o1 = $out; Kit sync; $o2 = $out
Check 'unplace: said once' { $o1.Contains("$G 不再是 agent gerrit") -and -not $o2.Contains('不再是 agent') }
Check 'unplace: .agentkit lists what it had (the agent''s less the one taken out, then yours), no agent line' { (@((ReadT "$G/.agentkit") -split "`n" | Where-Object { $_ -and -not $_.StartsWith('#') }) -join ' ') -ceq 'rule:gerrit-flow mcp:gerrit rule:coding-style' }
Check 'unplace: the files follow it; the prompt is gone' { $c = ReadT "$G/CLAUDE.md"; $c.Contains('rules/gerrit-flow.md') -and $c.Contains('rules/coding-style.md') -and -not $c.Contains('Gerrit helper') -and -not (Test-Path "$G/.claude/skills/gerrit-review") -and (JGet "$G/.mcp.json" 'mcpServers.gerrit.command') -ceq '"uvx"' }
KitJ list --json --dir $G
Check 'list --json --dir: here.folder.agent null, items the folder''s' { $out.Contains('"items": ["rule:gerrit-flow", "mcp:gerrit", "rule:coding-style"], "agent": null, "plugins": []}') }
# kit add|rm --dir before any kit sync turns it into a plain folder first
$HP = Join-Path $SP 'helper'; [void](New-Item -ItemType Directory -Path $HP); W "$HP/.agentkit" "agent:gerrit`ntool:codex`nnot:mcp:gerrit`n"
Kit rm --dir $HP rule gerrit-flow
Check 'rm --dir on such a folder: plain first, then the one taken out' { (@((ReadT "$HP/.agentkit") -split "`n" | Where-Object { $_ -and -not $_.StartsWith('#') }) -join ' ') -ceq 'skill:gerrit-review' -and (Test-Path "$HP/.claude/skills/gerrit-review/SKILL.md") }
Kit uninstall
Check 'uninstall: the folders are empty again' { @(Get-ChildItem -LiteralPath $G -Force).Count -eq 0 -and @(Get-ChildItem -LiteralPath $HP -Force).Count -eq 0 }

} finally { Done }
