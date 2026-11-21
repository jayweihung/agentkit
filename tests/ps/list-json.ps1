. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM; Kit add skill gerrit-review; Kit add mcp gerrit; Kit rm skill gerrit-workflow
W "$TEAM/skills/team-build/SKILL.md" "---`nname: team-build`ndescription: b`n---`nx`n"; Kit sync
# ---------- list --json (for programs) ----------
W "$TEAM/skills/quote/SKILL.md" "---`nname: quote`ndescription: 中文 `"引號`" \ 和`ttab`n---`nx`n"
Kit list --json; $lj = $out; $ljrc = $rc
W "$T/list.json" "$lj`n"
$teamJ = (Resolve-Path -LiteralPath $TEAM).ProviderPath.Replace('\', '\\')
Check 'list --json: exit 0, valid JSON' { $ljrc -eq 0 -and $null -ne (JGet "$T/list.json" 'kit') }
Check 'list --json: version and source' { (JGet "$T/list.json" 'kit') -eq ('"' + $KitVer + '"') -and $lj.Contains("{`"name`": `"team`", `"source`": `"$teamJ`", `"dir`": `"$teamJ`", `"push`": `"pr`", `"changed`": []}") }
Check 'list --json: required, used, unused' {
    $lj.Contains('{"kind": "rule", "name": "security", "status": "required", "new": false, "changed": false, "source": "team", "description": "", "path": ') -and
    $lj.Contains('{"kind": "skill", "name": "gerrit-review", "status": "used", "new": false, "changed": false, "source": "team", "description": "review a change", "path": ') -and
    $lj.Contains('{"kind": "skill", "name": "gerrit-workflow", "status": "unused", "new": false, "changed": false, "source": "third-party", "description": "upstream", "path": ') }
Check 'list --json: agent with its description' { $lj.Contains('{"kind": "agent", "name": "gerrit", "status": "agent", "new": false, "changed": false, "source": "team", "description": "Gerrit helper", "path": ') }
Check 'list --json: new item, text escaped (UTF-8 kept)' { $lj.Contains('{"kind": "skill", "name": "quote", "status": "unused", "new": true, "changed": false, "source": "team", "description": "中文 \"引號\" \\ 和\ttab", "path": ') }
Check 'list --json: tools (Claude only here), no version wanted' { $lj.Contains("`n  `"tools`": [`"claude`"],`n") -and (JGet "$T/list.json" 'kit_version_wanted') -eq '""' }
W "$TEAM/rules/headed.md" "note`r`n# 標題 one`r`n# second`r`n"
Kit list --json
Check 'list --json: a rule says its first # heading (CRLF too)' { $out.Contains('{"kind": "rule", "name": "headed", "status": "unused", "new": true, "changed": false, "source": "team", "description": "標題 one", "path": ') }
Remove-Item -LiteralPath "$TEAM/rules/headed.md" -Force
# kit describe: Chinese descriptions for the panel, in the source's descriptions-zh.txt, kept until the description changes
Kit describe --todo
Check 'describe --todo: English descriptions without a Chinese one, not the Chinese ones' { $rc -eq 0 -and ($out -split "`n") -ccontains "skill:gerrit-workflow`tupstream" -and -not ($out -match '(?m)^skill:quote\t') }
Kit describe skill gerrit-workflow "上游`t的`n說明"
Check 'describe: written in the source that has it, one line (tabs, line breaks made spaces)' { $rc -eq 0 -and (ReadT "$TP/descriptions-zh.txt") -ceq "skill:gerrit-workflow`t2a767e25cb57`t上游 的 說明`n" }
Kit describe skill gerrit-workflow '上游的說明'
Kit list --json
Check 'describe: again replaces its line; list --json has description_zh' { @((ReadT "$TP/descriptions-zh.txt") -split "`n" | Where-Object { $_ }).Count -eq 1 -and $out.Contains('"description": "upstream", "description_zh": "上游的說明", "path": ') }
Kit describe --todo
Check 'describe: --todo no longer lists it' { -not $out.Contains('gerrit-workflow') }
$gw = ReadT "$TP/skills/gerrit-workflow/SKILL.md"; W "$TP/skills/gerrit-workflow/SKILL.md" ($gw.Replace('description: upstream', 'description: upstream v2'))
Kit list --json; $lz = $out; Kit describe --todo
Check 'describe: a changed description is not shown in Chinese until translated again' { -not $lz.Contains('description_zh') -and ($out -split "`n") -ccontains "skill:gerrit-workflow`tupstream v2" }
W "$TP/skills/gerrit-workflow/SKILL.md" $gw; Remove-Item -LiteralPath "$TP/descriptions-zh.txt" -Force
Kit describe skill nope x
Check 'describe: unknown item refused' { $rc -ne 0 -and $out.Contains('找不到 skill:nope') }
Kit describe skill gerrit-workflow '  '
Check 'describe: no text refused, nothing written' { $rc -ne 0 -and -not (Test-Path -LiteralPath "$TP/descriptions-zh.txt") }
Kit list --json
Check 'list --json does not mark items seen' { ([regex]::Matches($out, '"new": true')).Count -eq 1 }
Kit list --bad
Check 'list with a wrong option: usage' { $rc -ne 0 -and $out.Contains('kit list [--json') }
Remove-Item -Recurse -Force "$TEAM/skills/quote"

# ---------- status --json (a panel: which kit, api and commits this account uses; read only) ----------
& git -C $TEAM init -q; & git -C $TEAM add -A; & git -C $TEAM -c user.name=t -c user.email=t@t commit -qm init
$teamHead = "$(& git -C $TEAM rev-parse HEAD)".Trim()
$tpJ = (Resolve-Path -LiteralPath $TP).ProviderPath.Replace('\', '\\')
function Snap([string]$d) { # every file (not PowerShell's own cache) with its size and time
    (@(Get-ChildItem -LiteralPath $d -Recurse -Force -File | Where-Object { $_.FullName -notmatch '[\\/](\.cache|\.local)[\\/]' } | Sort-Object FullName |
        ForEach-Object { "$($_.FullName) $($_.Length) $($_.LastWriteTimeUtc.Ticks)" })) -join "`n" }
Kit api; $api = $out
$snap0 = Snap $H
KitJ status --json; $sj = $out; $sjrc = $rc
W "$T/status.json" "$sj`n"
Check 'status --json: exit 0, valid JSON' { $sjrc -eq 0 -and $null -ne (JGet "$T/status.json" 'kit') }
Check 'status --json: kit, api, user, at' { (JGet "$T/status.json" 'kit') -eq ('"' + $KitVer + '"') -and (JGet "$T/status.json" 'api') -eq ('"' + $api + '"') -and
    (JGet "$T/status.json" 'user') -eq ('"' + [Environment]::UserName + '"') -and $sj -match "`n  `"at`": [0-9]{10},`n" }
Check 'status --json: no self (kit not installed from a clone), no approvals' { $sj.Contains("`n  `"self`": null,`n  `"approvals`": null,`n") }
Check 'status --json: a git source has its commit, a folder that is not git null' {
    $sj.EndsWith("`n    {`"name`": `"team`", `"source`": `"$teamJ`", `"dir`": `"$teamJ`", `"commit`": `"$teamHead`", `"approved`": null},`n    {`"name`": `"third-party`", `"source`": `"$tpJ`", `"dir`": `"$tpJ`", `"commit`": null, `"approved`": null}`n  ]`n}") }
Check 'status --json writes nothing' { (Snap $H) -ceq $snap0 }
if (-not $OnWindows) {
    $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' unix/kit status --json 2>/dev/null") -join "`n"
    Check 'status --json: unix/kit prints the same' { ($bash -replace '"at": [0-9]+,', '"at": 0,') -ceq ($sj -replace '"at": [0-9]+,', '"at": 0,') }
}
$env:AGENTKIT_CONFIG = Join-Path $T 'noconf'
KitJ status --json
Check 'status --json before kit init: exit 0, sources [], approvals null, nothing pending' { $rc -eq 0 -and $out.EndsWith("`n  `"approvals`": null,`n  `"pending`": [],`n  `"sources`": []`n}") -and -not (Test-Path (Join-Path $T 'noconf')) }
$AC = Join-Path $T 'apconf'; W "$AC/machine.yaml" ((ReadT "$H/.config/agentkit/machine.yaml") + "approvals: https://gitea.example/acme/approvals.git`nsigners: $T/allowed_signers`n")
$env:AGENTKIT_CONFIG = $AC
Kit status --json
Check 'status --json with approvals but no clone of them here yet: not valid, nothing approved, nothing fetched' { $rc -eq 0 -and -not $out.Contains('不支援') -and $out.Contains("`n  `"approvals`": {`"serial`": null, `"used`": null, `"valid`": false},`n") -and
    $out.Contains("`"commit`": `"$teamHead`", `"approved`": null}") -and -not (Test-Path "$H/agentkit/.approvals") }
Remove-Item env:AGENTKIT_CONFIG
KitJ status
Check 'status without --json: usage error as JSON' { $rc -ne 0 -and $out -ceq '{"error": {"code": "usage", "message": "用法：kit status --json"}}' }
# self: the clone kit was installed from (.repo next to kit.ps1), named after its origin
$KL = Join-Path $T 'kitlib'; [void](New-Item -ItemType Directory -Force -Path $KL)
Copy-Item -LiteralPath $Kit -Destination (Join-Path $KL 'kit.ps1'); Copy-Item -LiteralPath (Join-Path $Repo 'VERSION') -Destination (Join-Path $KL 'VERSION')
W "$KL/.repo" "$TEAM`n"
& git -C $TEAM remote add origin https://gitea.example/acme/agentkit.git
$sj2 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $KL 'kit.ps1') status --json 2>$null | ForEach-Object { "$_" }) -join "`n"
Check 'status --json: self is the clone kit was installed from (name from its origin) and its commit' { $sj2.Contains("`n  `"self`": {`"name`": `"agentkit`", `"commit`": `"$teamHead`", `"approved`": null},`n") }
Remove-Item -Recurse -Force (Join-Path $TEAM '.git'), $KL

} finally { Done }
