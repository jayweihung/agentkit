#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
mkdir -p "$HOME/.config/agentkit"; printf '# mine\nTopSecretName\n' > "$HOME/.config/agentkit/private-words.txt"
# ---------- export-self (a fake kit repo; the private word list of this HOME is still set) ----------
FK="$T/fakekit"; EX="$T/export"; EX2="$T/export2"
mkdir -p "$FK/unix" "$FK/windows" "$FK/.github/workflows" "$FK/tests" "$FK/docs"
cp "$HERE/../unix/kit" "$HERE/../unix/json.awk" "$HERE/../unix/yaml.awk" "$HERE/../unix/mcp.awk" "$FK/unix/"; cp "$HERE/../windows/kit.ps1" "$FK/windows/"
echo 0.3.0 > "$FK/VERSION"; echo "# kit" > "$FK/README.md"; echo notes > "$FK/CHANGELOG.md"; echo MIT > "$FK/LICENSE"; echo "on: push" > "$FK/.github/workflows/ci.yml"
echo "echo test" > "$FK/tests/t.sh"; echo "* text=auto" > "$FK/.gitattributes"; echo "*.tmp" > "$FK/.gitignore"; echo guide > "$FK/docs/guide.md"
echo repoword > "$FK/private-words.txt"
fkcommit() { git -C "$FK" add -A && git -C "$FK" -c user.name=t -c user.email=t@t commit -qm x; }
git -C "$FK" init -q; fkcommit
echo "not tracked" > "$FK/untracked.md"
out=$("$FK/unix/kit" export-self "$EX" --version 0.4.0+gitea.12 2>&1); rc=$?
check "export-self succeeds, says the commit message" '[ $rc -eq 0 ] && echo "$out" | grep -q "kit 0.4.0+gitea.12"'
check "export-self drops CHANGELOG, LICENSE, .github, private-words.txt; keeps README (the manual)" '[ -f "$EX/README.md" ] && [ ! -e "$EX/LICENSE" ] && [ ! -e "$EX/CHANGELOG.md" ] && [ ! -e "$EX/.github" ] && [ ! -e "$EX/private-words.txt" ]'
check "export-self keeps tests, .gitattributes, .gitignore, kit" '[ -f "$EX/tests/t.sh" ] && [ -f "$EX/.gitattributes" ] && [ -f "$EX/.gitignore" ] && [ -x "$EX/unix/kit" ] && [ -f "$EX/windows/kit.ps1" ]'
# kit's own repo must export too (a GitHub host in a test or an example once stopped every company update)
if git -C "$HERE/.." rev-parse --git-dir >/dev/null 2>&1; then
    mkdir -p "$T/exhome"; out=$(HOME="$T/exhome" "$KIT" export-self "$T/exself" 2>&1); rc=$?
    check "export-self: kit's own repo exports (nothing in it names GitHub)" '[ $rc -eq 0 ] && [ -f "$T/exself/VERSION" ] || { echo "$out" | grep "export-self:" | head -n 5; false; }'
    check "export-self: kit's own repo exports only kit (no screen program's add-ons)" '[ "$(cd "$T/exself" && ls -A | LC_ALL=C sort | tr "\n" " ")" = ".gitattributes .gitignore INSTALL.md README.md VERSION docs templates tests tools unix windows " ]'
fi
check "export-self leaves out untracked files" '[ ! -e "$EX/untracked.md" ]'
check "export-self writes VERSION" '[ "$(cat "$EX/VERSION")" = 0.4.0+gitea.12 ]'
check "export-self INSTALL.md, no URL" 'grep -q "sh unix/install.sh" "$EX/INSTALL.md" && grep -qF "windows\\install.ps1" "$EX/INSTALL.md" && ! grep -qE "://|@[A-Za-z0-9.-]+:" "$EX/INSTALL.md"'
check "export-self INSTALL.md: first use is docs/company.md, the manual README.md" 'grep -qF "照 docs/company.md 從頭做一次" "$EX/INSTALL.md" && grep -qF "用法看 README.md" "$EX/INSTALL.md"'
if [ -n "$PWSH" ]; then
    "$PWSH" -NoProfile -File "$FK/windows/kit.ps1" export-self "$T/export-ps" >/dev/null 2>&1
    check "export-self: kit.ps1 writes the same INSTALL.md" 'cmp -s "$T/export-ps/INSTALL.md" "$EX/INSTALL.md"'
    rm -rf "$T/export-ps"
fi
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
mkdir -p "$T/inst"; cp "$HERE/../unix/kit" "$HERE/../unix/json.awk" "$HERE/../unix/yaml.awk" "$HERE/../unix/mcp.awk" "$T/inst/"; echo "$FK" > "$T/inst/.repo"
out=$("$T/inst/kit" export-self "$EX2" 2>&1); rc=$?
check "export-self from an installed kit uses the clone in .repo" '[ $rc -eq 0 ] && [ "$(cat "$EX2/VERSION")" = 0.3.0 ] && [ -f "$EX2/docs/guide.md" ]'

finish
