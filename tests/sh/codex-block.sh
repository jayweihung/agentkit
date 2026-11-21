#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; team_later; printf 'review v2\n' >> "$TEAM/skills/gerrit-review/SKILL.md"
# ---------- what Codex itself adds in kit's block of config.toml stays (it appends new tables at the end of the file) ----------
cx_add() { python3 -c "import sys;f=sys.argv[1];s=open(f).read();open(f,\"w\").write(s.replace(\"# agentkit:end\",sys.argv[2].replace(\"\\\\n\",\"\\n\")+\"# agentkit:end\"))" "$1" "$2"; }   # \n in TEXT: a new line
for impl in sh ps; do
    [ $impl = ps ] && [ -z "$PWSH" ] && continue
    (
    export HOME="$T/home-cx-$impl"; mkdir -p "$HOME/.codex"
    k() { if [ $impl = ps ]; then kps "$@"; else kit "$@"; fi; }
    printf 'model = "gpt-5"\n' > "$HOME/.codex/config.toml"
    k init "$TEAM" >/dev/null 2>&1
    check "$impl: kit remembers what it wrote in Codex's config.toml" '[ -s "$HOME/.config/agentkit/codex-block.toml" ] && grep -qxF "[sandbox_workspace_write]" "$HOME/.config/agentkit/codex-block.toml"'
    cx_add "$HOME/.codex/config.toml" '\n[projects."/x/y"]\ntrust_level = "trusted"\n\n[mcp_servers.mine]\ncommand = "z"\n'
    out=$(k sync 2>&1)
    check "$impl: sync moves a table Codex put in kit's block out of it, says so" 'echo "$out" | grep -q "搬到那段外面" && python3 -c "import sys;a,b=open(sys.argv[1]).read().split(\"# agentkit:begin\");assert \"[projects.\\\"/x/y\\\"]\" in a and \"[mcp_servers.mine]\" in a and \"/x/y\" not in b and \"mine\" not in b and \"writable_roots\" in b" "$HOME/.codex/config.toml"'
    cp "$HOME/.codex/config.toml" "$T/cx-$impl.1"; out=$(k sync 2>&1)
    check "$impl: the next sync leaves it as it is (only turns off the MCP that is not kit's), says nothing" '[ "$(grep -vx "enabled = false" "$HOME/.codex/config.toml")" = "$(cat "$T/cx-$impl.1")" ] && ! echo "$out" | grep -q "搬到那段外面"'
    if python3 -c "import tomllib" 2>/dev/null; then
        check "$impl: Codex config valid TOML after the move" 'python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"projects\"][\"/x/y\"][\"trust_level\"]==\"trusted\" and d[\"mcp_servers\"][\"mine\"][\"command\"]==\"z\"" "$HOME/.codex/config.toml"'
    fi
    rm -f "$HOME/.config/agentkit/codex-block.toml"   # as kit 0.6.0 left it: only [projects."…"] counts as Codex's
    cx_add "$HOME/.codex/config.toml" '\n[projects."/p/q"]\ntrust_level = "trusted"\n\n[notice]\nx = 1\n'
    k sync >/dev/null 2>&1
    check "$impl: kit not yet remembering: a [projects] table moved, anything else kit's" 'python3 -c "import sys;a,b=open(sys.argv[1]).read().split(\"# agentkit:begin\");assert \"/p/q\" in a and \"/p/q\" not in b and \"[notice]\" not in a+b" "$HOME/.codex/config.toml"'
    k uninstall >/dev/null 2>&1
    check "$impl: uninstall keeps what Codex added, forgets what kit wrote" 'grep -qF "[projects.\"/x/y\"]" "$HOME/.codex/config.toml" && grep -qF "[projects.\"/p/q\"]" "$HOME/.codex/config.toml" && ! grep -q "agentkit" "$HOME/.codex/config.toml" && [ ! -e "$HOME/.config/agentkit/codex-block.toml" ]'
    echo "$pass $fail" > "$T/sub"
    )
    read pass fail < "$T/sub"
done
[ -n "$PWSH" ] && check "sh and ps: the same Codex config after the move" 'cmp -s "$T/cx-sh.1" <(sed "s|home-cx-ps|home-cx-sh|g" "$T/cx-ps.1")'

finish
