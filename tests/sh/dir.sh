#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"; team_later
# ---------- a folder's own (kit add --dir): only agents started there get it ----------
H5="$T/home5"; mkdir -p "$H5/.codex" "$H5/.omp/agent"
printf 'model = "gpt-5"\n\n[mcp_servers.mine]\ncommand = "x"\n' > "$H5/.codex/config.toml"; cp -p "$H5/.codex/config.toml" "$T/codex5.orig"
P="$T/fproj"; mkdir -p "$P/sub/deeper"; P=$(cd "$P" && pwd -P)
printf '# my notes\n' > "$P/CLAUDE.md"; printf '{\n  "mcpServers": {\n    "own": {\n      "command": "y"\n    }\n  }\n}\n' > "$P/.mcp.json"
cp "$P/CLAUDE.md" "$T/p.claude"; cp "$P/.mcp.json" "$T/p.mcp"
(
export HOME="$H5"
kit init "$TEAM" >/dev/null 2>&1
cp -p "$H5/.codex/config.toml" "$T/codex5.init"
check "init: Codex config = the user's own (its MCP turned off: not kit's) + kit's block with only the notes folder writable" 'python3 -c "import sys;s=open(sys.argv[1]).read();a,b=s.split(\"# agentkit:begin\");assert a.replace(\"command = \\\"x\\\"\\nenabled = false\\n\",\"command = \\\"x\\\"\\n\").rstrip(\"\\n\")+\"\\n\"==open(sys.argv[2]).read() and \"writable_roots = [\\\"\"+sys.argv[3]+\"\\\"]\" in b" "$H5/.codex/config.toml" "$T/codex5.orig" "$H5/.config/agentkit/notes"'
out=$(kit add --dir "$P" skill gerrit-review 2>&1); rc=$?
check "add --dir: done, says where" '[ $rc -eq 0 ] && echo "$out" | grep -qF "$P"'
check "add --dir: .agentkit lists it" 'grep -qx "skill:gerrit-review" "$P/.agentkit"'
check "add --dir: Claude and Codex/omp skill folders" '[ -f "$P/.claude/skills/gerrit-review/SKILL.md" ] && [ -f "$P/.agents/skills/gerrit-review/SKILL.md" ]'
check "add --dir: not the account" '[ ! -e "$H5/.claude/skills/gerrit-review" ] && [ ! -e "$H5/.agents/skills/gerrit-review" ] && ! kit list | grep -q "^\* *skill:gerrit-review"'
out=$(kit add --dir "$P/sub/deeper" rule gerrit-flow 2>&1)
check "add --dir from a sub-folder goes to the folder that has .agentkit" '[ ! -e "$P/sub/deeper/.agentkit" ] && grep -qx "rule:gerrit-flow" "$P/.agentkit"'
check "add --dir rule: CLAUDE.md keeps the user text, imports the rule" 'head -1 "$P/CLAUDE.md" | grep -qx "# my notes" && grep -q "^@.*rules/gerrit-flow.md" "$P/CLAUDE.md"'
check "add --dir rule: AGENTS.md (Codex, omp) has the text" 'grep -q "Only comment, never submit." "$P/AGENTS.md"'
check "add --dir: account rules untouched" '! grep -q gerrit-flow "$H5/.claude/CLAUDE.md"'
check "codex: project_root_markers at the top, user part kept, valid TOML" 'head -1 "$H5/.codex/config.toml" | grep -q "agentkit:top:begin" && grep -qF "project_root_markers = [\".git\", \".agentkit\"]" "$H5/.codex/config.toml" && grep -qx "model = \"gpt-5\"" "$H5/.codex/config.toml" && { ! python3 -c "import tomllib" 2>/dev/null || python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"project_root_markers\"]==[\".git\",\".agentkit\"] and d[\"model\"]==\"gpt-5\"" "$H5/.codex/config.toml"; }'
[ -f "$H5/.claude.json" ] || { printf '{\n  "numStartups": 1\n}\n' > "$H5/.claude.json"; chmod 600 "$H5/.claude.json"; }
cp -p "$H5/.claude.json" "$T/cj5.before"
out=$(kit add --dir "$P" mcp gerrit 2>&1)
check "add --dir mcp: Claude trusts the folder (~/.claude.json projects[DIR]; else Claude asks about the MCP at every start), said" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d[\"projects\"][sys.argv[2]]=={\"hasTrustDialogAccepted\":True}" "$H5/.claude.json" "$P" && echo "$out" | grep -qF "${P}：Claude 信任這個資料夾了"'
check "add --dir mcp: ~/.claude.json stays private (600)" '[ "$(ls -l "$H5/.claude.json" | cut -c1-10)" = "-rw-------" ]'
check "add --dir mcp: .mcp.json has it, the user's server kept" '[ "$(jget "$P/.mcp.json" mcpServers.gerrit.command)" = "\"uvx\"" ] && [ "$(jget "$P/.mcp.json" mcpServers.own.command)" = "\"y\"" ]'
check "add --dir mcp: Claude does not ask (settings.local.json)" 'jget "$P/.claude/settings.local.json" enabledMcpjsonServers | grep -q "\"gerrit\""'
check "add --dir mcp: the folder's Codex config" 'grep -q "^\[mcp_servers.gerrit\]" "$P/.codex/config.toml"'
check "add --dir mcp: Codex trusts the folder (valid TOML)" 'grep -qF "[projects.\"$P\"]" "$H5/.codex/config.toml" && { ! python3 -c "import tomllib" 2>/dev/null || python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"));assert d[\"projects\"][sys.argv[2]][\"trust_level\"]==\"trusted\"" "$H5/.codex/config.toml" "$P"; }'
check "add --dir mcp: not the account" '! jget "$H5/.claude.json" mcpServers.gerrit >/dev/null'
# ${HOME} in an MCP's command and args: this machine's home in every tool's file (omp and Codex do not expand it); other ${VAR} stay
cp "$TEAM/mcp/gerrit.yaml" "$T/gerrit.yaml.orig"
cat > "$TEAM/mcp/gerrit.yaml" <<'EOF'
name: gerrit
command: ${HOME}/bin/uv
args: [run, --directory, "${HOME}/src/gerrit-mcp-server", "${GERRIT_PROFILE}", gerrit-mcp-server]
env:
  GERRIT_CONFIG: ${HOME}/.config/gerrit/gerrit_config.json
EOF
kit add mcp gerrit >/dev/null 2>&1; kit sync >/dev/null 2>&1
hj='import json,sys;h=sys.argv[1]
for f in sys.argv[2:]:
  s=json.load(open(f))["mcpServers"]["gerrit"];assert s["command"]==h+"/bin/uv" and s["args"]==["run","--directory",h+"/src/gerrit-mcp-server","${GERRIT_PROFILE}","gerrit-mcp-server"] and s["env"]["GERRIT_CONFIG"]=="${HOME}/.config/gerrit/gerrit_config.json",f'
check "\${HOME} in command and args: the home in Claude's and omp's files (the account's, the folder's .mcp.json), other \${VAR} and env kept" 'python3 -c "$hj" "$H5" "$H5/.claude.json" "$H5/.omp/agent/mcp.json" "$P/.mcp.json"'
check "\${HOME} in command and args: the home in Codex's (the account's and the folder's config.toml)" 'for c in "$H5/.codex/config.toml" "$P/.codex/config.toml"; do grep -qxF "command = \"$H5/bin/uv\"" "$c" && grep -qxF "args = [\"run\", \"--directory\", \"$H5/src/gerrit-mcp-server\", \"\${GERRIT_PROFILE}\", \"gerrit-mcp-server\"]" "$c" || exit 1; done'
# turned off in Claude's /mcp (disabledMcpjsonServers wins over enabledMcpjsonServers): kit turns its own MCP on again
SL="$P/.claude/settings.local.json"
python3 -c 'import json,sys;f=sys.argv[1];d=json.load(open(f));d["disabledMcpjsonServers"]=["mine","gerrit"];json.dump(d,open(f,"w"))' "$SL"
out=$(kit sync 2>&1)
check "a folder's Claude settings turned kit's MCP off: on again, said; the user's other one stays off (and the one not kit's)" 'echo "$out" | grep -qF "$P 的 Claude 設定把 MCP gerrit 關掉了，kit 已經重新打開" && python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d[\"disabledMcpjsonServers\"]==[\"mine\",\"own\"] and d[\"enabledMcpjsonServers\"]==[\"gerrit\"]" "$SL"'
out=$(kit sync 2>&1)
check "turned on again: not said again" '! echo "$out" | grep -q "重新打開"'
python3 -c 'import json,sys;f=sys.argv[1];d=json.load(open(f));d["disabledMcpjsonServers"]=["gerrit"];json.dump(d,open(f,"w"))' "$SL"
kit sync >/dev/null 2>&1
check "the only one turned off: out of disabledMcpjsonServers (the one not kit's stays)" '[ "$(jget "$SL" disabledMcpjsonServers | tr -d " \n")" = "[\"own\"]" ] && [ "$(jget "$SL" enabledMcpjsonServers | tr -d " \n")" = "[\"gerrit\"]" ]'
cp "$T/gerrit.yaml.orig" "$TEAM/mcp/gerrit.yaml"; kit rm mcp gerrit >/dev/null 2>&1; kit sync >/dev/null 2>&1
kit list --json --dir "$P/sub" > "$T/here5.json" 2>/dev/null
check "list --json: folder = the one with .agentkit, its items" 'python3 -c "import json,sys;h=json.load(open(sys.argv[1]))[\"here\"];f=h[\"folder\"];assert f[\"dir\"]==sys.argv[2] and f[\"why\"]==\"\" and set(f[\"items\"])=={\"skill:gerrit-review\",\"rule:gerrit-flow\",\"mcp:gerrit\"}" "$T/here5.json" "$P"'
check "list --json: kit's folder things are not listed again as the folder's own" 'python3 -c "import json,sys;h=json.load(open(sys.argv[1]))[\"here\"];n=[(i[\"kind\"],i[\"name\"]) for i in h[\"items\"]];assert (\"skill\",\"gerrit-review\") not in n and not any(i[\"path\"].endswith(\"AGENTS.md\") for i in h[\"items\"]) and any(i[\"path\"].endswith(\"/CLAUDE.md\") for i in h[\"items\"])" "$T/here5.json"'
out=$(kit add --dir "$H5" skill gerrit-review 2>&1); rc=$?
check "add --dir: refuses the home folder" '[ $rc -ne 0 ] && echo "$out" | grep -q "家目錄" && [ ! -e "$H5/.agentkit" ]'
out=$(kit add --dir "$T" skill gerrit-review 2>&1); rc=$?
check "add --dir: refuses a folder the home folder is in" '[ $rc -ne 0 ] && [ ! -e "$T/.agentkit" ]'
out=$(kit rm --dir "$P" skill gerrit-workflow 2>&1); rc=$?
check "rm --dir: only what the folder added" '[ $rc -ne 0 ] && echo "$out" | grep -q "沒有加"'
out=$(kit rm rule gerrit-flow 2>&1); rc=$?
check "rm: the account hasn't it, a folder has: says which folder and --dir" '[ $rc -ne 0 ] && echo "$out" | grep -qF "$P" && echo "$out" | grep -qF "kit rm --dir"'
[ -z "$PWSH" ] || { out=$(kps rm rule gerrit-flow 2>&1); rc=$?
    check "rm: kit.ps1 says the same" '[ $rc -ne 0 ] && echo "$out" | grep -qF "$P" && echo "$out" | grep -qF "kit rm --dir"'; }
printf 'review v2\n' >> "$TEAM/skills/gerrit-review/SKILL.md"; kit sync >/dev/null 2>&1
check "sync updates the folder's copy" 'grep -q "review v2" "$P/.claude/skills/gerrit-review/SKILL.md" && grep -q "review v2" "$P/.agents/skills/gerrit-review/SKILL.md"'
kit rm --dir "$P" skill gerrit-review >/dev/null 2>&1; kit rm --dir "$P" rule gerrit-flow >/dev/null 2>&1; kit rm --dir "$P" mcp gerrit >/dev/null 2>&1
check "rm --dir all: the folder as before, but its .mcp.json server (not kit's, not in git) still off" 'cmp -s "$P/CLAUDE.md" "$T/p.claude" && cmp -s "$P/.mcp.json" "$T/p.mcp" && [ "$(cd "$P" && ls -A | LC_ALL=C sort | tr "\n" " ")" = ".claude .mcp.json CLAUDE.md sub " ] && [ "$(jget "$P/.claude/settings.local.json" disabledMcpjsonServers | tr -d " \n")" = "[\"own\"]" ]'
check "rm --dir all: Codex config byte-identical to after init" 'cmp -s "$H5/.codex/config.toml" "$T/codex5.init"'
check "rm --dir all: kit forgets the folder" '[ ! -e "$HOME/.config/agentkit/dirs" ] && ! grep -qF "dir:$P:" "$HOME/.config/agentkit/state.tsv"'
check "rm --dir all: ~/.claude.json byte-identical (kit's trust entry gone)" 'cmp -s "$H5/.claude.json" "$T/cj5.before"'
# Claude's own entry for the folder (not trusted): kit trusts it and puts back false when its MCP goes
python3 -c 'import json,sys;f=sys.argv[1];d=json.load(open(f));d.setdefault("projects",{})[sys.argv[2]]={"allowedTools":[],"hasTrustDialogAccepted":False,"lastCost":1};open(f,"w").write(json.dumps(d,indent=2)+"\n")' "$H5/.claude.json" "$P"
cp -p "$H5/.claude.json" "$T/cj5.claude"
kit add --dir "$P" mcp gerrit >/dev/null 2>&1
check "Claude's entry for the folder: trusted, the rest kept" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d[\"projects\"][sys.argv[2]]=={\"allowedTools\":[],\"hasTrustDialogAccepted\":True,\"lastCost\":1}" "$H5/.claude.json" "$P"'
python3 -c 'import json,sys;f=sys.argv[1];d=json.load(open(f));d["projects"][sys.argv[2]]["hasTrustDialogAccepted"]=False;open(f,"w").write(json.dumps(d,indent=2)+"\n")' "$H5/.claude.json" "$P"
kit sync >/dev/null 2>&1
check "trust turned off while kit's MCP is there: on again" '[ "$(LC_ALL=C awk -f "$JA" -v get="projects|$P|hasTrustDialogAccepted" -v sep="|" "$H5/.claude.json")" = true ]'
kit rm --dir "$P" mcp gerrit >/dev/null 2>&1
check "rm --dir mcp: Claude's entry as it was (false)" 'cmp -s "$H5/.claude.json" "$T/cj5.claude"'
kit add --dir "$P" skill gerrit-review >/dev/null 2>&1; kit add --dir "$P" mcp gerrit >/dev/null 2>&1
Q="$T/gone"; mkdir -p "$Q"; Q=$(cd "$Q" && pwd -P); kit add --dir "$Q" skill gerrit-review >/dev/null 2>&1; rm -rf "$Q"; kit sync >/dev/null 2>&1
check "sync: a folder that is gone leaves the list" '! grep -qxF "$Q" "$HOME/.config/agentkit/dirs" && grep -qxF "$P" "$HOME/.config/agentkit/dirs"'
kit uninstall >/dev/null 2>&1
check "uninstall: the folder exactly as before" 'cmp -s "$P/CLAUDE.md" "$T/p.claude" && cmp -s "$P/.mcp.json" "$T/p.mcp" && [ "$(cd "$P" && ls -A | LC_ALL=C sort | tr "\n" " ")" = ".mcp.json CLAUDE.md sub " ]'
check "uninstall: Codex config byte-identical" 'cmp -s "$H5/.codex/config.toml" "$T/codex5.orig"'
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
