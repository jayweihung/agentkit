#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- sync: why a source could not be updated ----------
SY="$T/syncwhy"; git -c init.defaultBranch=main init -q "$SY/w"
printf 'name: s\n' > "$SY/w/kit.yaml"; mkdir -p "$SY/w/rules"; echo v1 > "$SY/w/rules/a.md"
git -C "$SY/w" add -A; git -C "$SY/w" -c user.name=t -c user.email=t@t commit -qm v1; git clone -q --bare "$SY/w" "$SY/s.git"
sk() { HOME="$SY/home" AGENTKIT_CONFIG="$SY/home/.config/agentkit" AGENTKIT_SOURCES="$SY/home/agentkit" "$KIT" "$@"; }
sk init "file://$SY/s.git" >/dev/null 2>&1; C="$SY/home/agentkit/s"
echo v2 > "$SY/w/rules/a.md"; git -C "$SY/w" -c user.name=t -c user.email=t@t commit -qam v2; git -C "$SY/w" push -q "$SY/s.git" HEAD:main 2>/dev/null
echo mine > "$C/rules/a.md"
out=$(sk sync 2>&1)
check "sync: a source with your own changes in the way says so" 'echo "$out" | grep -q "沒辦法更新 s（.*自己改過"'
git -C "$C" checkout -q -- rules/a.md; git -C "$C" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
out=$(sk sync 2>&1)
check "sync: a source with its own commits says it went its own way" 'echo "$out" | grep -q "沒辦法更新 s（.*分岔"'
git -C "$C" remote set-url origin "file://$SY/gone.git"
out=$(sk sync 2>&1)
check "sync: no network is told apart" 'echo "$out" | grep -qF "沒辦法更新 s（沒網路？）"'

finish
