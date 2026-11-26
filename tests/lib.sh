#!/usr/bin/env bash
# What every section of the bash kit's tests (tests/sh/*.sh) starts from: its own throwaway T and HOME (so your
# real ~/.claude is never touched, and sections can run at the same time), the helpers, the fixture sources and
# the user's own files. Sourced by a section; tests/run.sh runs the sections.
set -u
# Started with Ctrl-C ignored (a background job of a script, `bash tests/run.sh &`, some runners): bash cannot undo
# that for itself or anything it starts, so the Ctrl-C tests would fail without testing kit. Start again with
# Ctrl-C back to normal.
if [ -z "${KIT_TEST_SIGINT:-}" ] && [ "$(python3 -Ic 'import signal; print(signal.getsignal(signal.SIGINT) == signal.SIG_IGN)' 2>/dev/null)" = True ]; then
    export KIT_TEST_SIGINT=1
    exec python3 -Ic 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' bash "$0" "$@"
fi
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT="$HERE/../unix/kit"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)   # links resolved, as kit names source folders (macOS: /var is /private/var)
export HOME="$T/home"; mkdir -p "$HOME"
# a Codex installed here is not run by the tests (kit asks it with codex app-server whether it trusts kit's hooks):
# this one says it does; tests that need another Codex put theirs first in PATH
if command -v codex >/dev/null 2>&1; then
    mkdir -p "$T/stubcx"; cat > "$T/stubcx/codex" <<'SH'
#!/bin/sh
[ "$1" = app-server ] || exit 0
while IFS= read -r l; do case $l in *'"method":"hooks/list"'*)
  printf '{"id":2,"result":{"data":[{"cwd":"/","hooks":[{"key":"k1","source":"user","pluginId":null,"command":"kit sync --hook","trustStatus":"trusted"},{"key":"k2","source":"user","pluginId":null,"command":"kit handoff-hook","trustStatus":"trusted"},{"key":"k3","source":"user","pluginId":null,"command":"kit codex-guard","trustStatus":"trusted"}]}]}}\n';; esac; done
SH
    chmod +x "$T/stubcx/codex"; export PATH="$T/stubcx:$PATH"
fi
# a Claude installed here: older than kit's MCP plugin wants, so kit keeps the MCP in ~/.claude.json (the tests of the
# plugin have their own claude)
if CL=$(command -v claude 2>/dev/null); then
    mkdir -p "$T/stubcl"; printf '#!/bin/sh\n[ "$1" = --version ] && { echo "1.0.0 (Claude Code)"; exit 0; }\nexec "%s" "$@"\n' "$CL" > "$T/stubcl/claude"
    chmod +x "$T/stubcl/claude"; export PATH="$T/stubcl:$PATH"
fi
# Herdr's hc here is never asked (kit add / rm / sync tell the open agents through it): this one knows of no terminal
mkdir -p "$T/stubhc"; printf '#!/bin/sh\nexit 1\n' > "$T/stubhc/hc"; chmod +x "$T/stubhc/hc"; export PATH="$T/stubhc:$PATH"
unset CLAUDE_CONFIG_DIR AGENTKIT_CONFIG AGENTKIT_SOURCES KIT_GITEA_TOKEN
export KIT_TRANSCRIPT_CHECK=0   # (kit sync --hook does not look at the Claude these tests may run in)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
kit() { "$KIT" "$@"; }
JA="$HERE/../unix/json.awk"
jget() { LC_ALL=C awk -f "$JA" -v get="$2" "$1" 2>/dev/null; }
# kit.ps1 next to unix/kit (found now: some parts run with a PATH of fakes only)
PWSH=$(command -v pwsh 2>/dev/null || true)
kps() { "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" "$@"; }
# capped SECS CMD... : CMD, stopped after SECS seconds (then 124)
capped() { local s=$1 p w rc; shift; "$@" & p=$!; { sleep "$s"; kill "$p"; } >/dev/null 2>&1 & w=$!; wait "$p"; rc=$?; { kill "$w"; wait "$w"; } 2>/dev/null; [ $rc -lt 128 ] || rc=124; return $rc; }
# the last line of a section: tests/run.sh adds these up
finish() { echo "kit: $pass passed, $fail failed"; [ $fail -eq 0 ]; }

# ---------- fixture sources ----------
TP="$T/third-party"; TEAM="$T/team"
mkdir -p "$TP/skills/gerrit-workflow" "$TEAM/rules" "$TEAM/skills/gerrit-review" "$TEAM/mcp" "$TEAM/agents"
printf -- '---\nname: gerrit-workflow\ndescription: upstream\n---\nupstream body\n' > "$TP/skills/gerrit-workflow/SKILL.md"
echo "Apache-2.0" > "$TP/skills/gerrit-workflow/LICENSE"
cat > "$TEAM/kit.yaml" <<EOF
name: team
include: [$TP]
allowed_hosts: [gitea.example]
required:
  rules: [security]
  tools:
    deny: [mcp__gerrit__submit_change]
recommended:
  rules:  [coding-style]
  skills: [gerrit-workflow]
EOF
echo "Never paste secrets." > "$TEAM/rules/security.md"
echo "Use 4 spaces." > "$TEAM/rules/coding-style.md"
echo "Only comment, never submit." > "$TEAM/rules/gerrit-flow.md"
printf -- '---\nname: gerrit-review\ndescription: review a change\n---\nhow to review\n' > "$TEAM/skills/gerrit-review/SKILL.md"
cat > "$TEAM/mcp/gerrit.yaml" <<'EOF'
name: gerrit
command: uvx
args: [--index-url, "https://pypi.example/simple", gerrit-mcp-server==1.0]
env:
  GERRIT_CONFIG: ${HOME}/.config/gerrit/gerrit_config.json   # expanded by Claude, not kit
EOF
cat > "$TEAM/agents/gerrit.md" <<'EOF'
---
name: gerrit
description: Gerrit helper
rules:  [gerrit-flow]
skills: [gerrit-review]
mcp:    [gerrit]
tools:
  only: [Read, Grep, Glob]
  deny: [mcp__gerrit__submit_change]
---
You are the Gerrit helper.
EOF

# ---------- the user's own files, which kit must keep ----------
mkdir -p "$HOME/.claude/skills/my-own"
echo "my own skill" > "$HOME/.claude/skills/my-own/SKILL.md"
printf '# My notes\nBe brief.\n' > "$HOME/.claude/CLAUDE.md"
printf '{\n  "model": "opus",\n  "permissions": {\n    "deny": [\n      "Bash(rm -rf:*)"\n    ]\n  }\n}\n' > "$HOME/.claude/settings.json"
printf '{\n  "numStartups": 5,\n  "projects": {\n    "/x": {\n      "note": "中文 \\"q\\""\n    }\n  }\n}' > "$HOME/.claude.json"
chmod 600 "$HOME/.claude.json"; cp -p "$HOME/.claude.json" "$T/claude.json.orig"

# what the sections before it left in the team source, for a section that starts later in the old one-file run
team_later() {
    printf 'team change\nteam change 2\nhook change\nsecond change\n' >> "$TEAM/skills/gerrit-review/SKILL.md"
    mkdir -p "$TEAM/skills/team-build"; printf -- '---\nname: team-build\ndescription: b\n---\nx\n' > "$TEAM/skills/team-build/SKILL.md"
    mkdir -p "$T/extra-src/rules"; echo "Extra rule." > "$T/extra-src/rules/extra-rule.md"
    sed "s#^include: \[\(.*\)\]#include: [\1, ../extra-src]#" "$TEAM/kit.yaml" > "$T/k.tmp" && mv "$T/k.tmp" "$TEAM/kit.yaml"
}
