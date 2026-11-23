. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM
W "$TEAM/skills/team-build/SKILL.md" "---`nname: team-build`ndescription: b`n---`nx`n"
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
Kit check $TEAM
Check 'check: an agent with tools.only: a note for its author (what Claude can''t do), not a problem' { $out.Contains('agents/gerrit.md: tools.only 在 Claude 是把其他內建工具寫進 deny') -and -not $out.Contains('kit check: agents/gerrit.md: tools.only') }
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
Kit api
Check 'api: one line, major.minor (1.18)' { $rc -eq 0 -and $out -ceq '1.18' }
$env:AGENTKIT_CONFIG = Join-Path $T 'noconf'
KitJ list --json
Check 'list --json before kit init: error not_init, only JSON on stdout' { $rc -ne 0 -and $out -ceq '{"error": {"code": "not_init", "message": "還沒設定：先打  kit init <網址或資料夾>"}}' }
Remove-Item env:AGENTKIT_CONFIG
KitJ list --json --bad
Check 'list --json with a wrong option: error usage' { $rc -ne 0 -and $out.StartsWith('{"error": {"code": "usage", ') }
Kit help
Check 'help: kit api is there' { $out -match '(?m)^  kit api  ' }
Check 'help: --json --dir is under kit list' { $out -match "(?m)^  kit list .*`n     --json --dir" -and $out -notmatch "(?m)^  kit agent .*`n     --json --dir" }

} finally { Done }
