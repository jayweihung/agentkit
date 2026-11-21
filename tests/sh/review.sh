#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; DAY=$(date +%Y%m%d)
# ---------- review fixes: the user's own MCP, state only after writing, CRLF / links / markers, URLs, push ----------
RF="$T/rf"; RS="$RF/src dir"; mkdir -p "$RF/home" "$RS/rules" "$RS/mcp"
rf() { HOME="$RF/home" AGENTKIT_CONFIG="$RF/home/.config/agentkit" AGENTKIT_SOURCES="$RF/home/agentkit" "$KIT" "$@"; }
printf 'name: rfsrc\nrequired:\n  rules: [r1]\n' > "$RS/kit.yaml"; echo "Rule one." > "$RS/rules/r1.md"
printf 'command: theirs\n' > "$RS/mcp/m1.yaml"; printf 'command: kits\n' > "$RS/mcp/m2.yaml"
printf '{\n  "mcpServers": {\n    "m1": {\n      "command": "mine"\n    }\n  }\n}\n' > "$RF/home/.claude.json"; cp "$RF/home/.claude.json" "$RF/cj.orig"
printf 'My line one\r\nMy line two\r\n' > "$RF/crlf.md"; mkdir -p "$RF/home/.claude"; cp "$RF/crlf.md" "$RF/home/.claude/CLAUDE.md"
rf init "$RS" >/dev/null 2>&1
check "@import: a folder with a space is escaped (Claude's @path stops at a space)" 'tr -d "\r" < "$RF/home/.claude/CLAUDE.md" | grep -qxF "@$(printf "%s" "$RS" | sed "s/ /\\\\ /g")/rules/r1.md"'
check "CLAUDE.md with CRLF: kit's lines get CRLF too, the user's kept" '[ "$(head -c 24 "$RF/home/.claude/CLAUDE.md")" = "$(printf "My line one\r\nMy line two")" ] && [ "$(grep -c "agentkit:begin.*$(printf "\r")\$" "$RF/home/.claude/CLAUDE.md")" = 1 ]'
rf sync >/dev/null 2>&1
check "CLAUDE.md with CRLF: one kit block after another sync" '[ "$(grep -c "agentkit:begin" "$RF/home/.claude/CLAUDE.md")" = 1 ]'
out=$(rf add mcp m1 2>&1); rc=$?
check "the user's own MCP with the same name is not replaced (warned)" '[ $rc -eq 0 ] && [ "$(jget "$RF/home/.claude.json" mcpServers.m1.command)" = "\"mine\"" ] && echo "$out" | grep -q "已經有自己的 MCP m1"'
rf add mcp m2 >/dev/null 2>&1; rf rm mcp m2 >/dev/null 2>&1
check "the backup is the file before kit first changed it" 'cmp -s "$RF/home/.claude.json.kit-backup" "$RF/cj.orig"'
cp "$RF/home/.claude.json" "$RF/cj.good"; printf '{"mcpServers": {' > "$RF/home/.claude.json"
out=$(rf add mcp m2 2>&1); rc=$?
check "a file kit cannot write stops kit, and state.tsv does not say it was done" '[ $rc -ne 0 ] && ! grep -q "^mcp	m2	" "$RF/home/.config/agentkit/state.tsv"'
printf '\357\273\277' > "$RF/home/.claude.json"; tr -d '\r' < "$RF/cj.good" | sed 's/$/\r/' >> "$RF/home/.claude.json"
out=$(rf sync 2>&1); rc=$?
check "the next sync adds it; a BOM and CRLF in .claude.json are kept" '[ $rc -eq 0 ] && [ "$(LC_ALL=C tr -d "\r" < "$RF/home/.claude.json" | tail -c +4 | LC_ALL=C awk -f "$JA" -v get=mcpServers.m2.command)" = "\"kits\"" ] && [ "$(od -An -tx1 -N3 "$RF/home/.claude.json" | tr -d " ")" = efbbbf ] && grep -q "$(printf "\r")\$" "$RF/home/.claude.json"'
rf uninstall >/dev/null 2>&1
check "uninstall leaves the user's own MCP" '[ "$(LC_ALL=C tr -d "\r" < "$RF/home/.claude.json" | tail -c +4 | LC_ALL=C awk -f "$JA" -v get=mcpServers.m1.command)" = "\"mine\"" ]'
check "uninstall gives the CRLF CLAUDE.md back byte for byte" 'cmp -s "$RF/home/.claude/CLAUDE.md" "$RF/crlf.md"'
mv "$RF/home/.claude/CLAUDE.md" "$RF/dot-claude.md"; ln -s "$RF/dot-claude.md" "$RF/home/.claude/CLAUDE.md"
rf init "$RS" >/dev/null 2>&1
check "a linked CLAUDE.md stays a link; the file it points to gets the block" '[ -L "$RF/home/.claude/CLAUDE.md" ] && grep -q "agentkit:begin" "$RF/dot-claude.md"'
rf uninstall >/dev/null 2>&1
printf 'Mine\n<!-- agentkit:begin (managed by kit, do not edit) -->\nkeep me\n' > "$RF/half.md"; rm -f "$RF/home/.claude/CLAUDE.md"; cp "$RF/half.md" "$RF/home/.claude/CLAUDE.md"
out=$(rf init "$RS" 2>&1)
check "a begin marker without an end: the file is not touched, kit says so" 'cmp -s "$RF/home/.claude/CLAUDE.md" "$RF/half.md" && echo "$out" | grep -q "找不到結束標記"'
out=$(rf uninstall 2>&1); rc=$?
check "uninstall with such a file: stops, state kept for another try" '[ $rc -ne 0 ] && [ -f "$RF/home/.config/agentkit/state.tsv" ]'
cp "$RF/crlf.md" "$RF/home/.claude/CLAUDE.md"; rf uninstall >/dev/null 2>&1
mkdir -p "$RF/home/.config/agentkit/sync.lock"
out=$(KIT_LOCK_WAIT=1 rf add mcp m2 2>&1); rc=$?
check "another kit running (the lock): waits, then stops" '[ $rc -ne 0 ] && echo "$out" | grep -q "另一個 kit 正在跑"'
rmdir "$RF/home/.config/agentkit/sync.lock"
out=$(rf init "https://me:s3cr3t-tok@gitea.example/acme/team.git" 2>&1); rc=$?
check "init: a URL with a password or token is refused, the token never printed" '[ $rc -ne 0 ] && echo "$out" | grep -q "https://gitea.example/acme/team.git" && ! echo "$out" | grep -q s3cr3t'
# kit check: URLs in MCP args only to listed hosts
printf 'command: uvx\nargs: [--index-url, "https://PyPI.corp.example/simple", srv]\n' > "$RS/mcp/m3.yaml"
out=$(rf check "$RS" 2>&1); rc=$?
check "check: an MCP package index not in allowed_hosts / content_hosts is a problem" '[ $rc -ne 0 ] && echo "$out" | grep -q "pypi.corp.example 不在 allowed_hosts"'
printf 'name: rfsrc\ncontent_hosts: [pypi.corp.example]\n' > "$RS/kit.yaml"
out=$(rf check "$RS" 2>&1); rc=$?
check "check: a listed package index is fine" '[ $rc -eq 0 ]'
# push (pr): origin's default branch from origin itself; no token to a host the source does not list; names with spaces
# origin is read over plain http from a local folder (so it is a URL, host 127.0.0.1) and pushed to that folder directly
PR="$RF/pr"; PO="$PR/srv/acme/team.git"; mkdir -p "$PR/srv/acme"
git -c init.defaultBranch=master init -q --bare "$PO"; git -c init.defaultBranch=master init -q "$PR/w"
printf 'name: prsrc\nauthor_domains: [corp.example]\n' > "$PR/w/kit.yaml"; mkdir -p "$PR/w/rules"; echo base > "$PR/w/rules/b.md"
git -C "$PR/w" config user.name t; git -C "$PR/w" config user.email me@CORP.example
git -C "$PR/w" add -A; git -C "$PR/w" commit -qm init; git -C "$PR/w" push -q "$PO" master 2>/dev/null; git --git-dir="$PO" update-server-info
cat > "$PR/serve" <<'PYEOF'
import functools, http.server, sys
s = http.server.HTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]))
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
PYEOF
python3 -I "$PR/serve" "$PR/srv" "$PR/port" >/dev/null 2>&1 & HTTPD=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$PR/port" ] && break; sleep 1; done
git -C "$PR/w" remote add origin "http://127.0.0.1:$(cat "$PR/port")/acme/team.git"; git -C "$PR/w" config remote.origin.pushurl "$PO"
mkdir -p "$PR/w/skills/sp"; printf -- '---\nname: sp\ndescription: s\n---\nx\n' > "$PR/w/skills/sp/SKILL.md"; echo y > "$PR/w/skills/sp/my file.md"
out=$(cd "$PR/w" && GIT_AUTHOR_EMAIL=x@home.example rf push --dry-run 2>&1); rc=$?
check "push: the author email git really uses (GIT_AUTHOR_EMAIL) is checked" '[ $rc -ne 0 ] && echo "$out" | grep -q "x@home.example 不是公司網域"'
out=$(cd "$PR/w" && KIT_GITEA_TOKEN=tok-777 rf push 2>&1); rc=$?
check "push: the PR goes to origin's default branch (master), asked from origin" '[ $rc -eq 0 ] && echo "$out" | grep -q "PR 到 master"'
check "push: a file name with a space is sent" 'git --git-dir="$PO" ls-tree -r --name-only "kit/sp-$DAY" | grep -qxF "skills/sp/my file.md"'
check "push: no token to a host this source does not list in allowed_hosts" 'echo "$out" | grep -q "不把 Gitea token 送過去" && echo "$out" | grep -qF "開 PR：https://127.0.0.1/acme/team/compare/master...kit/sp-$DAY" && ! echo "$out" | grep -q tok-777'
check "push: the kit branch does not track origin" '[ -z "$(git -C "$PR/w" config "branch.kit/sp-$DAY.remote")" ]'
kill $HTTPD 2>/dev/null
if [ "$(uname)" = Darwin ]; then
    IH="$RF/ih"; mkdir -p "$IH"; echo "# mine" > "$IH/.profile"
    HOME="$IH" SHELL=/bin/bash PATH=/usr/bin:/bin AGENTKIT_HOME="$IH/share" sh "$HERE/../unix/install.sh" --quiet >/dev/null 2>&1
    check "install.sh (Mac, bash): no new .bash_profile hiding .profile; .profile gets the PATH line" '[ ! -e "$IH/.bash_profile" ] && grep -q "added by agentkit" "$IH/.profile"'
fi

finish
