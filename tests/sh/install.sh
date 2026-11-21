#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- install / self-update / uninstall --self ----------
R="$T/clone"; mkdir -p "$R"; cp -R "$HERE/../unix" "$HERE/../templates" "$HERE/../tools" "$HERE/../VERSION" "$R/"
( cd "$R" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm v1 )
U="$T/clone2"; git clone -q "$R" "$U"
touch "$HOME/.bashrc"
out=$(PATH=/usr/bin:/bin sh "$U/unix/install.sh" 2>&1)
check "install puts kit in ~/.local/bin" '[ -x "$HOME/.local/bin/kit" ] && "$HOME/.local/bin/kit" --version | grep -qF "kit $(cat "$HERE/../VERSION")"'
check "install adds PATH once" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
mkdir -p "$HOME/.local/share/agentkit/herdr/kit-panel" "$HOME/.config/herdr-app/mods/kit"
echo old > "$HOME/.local/share/agentkit/herdr/kit-panel/main.js"
echo old > "$HOME/.config/herdr-app/mods/kit/main.js"; : > "$HOME/.config/herdr-app/mods/kit/.kit-panel"
PATH=/usr/bin:/bin sh "$U/unix/install.sh" >/dev/null 2>&1
check "reinstall does not add PATH twice" '[ "$(grep -c "added by agentkit" "$HOME/.bashrc")" = 1 ]'
check "reinstall removes the panel files kit 0.2 left in its own folder" '[ ! -e "$HOME/.local/share/agentkit/herdr" ] && [ -x "$HOME/.local/share/agentkit/kit" ]'
check "reinstall leaves a panel installed in a screen program alone" '[ "$(cat "$HOME/.config/herdr-app/mods/kit/main.js")" = old ] && [ -f "$HOME/.config/herdr-app/mods/kit/.kit-panel" ]'
rm -rf "$HOME/.config/herdr-app"
check "installed kit works" '"$HOME/.local/bin/kit" init "$TEAM" >/dev/null 2>&1 && grep -q agentkit:begin "$HOME/.claude/CLAUDE.md"'
check "installed kit has the ci template" '"$HOME/.local/bin/kit" ci-template | cmp -s - "$R/templates/gitea-kit-check.yaml"'
( cd "$R" && echo 0.1.1 > VERSION && git -c user.name=t -c user.email=t@t commit -qam v2 )
out=$("$HOME/.local/bin/kit" self-update 2>&1)
check "self-update pulls new version" '"$HOME/.local/bin/kit" --version | grep -q "kit 0.1.1"'
check "self-update shows the commit" 'echo "$out" | grep -qF "已更新到 0.1.1（$(git -C "$R" rev-parse --short=12 HEAD)）"'
out=$("$HOME/.local/bin/kit" self-update 2>&1)
check "self-update with nothing new says so" 'echo "$out" | grep -q "已經是最新"'
out=$("$HOME/.local/bin/kit" status --json 2>/dev/null)
check "status --json: self is the clone kit was installed from (name from its origin) and its commit" 'echo "$out" | grep -qxF "  \"self\": {\"name\": \"clone\", \"commit\": \"$(git -C "$U" rev-parse HEAD)\", \"approved\": null},"'
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

finish
