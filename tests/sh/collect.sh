#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- collect / outdated (other people's skills; a local repo plays the author) ----------
UP="$T/upstream"; CO="$T/collector"
mkdir -p "$UP/skills/foo/scripts" "$CO"
printf -- '---\nname: foo\ndescription: >-\n  Upstream foo.\n---\nfoo v1\n' > "$UP/skills/foo/SKILL.md"
echo 'echo hi' > "$UP/skills/foo/scripts/run.sh"; mkdir -p "$UP/skills/foo/.github"; echo x > "$UP/skills/foo/.github/ci.yml"; printf '\0\1' > "$UP/skills/foo/logo.png"; ln -s SKILL.md "$UP/skills/foo/link.md"
printf 'MIT License\n\nPermission is hereby granted, free of charge, ...\n' > "$UP/LICENSE"
( cd "$UP" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm v1 )
mkdir -p "$T/nolic/skills/bar"; printf -- '---\nname: bar\ndescription: b\n---\nb\n' > "$T/nolic/skills/bar/SKILL.md"
( cd "$T/nolic" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm x )
printf 'name: collector\ncollect_sources: [file://%s, file://%s]\n' "$UP" "$T/nolic" > "$CO/kit.yaml"
cd "$CO"
out=$(kit collect "file://$UP" --path skills/foo 2>&1); rc=$?
check "collect copies the skill with the repo's LICENSE" '[ $rc -eq 0 ] && [ -f "$CO/skills/foo/SKILL.md" ] && grep -q "MIT License" "$CO/skills/foo/LICENSE" && [ -f "$CO/skills/foo/scripts/run.sh" ]'
check "collect skips binaries, links and dot folders" '[ ! -e "$CO/skills/foo/logo.png" ] && [ ! -e "$CO/skills/foo/link.md" ] && [ ! -e "$CO/skills/foo/.github" ]'
check "collect points at files that run" 'echo "$out" | grep -q "會執行的檔案" && echo "$out" | grep -q scripts/run.sh'
v1=$(git -C "$UP" rev-parse HEAD)
check "third_party.lock records author, commit, license" 'awk -F"\t" -v u="file://$UP" -v s="$v1" "\$1 == \"foo\" && \$2 == u && \$3 == \"skills/foo\" && \$5 == s && \$6 == \"MIT\"" "$CO/third_party.lock" | grep -q .'
ud=$(git -C "$UP" log -1 --format=%cd --date=short)
check "third_party.lock: the upstream commit's own date (column 9; column 8, skip, is - for a skill)" '[ "$(awk -F"\t" "\$1 == \"foo\" { print \$8 \" \" \$9 }" "$CO/third_party.lock")" = "- $ud" ]'
# a line from before kit 0.9.0 (7 columns): still read; kit collect --dates asks the author for that commit's date
awk -F'\t' -v OFS='\t' '/^#/ { print; next } { NF = 7; print }' "$CO/third_party.lock" > "$T/lock7" && cp "$T/lock7" "$CO/third_party.lock"
out=$(kit outdated --json 2>/dev/null)
check "third_party.lock: an old line without the date still works" 'echo "$out" | grep -qF "\"commit\": \"$v1\", \"now\": \"$v1\", \"state\": \"latest\""'
out=$(kit collect --dates 2>&1); rc=$?
check "collect --dates: fills in the date from the author's repo" '[ $rc -eq 0 ] && [ "$(awk -F"\t" "\$1 == \"foo\" { print NF \" \" \$8 \" \" \$9 }" "$CO/third_party.lock")" = "9 - $ud" ] && echo "$out" | grep -q "補了 1 個日期"'
out=$(kit collect --dates 2>&1)
check "collect --dates: nothing left to ask" 'echo "$out" | grep -q "補了 0 個日期"'
cp "$T/lock7" "$CO/third_party.lock"; mv "$UP" "$UP.away"; out=$(kit collect --dates 2>&1); mv "$UP.away" "$UP"
check "collect --dates: an author gone: left empty, said so" '[ "$(awk -F"\t" "\$1 == \"foo\" { print NF }" "$CO/third_party.lock")" = 7 ] && echo "$out" | grep -q "foo：問不到"'
out=$(kit collect "file://$T/elsewhere" 2>&1); rc=$?
check "collect refuses authors not in collect_sources" '[ $rc -ne 0 ] && echo "$out" | grep -q "不在 collect_sources"'
out=$(kit collect "file://$T/nolic" --path skills/bar 2>&1); rc=$?
check "collect refuses a repo without a license" '[ $rc -ne 0 ] && echo "$out" | grep -q "沒有 LICENSE" && [ ! -e "$CO/skills/bar" ]'
mkdir -p "$CO/skills/own"; printf -- '---\nname: own\ndescription: mine\n---\nmine\n' > "$CO/skills/own/SKILL.md"
out=$(kit collect "file://$UP" --path skills/foo --name own 2>&1); rc=$?
check "collect will not replace your own skill without --force" '[ $rc -ne 0 ] && grep -q mine "$CO/skills/own/SKILL.md"'
rm -rf "$CO/skills/own"
out=$(kit outdated 2>&1)
check "outdated: up to date" 'echo "$out" | grep -q "foo：最新"'
( cd "$UP" && echo notes >> NOTES.md && git add NOTES.md && git commit -qm notes )
out=$(kit outdated 2>&1)
check "outdated: a commit elsewhere in the author's repo is not a new foo" 'echo "$out" | grep -q "foo：最新（原作者改的是 repo 裡別的地方"'
out=$(kit outdated --json 2>/dev/null)
check "outdated --json: the same, latest (now: the author's commit)" 'echo "$out" | grep -qF "\"commit\": \"$v1\", \"now\": \"$(git -C "$UP" rev-parse HEAD)\", \"state\": \"latest\""'
( cd "$UP" && echo "MIT, changed" > LICENSE && git commit -qam license )
out=$(kit outdated 2>&1)
check "outdated: the author's license changed: a new version" 'echo "$out" | grep -q "foo：有新版本"'
( cd "$UP" && git revert --no-edit HEAD >/dev/null )
TAB=$(printf '\t'); eval "$(sed -n '/^web_repo()/,/^}/p' "$KIT")"
check "a repo page's address: the repo, its branch and folder (GitHub tree / blob, GitLab, Gitea); a repo URL: nothing" '[ "$(web_repo https://git.example.org/a/r/tree/main/skills/tdd/)" = "https://git.example.org/a/r${TAB}main${TAB}skills/tdd" ] && [ "$(web_repo "https://git.example.org/a/r/blob/v1/x/SKILL.md?plain=1")" = "https://git.example.org/a/r${TAB}v1${TAB}x" ] && [ "$(web_repo https://gitlab.com/a/r/-/tree/dev)" = "https://gitlab.com/a/r${TAB}dev${TAB}" ] && [ "$(web_repo https://git.example.org/a/r/src/branch/main/s)" = "https://git.example.org/a/r${TAB}main${TAB}s" ] && [ -z "$(web_repo https://git.example.org/a/r)" ]'
( cd "$UP" && echo "foo v2" >> skills/foo/SKILL.md && git commit -qam v2 )
out=$(kit outdated 2>&1)
check "outdated: new version upstream" 'echo "$out" | grep -q "foo：有新版本" && echo "$out" | grep -q "kit collect foo"'
kit outdated --json > "$T/outd.json" 2> "$T/outd.err"; rc=$?
check "outdated --json: valid JSON, foo new, both commits, nothing on stderr" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/outd.json" > /dev/null && [ ! -s "$T/outd.err" ] && grep -qF "\"name\": \"foo\", \"url\": \"file://$UP\", \"path\": \"skills/foo\", \"ref\": \"\", \"commit\": \"$v1\", \"now\": \"$(git -C "$UP" rev-parse HEAD)\", \"state\": \"new\"" "$T/outd.json" && grep -q "\"source\": \"collector\"" "$T/outd.json"'
mv "$UP" "$UP.away"; out=$(kit outdated --json 2>/dev/null); mv "$UP.away" "$UP"
check "outdated --json: an author gone is unreachable" 'echo "$out" | grep -q "\"now\": \"\", \"state\": \"unreachable\""'
kit outdated --diff foo --json > "$T/odiff.json" 2> "$T/odiff.err"; rc=$?
check "outdated --diff --json: the commit that changed foo (not the ones elsewhere), its file with +/- lines" '[ $rc -eq 0 ] && LC_ALL=C awk -f "$JA" "$T/odiff.json" > /dev/null && [ ! -s "$T/odiff.err" ] && grep -qF "\"subject\": \"v2\"" "$T/odiff.json" && ! grep -q "\"subject\": \"notes\"" "$T/odiff.json" && grep -qF "{\"path\": \"SKILL.md\", \"status\": \"M\", \"added\": 1, \"removed\": 0}" "$T/odiff.json" && grep -qF "\"license\": false" "$T/odiff.json"'
out=$(kit outdated --diff foo --file SKILL.md --json 2>/dev/null)
check "outdated --diff --file: that file's diff" 'echo "$out" | grep -qF "+foo v2" && echo "$out" | grep -qF "\"diff_cut\": false"'
out=$(kit outdated --diff nope --json 2>/dev/null); rc=$?
check "outdated --diff: a name never collected: not_found" '[ $rc -ne 0 ] && echo "$out" | grep -q "\"code\": \"not_found\""'
echo "local edit" >> "$CO/skills/foo/SKILL.md"
out=$(kit collect foo 2>&1); rc=$?
check "collect <name> replaces the whole copy with the new version" '[ $rc -eq 0 ] && grep -q "foo v2" "$CO/skills/foo/SKILL.md" && ! grep -q "local edit" "$CO/skills/foo/SKILL.md" && grep -q "$(git -C "$UP" rev-parse HEAD)" "$CO/third_party.lock" && [ "$(grep -c "^foo" "$CO/third_party.lock")" = 1 ]'
( cd "$UP" && git tag -a v1.0 -m rel && echo "foo v3" >> skills/foo/SKILL.md && git commit -qam v3 )
out=$(kit collect foo --ref v1.0 2>&1); rc=$?
check "collect --ref takes a tag" '[ $rc -eq 0 ] && ! grep -q "foo v3" "$CO/skills/foo/SKILL.md"'
out=$(kit outdated 2>&1)
check "outdated follows the tag, not the branch" 'echo "$out" | grep -q "foo：最新"'
out=$(kit outdated --json 2>/dev/null)
check "outdated --json: the tag, latest" 'echo "$out" | grep -q "\"ref\": \"v1.0\".*\"state\": \"latest\""'
printf 'maintainers: [someone-else]\n' >> "$CO/kit.yaml"
out=$(kit collect foo 2>&1); rc=$?
check "only maintainers may collect" '[ $rc -ne 0 ] && echo "$out" | grep -q 維護者'
out=$(kit outdated --json 2>&1); rc=$?
check "outdated --json: not a maintainer, nothing listed (no error)" '[ $rc -eq 0 ] && echo "$out" | grep -q "\"skills\": \[\]"'
sed -i.bak "/^maintainers:/d" "$CO/kit.yaml"; rm -f "$CO/kit.yaml.bak"
# no --path: the only SKILL.md in the repo; several: kit lists them; --look says it all as JSON without writing anything
U2="$T/up-two"; mkdir -p "$U2/a" "$U2/b" "$U2/.hidden/c" "$U2/node_modules/d"
for x in a b .hidden/c node_modules/d; do printf -- '---\nname: %s\ndescription: say "%s" now\n---\nx\n' "${x##*/}" "${x##*/}" > "$U2/$x/SKILL.md"; done
echo 'echo' > "$U2/a/run.sh"; cp "$UP/LICENSE" "$U2/LICENSE"
( cd "$U2" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm x )
U1="$T/up-one"; mkdir -p "$U1/deep/one"; printf -- '---\nname: one\ndescription: o\n---\nx\n' > "$U1/deep/one/SKILL.md"; cp "$UP/LICENSE" "$U1/LICENSE"
( cd "$U1" && git init -q && git config user.name a && git config user.email a@a && git add -A && git commit -qm x )
printf 'name: collector\ncollect_sources: [file://%s, file://%s]\n' "$U2" "$U1" > "$CO/kit.yaml"
cd "$CO"; rm -rf "$CO/skills/foo" "$CO/third_party.lock"
out=$(kit collect "file://$U1" 2>&1); rc=$?
check "collect without --path finds the only SKILL.md" '[ $rc -eq 0 ] && [ -f "$CO/skills/one/SKILL.md" ] && grep -q "^one	.*	deep/one	" "$CO/third_party.lock"'
out=$(kit collect "file://$U2" 2>&1); rc=$?
check "collect without --path, several skills: lists them, collects nothing" '[ $rc -ne 0 ] && echo "$out" | grep -q "  a$" && echo "$out" | grep -q "  b$" && ! echo "$out" | grep -q hidden && [ ! -e "$CO/skills/a" ]'
before=$(cd "$CO" && find . -type f | sort | xargs cksum)
out=$(kit collect "file://$U2" --look 2>/dev/null); rc=$?
v=$(printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["allowed"],d["can_allow"],";".join(s["path"]+","+s["name"]+","+s["description"]+","+s["license"]+","+s["scripts"]+","+s["exists"] for s in d["skills"]))' 2>&1)
check "collect --look: every skill, as JSON" '[ $rc -eq 0 ] && [ "$v" = "True False a,a,say \"a\" now,MIT,run.sh,;b,b,say \"b\" now,MIT,," ]'
check "collect --look writes nothing" '[ "$before" = "$(cd "$CO" && find . -type f | sort | xargs cksum)" ]'
# the download --look made is kept: collecting one of its skills right after downloads nothing; a new commit upstream does
cp "$CO/third_party.lock" "$T/lock.keep"
out=$(kit collect "file://$U2" --path a 2>&1); rc=$?
check "collect after --look: the kept download, nothing downloaded again" '[ $rc -eq 0 ] && [ -f "$CO/skills/a/SKILL.md" ] && ! echo "$out" | grep -q 下載 && ls -d "$HOME/.config/agentkit/cache/collect/"*/repo >/dev/null 2>&1'
( cd "$U2" && echo news > NEWS && git add NEWS && git commit -qm news )
out=$(kit collect "file://$U2" --path a 2>&1); rc=$?
check "collect: a new commit upstream is downloaded (the kept one is not used)" '[ $rc -eq 0 ] && echo "$out" | grep -q 下載 && grep -q "^a	.*	$(git -C "$U2" rev-parse HEAD)	" "$CO/third_party.lock"'
rm -rf "$CO/skills/a"; cp "$T/lock.keep" "$CO/third_party.lock"
out=$(kit collect "file://$UP" --look 2>&1); rc=$?
check "collect --look on an author not on the list of a team source (no --allow): says so, downloads nothing" '[ $rc -ne 0 ] && echo "$out" | grep -q "不在 collect_sources" && echo "$out" | grep -q 不下載 && ! echo "$out" | grep -q "\"skills\""'
out=$(kit collect "file://$UP" --look 2>/dev/null); rc=$?
check "collect --look: error not_allowed, only JSON on stdout" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"not_allowed\", \"message\": \".*不下載" && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ]'
out=$(kit collect "file://$UP" --path skills/foo --allow 2>&1); rc=$?
check "collect --allow refused in a team source (no push: direct)" '[ $rc -ne 0 ] && echo "$out" | grep -q "push: direct" && [ ! -e "$CO/skills/foo" ]'
# your own source: --allow adds the author to collect_sources ([a, b] on one line, or - lines, or no list yet)
# (allowed_hosts listed: a file:/// folder on this machine has no host, so it is not refused)
printf 'name: collector\npush: direct\nallowed_hosts: [gitea.example]\ncollect_sources: [file://%s]   # authors\n' "$U2" > "$CO/kit.yaml"
v=$(kit collect "file://$UP" --look 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["can_allow"])')
check "collect --look: your own source can add the author" '[ "$v" = True ]'
out=$(kit collect "file://$UP" 2>&1); rc=$?
check "collect without --allow says how to add the author" '[ $rc -ne 0 ] && echo "$out" | grep -q -- "--allow"'
out=$(kit collect "file://$UP" --allow 2>&1); rc=$?
check "collect --allow: collected, the author added to the list on its line" '[ $rc -eq 0 ] && [ -f "$CO/skills/foo/SKILL.md" ] && grep -qxF "collect_sources: [file://$U2, $UP]   # authors" "$CO/kit.yaml"'
out=$(kit collect foo 2>&1); rc=$?
check "after --allow the author is on the list" '[ $rc -eq 0 ]'
printf 'name: collector\npush: direct\ncollect_sources:\n    - file://%s\n\n# more\nrecommended:\n  rules: []\n' "$U2" > "$CO/kit.yaml"
out=$(kit collect "file://$U1" --allow 2>&1); rc=$?
check "collect --allow: a - list gets a - line" '[ $rc -eq 0 ] && [ "$(sed -n 4,5p "$CO/kit.yaml")" = "    - file://$U2
    - $U1" ] && grep -q "^recommended:" "$CO/kit.yaml"'
printf 'name: collector\npush: direct' > "$CO/kit.yaml"
rm -rf "$CO/skills/one"; out=$(kit collect "file://$U1" --allow 2>&1); rc=$?
check "collect --allow: no list yet gets one" '[ $rc -eq 0 ] && [ "$(tail -n 1 "$CO/kit.yaml")" = "collect_sources: [$U1]" ] && grep -qx "push: direct" "$CO/kit.yaml"'
# the host must be in allowed_hosts (the source's own list, else every source's): --look and collect never go elsewhere
printf 'name: collector\npush: direct\nallowed_hosts: [gitea.example]\ncollect_sources: [https://public-git.example/someone]\n' > "$CO/kit.yaml"
out=$(kit collect https://public-git.example/someone/skills --look 2>&1); rc=$?
check "collect --look: a host outside allowed_hosts is refused before anything is downloaded" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單" && ! echo "$out" | grep -q 沒辦法下載'
out=$(kit collect https://public-git.example/someone/skills --look 2>/dev/null); rc=$?
check "collect --look: error host_not_allowed" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"host_not_allowed\", "'
out=$(kit collect https://public-git.example/someone/skills 2>&1); rc=$?
check "collect: a host outside allowed_hosts is refused (the same list)" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單" && ! echo "$out" | grep -q 沒辦法下載'
if [ -n "$PWSH" ]; then
    out=$(kps collect https://public-git.example/someone/skills --look 2>&1); rc=$?
    check "collect --look (kit.ps1): a host outside allowed_hosts is refused the same" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單"'
fi
rm -rf "$CO/skills/one" "$CO/skills/foo" "$CO/third_party.lock"
cd "$T"


finish
