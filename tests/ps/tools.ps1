. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- the programs a skill needs (kit tools / install-tool, "needs" in list --json) ----------
Set-Home (Join-Path $T 'home6')
$NT = Join-Path $T 'needteam'
W "$NT/skills/drawer/SKILL.md" "---`nname: drawer`ndescription: draws`n---`nRun ``node bin/draw.mjs <in>`` to draw.`n"
W "$NT/skills/drawer/package.json" "{`"name`": `"drawer`", `"engines`": {`"node`": `">=18`"}}`n"
W "$NT/skills/plain/SKILL.md" "---`nname: plain`ndescription: only text`n---`nNo node, no python here.`n"
W "$NT/skills/plain/package.json" "{`"name`": `"plain`"}`n"; W "$NT/skills/plain/scripts/check.py" "print(1)`n"
W "$NT/skills/told/SKILL.md" "---`nname: told`ndescription: says`nrequires: [node>=20, frob]`n---`nx`n"
W "$NT/kit.yaml" "name: needteam`nrequires:`n  plain: [git]`n"
W "$NT/skills/packed/SKILL.md" "---`nname: packed`ndescription: has npm packages`n---`nRun ``node scripts/run.mjs``.`n"
W "$NT/skills/packed/scripts/run.mjs" "x`n"; W "$NT/skills/packed/package.json" "{`"name`": `"packed`", `"dependencies`": {`"left-pad`": `"1.3.0`"}}`n"
W "$NT/skills/packed/package-lock.json" "{`"lockfileVersion`": 3, `"packages`": {`"`": {`"dependencies`": {`"left-pad`": `"1.3.0`"}}, `"node_modules/left-pad`": {`"version`": `"1.3.0`", `"resolved`": `"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz`", `"integrity`": `"sha512-XI5MPzVNApjAyhQzphX8BkmKsKUxD4LdyK24iZeQEGg9ylg3cs3KHoxHhvlaXRBmtqI9zaxOttfQ9EE5zORWb4w==`"}}}`n"
W "$NT/skills/packed/.npmrc" "registry=http://elsewhere.invalid/`n"
# npm packages kit must not install: a git dependency; a lock with a package from git; a lock on another registry
foreach ($n in 'npmgit', 'npmlock', 'npmreg') { W "$NT/skills/$n/SKILL.md" "---`nname: $n`ndescription: x`n---`nx`n" }
W "$NT/skills/npmgit/package.json" "{`"name`": `"npmgit`", `"dependencies`": {`"left-pad`": `"1.3.0`"}, `"optionalDependencies`": {`"tool`": `"github:someone/tool`"}}`n"
W "$NT/skills/npmlock/package.json" "{`"name`": `"npmlock`", `"dependencies`": {`"tool`": `"^1.0.0`"}}`n"
W "$NT/skills/npmlock/package-lock.json" "{`"lockfileVersion`": 1, `"dependencies`": {`"tool`": {`"version`": `"1.0.0`", `"resolved`": `"https://registry.npmjs.org/tool/-/tool-1.0.0.tgz`", `"integrity`": `"sha512-x`", `"dependencies`": {`"sub`": {`"version`": `"git+ssh://git@git.example.org/someone/sub.git#abc`", `"resolved`": `"git+ssh://git@git.example.org/someone/sub.git#abc`"}}}}}`n"
W "$NT/skills/npmreg/package.json" "{`"name`": `"npmreg`", `"dependencies`": {`"tool`": `"^1.0.0`"}}`n"
W "$NT/skills/npmreg/package-lock.json" "{`"lockfileVersion`": 3, `"packages`": {`"`": {}, `"node_modules/tool`": {`"version`": `"1.0.0`", `"resolved`": `"https://npm.example.com/r/tool/-/tool-1.0.0.tgz`", `"integrity`": `"sha512-x`"}}}`n"
W "$NT/skills/asks/SKILL.md" "---`nname: asks`ndescription: x`nrequires: [noprobe]`n---`nx`n"
W "$NT/skills/pyskill/SKILL.md" "---`nname: pyskill`ndescription: python packages`n---`nRun ``python3 scripts/go.py``.`n"
W "$NT/skills/pyskill/requirements.txt" "# what it needs`nrequests==2.32.0`ncertifi ; sys_platform != 'win32' and python_version < `"4`"  # ok`n"
W "$NT/skills/pybad/SKILL.md" "---`nname: pybad`ndescription: b`n---`nx`n"; W "$NT/skills/pybad/requirements.txt" "requests`n-e git+http://elsewhere.invalid/x`n"
W "$NT/skills/pymark/SKILL.md" "---`nname: pymark`ndescription: b`n---`nx`n"; W "$NT/skills/pymark/requirements.txt" "requests ; python_version >= `"3.8`" --config-settings=x=y`n"
Kit init $NT
Kit list --json
$items = @{}; foreach ($m in [regex]::Matches($out, '"name": "(drawer|plain|told)".*?"needs": (\[[^\]]*\])')) { $items[$m.Groups[1].Value] = $m.Groups[2].Value }
Check 'needs: SKILL.md runs node, package.json gives the lowest version' { $items['drawer'] -match '"tool": "node", "title": "Node.js", "min": "18"' }
Check 'needs: a package.json or a .py of the author says nothing; kit.yaml requires does' { $items['plain'] -match '"tool": "git"' -and $items['plain'] -notmatch '"tool": "(node|python)"' }
Check 'needs: SKILL.md requires; an unknown program has no install' { $items['told'] -match '"min": "20"' -and $items['told'] -match '"tool": "frob", "title": "frob", "min": "", "have": "", "ok": false, "install": ""' }
if (-not $OnWindows) {
    $FB = Join-Path $T 'fakebin6'; [void](New-Item -ItemType Directory -Force -Path $FB)
    W "$FB/node" "#!/bin/sh`necho v16.2.0`n"
    W "$FB/brew" "#!/bin/sh`necho `"`$*`" >> '$T/brew6.log'`n[ `"`$1`" = upgrade ] && printf '#!/bin/sh\necho v26.1.0\n' > '$FB/node'`ncase `$2 in bad*) exit 1;; frob) printf '#!/bin/sh\necho frob 1.2.3\n' > '$FB/frob'; chmod +x '$FB/frob';; esac`nexit 0`n"
    W "$FB/apt-get" "#!/bin/sh`nexit 1`n"                       # (a Linux run as root: never the real one)
    W "$FB/noprobe" "#!/bin/sh`necho ran >> '$T/noprobe6.log'`necho noprobe 1.0`n"
    & chmod +x "$FB/node" "$FB/brew" "$FB/apt-get" "$FB/noprobe"
    $savedP = $env:PATH; $env:PATH = "$FB" + [IO.Path]::PathSeparator + '/usr/bin:/bin'
    Kit list --json
    Check 'needs: a program kit has no recipe for is not run to look at it' { $out -match '"tool": "noprobe", "title": "noprobe", "min": "", "have": "", "ok": false, "install": ""' -and -not (Test-Path "$T/noprobe6.log") }
    Check 'needs: too old here, kit says the upgrade' { $out -match '"tool": "node", "title": "Node.js", "min": "18", "have": "16.2.0", "ok": false, "install": "brew upgrade node"' }
    Kit tools
    Check 'tools: what this machine has and how kit would install it' { $out -match '(?m)^node +16\.2\.0 +brew install node$' }
    $env:KIT_DRY_RUN = '1'; Kit install-tool node --min 18; Remove-Item env:KIT_DRY_RUN
    Check 'install-tool --min, dry run: only says the upgrade' { $out.Contains('執行 brew upgrade node') -and -not (Test-Path "$T/brew6.log") }
    Kit install-tool node --min 18
    Check 'install-tool --min: runs kit''s upgrade, then looks again' { $rc -eq 0 -and (ReadT "$T/brew6.log") -eq "upgrade node`n" -and $out.Contains('Node.js 26.1.0 裝好了') }
    Remove-Item "$T/brew6.log"
    $bad = '"sh -c evil", "brew frob;rm", "curl x", "brew user/tap/frob", "brew -frob", "brew ../frob", "brew frob"'
    W "$NT/tools/frob.yaml" "name: frob`ntitle: Frob`ninstall:`n  mac: [$bad]`n  linux: [$bad]`n"
    Kit install-tool frob
    Check 'install-tool: a recipe can only pick a known manager and a plain package name' { (ReadT "$T/brew6.log") -eq "install frob`n" -and $out.Contains('執行 brew install frob') -and $out.Contains('Frob 1.2.3 裝好了') }
    Remove-Item "$T/brew6.log", "$FB/frob"
    W "$NT/tools/frob.yaml" "name: frob`ntitle: Frob`ninstall:`n  mac: [brew badfrob, brew frob]`n  linux: [brew badfrob, brew frob]`n"
    Kit install-tool frob
    Check 'install-tool: one way fails -> the next way in the recipe' { $rc -eq 0 -and (ReadT "$T/brew6.log") -eq "install badfrob`ninstall frob`n" -and $out.Contains('用 brew 裝失敗') -and $out.Contains('Frob 1.2.3 裝好了') }
    W "$NT/tools/frob.yaml" "name: frob`ntitle: Frob`ninstall:`n  mac: [brew badfrob]`n  linux: [brew badfrob]`n"; Remove-Item "$FB/frob"
    Kit install-tool frob
    Check 'install-tool: every way fails -> says so' { $rc -ne 0 -and $out.Contains('每一種裝法都沒有成功（最後是 brew）') }
    W "$NT/tools/pyfrob.yaml" "name: pyfrob`ninstall:`n  mac: [pip pyfrob]`n  linux: [pip pyfrob]`n"
    $env:KIT_DRY_RUN = '1'; Kit install-tool pyfrob; Remove-Item env:KIT_DRY_RUN
    Check 'install-tool (pip): wheels only, for this account' { $out.Contains('執行 python3 -m pip install --user --only-binary=:all: pyfrob') }
    W "$NT/tools/node.yaml" "name: node`ntitle: Node`ninstall:`n  mac: [scoop node]`n  linux: [scoop node]`n"; Remove-Item "$FB/node", "$T/brew6.log" -ErrorAction SilentlyContinue
    Kit install-tool node
    Check 'install-tool: kit''s own recipe wins over a source''s' { (Test-Path /usr/bin/node) -or ($out.Contains('執行 brew install node') -and (ReadT "$T/brew6.log") -eq "install node`n" -and -not $out.Contains('scoop')) }
    Kit tools
    Check 'tools: kit''s own recipe for node, not the source''s' { $out -match '(?m)^node .*(brew install node|apt-get install -y nodejs)$' }
    W "$NT/tools/slowtool.yaml" "name: slowtool`nbin: [slowtool]`ninstall:`n  mac: [brew slowtool]`n  linux: [brew slowtool]`n"; W "$FB/slowtool" "#!/bin/sh`nsleep 30`necho slowtool 1.0`n"
    W "$NT/tools/chatty.yaml" "name: chatty`nbin: [chatty]`ninstall:`n  mac: [brew chatty]`n  linux: [brew chatty]`n"; W "$FB/chatty" "#!/bin/sh`nexec yes 'chatty 2.5'`n"
    & chmod +x "$FB/slowtool" "$FB/chatty"
    $env:KIT_PROBE_WAIT = '1'; $t0 = Get-Date; Kit tools; $took = ((Get-Date) - $t0).TotalSeconds; Remove-Item env:KIT_PROBE_WAIT
    Check 'tools: a --version that hangs is given up, one that never stops is cut' { $took -lt 30 -and $out -match '(?m)^slowtool +（沒有）' -and $out -match '(?m)^chatty +2\.5 ' }
    foreach ($f in "$NT/tools/slowtool.yaml", "$NT/tools/chatty.yaml", "$NT/tools/pyfrob.yaml", "$NT/tools/node.yaml", "$FB/slowtool", "$FB/chatty") { Remove-Item $f -ErrorAction SilentlyContinue }
    $env:PATH = $savedP
}
Kit install-tool nope
Check 'install-tool: no recipe, says how to add one' { $rc -ne 0 -and $out.Contains('tools/nope.yaml') }
# a skill's own npm packages (kit install-deps): only when asked, in kit's folder, no package scripts, linked into each copy
$FB7 = Join-Path $T 'fakebin7'; [void](New-Item -ItemType Directory -Force -Path $FB7)
if ($OnWindows) {
    W "$FB7/npm.cmd" "@echo off`r`necho %CD% %*>> `"$T\npm7.log`"`r`nif exist .npmrc exit /b 9`r`nmkdir node_modules\left-pad`r`necho x> node_modules\left-pad\index.js`r`n"
} else {
    W "$FB7/npm" "#!/bin/sh`necho `"`$PWD `$*`" >> '$T/npm7.log'`n[ -f .npmrc ] && exit 9`nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js`n"; & chmod +x "$FB7/npm"
}
$savedP = $env:PATH; $env:PATH = "$FB7" + [IO.Path]::PathSeparator + $env:PATH
function PkOf([string]$n, [string]$k = 'npm') { $m = [regex]::Match($out, '"name": "' + $n + '"[^\n]*?"packages": \[[^\n]*?(\{"kind": "' + $k + '"[^}]*\})'); if ($m.Success) { $m.Groups[1].Value } else { $null } }
Kit list --json
Check 'packages: a lock -> npm ci, no package scripts' { (PkOf 'packed') -eq '{"kind": "npm", "ok": false, "had": false, "install": "npm ci --ignore-scripts --omit=dev --no-audit --no-fund", "bad": ""}' -and $null -eq (PkOf 'drawer') }
Kit add skill packed
$env:KIT_DRY_RUN = '1'; Kit install-deps packed; Remove-Item env:KIT_DRY_RUN
Check 'install-deps, dry run: only says the command' { $out.Contains('執行 npm ci --ignore-scripts --omit=dev --no-audit --no-fund') -and -not (Test-Path "$T/npm7.log") }
$S7 = Join-Path $H '.config/agentkit/deps/packed'; $C7 = Join-Path $H '.claude/skills/packed'
Kit install-deps packed
Check 'install-deps: npm ci in a new folder next to kit''s, not the source, without the skill''s .npmrc' { $rc -eq 0 -and (ReadT "$T/npm7.log").Trim().Replace('\', '/') -match '\.config/agentkit/deps/packed\.new\.[a-z0-9]+ ci --ignore-scripts --omit=dev --no-audit --no-fund$' -and (Test-Path "$S7/node_modules/left-pad/index.js") -and -not (Test-Path "$NT/skills/packed/node_modules") -and -not (Test-Path "$S7/.npmrc") -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $S7) -Filter 'packed.new.*').Count -eq 0 }
Check 'install-deps: the copy kit put gets node_modules linked to it' { (Get-Item -LiteralPath "$C7/node_modules" -Force).LinkType -and (Test-Path "$C7/node_modules/left-pad/index.js") }
Kit list --json
Check 'packages: installed now' { (PkOf 'packed') -eq '{"kind": "npm", "ok": true, "had": true, "install": "npm ci --ignore-scripts --omit=dev --no-audit --no-fund", "bad": ""}' }
Kit sync
Check 'sync: the link is not a change to the skill' { $out -notmatch '手動' -and (Get-Item -LiteralPath "$C7/node_modules" -Force).LinkType }
# kit run: the agent's folder gets the links too, and goes with them (never into kit's store); a dry run has none
W "$NT/agents/packer.md" "---`nname: packer`ndescription: x`nskills: [packed]`n---`nx`n"
$env:KIT_DRY_RUN = '1'; Kit run packer; Remove-Item env:KIT_DRY_RUN
$rt = (@($out -split "`n" | Where-Object { $_.StartsWith('tmp=') })[0]).Substring(4).TrimEnd("`r")
Check 'run, dry run: the agent''s folder to look at, without kit''s links' { (Test-Path "$rt/.claude/skills/packed/SKILL.md") -and -not (Test-Path "$rt/.claude/skills/packed/node_modules") -and -not (Test-Path "$rt/.kit-pid") }
Remove-Item -LiteralPath $rt -Recurse -Force
$SR = Join-Path ([IO.Path]::GetTempPath()) "kit-run.kittest$PID"; [void](New-Item -ItemType Directory -Force -Path "$SR/x"); W "$SR/.kit-pid" "999999`n"
[void](New-Item -ItemType $(if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }) -Path "$SR/x/node_modules" -Target "$S7/node_modules")
if ($OnWindows) { W "$FB7/claude.cmd" "@echo off`r`necho %*> `"$T\claude.args`"`r`nif not exist `"%2\.claude\skills\packed\node_modules\left-pad`" exit /b 4`r`nexit /b 3`r`n" }
else { W "$FB7/claude" "#!/bin/sh`necho `"`$*`" > '$T/claude.args'`n[ -L `"`$2/.claude/skills/packed/node_modules`" ] || exit 4`nexit 3`n"; & chmod +x "$FB7/claude" }
Kit run packer
$rt = ([regex]::Match((ReadT "$T/claude.args"), '--add-dir (\S+)')).Groups[1].Value.Trim('"')
Check 'run: the agent''s folder has kit''s links; its exit code; the folder gone, kit''s packages still there' { $rc -eq 3 -and $rt -and -not (Test-Path -LiteralPath $rt) -and (Test-Path "$S7/node_modules/left-pad/index.js") }
Check 'run: the folder of a run that was killed goes (its links only)' { -not (Test-Path -LiteralPath $SR) -and (Test-Path "$S7/node_modules/left-pad/index.js") }
foreach ($f in "$FB7/claude", "$FB7/claude.cmd", "$NT/agents/packer.md") { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
# what kit does not install: git, a URL, another registry without your ~/.npmrc
Kit list --json
Check 'packages: a git dependency is shown as refused' { (PkOf 'npmgit') -eq '{"kind": "npm", "ok": false, "had": false, "install": "npm install --ignore-scripts --omit=dev --no-audit --no-fund", "bad": "package.json: optionalDependencies.tool = github:someone/tool"}' }
Check 'packages: a lock (v1) with a package from git, or one from another registry, is refused' { (PkOf 'npmlock') -match '"bad": "package-lock.json: node_modules/tool/node_modules/sub: resolved git\+ssh://git@git.example.org/someone/sub.git#abc"' -and (PkOf 'npmreg') -match '"bad": "package-lock.json: node_modules/tool: resolved https://npm.example.com/r/tool/-/tool-1.0.0.tgz"' }
if (Test-Path "$T/npm7.log") { Remove-Item "$T/npm7.log" }
Kit install-deps npmgit
Check 'install-deps: refuses a git dependency, npm not run' { $rc -ne 0 -and $out.Contains('kit 不裝這些 npm 套件') -and $out.Contains('github:someone/tool') -and -not (Test-Path "$T/npm7.log") -and -not (Test-Path (Join-Path $H '.config/agentkit/deps/npmgit')) }
W "$H/.npmrc" "registry = https://npm.example.com/r`n"
Kit list --json
Check 'packages: your own ~/.npmrc registry is fine' { (PkOf 'npmreg') -match '"bad": ""' }
Remove-Item -Force "$H/.npmrc"
if (-not $OnWindows) {
    $env:HOME = $H; $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' PATH='$FB7':`"`$PATH`" unix/kit list --json 2>&1") -join "`n"; Kit list --json
    Check 'packages (refused): unix/kit says the same' { $bash -ceq $out }
}
# npm fails: nothing half-made
if ($OnWindows) { W "$FB7/npm.cmd" "@echo off`r`nmkdir node_modules\x`r`nexit /b 3`r`n" } else { W "$FB7/npm" "#!/bin/sh`nmkdir -p node_modules/x`nexit 3`n" }
Remove-Item -LiteralPath $S7 -Recurse -Force
Kit install-deps packed
Check 'install-deps: npm fails -> says so, nothing half-made' { $rc -ne 0 -and $out.Contains('裝套件失敗') -and -not (Test-Path $S7) -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $S7) -Filter 'packed.new.*').Count -eq 0 }
if ($OnWindows) { W "$FB7/npm.cmd" "@echo off`r`nmkdir node_modules\left-pad`r`necho x> node_modules\left-pad\index.js`r`n" } else { W "$FB7/npm" "#!/bin/sh`nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js`n" }
Kit install-deps packed
# Python: a venv of the skill's own (fake python here), requirements.txt with names and versions only
Kit list --json
Check 'packages (pip): a requirements.txt with options is shown as refused' { (PkOf 'pybad' 'pip') -match '"bad": "2: -e git\+http://elsewhere.invalid/x"' }
Check 'packages (pip): an option after a marker is refused too' { (PkOf 'pymark' 'pip').Contains('"bad": "1: requests ; python_version >= \"3.8\" --config-settings=x=y"') }
Kit install-deps pybad
Check 'install-deps (pip): refuses options in requirements.txt' { $rc -ne 0 -and $out.Contains('第 2: -e') -and -not (Test-Path (Join-Path $H '.config/agentkit/pydeps/pybad')) }
if (-not $OnWindows) {
    $realPy = (Get-Command python3 -CommandType Application | Select-Object -First 1).Source
    W "$FB7/python3" "#!/bin/sh`n[ `"`$1 `$2`" = '-m venv' ] || exec '$realPy' `"`$@`"`nmkdir -p `"`$3/bin`" && printf '#!/bin/sh\necho `"`$PWD `$*`" >> $T/pip7.log\n' > `"`$3/bin/python`" && chmod +x `"`$3/bin/python`"`n"; & chmod +x "$FB7/python3"
    Kit list --json
    Check 'packages (pip): a venv and pip with wheels only' { (PkOf 'pyskill' 'pip') -eq '{"kind": "pip", "ok": false, "had": false, "install": "python3 -m venv venv; venv/bin/python -m pip install --only-binary=:all: --no-input --disable-pip-version-check -r requirements.txt", "bad": ""}' }
    Kit add skill pyskill
    Kit install-deps pyskill pip
    $S8 = Join-Path $H '.config/agentkit/pydeps/pyskill'; $C8 = Join-Path $H '.claude/skills/pyskill'
    Check 'install-deps (pip): a venv in kit''s folder, pip run there with wheels only' { $rc -eq 0 -and (ReadT "$T/pip7.log").Trim().EndsWith('pydeps/pyskill -m pip install --only-binary=:all: --no-input --disable-pip-version-check -r requirements.txt') -and (Test-Path "$S8/venv/bin/python") -and -not (Test-Path "$NT/skills/pyskill/.venv") }
    Check 'install-deps (pip): the copy gets .venv linked, the instructions say to use it' { (Get-Item -LiteralPath "$C8/.venv" -Force).LinkType -and (ReadT (Join-Path $H '.claude/CLAUDE.md')).Contains('.venv/bin/python') }
    # the python line is the account's (for the account's skills), never in a folder's own files
    $PD = Join-Path $T 'pyproj'; W "$PD/CLAUDE.md" "# mine`n"; Copy-Item "$PD/CLAUDE.md" "$T/pd.orig"
    Kit add --dir $PD skill pyskill
    Check 'add --dir with kit''s venv: the folder''s copy gets .venv, its CLAUDE.md is not touched' { (Get-Item -LiteralPath "$PD/.claude/skills/pyskill/.venv" -Force).LinkType -and (SameBytes "$T/pd.orig" "$PD/CLAUDE.md") -and -not (Test-Path "$PD/AGENTS.md") }
    Kit rm --dir $PD skill pyskill
    Check 'rm --dir with kit''s venv: the folder exactly as before' { (SameBytes "$T/pd.orig" "$PD/CLAUDE.md") -and ((@(Get-ChildItem -LiteralPath $PD -Force | ForEach-Object { $_.Name }) -join ' ') -eq 'CLAUDE.md') }
    Kit rm skill pyskill
    Check 'python line: gone with the skill (kit''s venv stays)' { $cm = Join-Path $H '.claude/CLAUDE.md'; (Test-Path "$S8/venv/bin/python") -and (-not (Test-Path $cm) -or -not (ReadT $cm).Contains('.venv/bin/python')) }
    Kit add skill pyskill
    $env:HOME = $H; $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' PATH='$FB7':`"`$PATH`" unix/kit list --json 2>&1") -join "`n"; Kit list --json
    Check 'packages (pip, installed): unix/kit says the same' { $bash -ceq $out }
    # pip fails: the venv kit had goes back
    W "$NT/skills/pyskill/requirements.txt" "requests==2.33.0`n"
    W "$FB7/python3" "#!/bin/sh`n[ `"`$1 `$2`" = '-m venv' ] || exec '$realPy' `"`$@`"`nmkdir -p `"`$3/bin`" && printf '#!/bin/sh\nexit 4\n' > `"`$3/bin/python`" && chmod +x `"`$3/bin/python`"`n"
    Kit install-deps pyskill pip
    Check 'install-deps (pip): pip fails -> the old venv stays' { $rc -ne 0 -and $out.Contains('裝套件失敗') -and (ReadT "$S8/.kit-src/requirements.txt").Contains('2.32.0') -and (Test-Path "$S8/venv/bin/python") -and -not (Test-Path "$S8.old") }
    Remove-Item "$FB7/python3"
}
Kit rm skill packed
Check 'rm skill: the copy goes, kit''s packages stay (the link only)' { -not (Test-Path $C7) -and (Test-Path "$S7/node_modules/left-pad/index.js") }
Kit uninstall
Check 'uninstall: kit''s packages go too' { -not (Test-Path (Join-Path $H '.config/agentkit/deps')) -and -not (Test-Path (Join-Path $H '.config/agentkit/pydeps')) }
# a skill's hash is its own files, not what a link in it points at (PowerShell 5.1 would follow a junction)
W "$T/hashme/a.txt" "a`n"; W "$T/linked/b.txt" "b`n"
$h1 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __dir-hash "$T/hashme" 2>&1 | ForEach-Object { "$_" }) -join ''
[void](New-Item -ItemType $(if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }) -Path "$T/hashme/node_modules" -Target "$T/linked")
$h2 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __dir-hash "$T/hashme" 2>&1 | ForEach-Object { "$_" }) -join ''
W "$T/hashme/c.txt" "c`n"
$h3 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __dir-hash "$T/hashme" 2>&1 | ForEach-Object { "$_" }) -join ''
Check 'skill hash: a link (junction) in it does not count, its own files do' { $h1 -match '^[0-9A-F]{16}$' -and $h1 -eq $h2 -and $h3 -ne $h1 }
[void](New-Item -ItemType Directory -Force -Path "$T/hashme/scripts/__pycache__"); [IO.File]::WriteAllBytes("$T/hashme/scripts/__pycache__/x.cpython-314.pyc", [byte[]]@(0, 1, 2)); [IO.File]::WriteAllBytes("$T/hashme/y.pyc", [byte[]]@(0, 1, 2))
$h4 = (& $Exe -NoProfile -ExecutionPolicy Bypass -File $Kit __dir-hash "$T/hashme" 2>&1 | ForEach-Object { "$_" }) -join ''
Check 'skill hash: Python caches (__pycache__, .pyc) do not count' { $h4 -eq $h3 }
$env:PATH = $savedP

} finally { Done }
