#!/usr/bin/env bash
# End-to-end tests for the bash kit. Everything runs in a throwaway HOME,
# so your real ~/.claude is never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
KIT="$HERE/../unix/kit"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR AGENTKIT_CONFIG AGENTKIT_SOURCES
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
kit() { "$KIT" "$@"; }
JA="$HERE/../unix/json.awk"
jget() { LC_ALL=C awk -f "$JA" -v get="$2" "$1" 2>/dev/null; }

# ---------- fixture sources ----------
TP="$T/third-party"; TEAM="$T/team"
mkdir -p "$TP/skills/gerrit-workflow" "$TEAM/rules" "$TEAM/skills/gerrit-review" "$TEAM/mcp" "$TEAM/agents"
printf -- '---\nname: gerrit-workflow\ndescription: upstream\n---\nupstream body\n' > "$TP/skills/gerrit-workflow/SKILL.md"
echo "Apache-2.0" > "$TP/skills/gerrit-workflow/LICENSE"
cat > "$TEAM/kit.yaml" <<EOF
name: team
include: [$TP]
allowed_hosts: [gitea.example]
required:
  rules: [security]
  tools:
    deny: [mcp__gerrit__submit_change]
recommended:
  rules:  [coding-style]
  skills: [gerrit-workflow]
EOF
echo "Never paste secrets." > "$TEAM/rules/security.md"
echo "Use 4 spaces." > "$TEAM/rules/coding-style.md"
echo "Only comment, never submit." > "$TEAM/rules/gerrit-flow.md"
printf -- '---\nname: gerrit-review\ndescription: review a change\n---\nhow to review\n' > "$TEAM/skills/gerrit-review/SKILL.md"
cat > "$TEAM/mcp/gerrit.yaml" <<'EOF'
name: gerrit
command: uvx
args: [--index-url, "https://pypi.example/simple", gerrit-mcp-server==1.0]
env:
  GERRIT_CONFIG: ${HOME}/.config/gerrit/gerrit_config.json   # expanded by Claude, not kit
EOF
cat > "$TEAM/agents/gerrit.md" <<'EOF'
---
name: gerrit
description: Gerrit helper
rules:  [gerrit-flow]
skills: [gerrit-review]
mcp:    [gerrit]
tools:
  only: [Read, Grep, Glob]
  deny: [mcp__gerrit__submit_change]
---
You are the Gerrit helper.
EOF

# ---------- the user's own files, which kit must keep ----------
mkdir -p "$HOME/.claude/skills/my-own"
echo "my own skill" > "$HOME/.claude/skills/my-own/SKILL.md"
printf '# My notes\nBe brief.\n' > "$HOME/.claude/CLAUDE.md"
printf '{\n  "model": "opus",\n  "permissions": {\n    "deny": [\n      "Bash(rm -rf:*)"\n    ]\n  }\n}\n' > "$HOME/.claude/settings.json"
printf '{\n  "numStartups": 5,\n  "projects": {\n    "/x": {\n      "note": "中文 \\"q\\""\n    }\n  }\n}' > "$HOME/.claude.json"
chmod 600 "$HOME/.claude.json"; cp -p "$HOME/.claude.json" "$T/claude.json.orig"

# ---------- init ----------
out=$(kit init "$TEAM" 2>&1); rc=$?
check "init exit 0" '[ $rc -eq 0 ]'
check "include pulled third-party" 'grep -qF "$TP" "$HOME/.config/agentkit/machine.yaml"'
check "recommended added" 'grep -q "added: \[rule:coding-style, skill:gerrit-workflow\]" "$HOME/.config/agentkit/machine.yaml"'
check "CLAUDE.md keeps user text" 'head -2 "$HOME/.claude/CLAUDE.md" | grep -q "Be brief."'
check "CLAUDE.md imports required rule" 'grep -qxF "@$TEAM/rules/security.md" "$HOME/.claude/CLAUDE.md"'
check "CLAUDE.md imports recommended rule" 'grep -qxF "@$TEAM/rules/coding-style.md" "$HOME/.claude/CLAUDE.md"'
check "third-party skill copied with LICENSE" '[ -f "$HOME/.claude/skills/gerrit-workflow/LICENSE" ]'
check "own skill untouched" '[ "$(cat "$HOME/.claude/skills/my-own/SKILL.md")" = "my own skill" ]'
check "deny added, user deny kept" '[ "$(jget "$HOME/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"Bash(rm-rf:*)\",\"mcp__gerrit__submit_change\"]" ]'
check "settings other keys kept" '[ "$(jget "$HOME/.claude/settings.json" model)" = "\"opus\"" ]'
check "claude.json untouched (no mcp yet)" 'cmp -s "$HOME/.claude.json" "$T/claude.json.orig"'

# ---------- add ----------
kit add skill gerrit-review >/dev/null 2>&1
check "add skill" '[ -f "$HOME/.claude/skills/gerrit-review/SKILL.md" ]'
kit add mcp gerrit >/dev/null 2>&1
check "mcp written" '[ "$(jget "$HOME/.claude.json" mcpServers.gerrit.command)" = "\"uvx\"" ]'
check "claude.json stays private (600)" '[ "$(ls -l "$HOME/.claude.json" | cut -c1-10)" = "-rw-------" ]'
check "no temp files left" '[ -z "$(ls -a "$HOME" | grep kit\\.)" ]'
check "mcp env not expanded" 'jget "$HOME/.claude.json" mcpServers.gerrit.env | grep -qF "\${HOME}/.config/gerrit"'
check "claude.json other data kept" 'jget "$HOME/.claude.json" projects | grep -qF "中文 \\\"q\\\""'
out=$(kit add skill nope 2>&1); rc=$?; check "add unknown fails with a message" '[ $rc -ne 0 ] && echo "$out" | grep -q "找不到 skill:nope"'

# ---------- rm ----------
out=$(kit rm rule security 2>&1); rc=$?
check "required cannot be removed" '[ $rc -ne 0 ] && echo "$out" | grep -q 團隊必備'
kit rm skill gerrit-workflow >/dev/null 2>&1
check "rm skill deletes copy" '[ ! -e "$HOME/.claude/skills/gerrit-workflow" ]'
kit sync >/dev/null 2>&1
check "removed stays removed after sync" '[ ! -e "$HOME/.claude/skills/gerrit-workflow" ]'

# ---------- hand edits and new items ----------
echo "my change" >> "$HOME/.claude/skills/gerrit-review/SKILL.md"
echo "team change" >> "$TEAM/skills/gerrit-review/SKILL.md"
out=$(kit sync 2>&1)
check "hand-edited skill not overwritten" 'grep -q "my change" "$HOME/.claude/skills/gerrit-review/SKILL.md" && echo "$out" | grep -q 手動改過'
kit sync --force >/dev/null 2>&1
check "--force overwrites" 'grep -q "team change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
mkdir -p "$TEAM/skills/team-build"; printf -- '---\nname: team-build\ndescription: b\n---\nx\n' > "$TEAM/skills/team-build/SKILL.md"
out=$(kit sync 2>&1)
check "new item announced" 'echo "$out" | grep -q "新： skill:team-build"'
out=$(kit sync 2>&1)
check "announced only once" '! echo "$out" | grep -q "新："'

# ---------- list ----------
out=$(kit list 2>&1)
check "list marks required" 'echo "$out" | grep -q "^R  rule:security"'
check "list marks in use" 'echo "$out" | grep -q "^\*  skill:gerrit-review"'
check "list shows unused" 'echo "$out" | grep -q "^   skill:gerrit-workflow"'
check "list shows agent" 'echo "$out" | grep -q "agent:gerrit"'

# ---------- kit_version: tell once when the team wants a newer kit ----------
cp "$TEAM/kit.yaml" "$T/kit.yaml.orig"
echo "kit_version: 0.4.0" >> "$TEAM/kit.yaml"
out=$(kit sync 2>&1)
check "old kit: sync tells the user" 'echo "$out" | grep -qF "團隊要 kit 0.4.0 以上，你的是 0.1.0。請打  kit self-update"'
out=$(kit sync 2>&1; kit list 2>&1)
check "old kit: told only once" '! echo "$out" | grep -q 團隊要'
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"; echo "kit_version: 0.10.0" >> "$TEAM/kit.yaml"
out=$(kit list 2>&1)
check "team version changed: list tells again (numbers, not text)" 'echo "$out" | grep -qF "團隊要 kit 0.10.0 以上"'
mkdir -p "$T/dev/unix"; cp "$HERE"/../unix/* "$T/dev/unix/"
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"; echo "kit_version: 0.6.0" >> "$TEAM/kit.yaml"
out=$("$T/dev/unix/kit" sync 2>&1)
check "dev build (no VERSION) is not told" '! echo "$out" | grep -q 團隊要'
echo "0.6.0+local" > "$T/dev/VERSION"
out=$("$T/dev/unix/kit" sync 2>&1)
check "+build part ignored" '! echo "$out" | grep -q 團隊要'
echo "0.5.9" > "$T/dev/VERSION"
out=$("$T/dev/unix/kit" sync 2>&1)
check "older patch level is told" 'echo "$out" | grep -qF "團隊要 kit 0.6.0 以上，你的是 0.5.9"'
state_nag() { awk -F'\t' '$1 == "nag"' "$HOME/.config/agentkit/state.tsv"; }
echo "0.6.0" > "$T/dev/VERSION"; "$T/dev/unix/kit" sync >/dev/null 2>&1
check "new enough: note forgotten" '[ -z "$(state_nag)" ]'
# kit_version 0.6.0 stays for the background sync below

# ---------- ci-template ----------
out=$(kit ci-template)
check "ci-template prints the template" '[ "$out" = "$(cat "$HERE/../templates/gitea-kit-check.yaml")" ]'

# ---------- run (dry run: show the claude command) ----------
out=$(KIT_DRY_RUN=1 kit run gerrit --model sonnet 2>&1)
tmp=$(echo "$out" | sed -n 's/^tmp=//p')
check "run passes --tools" 'echo "$out" | grep -qx -- "Read,Grep,Glob"'
check "run passes deny" 'echo "$out" | grep -qx "mcp__gerrit__submit_change"'
check "run keeps user args" 'echo "$out" | grep -qx "sonnet"'
check "run skill in temp dir" '[ -f "$tmp/.claude/skills/gerrit-review/SKILL.md" ]'
check "run prompt has rule and body" 'grep -q "Only comment" "$tmp/prompt.md" && grep -q "Gerrit helper" "$tmp/prompt.md" && ! grep -q "^name:" "$tmp/prompt.md"'
check "run mcp json valid" 'LC_ALL=C awk -f "$JA" "$tmp/mcp.json" >/dev/null && grep -q gerrit-mcp-server "$tmp/mcp.json"'
rm -rf "$tmp"

out=$(KIT_DRY_RUN=1 kit run gerrit --tool codex exec 2>&1)
tmp=$(echo "$out" | sed -n 's/^tmp=//p')
dev=$(echo "$out" | sed -n 's/^developer_instructions=//p')
srv=$(echo "$out" | sed -n 's/^mcp_servers\.gerrit=//p')
check "codex run: instructions have rule, body, skill path" 'echo "$dev" | grep -q "Only comment" && echo "$dev" | grep -q "Gerrit helper" && echo "$dev" | grep -qF "$tmp/skills/gerrit-review/SKILL.md"'
check "codex run: values are valid TOML" 'printf "a = %s\nb = %s\n" "$dev" "$srv" | python3 -c "import sys,tomllib; d=tomllib.loads(sys.stdin.read()); assert d[\"b\"][\"command\"]==\"uvx\"" 2>/dev/null'
check "codex run: deny -> disabled_tools" 'echo "$srv" | grep -qF "disabled_tools=[\"submit_change\"]"'
check "codex run: env not expanded" 'echo "$srv" | grep -qF "\${HOME}/.config/gerrit"'
check "codex run: warns tools.only, keeps user args" 'echo "$out" | grep -q "tools.only" && echo "$out" | grep -qx exec'
rm -rf "$tmp"

out=$(KIT_DRY_RUN=1 kit run gerrit --tool omp 2>&1)
tmp=$(echo "$out" | sed -n 's/^tmp=//p')
check "omp run: config overlay points at skills" 'grep -qF "$tmp/skills" "$tmp/omp.yml" && [ -f "$tmp/skills/gerrit-review/SKILL.md" ]'
check "omp run: prompt + lowercase tools" 'echo "$out" | grep -qx -- --append-system-prompt && echo "$out" | grep -qx "read,grep,glob"'
check "omp run: warns no per-agent mcp" 'echo "$out" | grep -q "kit add mcp"'
rm -rf "$tmp"
out=$(kit run gerrit --tool vim 2>&1); rc=$?
check "run rejects unknown tool" '[ $rc -ne 0 ]'

# ---------- auto sync when Claude starts ----------
check "SessionStart hook added" 'jget "$HOME/.claude/settings.json" hooks.SessionStart | grep -qF "sync --hook"'
check "hook added once" '[ "$(jget "$HOME/.claude/settings.json" hooks.SessionStart | grep -c "sync --hook")" = 1 ]'
echo "hook change" >> "$TEAM/skills/gerrit-review/SKILL.md"
start=$(date +%s); kit sync --hook; rc=$?; took=$(( $(date +%s) - start ))
check "hook returns at once, exit 0" '[ $rc -eq 0 ] && [ $took -le 1 ]'
for i in 1 2 3 4 5 6 7 8 9 10; do [ -d "$HOME/.config/agentkit/sync.lock" ] || break; sleep 1; done
check "hook synced in the background" 'grep -q "hook change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
check "hook logs" 'grep -q "^== " "$HOME/.config/agentkit/sync.log"'
check "hook: kit_version not told in the background" '! grep -q 團隊要 "$HOME/.config/agentkit/sync.log" && [ -z "$(state_nag)" ]'
echo "second change" >> "$TEAM/skills/gerrit-review/SKILL.md"
kit sync --hook; sleep 2
check "hook runs at most every 10 minutes" '! grep -q "second change" "$HOME/.claude/skills/gerrit-review/SKILL.md"'
out=$(kit sync 2>&1)
check "hook: kit_version told at the next sync" 'echo "$out" | grep -qF "團隊要 kit 0.6.0 以上"'
cp "$T/kit.yaml.orig" "$TEAM/kit.yaml"

# ---------- allowed_hosts ----------
out=$(kit init "$TEAM" https://public-git.example/someone/agentkit-library.git 2>&1); rc=$?
check "host outside allowed_hosts refused" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單"'
kit init "$TEAM" >/dev/null 2>&1

# ---------- new / diff / update / check (authoring, local only) ----------
AU="$T/authoring"; LIB="$T/lib"
mkdir -p "$AU" "$LIB/skills/foo/scripts" "$LIB/skills/foo/.git" "$LIB/skills/bar"
printf 'name: authoring\ncontent_hosts: [gitea.example]\nrequired:\n  rules: [sec]\n' > "$AU/kit.yaml"
printf -- '---\nname: foo\ndescription: foo skill\n---\nRun scripts/x.sh, see https://gitea.example/doc\n' > "$LIB/skills/foo/SKILL.md"
echo 'echo hi' > "$LIB/skills/foo/scripts/x.sh"; echo MIT > "$LIB/skills/foo/LICENSE"; echo readme > "$LIB/skills/foo/README.md"
printf '\0\1\2' > "$LIB/skills/foo/logo.png"; echo x > "$LIB/skills/foo/.git/config"
printf -- '---\nname: bar\ndescription: >-\n  Use for bar.\n  Two lines # not a comment\n\nlicense: MIT\n---\nbar\n' > "$LIB/skills/bar/SKILL.md"; echo 'echo no' > "$LIB/skills/bar/run.sh"
cd "$AU"
out=$(kit new rule sec 2>&1); rc=$?
check "new rule skeleton in the folder with kit.yaml" '[ $rc -eq 0 ] && [ -s "$AU/rules/sec.md" ]'
kit new agent bot >/dev/null 2>&1
check "new agent skeleton has frontmatter" 'head -2 "$AU/agents/bot.md" | grep -qx "name: bot"'
out=$(kit new skill foo --from "$LIB/skills/foo" 2>&1); rc=$?
check "new --from copies md and declared scripts" '[ $rc -eq 0 ] && [ -f "$AU/skills/foo/SKILL.md" ] && [ -f "$AU/skills/foo/scripts/x.sh" ]'
check "new --from skips LICENSE, README, binaries, .git" '[ ! -e "$AU/skills/foo/LICENSE" ] && [ ! -e "$AU/skills/foo/README.md" ] && [ ! -e "$AU/skills/foo/logo.png" ] && [ ! -e "$AU/skills/foo/.git" ]'
check "new --from reminds to delete the temp folder" 'echo "$out" | grep -q 記得刪掉'
kit new skill bar --from "$LIB/skills/bar" >/dev/null 2>&1
check "undeclared extra files not copied" '[ ! -e "$AU/skills/bar/run.sh" ]'
check "yaml block text joined into one line" '[ "$(LC_ALL=C awk -f "$HERE/../unix/yaml.awk" -v frontmatter=1 "$AU/skills/bar/SKILL.md" | tr "\t" "|")" = "name|bar
description|Use for bar. Two lines # not a comment
license|MIT" ]'
out=$(kit new skill foo 2>&1); rc=$?
check "new refuses an existing name" '[ $rc -ne 0 ]'
out=$(kit new skill gerrit-review 2>&1); rc=$?
check "new refuses a name another source has" '[ $rc -ne 0 ] && echo "$out" | grep -q 名字重複'
out=$(kit new skill Bad_Name 2>&1); rc=$?
check "new refuses bad names" '[ $rc -ne 0 ]'
for u in https://public-git.example/x/y git@public-git.example:x/y.git; do
    out=$(kit new skill zz --from "$u" 2>&1); rc=$?
    check "--from refuses $u" '[ $rc -ne 0 ] && echo "$out" | grep -q 本機'
done
echo "new line" >> "$LIB/skills/foo/SKILL.md"
out=$(kit diff foo --from "$LIB/skills/foo" 2>&1)
check "diff shows the change" 'echo "$out" | grep -q "^+new line"'
out=$(kit update foo --from "$LIB/skills/foo" 2>&1); rc=$?
check "update applies it" '[ $rc -eq 0 ] && grep -q "new line" "$AU/skills/foo/SKILL.md"'
echo "colleague edit" >> "$AU/skills/foo/SKILL.md"; echo "second" >> "$LIB/skills/foo/SKILL.md"
out=$(kit update foo --from "$LIB/skills/foo" 2>&1); rc=$?
check "update stops when someone changed it" '[ $rc -ne 0 ] && grep -q "colleague edit" "$AU/skills/foo/SKILL.md" && echo "$out" | grep -q 被改過'
out=$(kit update skill foo --from "$LIB/skills/foo" --force 2>&1); rc=$?
check "update --force overwrites" '[ $rc -eq 0 ] && ! grep -q "colleague edit" "$AU/skills/foo/SKILL.md" && grep -q second "$AU/skills/foo/SKILL.md"'
printf -- '---\nname: bot\ndescription: b\nskills: [foo]\n---\nhi\n' > "$AU/agents/bot.md"
out=$(kit check 2>&1); rc=$?
check "check passes on clean content" '[ $rc -eq 0 ]'
printf -- '---\nname: bot\ndescription: b\nskills: [foo, nope]\n---\nsee https://evil.example/x\n' > "$AU/agents/bot.md"
mkdir -p "$AU/mcp"; printf 'command: uvx\nargs: [git+https://gitea.example/x.git]\n' > "$AU/mcp/m.yaml"
mkdir -p "$AU/skills/baz"; printf 'no header\n' > "$AU/skills/baz/SKILL.md"
cp "$LIB/skills/foo/logo.png" "$AU/skills/foo/"; ln -s /etc/hosts "$AU/rules/link.md"
mkdir -p "$AU/skills/foo/.git"; echo "[submodule]" > "$AU/.gitmodules"
mkdir -p "$HOME/.config/agentkit"; printf '# mine\nTopSecretName\n' > "$HOME/.config/agentkit/private-words.txt"
echo "by topsecretname" >> "$AU/rules/sec.md"
out=$(kit check 2>&1); rc=$?
check "check fails" '[ $rc -ne 0 ]'
check "check: missing reference" 'echo "$out" | grep -q "agents/bot.md: 找不到 skill:nope"'
check "check: url not in content_hosts" 'echo "$out" | grep -q "agents/bot.md:6: 網址 evil.example"'
check "check: mcp from git" 'echo "$out" | grep -q "mcp/m.yaml: MCP 只能"'
check "check: skill header" 'echo "$out" | grep -q "skills/baz/SKILL.md: 開頭要有"'
check "check: binary, symlink, submodule, nested git" 'echo "$out" | grep -q "logo.png: 只能放文字檔" && echo "$out" | grep -q "link.md: 不能放捷徑" && echo "$out" | grep -q ".gitmodules: 不能用" && echo "$out" | grep -q "skills/foo/.git: 裡面不能有"'
check "check: private word found, never printed" 'echo "$out" | grep -q "rules/sec.md:[0-9]*: 有不該公開的字" && ! echo "$out" | grep -qi topsecret'
check "check: counts every problem" 'echo "$out" | grep -q "kit check：9 個問題"'
mkdir -p "$AU/skills/gerrit-review"; printf -- '---\nname: gerrit-review\ndescription: x\n---\nx\n' > "$AU/skills/gerrit-review/SKILL.md"
out=$(kit check "$AU" 2>&1)
check "check: duplicate name across sources" 'echo "$out" | grep -q "名字重複：skill:gerrit-review"'
rm -rf "$AU/skills/gerrit-review"
# --ci: author emails from the company domain only
rm -rf "$AU/skills/foo/.git" "$AU/.gitmodules" "$AU/rules/link.md" "$AU/skills/foo/logo.png" "$AU/skills/baz" "$AU/mcp"
printf -- '---\nname: bot\ndescription: b\nskills: [foo]\n---\nhi\n' > "$AU/agents/bot.md"; echo "Be safe." > "$AU/rules/sec.md"
echo "author_domains: [corp.example]" >> "$AU/kit.yaml"
git -C "$AU" init -q && git -C "$AU" add -A && git -C "$AU" -c user.name=a -c user.email=me@home.example commit -qm x
out=$(kit check --ci 2>&1); rc=$?
check "check --ci: author email must be company" '[ $rc -ne 0 ] && echo "$out" | grep -q "作者 email 不是公司網域"'
git -C "$AU" -c user.name=a -c user.email=me@corp.example commit -q --amend --reset-author -m x
out=$(kit check --ci 2>&1); rc=$?
check "check --ci passes" '[ $rc -eq 0 ]'
cd "$T"

# ---------- export-self (a fake kit repo; the private word list of this HOME is still set) ----------
FK="$T/fakekit"; EX="$T/export"; EX2="$T/export2"
mkdir -p "$FK/unix" "$FK/windows" "$FK/.github/workflows" "$FK/tests" "$FK/docs"
cp "$HERE/../unix/kit" "$HERE/../unix/json.awk" "$HERE/../unix/yaml.awk" "$FK/unix/"; cp "$HERE/../windows/kit.ps1" "$FK/windows/"
echo 0.3.0 > "$FK/VERSION"; echo "# kit" > "$FK/README.md"; echo notes > "$FK/CHANGELOG.md"; echo "on: push" > "$FK/.github/workflows/ci.yml"
echo "echo test" > "$FK/tests/t.sh"; echo "* text=auto" > "$FK/.gitattributes"; echo "*.tmp" > "$FK/.gitignore"; echo guide > "$FK/docs/guide.md"
echo repoword > "$FK/private-words.txt"
fkcommit() { git -C "$FK" add -A && git -C "$FK" -c user.name=t -c user.email=t@t commit -qm x; }
git -C "$FK" init -q; fkcommit
echo "not tracked" > "$FK/untracked.md"
out=$("$FK/unix/kit" export-self "$EX" --version 0.4.0+gitea.12 2>&1); rc=$?
check "export-self succeeds, says the commit message" '[ $rc -eq 0 ] && echo "$out" | grep -q "kit 0.4.0+gitea.12"'
check "export-self drops README, CHANGELOG, .github, private-words.txt" '[ ! -e "$EX/README.md" ] && [ ! -e "$EX/CHANGELOG.md" ] && [ ! -e "$EX/.github" ] && [ ! -e "$EX/private-words.txt" ]'
check "export-self keeps tests, .gitattributes, .gitignore, kit" '[ -f "$EX/tests/t.sh" ] && [ -f "$EX/.gitattributes" ] && [ -f "$EX/.gitignore" ] && [ -x "$EX/unix/kit" ] && [ -f "$EX/windows/kit.ps1" ]'
check "export-self leaves out untracked files" '[ ! -e "$EX/untracked.md" ]'
check "export-self writes VERSION" '[ "$(cat "$EX/VERSION")" = 0.4.0+gitea.12 ]'
check "export-self INSTALL.md, no URL" 'grep -q "sh unix/install.sh" "$EX/INSTALL.md" && grep -qF "windows\\install.ps1" "$EX/INSTALL.md" && ! grep -qE "://|@[A-Za-z0-9.-]+:" "$EX/INSTALL.md"'
out=$("$FK/unix/kit" export-self "$EX" 2>&1); rc=$?
check "export-self stops when the folder is not empty" '[ $rc -ne 0 ] && echo "$out" | grep -q 不是空的 && [ -f "$EX/VERSION" ]'
gh='github''.com'
mkdir "$EX2"; echo "see https://$gh/x" >> "$FK/docs/guide.md"; fkcommit
out=$("$FK/unix/kit" export-self "$EX2" 2>&1); rc=$?
check "export-self: GitHub word fails, folder deleted" '[ $rc -ne 0 ] && echo "$out" | grep -q "docs/guide.md:2: 有 GitHub 的字" && [ ! -e "$EX2" ]'
echo guide > "$FK/docs/guide.md"; echo "by TopSecretName" > "$FK/tests/t.sh"; echo x > "$FK/docs/my-repoword.md"; printf '\0\1' > "$FK/docs/logo.png"; fkcommit
out=$("$FK/unix/kit" export-self "$EX2" 2>&1); rc=$?
check "export-self: private words (this machine and the repo's list), file names, binaries" '[ $rc -ne 0 ] && echo "$out" | grep -q "tests/t.sh:1: 有不該公開的字" && echo "$out" | grep -q "docs/<不公開>: 檔名有不該公開的字" && echo "$out" | grep -q "docs/logo.png: 只能放文字檔" && [ ! -e "$EX2" ]'
check "export-self never prints the private word" '! echo "$out" | grep -qi -e topsecret -e repoword'
git -C "$FK" rm -q docs/my-repoword.md docs/logo.png; echo "echo test" > "$FK/tests/t.sh"; fkcommit
mkdir -p "$T/inst"; cp "$HERE/../unix/kit" "$HERE/../unix/json.awk" "$HERE/../unix/yaml.awk" "$T/inst/"; echo "$FK" > "$T/inst/.repo"
out=$("$T/inst/kit" export-self "$EX2" 2>&1); rc=$?
check "export-self from an installed kit uses the clone in .repo" '[ $rc -eq 0 ] && [ "$(cat "$EX2/VERSION")" = 0.3.0 ] && [ -f "$EX2/docs/guide.md" ]'

# ---------- push (local bare repo as origin, fake Gitea on localhost) ----------
P="$T/push"; W="$P/work"; ORIGIN="$P/remote/acme/team.git"; DAY=$(date +%Y%m%d)
mkdir -p "$P/remote/acme"; git -c init.defaultBranch=main init -q --bare "$ORIGIN"
git -c init.defaultBranch=main init -q "$W"
printf 'name: team\nallowed_hosts: [gitea.example, 127.0.0.1]\nauthor_domains: [corp.example]\n' > "$W/kit.yaml"
mkdir -p "$W/rules"; echo "Be kind." > "$W/rules/base.md"
git -C "$W" config user.name tester; git -C "$W" config user.email me@corp.example
git -C "$W" add -A; git -C "$W" commit -qm init; git -C "$W" remote add origin "$ORIGIN"
git -C "$W" push -q origin main 2>/dev/null; git -C "$W" fetch -q origin; git -C "$W" remote set-head origin main
cat > "$P/fake-gitea" <<'PYEOF'
import http.server, json, sys
port_file, log_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(log_file, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": json.loads(body)}) + "\n")
        out = json.dumps({"number": 1, "html_url": "http://127.0.0.1/acme/team/pulls/1"}).encode()
        self.send_response(201); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PYEOF
: > "$P/req.log"; python3 -I "$P/fake-gitea" "$P/port" "$P/req.log" & FAKE=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$P/port" ] && break; sleep 1; done
export KIT_GITEA_API="http://127.0.0.1:$(cat "$P/port")/api/v1"; unset KIT_GITEA_TOKEN
remote_heads() { git --git-dir="$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads; }
cd "$W"
out=$(kit push 2>&1); rc=$?
check "push: nothing to send" '[ $rc -eq 0 ] && echo "$out" | grep -q 沒有要送的'
kit new skill pfoo >/dev/null 2>&1
head0=$(git rev-parse HEAD)
out=$(kit push --dry-run 2>&1); rc=$?
check "push --dry-run lists files and branch, sends nothing" '[ $rc -eq 0 ] && echo "$out" | grep -q "skills/pfoo/SKILL.md" && echo "$out" | grep -q "kit/pfoo-$DAY" && [ "$(git rev-parse HEAD)" = "$head0" ] && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
echo "TopSecretName here" >> skills/pfoo/SKILL.md
out=$(kit push 2>&1); rc=$?
check "push: check problem stops, nothing sent" '[ $rc -ne 0 ] && echo "$out" | grep -q 什麼都沒送 && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
printf -- '---\nname: pfoo\ndescription: p\n---\nok\n' > skills/pfoo/SKILL.md
git config user.email me@home.example
out=$(kit push 2>&1); rc=$?
check "push: author domain must be company" '[ $rc -ne 0 ] && echo "$out" | grep -q "user.email 不是公司網域" && [ "$(remote_heads)" = main ]'
git config user.email me@corp.example
git remote set-url origin https://github.com/acme/team.git
out=$(kit push 2>&1); rc=$?
check "push: origin host not allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "github.com 不在允許的主機清單" && [ "$(remote_heads)" = main ]'
git remote set-url origin "$ORIGIN"
echo "local only" > notes.txt; git add notes.txt; git commit -qm "local only"   # an unpushed commit on main
out=$(kit push 2>&1); rc=$?
check "push: no token -> compare URL" '[ $rc -eq 0 ] && echo "$out" | grep -qF "開 PR：${KIT_GITEA_API%/api/v1}/acme/team/compare/main...kit/pfoo-$DAY"'
check "push: only the kit branch is pushed" '[ "$(remote_heads | sort | paste -sd" " -)" = "kit/pfoo-$DAY main" ] && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$head0" ]'
check "push: commit has only the item, message" '[ "$(git --git-dir="$ORIGIN" log -1 --format=%s "kit/pfoo-$DAY")" = "kit: add skill:pfoo" ] && [ "$(git --git-dir="$ORIGIN" diff --name-only main "kit/pfoo-$DAY")" = skills/pfoo/SKILL.md ]'
check "push: back on main, no PR request" '[ "$(git symbolic-ref --short HEAD)" = main ] && [ ! -s "$P/req.log" ]'
echo "Be kinder." > rules/base.md; kit new rule pnew >/dev/null 2>&1; echo "x" > rules/pnew.md
out=$(KIT_GITEA_TOKEN=fake-tok-123 kit push 2>&1); rc=$?
req=$(tail -1 "$P/req.log")
check "push: PR opened, URL printed" '[ $rc -eq 0 ] && echo "$out" | grep -qF "已開 PR：http://127.0.0.1/acme/team/pulls/1"'
check "push: PR request path, token header, head/base" 'echo "$req" | grep -qF "\"path\": \"/api/v1/repos/acme/team/pulls\"" && echo "$req" | grep -qF "\"auth\": \"token fake-tok-123\"" && echo "$req" | grep -qF "\"head\": \"kit/base-pnew-$DAY\"" && echo "$req" | grep -qF "\"base\": \"main\""'
check "push: PR title is the commit message" 'echo "$req" | grep -qF "\"title\": \"kit: add rule:pnew; update rule:base\""'
check "push: token never printed" '! echo "$out" | grep -q fake-tok'
mkdir -p "$HOME/.config/agentkit"; echo "file-tok-456" > "$HOME/.config/agentkit/gitea-token"; chmod 644 "$HOME/.config/agentkit/gitea-token"
kit new skill pfoo >/dev/null 2>&1; printf -- '---\nname: pfoo\ndescription: p\n---\nagain\n' > skills/pfoo/SKILL.md
out=$(kit push 2>&1); rc=$?
check "push: same branch name taken -> -2" '[ $rc -eq 0 ] && remote_heads | grep -qx "kit/pfoo-$DAY-2"'
check "push: token file used, loose permission warned" 'tail -1 "$P/req.log" | grep -qF "token file-tok-456" && echo "$out" | grep -q "chmod 600" && ! echo "$out" | grep -q file-tok'
rm -f "$HOME/.config/agentkit/gitea-token"
kill $FAKE 2>/dev/null; unset KIT_GITEA_API
cd "$T"

# ---------- uninstall ----------
kit add skill gerrit-review >/dev/null 2>&1; kit add mcp gerrit >/dev/null 2>&1
kit uninstall >/dev/null 2>&1
check "uninstall restores CLAUDE.md" '[ "$(cat "$HOME/.claude/CLAUDE.md")" = "$(printf "# My notes\nBe brief.")" ]'
check "uninstall removes kit skills" '[ ! -e "$HOME/.claude/skills/gerrit-review" ] && [ -f "$HOME/.claude/skills/my-own/SKILL.md" ]'
check "uninstall removes hook" '! grep -q "sync --hook" "$HOME/.claude/settings.json"'
check "uninstall removes only kit deny" '[ "$(jget "$HOME/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"Bash(rm-rf:*)\"]" ]'
check "uninstall leaves no empty deny" '[ "$(jget "$HOME/.claude/settings.json" permissions.deny | tr -d " \n")" = "[\"Bash(rm-rf:*)\"]" ]'
printf '{\n  "model": "opus",\n  "hooks": {\n    "SessionStart": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "my-hook"\n          }\n        ]\n      }\n    ]\n  }\n}\n' > "$T/s.orig"; cp "$T/s.orig" "$HOME/.claude/settings.json"
kit init "$TEAM" >/dev/null 2>&1
check "user hook kept next to kit hook" '[ "$(jget "$HOME/.claude/settings.json" hooks.SessionStart | grep -c "my-hook\|sync --hook")" = 2 ]'
kit uninstall >/dev/null 2>&1
check "settings.json byte-identical after init+uninstall" 'cmp -s "$T/s.orig" "$HOME/.claude/settings.json"'
check "uninstall leaves no empty mcpServers" '! grep -q mcpServers "$HOME/.claude.json"'
check "claude.json byte-identical after everything" 'cmp -s "$HOME/.claude.json" "$T/claude.json.orig"'
check "uninstall removes mcp" '! jget "$HOME/.claude.json" mcpServers.gerrit >/dev/null'

# ---------- install / self-update / uninstall --self ----------
R="$T/clone"; mkdir -p "$R"; cp -R "$HERE/../unix" "$HERE/../templates" "$HERE/../VERSION" "$R/"
( cd "$R" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm v1 )
U="$T/clone2"; git clone -q "$R" "$U"
touch "$HOME/.bashrc"
out=$(PATH=/usr/bin:/bin sh "$U/unix/install.sh" 2>&1)
check "install puts kit in ~/.local/bin" '[ -x "$HOME/.local/bin/kit" ] && "$HOME/.local/bin/kit" --version | grep -q "kit 0.1.0"'
check "install adds PATH once" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
check "reinstall does not add PATH twice" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
check "installed kit works" '"$HOME/.local/bin/kit" init "$TEAM" >/dev/null 2>&1 && grep -q agentkit:begin "$HOME/.claude/CLAUDE.md"'
check "installed kit has the ci template" '"$HOME/.local/bin/kit" ci-template | cmp -s - "$R/templates/gitea-kit-check.yaml"'
( cd "$R" && echo 0.1.1 > VERSION && git -c user.name=t -c user.email=t@t commit -qam v2 )
out=$("$HOME/.local/bin/kit" self-update 2>&1)
check "self-update pulls new version" '"$HOME/.local/bin/kit" --version | grep -q "kit 0.1.1"'
"$HOME/.local/bin/kit" uninstall --self >/dev/null 2>&1
# a new Mac: zsh, no startup files at all
H2="$T/home2"; mkdir -p "$H2"
HOME="$H2" SHELL=/bin/zsh PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
check "zsh user without rc gets ~/.zshrc" 'grep -q "added by agentkit" "$H2/.zshrc"'
command -v zsh >/dev/null && check "zsh PATH line works" '[ "$(HOME="$H2" PATH=/usr/bin:/bin zsh -c ". \"$H2/.zshrc\"; command -v kit")" = "$H2/.local/bin/kit" ]' || echo "skip: zsh not installed"
H3="$T/home3"; mkdir -p "$H3"
HOME="$H3" SHELL=/bin/bash PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
if [ "$(uname)" = Darwin ]; then check "mac bash user gets ~/.bash_profile" 'grep -q "added by agentkit" "$H3/.bash_profile"'
else check "linux bash user gets ~/.bashrc" 'grep -q "added by agentkit" "$H3/.bashrc"'; fi
check "uninstall --self removes kit" '[ ! -e "$HOME/.local/bin/kit" ] && [ ! -e "$HOME/.local/share/agentkit" ] && ! grep -q agentkit:begin "$HOME/.claude/CLAUDE.md"'

# ---------- Codex and omp ----------
H4="$T/home4"; mkdir -p "$H4/.codex" "$H4/.omp/agent"
printf '# my codex notes\n' > "$H4/.codex/AGENTS.md"
printf 'model = "gpt-5"\n\n[mcp_servers.mine]\ncommand = "x"\n' > "$H4/.codex/config.toml"; chmod 600 "$H4/.codex/config.toml"
cp -p "$H4/.codex/config.toml" "$T/codex.orig"
printf '{\n  "mcpServers": {\n    "own": {\n      "command": "y"\n    }\n  }\n}\n' > "$H4/.omp/agent/mcp.json"; cp "$H4/.omp/agent/mcp.json" "$T/omp.orig"
(
export HOME="$H4"
kit init "$TEAM" >/dev/null 2>&1; kit add mcp gerrit >/dev/null 2>&1; kit add skill gerrit-review >/dev/null 2>&1
check "list shows targets" 'kit list | grep -q "寫到：Claude、Codex、omp"'
check "codex AGENTS.md keeps user text" 'head -1 "$H4/.codex/AGENTS.md" | grep -q "my codex notes"'
check "codex AGENTS.md has rule text inline" 'grep -q "Never paste secrets." "$H4/.codex/AGENTS.md" && grep -q "Use 4 spaces." "$H4/.codex/AGENTS.md"'
check "omp AGENTS.md has rule text" 'grep -q "Never paste secrets." "$H4/.omp/agent/AGENTS.md"'
check "skills in ~/.agents/skills" '[ -f "$H4/.agents/skills/gerrit-review/SKILL.md" ] && [ -f "$H4/.agents/skills/gerrit-workflow/LICENSE" ]'
check "codex toml keeps user part" 'head -4 "$H4/.codex/config.toml" | grep -q "^\[mcp_servers.mine\]"'
check "codex toml has kit server" 'grep -q "^\[mcp_servers.gerrit\]" "$H4/.codex/config.toml" && grep -q "^command = \"uvx\"" "$H4/.codex/config.toml"'
check "codex toml args" 'grep -qF "args = [\"--index-url\", \"https://pypi.example/simple\", \"gerrit-mcp-server==1.0\"]" "$H4/.codex/config.toml"'
check "codex team deny -> disabled_tools" 'grep -qF "disabled_tools = [\"submit_change\"]" "$H4/.codex/config.toml"'
check "codex env table, not expanded" 'grep -q "^\[mcp_servers.gerrit.env\]" "$H4/.codex/config.toml" && grep -qF "GERRIT_CONFIG = \"\${HOME}/.config" "$H4/.codex/config.toml"'
check "codex toml stays private" '[ "$(ls -l "$H4/.codex/config.toml" | cut -c1-10)" = "-rw-------" ]'
if python3 -c "import tomllib" 2>/dev/null; then
  check "codex toml is valid TOML" 'python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"mcp_servers\"][\"gerrit\"][\"env\"][\"GERRIT_CONFIG\"]" "$H4/.codex/config.toml"'
fi
check "no backup for a file kit created" '[ ! -e "$H4/.agents/mcp.json.kit-backup" ] && [ ! -e "$H4/.omp/agent/mcp.json.kit-backup" ] || [ "$(cat "$H4/.omp/agent/mcp.json.kit-backup")" != "{}" ]'
check "omp mcp.json has kit server and own" '[ "$(jget "$H4/.omp/agent/mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && [ "$(jget "$H4/.omp/agent/mcp.json" mcpServers.own.command)" = "\"y\"" ]'
# a server the user already has in config.toml is left alone
printf '\n[mcp_servers.gerrit]\ncommand = "theirs"\n' > "$T/extra"; cp "$H4/.codex/config.toml" "$T/c2"
awk '/^# agentkit:begin/{exit} {print}' "$T/c2" > "$H4/.codex/config.toml"; cat "$T/extra" >> "$H4/.codex/config.toml"
out=$(kit sync 2>&1)
check "codex: user server with same name wins" 'echo "$out" | grep -q "已經有自己的 mcp_servers.gerrit" && [ "$(grep -c "^\[mcp_servers.gerrit\]" "$H4/.codex/config.toml")" = 1 ]'
cp "$T/c2" "$H4/.codex/config.toml"; kit sync >/dev/null 2>&1
kit rm mcp gerrit >/dev/null 2>&1
check "rm mcp clears codex and omp" '! grep -q "mcp_servers.gerrit" "$H4/.codex/config.toml" && ! jget "$H4/.omp/agent/mcp.json" mcpServers.gerrit >/dev/null'
kit uninstall >/dev/null 2>&1
check "uninstall: codex AGENTS.md back" '[ "$(cat "$H4/.codex/AGENTS.md")" = "# my codex notes" ]'
check "uninstall: codex toml byte-identical" 'cmp -s "$T/codex.orig" "$H4/.codex/config.toml"'
check "uninstall: omp mcp.json byte-identical" 'cmp -s "$T/omp.orig" "$H4/.omp/agent/mcp.json"'
check "uninstall: omp AGENTS.md (made by kit) gone" '[ ! -e "$H4/.omp/agent/AGENTS.md" ]'
check "uninstall: ~/.agents/skills emptied" '[ -z "$(ls -A "$H4/.agents/skills" 2>/dev/null)" ]'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

# ---------- code checks ----------
check "no \$var directly before non-ASCII (bash 3.2 reads it as part of the name)" '! LC_ALL=C grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" "$KIT" "$HERE/../unix/install.sh"'

echo "kit: $pass passed, $fail failed"
[ $fail -eq 0 ]
