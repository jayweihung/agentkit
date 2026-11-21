#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; kit init "$TEAM" >/dev/null 2>&1
mkdir -p "$HOME/.config/agentkit"; printf '# mine\nTopSecretName\n' > "$HOME/.config/agentkit/private-words.txt"
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
echo "not an item" > notes.txt
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: nothing to send, said in JSON (what is left out too)" '[ $rc -eq 0 ] && [ "$out" = "{\"source\": \"work\", \"dir\": \"$(pwd -P)\", \"push\": \"pr\", \"dry_run\": true, \"files\": [], \"skipped\": [\"notes.txt\"], \"commit\": null, \"branch\": null, \"into\": null, \"remotes\": [], \"sent\": false, \"pr_url\": null, \"compare_url\": null}" ]'
rm -f notes.txt
kit new skill pfoo >/dev/null 2>&1
head0=$(git rev-parse HEAD)
out=$(kit push --dry-run 2>&1); rc=$?
check "push --dry-run lists files and branch, sends nothing" '[ $rc -eq 0 ] && echo "$out" | grep -q "skills/pfoo/SKILL.md" && echo "$out" | grep -q "kit/pfoo-$DAY" && [ "$(git rev-parse HEAD)" = "$head0" ] && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --dry-run --json: only one JSON line on stdout: files, commit, branch, where the PR goes" '[ $rc -eq 0 ] && [ "$out" = "{\"source\": \"work\", \"dir\": \"$(pwd -P)\", \"push\": \"pr\", \"dry_run\": true, \"files\": [\"skills/pfoo/SKILL.md\"], \"skipped\": [], \"commit\": \"kit: add skill:pfoo\", \"branch\": \"kit/pfoo-$DAY\", \"into\": \"main\", \"remotes\": [\"origin\"], \"sent\": false, \"pr_url\": null, \"compare_url\": \"${KIT_GITEA_API%/api/v1}/acme/team/compare/main...kit/pfoo-$DAY\"}" ] && [ "$(git rev-parse HEAD)" = "$head0" ]'
if [ -n "$PWSH" ]; then
    check "push --dry-run --json: kit.ps1 prints the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
mkdir -p skills/pfoo/scripts/__pycache__; printf '\0\1\2' > skills/pfoo/scripts/__pycache__/x.cpython-314.pyc
check "push: Python caches in a skill are not sent, not listed as left out, do not stop kit check" '[ "$(kit push --dry-run --json 2>/dev/null)" = "$out" ]'
if [ -n "$PWSH" ]; then
    check "push: Python caches: kit.ps1 the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
rm -rf skills/pfoo/scripts
echo "TopSecretName here" >> skills/pfoo/SKILL.md
out=$(kit push 2>&1); rc=$?
check "push: check problem stops, nothing sent" '[ $rc -ne 0 ] && echo "$out" | grep -q 什麼都沒送 && [ -z "$(git branch --list "kit/*")" ] && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: a check problem is error check_failed" '[ $rc -ne 0 ] && [ "$out" = "{\"error\": {\"code\": \"check_failed\", \"message\": \"kit check 有問題，什麼都沒送（改好再 kit push）\"}}" ]'
if [ -n "$PWSH" ]; then
    check "push --json error: kit.ps1 prints the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
printf -- '---\nname: pfoo\ndescription: p\n---\nok\n' > skills/pfoo/SKILL.md
git config user.email me@home.example
out=$(kit push 2>&1); rc=$?
check "push: author domain must be company" '[ $rc -ne 0 ] && echo "$out" | grep -q "不是公司網域" && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: error author_not_allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"author_not_allowed\", \"message\": \"git 的作者信箱 me@home.example 不是公司網域"'
git config user.email me@corp.example
git remote set-url origin https://public-git.example/acme/team.git
out=$(kit push 2>&1); rc=$?
check "push: origin host not allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單" && [ "$(remote_heads)" = main ]'
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push --json: error host_not_allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"host_not_allowed\", " && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ]'
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
echo "Be kindest." > rules/base.md
out=$(KIT_GITEA_TOKEN=fake-tok-123 kit push --json 2>/dev/null); rc=$?
check "push --json: sent, the PR's URL; nothing else on stdout" '[ $rc -eq 0 ] && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ] && echo "$out" | grep -qF "\"dry_run\": false, \"files\": [\"rules/base.md\"], " && echo "$out" | grep -qF "\"branch\": \"kit/base-$DAY\", \"into\": \"main\", \"remotes\": [\"origin\"], \"sent\": true, \"pr_url\": \"http://127.0.0.1/acme/team/pulls/1\", \"compare_url\": " && remote_heads | grep -qx "kit/base-$DAY"'
kill $FAKE 2>/dev/null; unset KIT_GITEA_API
cd "$T"

finish
