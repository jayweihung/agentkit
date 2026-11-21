. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- MCP: a pasted setup, URL servers, secrets as ${VAR}, packages (kit new mcp --config, install-deps mcp) ----------
Set-Home (Join-Path $T 'home-mcp')
$MS = Join-Path $T 'mcpsrc'; W "$MS/kit.yaml" "name: msrc`n"
[void](New-Item -ItemType Directory -Force -Path "$H/.codex", "$H/.omp/agent")
Kit init $MS
# secrets made here (not written out in this file): never in any output or file kit writes
$S1 = 'ghp' + '_Zq7Lm2Xc9Vb4Nn8Kk3Jj6Hh1Gg5Ff0Dd2Ss4'; $S2 = 'tok' + 'Val-9f8e7d'; $S3 = 'Ab3' + 'dEf5GhIj7KlMn9PqRs1Tu'
W "$T/m1.json" "{`"mcpServers`": {`"GitHub Server`": {`"command`": `"npx`", `"args`": [`"-y`", `"@modelcontextprotocol/server-github@1.2.3`"], `"env`": {`"GITHUB_PERSONAL_ACCESS_TOKEN`": `"$S1`", `"LOG_LEVEL`": `"info`"}},`n `"web`": {`"type`": `"http`", `"url`": `"https://mcp.example.com/mcp`", `"headers`": {`"Authorization`": `"Bearer $S2`", `"X-Api-Key`": `"$S3`", `"X-Plain`": `"v1`"}}}}`n"
KitJ new mcp --config "$T/m1.json" --look
Check 'mcp paste: several servers -> several_servers with their names' { $rc -ne 0 -and $out.Contains('"code": "several_servers"') -and $out.Contains('"servers": ["GitHub Server", "web"]') }
KitJ new mcp nope --config "$T/m1.json" --look
Check 'mcp paste: a name not in it -> not_found' { $rc -ne 0 -and $out.Contains('"code": "not_found"') }
KitJ new mcp github-server --config "$T/m1.json" --look
$lk = $out | ConvertFrom-Json
Check 'mcp paste --look: one line; name, type, the secret by its variable, the package; nothing written' { $rc -eq 0 -and @($out -split "`n").Count -eq 1 -and $lk.name -eq 'github-server' -and $lk.type -eq 'stdio' -and $lk.secrets[0].var -eq 'GITHUB_PERSONAL_ACCESS_TOKEN' -and $lk.secrets[0].where -eq 'env.GITHUB_PERSONAL_ACCESS_TOKEN' -and $lk.packages[0].version -eq '1.2.3' -and @($lk.requires) -contains 'node' -and -not (Test-Path "$MS/mcp") }
Kit new mcp github-server --config "$T/m1.json"
Check 'mcp paste: writes the yaml with ${VAR}, says the variable' { $rc -eq 0 -and $out.Contains('${GITHUB_PERSONAL_ACCESS_TOKEN}') -and (ReadT "$MS/mcp/github-server.yaml").Contains("  GITHUB_PERSONAL_ACCESS_TOKEN: `${GITHUB_PERSONAL_ACCESS_TOKEN}`n") }
Kit new mcp web --config "$T/m1.json"
Check 'mcp paste http: type, secret headers as ${VAR}' { $y = ReadT "$MS/mcp/web.yaml"; $rc -eq 0 -and $y.Contains("type: http`n") -and $y.Contains("  Authorization: `"Bearer `${WEB_TOKEN}`"`n") -and $y.Contains("  X-Api-Key: `${WEB_API_KEY}`n") -and $y.Contains("  X-Plain: v1`n") }
KitJ new mcp web --config "$T/m1.json" --look
Check 'mcp paste --look: a name already there says exists' { $rc -eq 0 -and $out.Contains('"exists": true') }
W "$T/m2.txt" "claude mcp add --transport sse -s user events https://events.example.com/sse ```n  -H `"X-Api-Key: $S3`"`n"
Kit new mcp --config "$T/m2.txt"
Check 'mcp paste claude mcp add (sse, -H, a PowerShell line continued with a backtick)' { $y = ReadT "$MS/mcp/events.yaml"; $rc -eq 0 -and $y.Contains("type: sse`n") -and $y.Contains("  X-Api-Key: `${EVENTS_API_KEY}`n") }
W "$T/m3.txt" "codex mcp add docs --env DOCS_TOKEN=`$env:DOCS_TOKEN -- node C:\tools\docs.js`n"
Kit new mcp --config "$T/m3.txt"
Check 'mcp paste codex mcp add: $env:X becomes ${X}, a Windows path kept' { $y = ReadT "$MS/mcp/docs.yaml"; $rc -eq 0 -and $y.Contains("  DOCS_TOKEN: `${DOCS_TOKEN}`n") -and $y.Contains('C:\tools\docs.js') }
W "$T/m4.toml" "# Codex`n[mcp_servers.remote]`nurl = `"https://r.example.com/mcp`"`nbearer_token_env_var = `"R_TOKEN`"`nhttp_headers = { `"X-Team`" = `"a`" }`n"
Kit new mcp --config "$T/m4.toml"
Check 'mcp paste Codex config.toml: bearer_token_env_var -> Authorization: Bearer ${VAR}' { $y = ReadT "$MS/mcp/remote.yaml"; $rc -eq 0 -and $y.Contains("  Authorization: `"Bearer `${R_TOKEN}`"`n") -and $y.Contains("  X-Team: a`n") }
W "$T/m5.json" "{`"x`": {`"command`": `"a`","
KitJ new mcp --config "$T/m5.json" --look
Check 'mcp paste: not JSON -> bad_config' { $rc -ne 0 -and $out.Contains('"code": "bad_config"') }
W "$T/m6.json" "{`"command`": `"docker`", `"args`": [`"run`", `"-i`", `"img`"]}`n"
KitJ new mcp --config "$T/m6.json" --look
Check 'mcp paste: a bare object without a name -> no_name' { $rc -ne 0 -and $out.Contains('"code": "no_name"') }
Kit check $MS
Check 'mcp check: the pasted ones pass' { $rc -eq 0 }
W "$MS/mcp/leak.yaml" "command: x`nenv:`n  API_TOKEN: $S3`n"
Kit check $MS
Check 'mcp check: a literal secret fails, the value is not printed' { $rc -ne 0 -and $out.Contains('env.API_TOKEN 看起來是密碼或 token') -and -not $out.Contains($S3) }
W "$MS/mcp/leak.yaml" "command: x`nenv:`n  DB_PASS: $S3`n  MYSQL_PWD: x$S3`n"
Kit check $MS
Check 'mcp check: DB_PASS, MYSQL_PWD written in the yaml fail' { $rc -ne 0 -and $out.Contains('env.DB_PASS 看起來是密碼或 token') -and $out.Contains('env.MYSQL_PWD 看起來是密碼或 token') -and -not $out.Contains($S3) }
W "$MS/mcp/leak.yaml" "command: x`nenv:`n  API_TOKEN: `${API_TOKEN:-$S3}`n  LOG: `${LOG:-info}`n"
Kit check $MS
Check 'mcp check: a secret as the default of ${VAR:-…} fails (a plain default does not)' { $rc -ne 0 -and $out.Contains('env.API_TOKEN 看起來是密碼或 token') -and -not $out.Contains('env.LOG') -and -not $out.Contains($S3) }
W "$MS/mcp/leak.yaml" "command: x`nargs: [--workspace=AcmeCorpProduction2024, `"--id=$S3`", --path=WorkspaceAcme2024Main]`n"
Kit check $MS
Check 'mcp check: a long random value fails, words do not' { $rc -ne 0 -and $out.Contains('args[2] 看起來是密碼或 token') -and -not $out.Contains('args[1]') -and -not $out.Contains('args[3]') }
W "$MS/mcp/leak.yaml" "command: x`nargs: [--workspace=AcmeCorpProduction2024, `"--id=$S3`", --path=WorkspaceAcme2024Main]`nnot_secret: [`"args[2]`"]`n"
Kit check $MS
Check 'mcp check: not_secret: [args[2]] lets it pass' { $rc -eq 0 }
Remove-Item "$MS/mcp/leak.yaml"
W "$T/m8.json" "{`"1Password`": {`"command`": `"x`", `"env`": {`"DB_PASS`": `"$S3`", `"API_TOKEN`": `"`${API_TOKEN:-$S1}`", `"LOG`": `"`${LOG_LEVEL:-info}`"}, `"args`": [`"--workspace=AcmeCorpProduction2024`", `"--key=$S3`"]}}`n"
KitJ new mcp --config "$T/m8.json" --look
$lk = $out | ConvertFrom-Json
Check 'mcp paste: DB_PASS and a secret default ${VAR:-…} become ${VAR}; a name starting with a digit gets MCP_; words stay' { $rc -eq 0 -and $lk.name -eq '1password' -and (@($lk.secrets | ForEach-Object { "$($_.where)=$($_.var)" }) -join ' ') -ceq 'env.API_TOKEN=API_TOKEN env.DB_PASS=DB_PASS args[2]=MCP_1PASSWORD_KEY' -and $lk.yaml.Contains("  LOG: `${LOG_LEVEL:-info}`n") -and $lk.yaml.Contains("  - --workspace=AcmeCorpProduction2024`n") -and -not $lk.yaml.Contains($S1) }
W "$T/m9.json" "{`"mcpServers`": {`"$([char]0x212A)ube`": {`"command`": `"x`"}}}`n"
KitJ new mcp --config "$T/m9.json" --look
Check 'mcp paste: the name is made from A-Z, a-z, 0-9 only (the Kelvin sign is not a k)' { $rc -eq 0 -and ($out | ConvertFrom-Json).name -ceq 'ube' }
# stdin is read as UTF-8 (Windows PowerShell 5.1 would read it in the console's code page)
$oe = $OutputEncoding; $OutputEncoding = New-Object System.Text.UTF8Encoding $false
$dash = @(if ($PSVersionTable.PSEdition -ne 'Desktop') { '-' })   # (Windows PowerShell 5.1's -File cannot pass a lone -: --config with nothing after it reads stdin)
$o = ("claude mcp add u8 -e NOTE=é漢 -- uvx u8-srv@2.0.0`n" | & $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit new mcp --config @dash --look 2>$null | ForEach-Object { "$_" }) -join "`n"
$OutputEncoding = $oe
Check 'mcp paste --config -: read as UTF-8' { ($o | ConvertFrom-Json).yaml.Contains('é漢') }
# kit new: a failure is a failure (the error JSON only, exit not 0, nothing said to be made)
KitJ new mcp dock --config "$T/m6.json" --to nosuch --look
Check 'mcp new --look --to nosuch: only the error JSON, exit 1' { $rc -ne 0 -and @($out -split "`n").Count -eq 1 -and $out.Contains('"code": "no_source"') }
Kit new mcp dock --config "$T/m6.json" --to nosuch
Check 'mcp new --to nosuch: exit 1, nothing made' { $rc -ne 0 -and -not $out.Contains('已建立') -and -not (Test-Path "$MS/mcp/dock.yaml") }
if (-not $OnWindows) {
    & chmod 555 "$MS/mcp"
    Kit new mcp dock --config "$T/m6.json"; $o1 = $out; $r1 = $rc
    Kit new mcp dock2; $o2 = $out; $r2 = $rc
    & chmod 755 "$MS/mcp"
    Check 'mcp new: a file kit cannot write is an error' { $r1 -ne 0 -and $o1.Contains('沒辦法寫') -and -not $o1.Contains('已建立') -and $r2 -ne 0 -and $o2.Contains('沒辦法寫') -and -not $o2.Contains('已建立') }
}
$addOut = ''; foreach ($n in 'github-server', 'web', 'events', 'docs', 'remote') { Kit add mcp $n; $addOut += $out + "`n" }
$cj = ReadT "$H/.claude.json" | ConvertFrom-Json
$npx = if ($OnWindows) { 'cmd' } else { 'npx' }   # (on Windows npx.cmd runs through cmd /c)
Check 'mcp Claude: stdio without type, env as ${VAR}' { $s = $cj.mcpServers.'github-server'; $s.command -eq $npx -and $s.env.GITHUB_PERSONAL_ACCESS_TOKEN -eq '${GITHUB_PERSONAL_ACCESS_TOKEN}' -and -not (@($s.PSObject.Properties.Name) -contains 'type') }
Check 'mcp Claude: http and sse with type, url, headers' { $w = $cj.mcpServers.web; $w.type -eq 'http' -and $w.url -eq 'https://mcp.example.com/mcp' -and $w.headers.Authorization -eq 'Bearer ${WEB_TOKEN}' -and $cj.mcpServers.events.type -eq 'sse' }
$om = ReadT "$H/.omp/agent/mcp.json" | ConvertFrom-Json
Check 'mcp omp: the same' { $om.mcpServers.web.type -eq 'http' -and $om.mcpServers.web.headers.'X-Api-Key' -eq '${WEB_API_KEY}' -and $om.mcpServers.'github-server'.command -eq $npx }
$ct = (ReadT "$H/.codex/config.toml").Replace("`r`n", "`n")
Check 'mcp Codex http: url, bearer_token_env_var, env_http_headers, http_headers' { $ct.Contains("[mcp_servers.web]`nurl = `"https://mcp.example.com/mcp`"`nbearer_token_env_var = `"WEB_TOKEN`"`n") -and $ct.Contains('env_http_headers = { X-Api-Key = "WEB_API_KEY" }') -and $ct.Contains('http_headers = { X-Plain = "v1" }') }
Check 'mcp Codex stdio: an env that is ${ITSELF} -> env_vars' { $ct.Contains('env_vars = ["GITHUB_PERSONAL_ACCESS_TOKEN"]') -and $ct.Contains('env_vars = ["DOCS_TOKEN"]') -and $ct.Contains('LOG_LEVEL = "info"') }
Check 'mcp Codex: no SSE (left out, said once)' { -not $ct.Contains('mcp_servers.events') -and $addOut.Contains('Codex 不能用 SSE 的 MCP：events') }
KitJ list --json
$lj = $out | ConvertFrom-Json
Check 'mcp list --json: type, vars, needs, packages (not installed)' { $g = @($lj.items | Where-Object { $_.kind -eq 'mcp' -and $_.name -eq 'github-server' })[0]; $w = @($lj.items | Where-Object { $_.kind -eq 'mcp' -and $_.name -eq 'web' })[0]; $g.type -eq 'stdio' -and $g.vars[0].name -eq 'GITHUB_PERSONAL_ACCESS_TOKEN' -and $g.needs[0].tool -eq 'node' -and $g.packages[0].package -eq '@modelcontextprotocol/server-github' -and $g.packages[0].version -eq '1.2.3' -and $g.packages[0].ok -eq $false -and $w.type -eq 'http' -and @($w.packages).Count -eq 0 }
Kit list
Check 'mcp list: downloaded at each start, says how to install it' { $out.Contains('mcp:github-server 每次啟動時下載 @modelcontextprotocol/server-github（先裝好：kit install-deps mcp github-server）') }
Kit new mcp skel
Check 'mcp skeleton: both forms, and it passes kit check' { $y = ReadT "$MS/mcp/skel.yaml"; $y.Contains('command: （啟動 MCP server 的程式，例如 npx 或 uvx）') -and $y.Contains('# type: http          # 或 sse') -and $(Kit check $MS; $rc -eq 0) }
Remove-Item "$MS/mcp/skel.yaml"
if (-not $OnWindows) {
    # a fake npm: "view" says 9.8.7; "install" makes the package with a bin (no network)
    $FB = Join-Path $T 'fakebin-mcp'; [void](New-Item -ItemType Directory -Force -Path $FB)
    W "$FB/npm" ((@('#!/bin/sh', ('echo "$PWD $*" >> "' + "$T/npm-mcp.log" + '"'), 'case $1 in',
        'view) case $2 in *@^1) printf ''%s\n'' "rng-srv@1.2.0 ''1.2.0''" "rng-srv@1.10.1 ''1.10.1''" "rng-srv@1.9.0 ''1.9.0''";; *@next) echo 2.0.0-rc.1;; *) echo 9.8.7;; esac;;',
        'install) p=$(sed -n ''s/.*"dependencies": {"\([^"]*\)".*/\1/p'' package.json); mkdir -p "node_modules/$p/dist"',
        '  printf ''{"name": "%s", "bin": {"x": "dist/cli.js"}}\n'' "$p" > "node_modules/$p/package.json"; echo x > "node_modules/$p/dist/cli.js";;', 'esac') -join "`n") + "`n")
    & chmod +x "$FB/npm"
    $savedP = $env:PATH; $env:PATH = "$FB" + [IO.Path]::PathSeparator + $env:PATH
    W "$T/m7.json" "{`"pin`": {`"command`": `"npx`", `"args`": [`"-y`", `"left-pad-srv`", `"--x`"]}}`n"
    KitJ new mcp --config "$T/m7.json" --look
    Check 'mcp paste: an npx package without a version is pinned to what npm says' { $o = $out | ConvertFrom-Json; $rc -eq 0 -and $o.packages[0].version -eq '9.8.7' -and $o.yaml.Contains('left-pad-srv@9.8.7') }
    W "$T/m10.json" "{`"rng`": {`"command`": `"npx`", `"args`": [`"-y`", `"rng-srv@^1`"]}, `"nx`": {`"command`": `"npx`", `"args`": [`"tag-srv@next`"]}}`n"
    KitJ new mcp rng --config "$T/m10.json" --look
    Check 'mcp paste: an npm range is pinned to the highest that matches it (asked with the range), and says so' { $o = $out | ConvertFrom-Json; $rc -eq 0 -and $o.packages[0].version -eq '1.10.1' -and $o.yaml.Contains('rng-srv@1.10.1') -and @($o.warnings)[0] -ceq '套件 rng-srv 原本寫 @^1：固定在 1.10.1 版（符合 ^1 的最新版本）' -and (ReadT "$T/npm-mcp.log").Contains('view rng-srv@^1 version') }
    KitJ new mcp nx --config "$T/m10.json" --look
    Check 'mcp paste: an npm tag is pinned to its version, and says so' { $o = $out | ConvertFrom-Json; $rc -eq 0 -and $o.packages[0].version -eq '2.0.0-rc.1' -and @($o.warnings)[0].Contains('原本寫 @next：固定在 2.0.0-rc.1 版') }
    Kit install-deps mcp github-server
    $md = "$H/.config/agentkit/mcp-deps/github-server"
    Check 'mcp install-deps (npm): the pinned version, --ignore-scripts, in mcp-deps' { $rc -eq 0 -and (ReadT "$T/npm-mcp.log").Contains('install --ignore-scripts') -and (ReadT "$md/.kit-src/package.json").Contains('"@modelcontextprotocol/server-github": "1.2.3"') }
    $cj = ReadT "$H/.claude.json" | ConvertFrom-Json
    Check 'mcp installed: Claude runs node with the installed bin' { $s = $cj.mcpServers.'github-server'; $s.command -eq 'node' -and @($s.args)[0] -eq "$md/node_modules/@modelcontextprotocol/server-github/dist/cli.js" }
    KitJ list --json
    Check 'mcp list --json: installed -> ok' { $g = @(($out | ConvertFrom-Json).items | Where-Object { $_.kind -eq 'mcp' -and $_.name -eq 'github-server' })[0]; $g.packages[0].ok -eq $true }
    $env:PATH = $savedP
}
Check 'mcp: the secrets are in no file kit wrote' { @(Get-ChildItem -Recurse -File -Force $H, $MS | Where-Object { $c = [IO.File]::ReadAllText($_.FullName); $c.Contains($S1) -or $c.Contains($S2) -or $c.Contains($S3) }).Count -eq 0 }

} finally { Done }
