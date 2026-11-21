#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# left by the sections before: a fake claude, a home that had kit place and kit uninstall
mkdir -p "$T/fakebin"; printf '#!/bin/sh\n"$FAKE_KIT" list --json --dir "$PWD" --pid $PPID > "$FAKE_OUT" 2>&1\n' > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
mkdir -p "$T/home6/.codex" "$T/home6/.omp/agent" "$T/home6/.claude"; printf '{"permissions": {"deny": ["mcp__gerrit__submit_change"]}}\n' > "$T/home6/.claude/settings.json"
# ---------- the programs a skill needs (kit tools / install-tool, "needs" in list --json) ----------
H6="$T/home6"; FB="$T/fakebin"; mkdir -p "$H6" "$FB"
printf '#!/bin/sh\necho v16.2.0\n' > "$FB/node"; chmod +x "$FB/node"
printf '#!/bin/sh\necho "$*" >> "%s/brew.log"\n[ "$1" = upgrade ] && printf "#!/bin/sh\\necho v26.1.0\\n" > "%s/node" && chmod +x "%s/node"\ncase $2 in bad*) exit 1;; frob) printf "#!/bin/sh\\necho frob 1.2.3\\n" > "%s/frob" && chmod +x "%s/frob";; esac\nexit 0\n' "$T" "$FB" "$FB" "$FB" "$FB" > "$FB/brew"; chmod +x "$FB/brew"
printf '#!/bin/sh\necho "$*" >> "%s/apt.log"\nexit 1\n' "$T" > "$FB/apt-get"; chmod +x "$FB/apt-get"     # (a Linux run as root: never the real one)
NT="$T/needteam"; mkdir -p "$NT/skills/drawer/bin" "$NT/skills/plain/scripts" "$NT/skills/told" "$NT/tools"
printf -- '---\nname: drawer\ndescription: draws\n---\nRun `node bin/draw.mjs <in>` to draw.\n' > "$NT/skills/drawer/SKILL.md"; echo 'x' > "$NT/skills/drawer/bin/draw.mjs"
printf '{"name": "drawer", "engines": {"node": ">=18"}}\n' > "$NT/skills/drawer/package.json"
printf -- '---\nname: plain\ndescription: only text\n---\nNo node, no python here.\n' > "$NT/skills/plain/SKILL.md"
printf '{"name": "plain", "private": true}\n' > "$NT/skills/plain/package.json"; echo 'print(1)' > "$NT/skills/plain/scripts/check.py"
printf -- '---\nname: told\ndescription: says what it needs\nrequires: [node>=20, frob]\n---\nx\n' > "$NT/skills/told/SKILL.md"
printf 'name: needteam\nrequires:\n  plain: [git]\n' > "$NT/kit.yaml"
mkdir -p "$NT/skills/packed/scripts"; printf -- '---\nname: packed\ndescription: has npm packages\n---\nRun `node scripts/run.mjs`.\n' > "$NT/skills/packed/SKILL.md"
echo 'x' > "$NT/skills/packed/scripts/run.mjs"; printf '{"name": "packed", "dependencies": {"left-pad": "1.3.0"}}\n' > "$NT/skills/packed/package.json"
printf '{"lockfileVersion": 3, "packages": {"": {"dependencies": {"left-pad": "1.3.0"}}, "node_modules/left-pad": {"version": "1.3.0", "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", "integrity": "sha512-XI5MPzVNApjAyhQzphX8BkmKsKUxD4LdyK24iZeQEGg9ylg3cs3KHoxHhvlaXRBmtqI9zaxOttfQ9EE5zORWb4w==", "license": "WTFPL"}}}\n' > "$NT/skills/packed/package-lock.json"
printf 'registry=http://elsewhere.invalid/\n' > "$NT/skills/packed/.npmrc"
# npm packages kit must not install: a git dependency; a lock with a package from git; a lock on another registry
for n in npmgit npmlock npmreg; do mkdir -p "$NT/skills/$n"; printf -- '---\nname: %s\ndescription: x\n---\nx\n' "$n" > "$NT/skills/$n/SKILL.md"; done
printf '{"name": "npmgit", "dependencies": {"left-pad": "1.3.0"}, "optionalDependencies": {"tool": "github:someone/tool"}}\n' > "$NT/skills/npmgit/package.json"
printf '{"name": "npmlock", "dependencies": {"tool": "^1.0.0"}}\n' > "$NT/skills/npmlock/package.json"
printf '{"lockfileVersion": 3, "packages": {"": {}, "node_modules/tool": {"version": "1.0.0", "resolved": "git+ssh://git@git.example.org/someone/tool.git#abc", "integrity": "sha512-x"}}}\n' > "$NT/skills/npmlock/package-lock.json"
printf '{"name": "npmreg", "dependencies": {"tool": "^1.0.0"}}\n' > "$NT/skills/npmreg/package.json"
printf '{"lockfileVersion": 3, "packages": {"": {}, "node_modules/tool": {"version": "1.0.0", "resolved": "https://npm.example.com/r/tool/-/tool-1.0.0.tgz", "integrity": "sha512-x"}}}\n' > "$NT/skills/npmreg/package-lock.json"
# a program a skill asks for that kit has no recipe for: never run
mkdir -p "$NT/skills/asks"; printf -- '---\nname: asks\ndescription: x\nrequires: [noprobe]\n---\nx\n' > "$NT/skills/asks/SKILL.md"
printf '#!/bin/sh\necho ran >> "%s/noprobe.log"\necho noprobe 1.0\n' "$T" > "$FB/noprobe"; chmod +x "$FB/noprobe"
mkdir -p "$NT/skills/pyskill/scripts" "$NT/skills/pybad"; printf -- '---\nname: pyskill\ndescription: python packages\n---\nRun `python3 scripts/go.py`.\n' > "$NT/skills/pyskill/SKILL.md"
echo 'print(1)' > "$NT/skills/pyskill/scripts/go.py"; printf '# what it needs\nrequests==2.32.0\nrich[jupyter] >=13, <15 ; python_version >= "3.9"\ncertifi ; sys_platform != '"'win32'"' and python_version < "4"  # ok\n' > "$NT/skills/pyskill/requirements.txt"
printf -- '---\nname: pybad\ndescription: b\n---\nx\n' > "$NT/skills/pybad/SKILL.md"; printf 'requests\n--index-url http://elsewhere.invalid/\n' > "$NT/skills/pybad/requirements.txt"
# an option after a marker (pip takes it from there too)
mkdir -p "$NT/skills/pymark"; printf -- '---\nname: pymark\ndescription: b\n---\nx\n' > "$NT/skills/pymark/SKILL.md"; printf 'requests ; python_version >= "3.8" --config-settings=x=y\n' > "$NT/skills/pymark/requirements.txt"
REALPY=$(command -v python3)
(
export HOME="$H6" PATH="$FB:/usr/bin:/bin"
kit init "$NT" >/dev/null 2>&1
kit list --json > "$T/needs.json" 2>/dev/null
nd() { python3 -c "import json,sys;d={i['name']:i for i in json.load(open(sys.argv[1]))['items']};print(json.dumps(d[sys.argv[2]]['needs'],sort_keys=True))" "$T/needs.json" "$1"; }
check "needs: SKILL.md runs node, package.json gives the lowest version, too old here, brew is there" '[ "$(nd drawer)" = "[{\"have\": \"16.2.0\", \"install\": \"brew upgrade node\", \"min\": \"18\", \"ok\": false, \"title\": \"Node.js\", \"tool\": \"node\"}]" ]'
check "needs: a package.json or a .py of the author says nothing; kit.yaml requires does" 'nd plain | grep -q "\"tool\": \"git\"" && ! nd plain | grep -q "\"tool\": \"node\"" && ! nd plain | grep -q python'
check "needs: SKILL.md requires, an unknown program has no install" 'nd told | grep -q "\"min\": \"20\"" && nd told | grep -q "\"install\": \"\", \"min\": \"\", \"ok\": false, \"title\": \"frob\", \"tool\": \"frob\""'
check "needs: kit.ps1 prints the same list" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(cat "$T/needs.json")" ]'
check "needs: a program kit has no recipe for is not run to look at it" 'nd asks | grep -qF "\"have\": \"\", \"install\": \"\"" && [ ! -e "$T/noprobe.log" ]'
out=$(kit tools 2>&1)
check "tools: what this machine has and how kit would install it" 'echo "$out" | grep -qE "^node +16.2.0 +brew install node$"'
out=$(kit install-tool node 2>&1)
check "install-tool: there (no lowest version asked)" 'echo "$out" | grep -qF "已經有 Node.js 16.2.0" && [ ! -e "$T/brew.log" ]'
out=$(KIT_DRY_RUN=1 kit install-tool node --min 18 2>&1)
check "install-tool --min, dry run: too old -> only says the upgrade command" 'echo "$out" | grep -qF "執行 brew upgrade node" && [ ! -e "$T/brew.log" ]'
out=$(kit install-tool node --min 18 2>&1); rc=$?
check "install-tool --min: runs kit's upgrade, then looks again" '[ $rc -eq 0 ] && [ "$(cat "$T/brew.log")" = "upgrade node" ] && echo "$out" | grep -qF "Node.js 26.1.0 裝好了"'
out=$(kit install-tool node --min 18 2>&1)
check "install-tool --min: new enough now" 'echo "$out" | grep -qF "已經有 Node.js 26.1.0"'
out=$(kit install-tool frob 2>&1); rc=$?
check "install-tool: no recipe, says how to add one" '[ $rc -ne 0 ] && echo "$out" | grep -qF "tools/frob.yaml"'
# a source's recipe adds programs, with only "manager package": a manager kit knows, a plain package name; never a command
rm -f "$T/brew.log"
printf 'name: frob\ntitle: Frob\ninstall:\n  mac: ["sh -c evil", "brew frob;rm", "curl x", "brew user/tap/frob", "brew -frob", "brew ../frob", "brew frob"]\n  linux: ["sh -c evil", "brew frob;rm", "curl x", "brew user/tap/frob", "brew -frob", "brew ../frob", "brew frob"]\n' > "$NT/tools/frob.yaml"
out=$(kit install-tool frob 2>&1)
check "install-tool: a recipe can only pick a known manager and a plain package name" '[ "$(cat "$T/brew.log")" = "install frob" ] && echo "$out" | grep -qF "執行 brew install frob" && echo "$out" | grep -qF "Frob 1.2.3 裝好了"'
rm -f "$T/brew.log" "$FB/frob"
printf 'name: frob\ntitle: Frob\ninstall:\n  mac: [brew badfrob, brew frob]\n  linux: [brew badfrob, brew frob]\n' > "$NT/tools/frob.yaml"
out=$(kit install-tool frob 2>&1); rc=$?
check "install-tool: one way fails -> the next way in the recipe" '[ $rc -eq 0 ] && [ "$(cat "$T/brew.log" | tr "\n" " ")" = "install badfrob install frob " ] && echo "$out" | grep -qF "用 brew 裝失敗" && echo "$out" | grep -qF "Frob 1.2.3 裝好了"'
printf 'name: frob\ntitle: Frob\ninstall:\n  mac: [brew badfrob]\n  linux: [brew badfrob]\n' > "$NT/tools/frob.yaml"; rm -f "$FB/frob"
out=$(kit install-tool frob 2>&1); rc=$?
check "install-tool: every way fails -> says so" '[ $rc -ne 0 ] && echo "$out" | grep -qF "每一種裝法都沒有成功（最後是 brew）"'
printf 'name: pyfrob\ninstall:\n  mac: [pip pyfrob]\n  linux: [pip pyfrob]\n' > "$NT/tools/pyfrob.yaml"
out=$(KIT_DRY_RUN=1 kit install-tool pyfrob 2>&1)
check "install-tool (pip): wheels only, for this account" 'echo "$out" | grep -qF "執行 python3 -m pip install --user --only-binary=:all: pyfrob"'
# kit's own recipes (node, python, git) cannot be replaced by a source
printf 'name: node\ntitle: Node\ninstall:\n  mac: [scoop node]\n  linux: [scoop node]\n' > "$NT/tools/node.yaml"; rm -f "$FB/node" "$T/brew.log"
out=$(kit install-tool node 2>&1); rc=$?
# (a machine with node in /usr/bin, like a Linux server, has it already: kit tools still shows kit's way)
check "install-tool: kit's own recipe wins over a source's" 'PATH=/usr/bin:/bin command -v node >/dev/null || { echo "$out" | grep -qF "執行 brew install node" && [ "$(cat "$T/brew.log")" = "install node" ] && ! echo "$out" | grep -q scoop; }'
check "tools: kit's own recipe for node, not the source's" 'kit tools 2>&1 | grep -E "^node " | grep -qE "(brew install node|apt-get install -y nodejs)$"'
# --version of a program that hangs (and what it started) or never stops talking: a few seconds, 4 KB
printf 'name: slowtool\nbin: [slowtool]\ninstall:\n  mac: [brew slowtool]\n  linux: [brew slowtool]\n' > "$NT/tools/slowtool.yaml"
printf '#!/bin/sh\nsleep 30\necho slowtool 1.0\n' > "$FB/slowtool"
printf 'name: chatty\nbin: [chatty]\ninstall:\n  mac: [brew chatty]\n  linux: [brew chatty]\n' > "$NT/tools/chatty.yaml"
printf '#!/bin/sh\nexec yes "chatty 2.5"\n' > "$FB/chatty"; chmod +x "$FB/slowtool" "$FB/chatty"
t0=$SECONDS; out=$(KIT_PROBE_WAIT=1 capped 25 kit tools 2>&1); rc=$?; took=$((SECONDS - t0))
check "tools: a --version that hangs is given up, one that never stops is cut" '[ $rc -eq 0 ] && [ $took -lt 15 ] && echo "$out" | grep -qE "^slowtool +（沒有）" && echo "$out" | grep -qE "^chatty +2.5 "'
if [ -n "$PWSH" ]; then
    t0=$SECONDS; out=$(KIT_PROBE_WAIT=1 capped 40 kps tools 2>&1); rc=$?; took=$((SECONDS - t0))
    check "tools: kit.ps1 gives up and cuts the same" '[ $rc -eq 0 ] && [ $took -lt 30 ] && echo "$out" | grep -qE "^slowtool +（沒有）" && echo "$out" | grep -qE "^chatty +2.5 "'
fi
rm -f "$NT/tools/slowtool.yaml" "$NT/tools/chatty.yaml" "$NT/tools/pyfrob.yaml" "$FB/slowtool" "$FB/chatty"
# a skill's own npm packages (kit install-deps): only when asked, in kit's folder, no package scripts, linked into each copy
pk() { kit list --json 2>/dev/null | python3 -c "import json,sys;d={i['name']:i for i in json.load(sys.stdin)['items']};p=[x for x in d[sys.argv[1]].get('packages') or [] if x['kind']==sys.argv[2]];print(json.dumps(p[0] if p else None,sort_keys=True))" "$1" "${2:-npm}"; }
check "packages: no npm here, nothing to run it with" '{ PATH=/usr/bin:/bin command -v npm >/dev/null || [ "$(pk packed)" = "{\"bad\": \"\", \"had\": false, \"install\": \"\", \"kind\": \"npm\", \"ok\": false}" ]; } && [ "$(pk drawer)" = null ] && [ "$(pk plain)" = null ] && [ "$(pk plain pip)" = null ]'
printf '#!/bin/sh\necho "$PWD $*" >> "%s/npm.log"\n[ -f .npmrc ] && exit 9\nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js\n' "$T" > "$FB/npm"; chmod +x "$FB/npm"
check "packages: a lock -> npm ci, no package scripts" '[ "$(pk packed)" = "{\"bad\": \"\", \"had\": false, \"install\": \"npm ci --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": false}" ]'
kit add skill packed >/dev/null 2>&1
out=$(KIT_DRY_RUN=1 kit install-deps packed 2>&1)
check "install-deps, dry run: only says the command" 'echo "$out" | grep -qF "執行 npm ci --ignore-scripts --omit=dev --no-audit --no-fund" && [ ! -e "$T/npm.log" ]'
S6="$H6/.config/agentkit/deps/packed"; C6="$H6/.claude/skills/packed"
out=$(kit install-deps packed 2>&1); rc=$?
nl=$(cat "$T/npm.log")
check "install-deps: npm ci in a new folder next to kit's, not the source, without the skill's .npmrc" '[ $rc -eq 0 ] && [ "${nl#"$S6".new.}" != "$nl" ] && [ "${nl#* }" = "ci --ignore-scripts --omit=dev --no-audit --no-fund" ] && [ -f "$S6/node_modules/left-pad/index.js" ] && [ ! -e "$NT/skills/packed/node_modules" ] && [ ! -e "$S6/.npmrc" ] && ! ls -d "$S6".new.* >/dev/null 2>&1'
check "install-deps: the copy kit put gets node_modules linked to it" '[ -L "$C6/node_modules" ] && [ -f "$C6/node_modules/left-pad/index.js" ]'
check "packages: installed now" '[ "$(pk packed)" = "{\"bad\": \"\", \"had\": true, \"install\": \"npm ci --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": true}" ]'
check "packages: kit.ps1 sees the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
out=$(kit install-deps packed 2>&1)
check "install-deps again: already there, npm not run" 'echo "$out" | grep -qF "已經裝好了" && [ "$(wc -l < "$T/npm.log")" -eq 1 ]'
out=$(kit sync 2>&1)
check "sync: the link is not a change to the skill" '! echo "$out" | grep -q "手動" && [ -L "$C6/node_modules" ]'
echo '{"lockfileVersion": 3, "x": 1}' > "$NT/skills/packed/package-lock.json"; kit sync >/dev/null 2>&1
check "the skill changed its lock: needs 更新, the new copy has no old packages" '[ "$(pk packed)" = "{\"bad\": \"\", \"had\": true, \"install\": \"npm ci --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": false}" ] && [ -f "$C6/SKILL.md" ] && [ ! -e "$C6/node_modules" ]'
out=$(kit install-deps packed 2>&1); rc=$?
check "install-deps after the change: again, and linked" '[ $rc -eq 0 ] && [ "$(wc -l < "$T/npm.log")" -eq 2 ] && [ -L "$C6/node_modules" ]'
# kit run: the agent's folder gets the links too, and goes with them (never into kit's store); a dry run has none
mkdir -p "$NT/agents"; printf -- '---\nname: packer\ndescription: x\nskills: [packed]\n---\nx\n' > "$NT/agents/packer.md"
out=$(KIT_DRY_RUN=1 kit run packer 2>&1); rt=$(printf '%s\n' "$out" | sed -n 's/^tmp=//p')
check "run, dry run: the agent's folder to look at, without kit's links" '[ -f "$rt/.claude/skills/packed/SKILL.md" ] && [ ! -e "$rt/.claude/skills/packed/node_modules" ] && [ ! -e "$rt/.kit-pid" ]'
rm -rf "$rt"
SR="${TMPDIR:-/tmp}/kit-run.kittest$$"; mkdir -p "$SR/x"; echo 999999 > "$SR/.kit-pid"; ln -s "$S6/node_modules" "$SR/x/node_modules"
printf '#!/bin/sh\necho "$*" > "%s/claude.args"\n[ -L "$2/.claude/skills/packed/node_modules" ] || exit 4\nexit 3\n' "$T" > "$FB/claude"; chmod +x "$FB/claude"
kit run packer >/dev/null 2>&1; rc=$?
rt=$(sed -n 's/^--add-dir \([^ ]*\) .*/\1/p' "$T/claude.args")
check "run: the agent's folder has kit's links; its exit code; the folder gone, kit's packages still there" '[ $rc -eq 3 ] && [ -n "$rt" ] && [ ! -e "$rt" ] && [ -f "$S6/node_modules/left-pad/index.js" ]'
check "run: the folder of a run that was killed goes (its links only)" '[ ! -e "$SR" ] && [ -f "$S6/node_modules/left-pad/index.js" ]'
if [ -n "$PWSH" ]; then
    mkdir -p "$SR/x"; echo 999999 > "$SR/.kit-pid"; ln -s "$S6/node_modules" "$SR/x/node_modules"; rm -f "$T/claude.args"
    kps run packer >/dev/null 2>&1; rc=$?
    rt=$(sed -n 's/^--add-dir \([^ ]*\) .*/\1/p' "$T/claude.args")
    check "run (kit.ps1): the same: links in, exit code, folder gone, packages there, a killed run's folder gone" '[ $rc -eq 3 ] && [ -n "$rt" ] && [ ! -e "$rt" ] && [ -f "$S6/node_modules/left-pad/index.js" ] && [ ! -e "$SR" ]'
fi
rm -f "$FB/claude" "$NT/agents/packer.md"
printf '#!/bin/sh\nexit 3\n' > "$FB/npm"; rm -rf "$S6"
out=$(kit install-deps packed 2>&1); rc=$?
check "install-deps: npm fails -> says so, nothing half-made" '[ $rc -ne 0 ] && echo "$out" | grep -qF "裝套件失敗" && [ ! -e "$S6" ] && ! ls -d "$S6".new.* >/dev/null 2>&1'
# npm stopped halfway (Ctrl-C, the panel closed): its half-made folder goes too
printf '#!/bin/sh\nmkdir -p node_modules/left-pad\necho started > "%s/npm.started"\nexec sleep 31\n' "$T" > "$FB/npm"
# (set -m: kit and npm in a process group of their own, which gets the Ctrl-C, like a terminal's)
set -m; kit install-deps packed >/dev/null 2>&1 & kp=$!; set +m
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/npm.started" ] && break; sleep 0.5; done
kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
check "install-deps: stopped halfway (Ctrl-C) -> no half-made folder, no lock left" '[ -e "$T/npm.started" ] && [ ! -e "$S6" ] && ! ls -d "$S6".new.* >/dev/null 2>&1 && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
rm -f "$T/npm.started"
if [ -n "$PWSH" ]; then
    set -m; kps install-deps packed >/dev/null 2>&1 & kp=$!; set +m
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/npm.started" ] && break; sleep 0.5; done
    kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
    check "install-deps (kit.ps1): stopped halfway (Ctrl-C) -> no half-made folder, no lock left" '[ -e "$T/npm.started" ] && [ ! -e "$S6" ] && ! ls -d "$S6".new.* >/dev/null 2>&1 && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
    rm -f "$T/npm.started"
fi
# what kit does not install: git, a URL, another registry without your ~/.npmrc
check "packages: a git dependency is shown as refused" '[ "$(pk npmgit)" = "{\"bad\": \"package.json: optionalDependencies.tool = github:someone/tool\", \"had\": false, \"install\": \"npm install --ignore-scripts --omit=dev --no-audit --no-fund\", \"kind\": \"npm\", \"ok\": false}" ]'
check "packages: a lock with a package from git, or from another registry, is refused" 'pk npmlock | grep -qF "\"bad\": \"package-lock.json: node_modules/tool: resolved git+ssh://git@git.example.org/someone/tool.git#abc\"" && pk npmreg | grep -qF "\"bad\": \"package-lock.json: node_modules/tool: resolved https://npm.example.com/r/tool/-/tool-1.0.0.tgz\""'
check "packages (refused): kit.ps1 says the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
rm -f "$T/npm.log"
out=$(kit install-deps npmgit 2>&1); rc=$?
check "install-deps: refuses a git dependency, npm not run" '[ $rc -ne 0 ] && echo "$out" | grep -qF "kit 不裝這些 npm 套件" && echo "$out" | grep -qF "github:someone/tool" && [ ! -e "$T/npm.log" ] && [ ! -e "$H6/.config/agentkit/deps/npmgit" ]'
printf 'registry = https://npm.example.com/r\n' > "$H6/.npmrc"
check "packages: your own ~/.npmrc registry is fine" '[ "$(pk npmreg | grep -o "\"bad\": \"[^\"]*\"")" = "\"bad\": \"\"" ]'
check "packages (your registry): kit.ps1 says the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
rm -f "$H6/.npmrc"
out=$(kit install-deps drawer 2>&1); rc=$?
check "install-deps: a skill without packages" '[ $rc -eq 0 ] && echo "$out" | grep -qF "不用另外裝套件"'
printf '#!/bin/sh\nmkdir -p node_modules/left-pad && echo x > node_modules/left-pad/index.js\n' > "$FB/npm"; kit install-deps packed >/dev/null 2>&1
kit rm skill packed >/dev/null 2>&1
check "rm skill: the copy goes, kit's packages stay (the link only)" '[ ! -e "$C6" ] && [ -f "$S6/node_modules/left-pad/index.js" ]'
# Python: a venv of the skill's own, only wheels, requirements.txt with names and versions only
printf '#!/bin/sh\n[ "$1 $2" = "-m venv" ] || exec "%s" "$@"\nmkdir -p "$3/bin" && printf "#!/bin/sh\\necho \\"\\$PWD \\$*\\" >> %s/pip.log\\n" > "$3/bin/python" && chmod +x "$3/bin/python"\n' "$REALPY" "$T" > "$FB/python3"; chmod +x "$FB/python3"
PIPX="-m pip install --only-binary=:all: --no-input --disable-pip-version-check -r requirements.txt"
check "packages (pip): a requirements.txt -> a venv and pip with wheels only" '[ "$(pk pyskill pip)" = "{\"bad\": \"\", \"had\": false, \"install\": \"python3 -m venv venv; venv/bin/python $PIPX\", \"kind\": \"pip\", \"ok\": false}" ] && [ "$(pk packed pip)" = null ]'
check "packages (pip): a requirements.txt with options is shown as refused" 'pk pybad pip | grep -qF "\"bad\": \"2: --index-url http://elsewhere.invalid/\""'
check "packages (pip): an option after a marker is refused too" 'pk pymark pip | grep -qF "\"bad\": \"1: requests ; python_version >= \\\"3.8\\\" --config-settings=x=y\""'
check "packages (pip): kit.ps1 sees the same" '[ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]'
out=$(kit install-deps pybad 2>&1); rc=$?
check "install-deps (pip): refuses options in requirements.txt, nothing made" '[ $rc -ne 0 ] && echo "$out" | grep -qF "第 2: --index-url" && [ ! -e "$H6/.config/agentkit/pydeps/pybad" ] && [ ! -e "$T/pip.log" ]'
kit add skill pyskill >/dev/null 2>&1
S7="$H6/.config/agentkit/pydeps/pyskill"; C7="$H6/.claude/skills/pyskill"
out=$(kit install-deps pyskill 2>&1); rc=$?
check "install-deps (pip): a venv in kit's folder, pip with wheels only, run there" '[ $rc -eq 0 ] && [ "$(cat "$T/pip.log")" = "$S7 $PIPX" ] && [ -x "$S7/venv/bin/python" ] && [ ! -e "$NT/skills/pyskill/.venv" ] && [ ! -e "$S7.old" ]'
check "install-deps (pip): the copy gets .venv linked, the instructions say to use it" '[ -L "$C7/.venv" ] && [ -x "$C7/.venv/bin/python" ] && grep -qF ".venv/bin/python" "$H6/.claude/CLAUDE.md"'
# the python line is the account's (for the account's skills), never in a folder's own files
PD="$T/pyproj"; mkdir -p "$PD"; PD=$(cd "$PD" && pwd -P); printf '# mine\n' > "$PD/CLAUDE.md"; cp "$PD/CLAUDE.md" "$T/pd.orig"
kit add --dir "$PD" skill pyskill >/dev/null 2>&1
check "add --dir with kit's venv: the folder's copy gets .venv, its CLAUDE.md is not touched" '[ -L "$PD/.claude/skills/pyskill/.venv" ] && cmp -s "$PD/CLAUDE.md" "$T/pd.orig" && [ ! -e "$PD/AGENTS.md" ]'
kit rm --dir "$PD" skill pyskill >/dev/null 2>&1
check "rm --dir with kit's venv: the folder exactly as before" 'cmp -s "$PD/CLAUDE.md" "$T/pd.orig" && [ "$(cd "$PD" && ls -A | tr "\n" " ")" = "CLAUDE.md " ]'
kit rm skill pyskill >/dev/null 2>&1
check "python line: gone with the skill (kit's venv stays)" '[ -x "$S7/venv/bin/python" ] && ! grep -qF ".venv/bin/python" "$H6/.claude/CLAUDE.md" 2>/dev/null'
kit add skill pyskill >/dev/null 2>&1
check "packages (pip): installed now; kit.ps1 sees the same" 'pk pyskill pip | grep -qF "\"ok\": true" && { [ -z "$PWSH" ] || [ "$(kps list --json 2>/dev/null)" = "$(kit list --json 2>/dev/null)" ]; }'
out=$(kit sync 2>&1)
check "sync (pip): the link is not a change to the skill" '! echo "$out" | grep -q "手動" && [ -L "$C7/.venv" ]'
printf 'requests==2.33.0\n' > "$NT/skills/pyskill/requirements.txt"; kit sync >/dev/null 2>&1
check "pip: requirements changed -> 更新, the new copy has no old venv" 'pk pyskill pip | grep -qF "\"had\": true" && pk pyskill pip | grep -qF "\"ok\": false" && [ ! -e "$C7/.venv" ]'
printf '#!/bin/sh\n[ "$1 $2" = "-m venv" ] || exec "%s" "$@"\nmkdir -p "$3/bin" && printf "#!/bin/sh\\nexit 4\\n" > "$3/bin/python" && chmod +x "$3/bin/python"\n' "$REALPY" > "$FB/python3"
out=$(kit install-deps pyskill pip 2>&1); rc=$?
check "install-deps (pip): pip fails -> the old venv stays" '[ $rc -ne 0 ] && echo "$out" | grep -qF "裝套件失敗" && [ -f "$S7/.kit-src/requirements.txt" ] && grep -q 2.32.0 "$S7/.kit-src/requirements.txt" && [ ! -e "$S7.old" ]'
printf '#!/bin/sh\n[ "$1 $2" = "-m venv" ] || exec "%s" "$@"\nmkdir -p "$3/bin" && printf "#!/bin/sh\\necho started > %s/pip.started\\nexec sleep 32\\n" > "$3/bin/python" && chmod +x "$3/bin/python"\n' "$REALPY" "$T" > "$FB/python3"
set -m; kit install-deps pyskill pip >/dev/null 2>&1 & kp=$!; set +m
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/pip.started" ] && break; sleep 0.5; done
kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
check "install-deps (pip): stopped halfway (Ctrl-C) -> the old venv back, no lock left" '[ -e "$T/pip.started" ] && grep -q 2.32.0 "$S7/.kit-src/requirements.txt" && [ -x "$S7/venv/bin/python" ] && [ ! -e "$S7.old" ] && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
if [ -n "$PWSH" ]; then
    rm -f "$T/pip.started"
    set -m; kps install-deps pyskill pip >/dev/null 2>&1 & kp=$!; set +m
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$T/pip.started" ] && break; sleep 0.5; done
    kill -INT -- -"$kp" 2>/dev/null; wait "$kp" 2>/dev/null
    check "install-deps (pip, kit.ps1): stopped halfway (Ctrl-C) -> the old venv back, no lock left" '[ -e "$T/pip.started" ] && grep -q 2.32.0 "$S7/.kit-src/requirements.txt" && [ -x "$S7/venv/bin/python" ] && [ ! -e "$S7.old" ] && [ ! -e "$H6/.config/agentkit/sync.lock" ]'
fi
out=$(kit install-deps pyskill npm 2>&1)
check "install-deps <skill> npm: only that kind" 'echo "$out" | grep -qF "不用另外裝套件"'
rm -f "$FB/python3"
kit uninstall >/dev/null 2>&1
check "uninstall: kit's packages go too" '[ ! -e "$H6/.config/agentkit/deps" ] && [ ! -e "$H6/.config/agentkit/pydeps" ] && ! grep -qF ".venv/bin/python" "$H6/.claude/CLAUDE.md" 2>/dev/null'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
