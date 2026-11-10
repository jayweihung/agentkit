#!/bin/sh
# Install kit for the current user only (no root needed).
#   sh unix/install.sh            run from inside the git clone
# Files go to ~/.local/share/agentkit, the command to ~/.local/bin/kit.
set -eu
QUIET=; [ "${1:-}" = --quiet ] && QUIET=1
say() { [ -n "$QUIET" ] || printf '%s\n' "$*"; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
DEST=${AGENTKIT_HOME:-$HOME/.local/share/agentkit}
BIN=$HOME/.local/bin

for t in bash awk git; do
    command -v "$t" >/dev/null 2>&1 || { echo "install: 找不到 ${t}，請先裝好" >&2; exit 1; }
done
# on a Mac without the developer tools, /usr/bin/git is only a stub that pops up an installer
if [ "$(uname)" = Darwin ] && ! xcode-select -p >/dev/null 2>&1 && [ "$(command -v git)" = /usr/bin/git ]; then
    echo "install: Mac 還沒有 git。請先在終端機打  xcode-select --install  裝好開發者工具，再重跑一次" >&2
    exit 1
fi

mkdir -p "$DEST" "$BIN"
for f in kit json.awk yaml.awk; do cp "$REPO/unix/$f" "$DEST/$f.new" && mv "$DEST/$f.new" "$DEST/$f"; done
cp "$REPO/VERSION" "$DEST/VERSION"
mkdir -p "$DEST/templates"
for f in "$REPO"/templates/*; do cp "$f" "$DEST/templates/"; done
rm -rf "$DEST/herdr"; mkdir -p "$DEST/herdr"; cp -R "$REPO/herdr/kit-panel" "$DEST/herdr/"   # kit herdr-panel install
printf '%s\n' "$REPO" > "$DEST/.repo"      # where kit self-update pulls from
chmod 755 "$DEST/kit"
ln -sf "$DEST/kit" "$BIN/kit"

# put ~/.local/bin on PATH if it is not there yet
case ":$PATH:" in
    *":$BIN:"*) ;;
    *)
        line='export PATH="$HOME/.local/bin:$PATH"  # added by agentkit'
        # the startup file the user's login shell really reads must exist
        case "${SHELL:-}" in
            */zsh)  main=$HOME/.zshrc ;;
            */bash) if [ "$(uname)" = Darwin ]; then main=$HOME/.bash_profile; else main=$HOME/.bashrc; fi ;;
            *)      main=$HOME/.profile ;;
        esac
        [ -f "$main" ] || : > "$main"
        for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
            [ -f "$rc" ] || continue
            grep -qF '# added by agentkit' "$rc" || printf '\n%s\n' "$line" >> "$rc"
        done
        say "已把 ~/.local/bin 加進 PATH，開新的終端機後生效"
        ;;
esac

say "kit $(cat "$DEST/VERSION") 裝好了。下一步：kit init <團隊來源的網址>"
