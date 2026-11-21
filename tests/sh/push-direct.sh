#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; kit init "$TEAM" >/dev/null 2>&1
mkdir -p "$HOME/.config/agentkit"; printf '# mine\nTopSecretName\n' > "$HOME/.config/agentkit/private-words.txt"
# ---------- push: direct (kit.yaml): your own source, straight to every remote, no PR ----------
D="$T/pushdirect"; DW="$D/work"; R1="$D/one.git"; R2="$D/two.git"
git -c init.defaultBranch=main init -q --bare "$R1"; git -c init.defaultBranch=main init -q --bare "$R2"
git -c init.defaultBranch=main init -q "$DW"
printf 'name: mine\npush: direct\nallowed_hosts: [gitea.example]\n' > "$DW/kit.yaml"; mkdir -p "$DW/rules"; echo "Mine." > "$DW/rules/mine.md"
git -C "$DW" config user.name tester; git -C "$DW" config user.email me@home.example
git -C "$DW" add -A; git -C "$DW" commit -qm init
git -C "$DW" remote add one "$R1"; git -C "$DW" remote add two "$R2"
git -C "$DW" push -q one main 2>/dev/null; git -C "$DW" push -q two main 2>/dev/null; git -C "$DW" fetch -q one; git -C "$DW" fetch -q two
cd "$DW"
echo "Mine, changed." > rules/mine.md; echo "not an item" > notes.txt
dh0=$(git rev-parse HEAD)
printf 'name: mine\n' > kit.yaml
out=$(kit push --dry-run 2>&1); rc=$?
check "push (pr, the default) without origin: stops and says to write push: direct" '[ $rc -ne 0 ] && echo "$out" | grep -q "沒有 origin" && echo "$out" | grep -qF "push: direct" && [ "$(git rev-parse HEAD)" = "$dh0" ]'
printf 'name: mine\npush: maybe\n' > kit.yaml
out=$(kit check . 2>&1); rc=$?
check "check: push is pr or direct" '[ $rc -ne 0 ] && echo "$out" | grep -qF "kit.yaml: push 只能是 pr 或 direct"'
git checkout -q -- kit.yaml
git config remote.one.pushurl https://evil.example/one.git
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct: a push URL to a host not allowed stops it" '[ $rc -ne 0 ] && echo "$out" | grep -q "evil.example 不在允許的主機清單"'
git config --unset remote.one.pushurl
git config "url.https://evil.example/.pushInsteadOf" "$D/"
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct: pushInsteadOf to a host not allowed stops it" '[ $rc -ne 0 ] && echo "$out" | grep -q "evil.example 不在允許的主機清單"'
git config --remove-section "url.https://evil.example/"
git config "url.evil.example:.pushInsteadOf" "$D/"
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct: pushInsteadOf to host:path (no user@) is a host too" '[ $rc -ne 0 ] && echo "$out" | grep -q "evil.example 不在允許的主機清單"'
git config --remove-section "url.evil.example:"
out=$(kit push --dry-run --json 2>/dev/null); rc=$?
check "push direct --dry-run --json: the branch and every remote, no PR" '[ $rc -eq 0 ] && [ "$out" = "{\"source\": \"work\", \"dir\": \"$(pwd -P)\", \"push\": \"direct\", \"dry_run\": true, \"files\": [\"rules/mine.md\"], \"skipped\": [\"notes.txt\"], \"commit\": \"kit: update rule:mine\", \"branch\": \"main\", \"into\": null, \"remotes\": [\"one\", \"two\"], \"sent\": false, \"pr_url\": null, \"compare_url\": null}" ]'
if [ -n "$PWSH" ]; then
    check "push direct --dry-run --json: kit.ps1 prints the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
out=$(kit push --dry-run 2>&1); rc=$?
check "push direct --dry-run: straight to the remotes, nothing sent" '[ $rc -eq 0 ] && echo "$out" | grep -qF "push: direct" && echo "$out" | grep -q "one two" && echo "$out" | grep -q "rules/mine.md" && [ "$(git rev-parse HEAD)" = "$dh0" ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$dh0" ]'
out=$(kit push 2>&1); rc=$?
check "push direct: commit on main, pushed to every remote" '[ $rc -eq 0 ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$(git rev-parse HEAD)" ] && [ "$(git --git-dir="$R2" rev-parse main)" = "$(git rev-parse HEAD)" ] && [ "$(git log -1 --format=%s)" = "kit: update rule:mine" ] && [ "$(git symbolic-ref --short HEAD)" = main ]'
check "push direct: only the item is committed" '[ "$(git show --name-only --format= HEAD)" = rules/mine.md ] && [ "$(git status --porcelain)" = "?? notes.txt" ]'
git commit -q --allow-empty -m unpushed; echo "Mine, again." > rules/mine.md; dh1=$(git rev-parse HEAD)
out=$(kit push 2>&1); rc=$?
check "push direct: a commit not on a remote yet stops it, nothing committed" '[ $rc -ne 0 ] && echo "$out" | grep -q "還沒推到 one" && [ "$(git rev-parse HEAD)" = "$dh1" ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$(git rev-parse HEAD~1)" ]'
git reset -q --soft HEAD~1
git -c init.defaultBranch=main init -q --bare "$D/three.git"; git remote add three "$D/three.git"
out=$(kit push 2>&1); rc=$?
check "push direct: a remote without this branch stops it" '[ $rc -ne 0 ] && echo "$out" | grep -q "three 上沒有 main" && [ "$(git rev-parse HEAD)" = "$(git --git-dir="$R1" rev-parse main)" ]'
out=$(kit push --json 2>/dev/null); rc=$?
check "push direct --json: error out_of_sync" '[ $rc -ne 0 ] && echo "$out" | grep -q "^{\"error\": {\"code\": \"out_of_sync\", \"message\": \"three 上沒有 main"'
git remote remove three
git clone -q "$R1" "$D/other" 2>/dev/null; git -C "$D/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m theirs; git -C "$D/other" push -q origin HEAD:main 2>/dev/null
out=$(kit push 2>&1); rc=$?
check "push direct: new commits on a remote stop it (pull first)" '[ $rc -ne 0 ] && echo "$out" | grep -qF "git pull one main" && [ "$(git status --porcelain rules)" = " M rules/mine.md" ]'
git pull -q --no-rebase one main 2>/dev/null; git push -q two main 2>/dev/null; git fetch -q two
# kit.yaml goes along only when all that changed in it is collect_sources (kit collect --allow)
printf 'collect_sources: [example.com/a/b]\n' >> kit.yaml
out=$(kit push 2>&1); rc=$?
check "push direct: kit.yaml with only collect_sources changed goes along" '[ $rc -eq 0 ] && [ "$(git show --name-only --format= HEAD | sort | paste -sd" " -)" = "kit.yaml rules/mine.md" ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$(git rev-parse HEAD)" ]'
echo "Mine, once more." > rules/mine.md; printf 'maintainers: [me]\n' >> kit.yaml
out=$(kit push 2>&1); rc=$?
check "push direct: kit.yaml with other changes stays behind" '[ $rc -eq 0 ] && [ "$(git show --name-only --format= HEAD)" = rules/mine.md ] && echo "$out" | grep -q "不會送：kit.yaml"'
git checkout -q -- kit.yaml
# a commit hook says no: git's words are shown, and nothing is left staged
printf '#!/bin/sh\necho "hook: no thanks" >&2\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
echo "Mine, blocked." > rules/mine.md; h=$(git rev-parse HEAD)
out=$(kit push 2>&1); rc=$?
check "push direct: a commit hook refusing: its words shown, nothing committed or left staged" '[ $rc -ne 0 ] && echo "$out" | grep -q "hook: no thanks" && [ "$(git rev-parse HEAD)" = "$h" ] && [ -z "$(git diff --cached --name-only)" ] && [ "$(git status --porcelain rules)" = " M rules/mine.md" ]'
rm -f .git/hooks/pre-commit; git checkout -q -- rules/mine.md
# only the Chinese descriptions changed: the commit still says what it sends
printf 'rule:mine\t%s\t我的\n' "$(git hash-object rules/mine.md | cut -c1-12)" > descriptions-zh.txt
out=$(kit push --dry-run --json 2>/dev/null)
check "push direct: only descriptions-zh.txt: the commit names it" 'echo "$out" | grep -qF "\"commit\": \"kit: add descriptions-zh.txt\"" && { [ -z "$PWSH" ] || [ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]; }'
kit push >/dev/null 2>&1
# a deletion you already staged (git rm) goes along
echo "Other." > rules/other.md; git rm -q rules/mine.md   # (other first: git rm takes the folder with its last file)
out=$(kit push --dry-run --json 2>/dev/null)
[ -z "$PWSH" ] || check "push direct: a deletion already staged: kit.ps1 says the same" '[ "$(kps push --dry-run --json 2>/dev/null)" = "$out" ]'
out=$(kit push 2>&1); rc=$?
check "push direct: a deletion already staged (git rm) goes along" '[ $rc -eq 0 ] && [ "$(git log -1 --format=%s)" = "kit: add rule:other; remove rule:mine" ] && [ -z "$(git status --porcelain rules)" ] && [ "$(git --git-dir="$R1" rev-parse main)" = "$(git rev-parse HEAD)" ]'
echo "Mine, back." > rules/mine.md   # (a change waiting, for what follows)

# ---------- a source set up through a link (on macOS /tmp is really /private/tmp): still one source ----------
LH="$T/home-linked"; mkdir -p "$LH"; ln -s "$D" "$T/pd-link"; LW="$T/pd-link/work"; DWP=$(cd "$DW" && pwd -P)
LM="$LH/.config/agentkit/machine.yaml"; LS="$LH/.config/agentkit/state.tsv"
out=$(HOME="$LH" kit init "$LW" 2>&1); rc=$?
check "init through a link: the source is kept with links resolved" '[ $rc -eq 0 ] && grep -qxF "  - $DWP" "$LM"'
out=$(cd "$LW" && HOME="$LH" kit push --dry-run --json 2>/dev/null); rc=$?
check "init through a link, push in the link: one source, not two" '[ $rc -eq 0 ] && echo "$out" | grep -qF "{\"source\": \"work\", \"dir\": \"$DWP\", \"push\": \"direct\", \"dry_run\": true, \"files\": [\"rules/mine.md\"], "'
if [ -n "$PWSH" ]; then
    check "init through a link, push: kit.ps1 prints the same" '[ "$(cd "$LW" && HOME="$LH" kps push --dry-run --json 2>/dev/null)" = "$out" ]'
fi
out=$(cd "$T" && HOME="$LH" kit push --to "$LW" --dry-run --json 2>/dev/null); rc=$?
check "push --to a folder through a link: the same one source" '[ $rc -eq 0 ] && echo "$out" | grep -qF "\"dir\": \"$DWP\", "'
out=$(cd "$LW" && HOME="$LH" kit check 2>&1); rc=$?
check "check in a source opened through a link: no name twice" '[ $rc -eq 0 ] && echo "$out" | grep -qF "沒問題（1 個來源）"'
# upgrading: kit before 0.3.0 kept the folder as typed (the link)
awk -v p="  - $DWP" -v l="  - $LW" '{ print ($0 == p ? l : $0) }' "$LM" > "$LM.t" && mv "$LM.t" "$LM"
out=$(cd "$DW" && HOME="$LH" kit push --dry-run --json 2>/dev/null); rc=$?
check "upgrade: a source kept as a link still counts once" 'grep -qxF "  - $LW" "$LM" && [ $rc -eq 0 ] && echo "$out" | grep -qF "\"dir\": \"$DWP\", "'
out=$(cd "$LW" && HOME="$LH" kit check 2>&1); rc=$?
check "upgrade: check with a source kept as a link: no name twice" '[ $rc -eq 0 ] && echo "$out" | grep -qF "沒問題（1 個來源）"'
if [ -n "$PWSH" ]; then
    out=$(cd "$DW" && HOME="$LH" kps push --dry-run --json 2>/dev/null); rc=$?
    check "upgrade: kit.ps1 also counts a source kept as a link once" '[ $rc -eq 0 ] && echo "$out" | grep -qF "\"dir\": \"$DWP\", "'
fi
printf 'Linked.\n' > "$T/linked.md"
HOME="$LH" kit new rule linked --from "$T/linked.md" --to "$LW" >/dev/null 2>&1
check "kit new --from through a link: remembered under the folder with links resolved" 'grep -q "^from	rule:linked@$DWP	" "$LS"'
awk -F'\t' -v OFS='\t' -v p="rule:linked@$DWP" -v l="rule:linked@$LW" '$1 == "from" && $2 == p { $2 = l } 1' "$LS" > "$LS.t" && mv "$LS.t" "$LS"
printf 'Linked, newer.\n' > "$T/linked.md"
out=$(HOME="$LH" kit update rule linked --from "$T/linked.md" --to "$LW" 2>&1); rc=$?
check "upgrade: kit update finds what kit new remembered under the link" 'grep -q "^from	rule:linked@$LW	" "$LS" && [ $rc -eq 0 ] && grep -q "Linked, newer" "$DW/rules/linked.md"'
rm -f "$DW/rules/linked.md"
cd "$T"

finish
