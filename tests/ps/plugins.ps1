. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
function FileUrl([string]$p) { $p = $p.Replace('\', '/'); if ($p.StartsWith('/')) { "file://$p" } else { "file:///$p" } }
function G { & git @args 2>&1 | Out-Null }
function SshK([string]$a) { # ssh-keygen with that command line (an empty "" stays an argument); its exit code
    $c = @(Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue); if ($c.Count -eq 0) { return 1 }
    $psi = New-Object Diagnostics.ProcessStartInfo ([string]$c[0].Path), $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close(); $e = $p.StandardError.ReadToEndAsync(); $o = $p.StandardOutput.ReadToEndAsync()
    # Windows' ssh-keygen that writes to stderr through a pipe can wait there for minutes; like kit.ps1, 30 s and it counts as missing
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; return 1 }; $p.WaitForExit(); [void]$e.Result; [void]$o.Result; $p.ExitCode
}
function ApprSign([string]$dir, [string]$key, [string]$text) { # approved.txt with TEXT, signed by KEY (what kit approve writes)
    W "$dir/approved.txt" $text; Remove-Item -LiteralPath "$dir/approved.txt.sig" -Force -ErrorAction SilentlyContinue
    SshK "-Y sign -q -f `"$key`" -n agentkit `"$dir/approved.txt`""
}
$SA = Join-Path $T 'signed'; [void](New-Item -ItemType Directory -Force -Path $SA)
$sshOk = (SshK "-q -t ed25519 -N `"`" -C approver -f `"$SA/key`"") -eq 0 -and (SshK "-q -t ed25519 -N `"`" -C mallory -f `"$SA/badkey`"") -eq 0
if ($sshOk) { W "$SA/try.txt" "x`n"; $sshOk = (SshK "-Y sign -q -f `"$SA/key`" -n agentkit `"$SA/try.txt`"") -eq 0 -and (Test-Path "$SA/try.txt.sig") }
$SAs = "$SA/allowed_signers"
if ($sshOk) {
W $SAs ('jay namespaces="agentkit" ' + (ReadT "$SA/key.pub").Trim() + "`n")
}
# ---------- plugins: kit's own marketplace, each tool installs it; Codex's hooks trusted only for a signed version ----------
$PG = Join-Path $T 'plug'; $PB = Join-Path $PG 'bin'; $savedHome = $H; $savedP = $env:PATH
Set-Home (Join-Path $PG 'home')
W "$PB/fake.ps1" @'
$tool = $args[0]; $rest = @($args | Select-Object -Skip 1)
[IO.File]::AppendAllText($env:FAKE_LOG, "$tool $($rest -join ' ')`n")
if ($tool -eq 'codex' -and $rest[0] -eq 'plugin' -and $rest[1] -eq 'add') {
    $n = $rest[2] -replace '@kit$', ''; $c = Join-Path $env:FAKE_DIR "cxcache/$n"
    if (Test-Path -LiteralPath $c) { Remove-Item -LiteralPath $c -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $env:HOME ".config/agentkit/plugins/$n") -Destination $c -Recurse -Force
    if (Test-Path -LiteralPath (Join-Path $env:FAKE_DIR 'cxchange')) { [IO.File]::AppendAllText((Join-Path $c 'x'), "changed`n") }
    "Installed plugin root: $c"
}
function Own-Hooks { # kit's own hooks in hooks.json, trusted or not as $FAKE_DIR/cxown says (none without it)
    $f = Join-Path $env:FAKE_DIR 'cxown'; if (-not (Test-Path -LiteralPath $f)) { return '' }
    $ts = ([IO.File]::ReadAllText($f)).Trim()
    (@('session_start|sync --hook', 'user_prompt_submit|handoff-hook', 'pre_tool_use|codex-guard') | ForEach-Object { $e, $c = $_ -split '\|'
        ',{"key":"/h/.codex/hooks.json:' + $e + ':0:0","source":"user","pluginId":null,"command":"kit ' + $c + '","trustStatus":"' + $ts + '"}' }) -join ''
}
if ($tool -eq 'codex' -and $rest[0] -eq 'app-server') {   # Codex's JSON-RPC on stdin/stdout: hooks/list, config/batchWrite
    while ($null -ne ($l = [Console]::In.ReadLine())) {
        if ($l.Contains('"method":"hooks/list"')) {
            $i = [regex]::Match($l, '"id":([0-9]+)').Groups[1].Value; $st = if (Test-Path -LiteralPath (Join-Path $env:FAKE_DIR 'cxtrusted')) { 'trusted' } else { 'untrusted' }
            [Console]::Out.WriteLine('{"id":' + $i + ',"result":{"data":[{"cwd":"/","hooks":[{"key":"demo@kit:hooks/h.json:session_start:0:0","eventName":"sessionStart","pluginId":"demo@kit","currentHash":"sha256:aa/sha256:bb","trustStatus":"' + $st + '"},{"key":"/x/hooks.json:stop:0:0","pluginId":null,"currentHash":"sha256:cc","trustStatus":"untrusted"}' + $(Own-Hooks) + ']}]}}')
        } elseif ($l.Contains('config/batchWrite')) {
            [IO.File]::WriteAllText((Join-Path $env:FAKE_DIR 'cxwrite'), "$l`n"); [IO.File]::WriteAllText((Join-Path $env:FAKE_DIR 'cxtrusted'), '')
            [Console]::Out.WriteLine('{"id":3,"result":{"status":"ok"}}')
        } elseif ($l.Contains('"id":1,')) { [Console]::Out.WriteLine('{"id":1,"result":{}}') }
        [Console]::Out.Flush()
    }
}
exit 0
'@
foreach ($tn in 'claude', 'codex', 'omp') {
    if ($OnWindows) { W "$PB/$tn.cmd" "@`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$PB\fake.ps1`" $tn %*`r`n" }
    else { W "$PB/$tn" "#!/bin/sh`nexec '$Exe' -NoProfile -File '$PB/fake.ps1' $tn `"`$@`"`n"; & chmod +x "$PB/$tn" }
}
$env:FAKE_LOG = "$PG/log"; $env:FAKE_DIR = $PG; $env:PATH = $PB + $sep + $env:PATH
W "$PG/src/rules/pr.md" "Plugin rule.`n"
W "$PG/src/plugins/demo/.claude-plugin/plugin.json" "{`"name`": `"demo`", `"version`": `"1.0.0`", `"description`": `"A demo plugin`", `"hooks`": [`"./hooks/h.json`"]}`n"
W "$PG/src/plugins/demo/hooks/h.json" "{`"hooks`": {`"SessionStart`": [{`"hooks`": [{`"type`": `"command`", `"command`": `"node x.js`"}]}]}}`n"
W "$PG/src/plugins/demo/skills/demo/SKILL.md" "---`nname: demo`ndescription: d`n---`nbody`n"
G -C "$PG/src" init -q; G -C "$PG/src" config user.name t; G -C "$PG/src" config user.email t@t; G -C "$PG/src" add -A; G -C "$PG/src" commit -qm v1
function PLog { if (Test-Path -LiteralPath "$PG/log") { @((ReadT "$PG/log") -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) } else { @() } }
$PC = "$H/.config/agentkit/plugins"; $PCj = $PC.Replace('\', '/'); $PD = "$H/.config/agentkit/notes/pending"
Kit init "$PG/src"
$cxAt = @(PLog | Where-Object { $_ -like 'codex app-server*' }).Count   # kit's own hooks in hooks.json: asked Codex once
Kit list
Check 'plugins: kit list shows a plugin' { $out -match '(?m)^ +plugin:demo$' }
KitJ list --json
Check 'plugins: list --json, kind plugin with its description and the programs its hooks run' { $p = @(($out | ConvertFrom-Json).items | Where-Object { $_.kind -eq 'plugin' }); $p.Count -eq 1 -and $p[0].status -eq 'unused' -and $p[0].description -eq 'A demo plugin' -and @($p[0].needs | ForEach-Object { $_.tool }) -contains 'node' }
Check 'plugins: list --json, what it brings (parts), as unix/kit prints it' { $out -cmatch '"parts": \{"skills": \["demo"\], "commands": \[\], "agents": \[\], "mcp": \[\], "hooks": true\}' }
Kit add plugin demo
Check "plugins: add copies it to kit's marketplace (the same files as unix/kit)" { $rc -eq 0 -and (Test-Path "$PC/demo/hooks/h.json") -and (Test-Path "$PC/demo/.claude-plugin/plugin.json") -and
    (ReadT "$PC/.claude-plugin/marketplace.json") -ceq "{`"name`":`"kit`",`"owner`":{`"name`":`"kit`"},`"plugins`":[{`"name`":`"demo`",`"source`":`"./demo`"}]}`n" -and
    (ReadT "$PC/.agents/plugins/marketplace.json") -ceq "{`"name`":`"kit`",`"interface`":{`"displayName`":`"kit`"},`"plugins`":[{`"name`":`"demo`",`"source`":{`"source`":`"local`",`"path`":`"./demo`"},`"policy`":{`"installation`":`"AVAILABLE`",`"authentication`":`"ON_INSTALL`"},`"category`":`"Productivity`"}]}`n" }
$l = PLog
Check "plugins: each tool installs it from kit's marketplace" { @($l | Where-Object { $_.Replace('\', '/') -ceq "claude plugin marketplace add $PCj --scope user" }).Count -eq 1 -and ($l -ccontains 'claude plugin install demo@kit --scope user') -and ($l -ccontains 'codex plugin add demo@kit') -and ($l -ccontains 'omp plugin install demo@kit --scope user --force') }
Check "plugins: not signed -> Codex's hooks not trusted by kit, asked instead" { @($l | Where-Object { $_ -like 'codex app-server*' }).Count -eq $cxAt -and -not (Test-Path "$PG/cxwrite") -and (ReadT "$PD/codex-hooks-demo").Contains('/hooks') -and $out.Contains('沒有簽章') }
Check 'plugins: the pending item is kept until done (no agent)' { $x = @((ReadT "$PD/codex-hooks-demo") -split "`n"); $x[0] -eq '' -and $x[1] -eq '' }
[IO.File]::WriteAllText("$PG/log", ''); Kit sync
Check 'plugins: sync with nothing changed installs nothing again' { -not @(PLog | Where-Object { $_ -match 'install|plugin add' }) }
if ($sshOk) {   # signed later on the computer that signs (no approvals of its own: the approvals and key kit approve remembered)
    [void](ApprSign "$PG/appr" "$SA/key" "serial: 1`nsrc $("$(& git -C "$PG/src" rev-parse HEAD)".Trim())`n")
    [IO.File]::AppendAllText("$H/.config/agentkit/state.tsv", "sign`tapprovals`t$PG/appr`nsign`tkey`t$SA/key`n")
    [IO.File]::WriteAllText("$PG/log", ''); Kit sync
    $l = PLog
    Check 'plugins: signed after it was installed -> the next sync has Codex trust it (the key that signed here)' { ($l -ccontains 'codex plugin add demo@kit') -and -not @($l | Where-Object { $_ -match '^(claude|omp) plugin install' }) -and (Test-Path "$PG/cxwrite") -and -not (Test-Path "$PD/codex-hooks-demo") -and $out.Contains('Codex 已信任') }
    [IO.File]::WriteAllText("$PG/log", ''); Kit sync
    Check 'plugins: trusted, nothing to do at the next sync' { -not @(PLog | Where-Object { $_ -match 'plugin add|install' }) }
    Remove-Item -LiteralPath "$PG/cxwrite", "$PG/cxtrusted" -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path "$PG/fd" | Out-Null; [IO.File]::WriteAllText("$PG/log", '')
Kit add --dir "$PG/fd" plugin demo
$l = PLog
Check 'plugins: --dir -> Claude --scope local, omp --scope project ; kit says Codex is account-only' { $rc -eq 0 -and ($l -ccontains 'claude plugin install demo@kit --scope local') -and ($l -ccontains 'omp plugin install demo@kit --scope project --force') -and $out.Contains('Codex 只能整個帳號裝') }
KitJ list --json --dir "$PG/fd"
Check 'plugins: list --json --dir, here.folder.plugins' { $out.Contains('"plugins": [{"name": "demo", "tools": ["claude", "omp"], "note": "Codex 只能整個帳號裝"}]') }
[IO.File]::WriteAllText("$PG/log", ''); Kit rm --dir "$PG/fd" plugin demo
$l = PLog
Check 'plugins: rm --dir uninstalls there only' { ($l -ccontains 'claude plugin uninstall demo@kit --scope local') -and ($l -ccontains 'omp plugin uninstall demo@kit --scope project') -and -not @($l | Where-Object { $_ -like '*scope user*' }) }
Kit rm plugin demo
$l = PLog
Check "plugins: rm uninstalls from each tool, kit's copy gone" { ($l -ccontains 'claude plugin uninstall demo@kit --scope user') -and ($l -ccontains 'codex plugin remove demo@kit') -and ($l -ccontains 'omp plugin uninstall demo@kit --scope user') -and -not (Test-Path "$PC/demo") -and -not (Test-Path "$PD/codex-hooks-demo") }
W "$PG/src/plugins/demo/skills/demo/SKILL.md" "---`nname: demo`ndescription: d2`n---`nbody`n"; G -C "$PG/src" commit -qam v2
Kit add plugin demo
Check 'plugins: a changed source is copied and installed again' { $rc -eq 0 -and (ReadT "$PC/demo/skills/demo/SKILL.md").Contains('d2') }
if ($sshOk) {   # this machine's approvals say this commit -> kit has Codex trust the hooks (Codex's own hashes), and asks Codex again
    Kit rm plugin demo; Remove-Item -LiteralPath "$PG/cxwrite", "$PG/cxtrusted" -Force -ErrorAction SilentlyContinue
    [void](ApprSign "$PG/appr" "$SA/key" "serial: 2`nsrc $("$(& git -C "$PG/src" rev-parse HEAD)".Trim())`n")
    [IO.File]::AppendAllText("$H/.config/agentkit/machine.yaml", "approvals: $PG/appr`nsigners: $SAs`n")
    Kit add plugin demo
    Check "plugins: signed -> Codex trusts the plugin's hooks (only those), checked with Codex" { $w = ReadT "$PG/cxwrite"; $w.Contains('"keyPath":"hooks.state"') -and $w.Contains('"demo@kit:hooks/h.json:session_start:0:0":{"trusted_hash":"sha256:aa","trusted_content_hash":"sha256:bb"}') -and -not $w.Contains('/x/hooks.json') -and $out.Contains('Codex 已信任') -and -not (Test-Path "$PD/codex-hooks-demo") }
    Kit rm plugin demo; Remove-Item -LiteralPath "$PG/cxwrite", "$PG/cxtrusted" -Force -ErrorAction SilentlyContinue
    [IO.File]::AppendAllText("$PG/src/plugins/demo/hooks/h.json", "`n"); G -C "$PG/src" commit -qam v3
    Kit add plugin demo
    Check 'plugins: a commit nobody signed -> not trusted' { -not (Test-Path "$PG/cxwrite") -and (Test-Path "$PD/codex-hooks-demo") -and (ReadT "$H/.config/agentkit/machine.yaml").Contains('approvals: ') }
    Kit rm plugin demo; [void](ApprSign "$PG/appr" "$SA/key" "serial: 3`nsrc $("$(& git -C "$PG/src" rev-parse HEAD)".Trim())`n"); W "$PG/cxchange" "x`n"
    Kit add plugin demo
    Check "plugins: Codex's copy not the same as kit's -> not trusted" { -not (Test-Path "$PG/cxwrite") -and (Test-Path "$PD/codex-hooks-demo") }
    Remove-Item -LiteralPath "$PG/cxchange" -Force
}
Kit uninstall
$l = PLog
Check "plugins: uninstall takes them out and kit's marketplace with them" { ($l -ccontains 'claude plugin marketplace remove kit') -and ($l -ccontains 'omp plugin marketplace remove kit') -and ($l -ccontains 'codex plugin marketplace remove kit') -and -not (Test-Path $PC) }
# collect: the whole plugin, only what the tools load; --skip remembered in the lock, out of plugin.json too
$PU = Join-Path $PG 'upstream'
W "$PU/.claude-plugin/plugin.json" "{`"name`": `"up`", `"description`": `"Up plugin`", `"hooks`": [`"./hooks/a.json`", `"./hooks/band.json`"], `"types`": `"./hooks/band/t.d.ts`"}`n"
W "$PU/package.json" "{`"name`": `"up`", `"pi`": {`"extensions`": [`"./pi-ext/index.js`"]}}`n"
W "$PU/hooks/a.json" "{}`n"; W "$PU/hooks/band.json" "{}`n"; W "$PU/hooks/band/t.d.ts" "x`n"; W "$PU/hooks/run.js" "run()`n"
W "$PU/pi-ext/index.js" "ext()`n"; W "$PU/docs/d.md" "doc`n"; W "$PU/.github/ci.yml" "ci`n"; W "$PU/LICENSE" "MIT`n"; W "$PU/.claude-plugin/marketplace.json" "{`"name`": `"up`"}`n"
W "$PU/skills/one/SKILL.md" "---`nname: one`ndescription: o`n---`nb`n"
G -C $PU init -q; G -C $PU config user.name t; G -C $PU config user.email t@t; G -C $PU add -A; G -C $PU commit -qm up
$CL = Join-Path $PG 'lib'
W "$CL/kit.yaml" "push: direct`nmaintainers: [t@t]`ncollect_sources: [$(FileUrl $PU)]`n"
G -C $CL init -q; G -C $CL config user.name t; G -C $CL config user.email t@t; G -C $CL add -A; G -C $CL commit -qm l
Push-Location $CL
KitJ collect (FileUrl $PU) --look --skip hooks/band.json
Check 'collect --look: a plugin is one item, kind plugin' { $s = @(($out | ConvertFrom-Json).skills); $s.Count -eq 1 -and $s[0].kind -eq 'plugin' -and $s[0].name -eq 'up' -and $s[0].description -eq 'Up plugin' -and $s[0].scripts.Contains('hooks/run.js') }
Kit collect (FileUrl $PU) --skip hooks/band.json --skip hooks/band
Check 'collect: a plugin into plugins/<name>, only the parts the tools load' { $rc -eq 0 -and (Test-Path "$CL/plugins/up/hooks/a.json") -and (Test-Path "$CL/plugins/up/pi-ext/index.js") -and (Test-Path "$CL/plugins/up/skills/one/SKILL.md") -and (Test-Path "$CL/plugins/up/LICENSE") -and -not (Test-Path "$CL/plugins/up/docs") -and -not (Test-Path "$CL/plugins/up/.github") -and $out.Contains('kit add plugin up') }
Check 'collect --skip: left out, and out of plugin.json (hooks, a key naming it); no backup left in the copy' { -not (Test-Path "$CL/plugins/up/hooks/band.json") -and -not (Test-Path "$CL/plugins/up/hooks/band") -and -not (ReadT "$CL/plugins/up/.claude-plugin/plugin.json").Contains('band') -and (ReadT "$CL/plugins/up/.claude-plugin/plugin.json").Contains('./hooks/a.json') -and -not (Test-Path "$CL/plugins/up/.claude-plugin/plugin.json.kit-backup") -and -not (Test-Path "$CL/plugins/up/.claude-plugin/marketplace.json") }
Check 'collect --skip: the lock remembers it' { @((ReadT "$CL/third_party.lock") -split "`n" | Where-Object { $f = $_.Split("`t"); $f[0] -eq 'up' -and $f.Count -eq 9 -and $f[7] -eq 'hooks/band.json,hooks/band' -and $f[8] -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' }).Count -eq 1 -and (ReadT "$CL/third_party.lock").StartsWith('# third_party.lock - written by kit collect; name url path ref commit license date [skip] [upstream-date]') }
G -C $CL add -A; G -C $CL commit -qm up; W "$PU/hooks/band.json.new" "{}`n"; G -C $PU add -A; G -C $PU commit -qm up2
Kit collect up
Check 'collect <name> again: the same --skip' { $rc -eq 0 -and -not (Test-Path "$CL/plugins/up/hooks/band.json") -and (Test-Path "$CL/plugins/up/hooks/band.json.new") -and -not (ReadT "$CL/plugins/up/.claude-plugin/plugin.json").Contains('band.json"') }
W "$CL/skills/up/SKILL.md" "---`nname: up`ndescription: s`n---`nb`n"
Kit collect up
Check 'collect: a plugin and a skill may not share a name' { $rc -ne 0 -and $out.Contains('同名的 skill:up') }
Remove-Item -Recurse -Force "$CL/skills/up"
Kit collect (FileUrl $PU) --skip ../x
Check 'collect --skip: a path outside the plugin refused' { $rc -ne 0 -and $out.Contains('--skip 後面要接') }
Pop-Location
# Codex runs a new hook only after you trust it (/hooks): kit asks only while Codex has not
foreach ($x in 'untrusted', 'trusted') {
    W "$PG/cxown" "$x`n"; Set-Home (Join-Path $PG "cx-$x"); New-Item -ItemType Directory -Force -Path "$H/.codex" | Out-Null
    Kit init "$PG/src"; Set-Variable "cx_$x" $out
}
Check 'codex hooks new, Codex has not trusted them: asked once (/hooks)' { $cx_untrusted.Contains('/hooks') -and (Test-Path (Join-Path $PG 'cx-untrusted/.config/agentkit/notes/pending/codex-hooks')) }
Check 'codex hooks new, Codex already trusts them: not asked' { -not $cx_trusted.Contains('/hooks') -and -not (Test-Path (Join-Path $PG 'cx-trusted/.config/agentkit/notes/pending/codex-hooks')) }
W "$PG/cxown" "trusted`n"; Set-Home (Join-Path $PG 'cx-untrusted'); Kit sync
Check 'codex hooks trusted later (/hooks): the reminder goes, not asked again' { -not $out.Contains('/hooks') -and -not (Test-Path (Join-Path $PG 'cx-untrusted/.config/agentkit/notes/pending/codex-hooks')) }
Remove-Item -LiteralPath "$PG/cxown" -Force
$env:PATH = $savedP; Set-Home $savedHome

} finally { Done }
