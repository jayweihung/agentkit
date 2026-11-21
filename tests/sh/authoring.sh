#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
kit init "$TEAM" >/dev/null 2>&1
# ---------- new / diff / update / check (authoring, local only) ----------
AU="$T/authoring"; LIB="$T/lib"
mkdir -p "$AU" "$LIB/skills/foo/scripts" "$LIB/skills/foo/.git" "$LIB/skills/bar"
printf 'name: authoring\ncontent_hosts: [gitea.example]\nrequired:\n  rules: [sec]\n' > "$AU/kit.yaml"
printf -- '---\nname: foo\ndescription: foo skill\n---\nRun scripts/x.sh, see https://gitea.example/doc\n' > "$LIB/skills/foo/SKILL.md"
echo 'echo hi' > "$LIB/skills/foo/scripts/x.sh"; echo MIT > "$LIB/skills/foo/LICENSE"; echo readme > "$LIB/skills/foo/README.md"
printf '\0\1\2' > "$LIB/skills/foo/logo.png"; echo x > "$LIB/skills/foo/.git/config"
mkdir -p "$LIB/skills/foo/scripts/__pycache__"; printf '\0\1\2' > "$LIB/skills/foo/scripts/__pycache__/x.cpython-314.pyc"
printf -- '---\nname: bar\ndescription: >-\n  Use for bar.\n  Two lines # not a comment\n\nlicense: MIT\n---\nbar\n' > "$LIB/skills/bar/SKILL.md"; echo 'echo no' > "$LIB/skills/bar/run.sh"
cd "$AU"
out=$(kit new rule sec 2>&1); rc=$?
check "new rule skeleton in the folder with kit.yaml" '[ $rc -eq 0 ] && [ -s "$AU/rules/sec.md" ]'
kit new agent bot >/dev/null 2>&1
check "new agent skeleton has frontmatter" 'head -2 "$AU/agents/bot.md" | grep -qx "name: bot"'
out=$(kit new skill foo --from "$LIB/skills/foo" 2>&1); rc=$?
check "new --from copies md and declared scripts" '[ $rc -eq 0 ] && [ -f "$AU/skills/foo/SKILL.md" ] && [ -f "$AU/skills/foo/scripts/x.sh" ]'
check "new --from skips LICENSE, README, binaries, .git, Python caches" '[ ! -e "$AU/skills/foo/LICENSE" ] && [ ! -e "$AU/skills/foo/README.md" ] && [ ! -e "$AU/skills/foo/logo.png" ] && [ ! -e "$AU/skills/foo/.git" ] && [ ! -e "$AU/skills/foo/scripts/__pycache__" ]'
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
mkdir -p "$AU/skills/foo/scripts/__pycache__"; printf '\0\1\2' > "$AU/skills/foo/scripts/__pycache__/x.cpython-314.pyc"; printf '\0\1\2' > "$AU/skills/foo/z.pyo"
out=$(kit check 2>&1); rc=$?
check "check: Python caches (__pycache__, .pyc) are not part of a skill" '[ $rc -eq 0 ] && ! echo "$out" | grep -q 只能放文字檔'
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
# a source its kit.yaml calls private (never made public): its own private words are not problems
PV="$T/private-src"; mkdir -p "$PV/rules/topsecretname-notes"
printf 'name: pv\nprivate: true\n' > "$PV/kit.yaml"; printf -- '---\nname: pvr\ndescription: x\n---\nTopSecretName runs here\n' > "$PV/rules/pvr.md"
out=$(kit check "$PV" 2>&1); rc=$?
check "check: private: true, its private words (content, file names) are not problems" '[ $rc -eq 0 ] && ! echo "$out" | grep -q 不該公開'
printf 'name: pv\n' > "$PV/kit.yaml"
out=$(kit check "$PV" 2>&1); rc=$?
check "check: without private: true they are" '[ $rc -ne 0 ] && echo "$out" | grep -q "rules/pvr.md:5: 有不該公開的字" && echo "$out" | grep -q "rules/topsecretname-notes: 檔名有不該公開的字" && ! echo "$out" | grep -q "runs here"'
if [ -n "$PWSH" ]; then
    printf 'name: pv\nprivate: true\n' > "$PV/kit.yaml"
    out=$(kps check "$PV" 2>&1); rc=$?
    check "check private: true: kit.ps1 the same" '[ $rc -eq 0 ] && ! echo "$out" | grep -q 不該公開'
fi
rm -rf "$PV"
rm -rf "$AU/skills/gerrit-review"
# --ci: author emails from the company domain only
rm -rf "$AU/skills/foo/.git" "$AU/.gitmodules" "$AU/rules/link.md" "$AU/skills/foo/logo.png" "$AU/skills/baz" "$AU/mcp" "$AU/skills/foo/scripts/__pycache__" "$AU/skills/foo/z.pyo"
printf -- '---\nname: bot\ndescription: b\nskills: [foo]\n---\nhi\n' > "$AU/agents/bot.md"; echo "Be safe." > "$AU/rules/sec.md"
echo "author_domains: [corp.example]" >> "$AU/kit.yaml"
git -C "$AU" init -q && git -C "$AU" add -A && git -C "$AU" -c user.name=a -c user.email=me@home.example commit -qm x
out=$(kit check --ci 2>&1); rc=$?
check "check --ci: author email must be company" '[ $rc -ne 0 ] && echo "$out" | grep -q "作者 email 不是公司網域"'
git -C "$AU" -c user.name=a -c user.email=me@corp.example commit -q --amend --reset-author -m x
out=$(kit check --ci 2>&1); rc=$?
check "check --ci passes" '[ $rc -eq 0 ]'
cd "$T"

finish
