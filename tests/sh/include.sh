#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
kit init "$TEAM" >/dev/null 2>&1
# ---------- a source starts including another one ----------
mkdir -p "$T/extra-src/rules"; echo "Extra rule." > "$T/extra-src/rules/extra-rule.md"
before=$(grep '^added' "$HOME/.config/agentkit/machine.yaml")
sed "s#^include: \[\(.*\)\]#include: [\1, ../extra-src]#" "$TEAM/kit.yaml" > "$T/k.tmp" && mv "$T/k.tmp" "$TEAM/kit.yaml"
out=$(kit sync 2>&1)
check "sync adds a new include (relative to the source)" 'grep -qxF "  - $T/extra-src" "$HOME/.config/agentkit/machine.yaml" && echo "$out" | grep -q "加了來源"'
check "sync keeps what you added" '[ "$(grep "^added" "$HOME/.config/agentkit/machine.yaml")" = "$(echo "$before" | grep "^added")" ]'
check "items of the new source are announced" 'echo "$out" | grep -q "rule:extra-rule"'
out=$(kit sync 2>&1)
check "include added only once" '[ "$(grep -c "extra-src" "$HOME/.config/agentkit/machine.yaml")" = 1 ]'
# a clone of a URL source sits in ~/agentkit/<name>; an include pointing at that folder is the same source
mkdir -p "$T/lc/rules"; echo "x" > "$T/lc/rules/lc.md"
( cd "$T/lc" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm x && git clone -q --bare . "$T/lc.git" )
git clone -q "$T/lc.git" "$HOME/agentkit/lib-clone"     # as if kit had cloned the URL source (pull stays local)
cp "$HOME/.config/agentkit/machine.yaml" "$T/m.bak"
awk '{ print } /^sources:/ { print "  - https://gitea.example/team/lib-clone.git" }' "$T/m.bak" > "$HOME/.config/agentkit/machine.yaml"
sed "s#, ../extra-src]#, ../extra-src, $HOME/agentkit/lib-clone]#" "$TEAM/kit.yaml" > "$T/k.tmp" && mv "$T/k.tmp" "$TEAM/kit.yaml"
out=$(kit sync 2>&1); rc=$?
check "include of a cloned source's folder is not added twice" '[ $rc -eq 0 ] && [ "$(grep -c lib-clone "$HOME/.config/agentkit/machine.yaml")" = 1 ] && echo "$out" | grep -q "rule:lc"'
sed "s#, $HOME/agentkit/lib-clone]#]#" "$TEAM/kit.yaml" > "$T/k.tmp" && mv "$T/k.tmp" "$TEAM/kit.yaml"; cp "$T/m.bak" "$HOME/.config/agentkit/machine.yaml"; rm -rf "$HOME/agentkit/lib-clone"

# ---------- allowed_hosts ----------
out=$(kit init "$TEAM" https://public-git.example/someone/agentkit-library.git 2>&1); rc=$?
check "host outside allowed_hosts refused" '[ $rc -ne 0 ] && echo "$out" | grep -q "public-git.example 不在允許的主機清單"'
kit init "$TEAM" >/dev/null 2>&1

finish
