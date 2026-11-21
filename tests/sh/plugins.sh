#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
mj() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));exec(sys.argv[2])" "$@"; }
SA="$T/signed"; mkdir -p "$SA"
ssh-keygen -q -t ed25519 -N '' -C approver -f "$SA/key"
printf 'jay namespaces="agentkit" %s\n' "$(cat "$SA/key.pub")" > "$SA/allowed_signers"
# ---------- plugins: kit's own marketplace, each tool installs it; Codex's hooks trusted only for a signed version ----------
PG="$T/plug"; PH="$PG/home"; PB="$PG/bin"; mkdir -p "$PH" "$PB" "$PG/src/rules"
pk() { HOME="$PH" AGENTKIT_CONFIG="$PH/.config/agentkit" AGENTKIT_SOURCES="$PH/agentkit" PATH="$PB:$PATH" FAKE_LOG="$PG/log" FAKE_DIR="$PG" "$KIT" "$@"; }
for t in claude omp; do printf '#!/bin/sh\necho "%s $*" >> "$FAKE_LOG"\n' "$t" > "$PB/$t"; done
cat > "$PB/codex" <<'SH'
#!/bin/sh
echo "codex $*" >> "$FAKE_LOG"
case "$1 $2" in
  "plugin add") c="$FAKE_DIR/cxcache/${3%@kit}"; rm -rf "$c"; mkdir -p "$c"; cp -R "$HOME/.config/agentkit/plugins/${3%@kit}/." "$c/"
                [ -f "$FAKE_DIR/cxchange" ] && echo changed >> "$c/x"; echo "Installed plugin root: $c";;
  "app-server ") while IFS= read -r l; do
      case $l in
        *'"method":"hooks/list"'*) i=$(printf '%s' "$l" | sed 's/.*"id":\([0-9]*\).*/\1/'); st=untrusted; [ -f "$FAKE_DIR/cxtrusted" ] && st=trusted
            echo "{\"id\":$i,\"result\":{\"data\":[{\"cwd\":\"/\",\"hooks\":[{\"key\":\"demo@kit:hooks/h.json:session_start:0:0\",\"eventName\":\"sessionStart\",\"pluginId\":\"demo@kit\",\"currentHash\":\"sha256:aa/sha256:bb\",\"trustStatus\":\"$st\"},{\"key\":\"/x/hooks.json:stop:0:0\",\"pluginId\":null,\"currentHash\":\"sha256:cc\",\"trustStatus\":\"untrusted\"}]}]}}";;
        *config/batchWrite*) printf '%s\n' "$l" > "$FAKE_DIR/cxwrite"; touch "$FAKE_DIR/cxtrusted"; echo '{"id":3,"result":{"status":"ok"}}';;
        *'"id":1,'*) echo '{"id":1,"result":{}}';;
      esac; done;;
esac
SH
chmod +x "$PB"/*
mkdir -p "$PG/src/plugins/demo/.claude-plugin" "$PG/src/plugins/demo/hooks" "$PG/src/plugins/demo/skills/demo"
echo "Plugin rule." > "$PG/src/rules/pr.md"
printf '{"name": "demo", "version": "1.0.0", "description": "A demo plugin", "hooks": ["./hooks/h.json"]}\n' > "$PG/src/plugins/demo/.claude-plugin/plugin.json"
printf '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "node \\"x.js\\""}]}]}}\n' > "$PG/src/plugins/demo/hooks/h.json"
printf -- '---\nname: demo\ndescription: d\n---\nbody\n' > "$PG/src/plugins/demo/skills/demo/SKILL.md"
( cd "$PG/src" && git init -q && git config user.name t && git config user.email t@t && git add -A && git commit -qm v1 )
pk init "$PG/src" >/dev/null 2>&1
out=$(pk list 2>&1)
check "plugins: kit list shows a plugin" 'echo "$out" | grep -qE "^ +plugin:demo$"'
out=$(pk list --json 2>/dev/null)
check "plugins: list --json, kind plugin with its description" 'echo "$out" | mj /dev/stdin "assert [(x[\"status\"], x[\"description\"]) for x in d[\"items\"] if x[\"kind\"]==\"plugin\"]==[(\"unused\",\"A demo plugin\")]"'
check "plugins: list --json, the programs its hooks run (needs)" 'echo "$out" | mj /dev/stdin "assert [n[\"tool\"] for x in d[\"items\"] if x[\"kind\"]==\"plugin\" for n in x[\"needs\"]]==[\"node\"]"'
check "plugins: list --json, what it brings (parts)" 'echo "$out" | mj /dev/stdin "assert [x[\"parts\"] for x in d[\"items\"] if x[\"kind\"]==\"plugin\"]==[{\"skills\": [\"demo\"], \"commands\": [], \"agents\": [], \"mcp\": [], \"hooks\": True}]"'
out=$(pk add plugin demo 2>&1); rc=$?
PC="$PH/.config/agentkit/plugins"
check "plugins: add copies it to kit's marketplace" '[ $rc -eq 0 ] && [ -f "$PC/demo/hooks/h.json" ] && grep -qF "\"name\":\"demo\",\"source\":\"./demo\"" "$PC/.claude-plugin/marketplace.json" && grep -qF "\"path\":\"./demo\"" "$PC/.agents/plugins/marketplace.json"'
check "plugins: each tool installs it from kit's marketplace" 'grep -qxF "claude plugin marketplace add $PC --scope user" "$PG/log" && grep -qxF "claude plugin install demo@kit --scope user" "$PG/log" && grep -qxF "codex plugin add demo@kit" "$PG/log" && grep -qxF "omp plugin install demo@kit --scope user --force" "$PG/log"'
check "plugins: not signed -> Codex's hooks not trusted by kit, asked instead" '[ ! -f "$PG/cxwrite" ] && grep -qF "/hooks" "$PH/.config/agentkit/notes/pending/codex-hooks-demo" && echo "$out" | grep -qF "沒有簽章"'
: > "$PG/log"; pk sync >/dev/null 2>&1
check "plugins: sync with nothing changed installs nothing again" '! grep -q "install\|plugin add" "$PG/log"'
# signed later on the computer that signs (no approvals of its own: the approvals and key kit approve remembered)
mkdir -p "$PG/appr"; git -C "$PG/appr" init -q; git -C "$PG/appr" config user.name t; git -C "$PG/appr" config user.email t@t
pk approve "$PG/appr" "$PG/src" --key "$SA/key" --yes >/dev/null 2>&1
: > "$PG/log"; out=$(pk sync 2>&1)
check "plugins: signed after it was installed -> the next sync has Codex trust it (the key that signed here)" 'grep -qxF "codex plugin add demo@kit" "$PG/log" && ! grep -q "^claude plugin install\|^omp plugin install" "$PG/log" && [ -f "$PG/cxwrite" ] && [ ! -e "$PH/.config/agentkit/notes/pending/codex-hooks-demo" ]'
: > "$PG/log"; pk sync >/dev/null 2>&1
check "plugins: trusted, nothing to do at the next sync" '! grep -q "plugin add\|install" "$PG/log"'
rm -f "$PG/cxwrite" "$PG/cxtrusted"
pk rm plugin demo >/dev/null 2>&1
check "plugins: rm uninstalls from each tool, kit's copy gone" 'grep -qxF "claude plugin uninstall demo@kit --scope user" "$PG/log" && grep -qxF "codex plugin remove demo@kit" "$PG/log" && grep -qxF "omp plugin uninstall demo@kit --scope user" "$PG/log" && [ ! -e "$PC/demo" ] && [ ! -e "$PH/.config/agentkit/notes/pending/codex-hooks-demo" ]'
# signed: the approvals say this commit -> kit has Codex trust the hooks (Codex's own hashes), and asks Codex again
printf 'approvals: %s\nsigners: %s\n' "$PG/appr" "$SA/allowed_signers" >> "$PH/.config/agentkit/machine.yaml"
: > "$PG/log"; out=$(pk add plugin demo 2>&1)
check "plugins: signed -> Codex trusts the plugin's hooks (only those), checked with Codex" 'grep -qF "\"keyPath\":\"hooks.state\"" "$PG/cxwrite" && grep -qF "\"demo@kit:hooks/h.json:session_start:0:0\":{\"trusted_hash\":\"sha256:aa\",\"trusted_content_hash\":\"sha256:bb\"}" "$PG/cxwrite" && ! grep -qF "/x/hooks.json" "$PG/cxwrite" && echo "$out" | grep -qF "Codex 已信任" && [ ! -e "$PH/.config/agentkit/notes/pending/codex-hooks-demo" ]'
pk rm plugin demo >/dev/null 2>&1; rm -f "$PG/cxwrite" "$PG/cxtrusted"
( cd "$PG/src" && echo more >> plugins/demo/hooks/h.json && git commit -qam v2 )
out=$(pk add plugin demo 2>&1)
check "plugins: a commit nobody signed -> not trusted" '[ ! -f "$PG/cxwrite" ] && [ -f "$PH/.config/agentkit/notes/pending/codex-hooks-demo" ]'
pk rm plugin demo >/dev/null 2>&1; pk approve "$PG/appr" "$PG/src" --key "$SA/key" --yes >/dev/null 2>&1; touch "$PG/cxchange"
out=$(pk add plugin demo 2>&1)
check "plugins: Codex's copy not the same as kit's -> not trusted" '[ ! -f "$PG/cxwrite" ] && [ -f "$PH/.config/agentkit/notes/pending/codex-hooks-demo" ]'
rm -f "$PG/cxchange"
# a folder's plugin: Claude --scope local and omp --scope project, run in the folder; Codex only for the account (said)
mkdir -p "$PG/fd"; : > "$PG/log"
out=$(pk add --dir "$PG/fd" plugin demo 2>&1); rc=$?
check "plugins: --dir -> Claude --scope local, omp --scope project ; kit says Codex is account-only" '[ $rc -eq 0 ] && grep -qxF "claude plugin install demo@kit --scope local" "$PG/log" && grep -qxF "omp plugin install demo@kit --scope project --force" "$PG/log" && echo "$out" | grep -qF "Codex 只能整個帳號裝"'
out=$(pk list --json --dir "$PG/fd" 2>/dev/null)
check "plugins: list --json --dir, here.folder.plugins" 'echo "$out" | mj /dev/stdin "assert d[\"here\"][\"folder\"][\"plugins\"]==[{\"name\": \"demo\", \"tools\": [\"claude\", \"omp\"], \"note\": \"Codex 只能整個帳號裝\"}]"'
: > "$PG/log"; pk rm --dir "$PG/fd" plugin demo >/dev/null 2>&1
check "plugins: rm --dir uninstalls there only" 'grep -qxF "claude plugin uninstall demo@kit --scope local" "$PG/log" && grep -qxF "omp plugin uninstall demo@kit --scope project" "$PG/log" && ! grep -q "scope user" "$PG/log"'
pk uninstall >/dev/null 2>&1
check "plugins: uninstall takes them out and kit's marketplace with them" 'grep -qxF "claude plugin marketplace remove kit" "$PG/log" && grep -qxF "omp plugin marketplace remove kit" "$PG/log" && [ ! -e "$PC" ]'
# collect: the whole plugin, only what the tools load; --skip remembered in the lock, out of plugin.json too
PU="$PG/upstream"; mkdir -p "$PU/.claude-plugin" "$PU/hooks/band" "$PU/skills/one" "$PU/docs" "$PU/pi-ext" "$PU/.github"
printf '{"name": "up", "description": "Up plugin", "hooks": ["./hooks/a.json", "./hooks/band.json"], "types": "./hooks/band/t.d.ts"}\n' > "$PU/.claude-plugin/plugin.json"
printf '{"name": "up", "pi": {"extensions": ["./pi-ext/index.js"]}}\n' > "$PU/package.json"
echo '{}' > "$PU/hooks/a.json"; echo '{}' > "$PU/hooks/band.json"; echo 'x' > "$PU/hooks/band/t.d.ts"; echo 'run()' > "$PU/hooks/run.js"
echo 'ext()' > "$PU/pi-ext/index.js"; echo doc > "$PU/docs/d.md"; echo ci > "$PU/.github/ci.yml"; echo MIT > "$PU/LICENSE"; echo '{"name": "up"}' > "$PU/.claude-plugin/marketplace.json"
printf -- '---\nname: one\ndescription: o\n---\nb\n' > "$PU/skills/one/SKILL.md"
( cd "$PU" && git init -q && git config user.name t && git config user.email t@t && git add -A && git commit -qm up )
CL="$PG/lib"; mkdir -p "$CL"; printf 'push: direct\nmaintainers: [t@t]\ncollect_sources: [%s]\n' "$PU" > "$CL/kit.yaml"
( cd "$CL" && git init -q && git config user.name t && git config user.email t@t && git add -A && git commit -qm l )
out=$(cd "$CL" && pk collect "file://$PU" --look --skip hooks/band.json 2>/dev/null)
check "collect --look: a plugin is one item, kind plugin" 'echo "$out" | mj /dev/stdin "s=d[\"skills\"]; assert len(s)==1 and s[0][\"kind\"]==\"plugin\" and s[0][\"name\"]==\"up\" and s[0][\"description\"]==\"Up plugin\" and \"hooks/run.js\" in s[0][\"scripts\"]"'
out=$(cd "$CL" && pk collect "file://$PU" --skip hooks/band.json --skip hooks/band 2>&1); rc=$?
check "collect: a plugin into plugins/<name>, only the parts the tools load" '[ $rc -eq 0 ] && [ -f "$CL/plugins/up/hooks/a.json" ] && [ -f "$CL/plugins/up/pi-ext/index.js" ] && [ -f "$CL/plugins/up/skills/one/SKILL.md" ] && [ -f "$CL/plugins/up/LICENSE" ] && [ ! -e "$CL/plugins/up/docs" ] && [ ! -e "$CL/plugins/up/.github" ] && echo "$out" | grep -qF "kit add plugin up"'
check "collect: not the author's marketplace.json, no kit-backup left" '[ ! -e "$CL/plugins/up/.claude-plugin/marketplace.json" ] && [ -z "$(ls -a "$CL/plugins/up/.claude-plugin" | grep kit-backup)" ]'
check "collect --skip: left out, and out of plugin.json (hooks, a key naming it)" '[ ! -e "$CL/plugins/up/hooks/band.json" ] && [ ! -e "$CL/plugins/up/hooks/band" ] && ! grep -q band "$CL/plugins/up/.claude-plugin/plugin.json" && grep -qF "./hooks/a.json" "$CL/plugins/up/.claude-plugin/plugin.json"'
check "collect --skip: the lock remembers it" '[ "$(awk -F"\t" "\$1 == \"up\" { print \$8 }" "$CL/third_party.lock")" = "hooks/band.json,hooks/band" ]'
( cd "$CL" && git add -A && git commit -qm up ); echo '{}' > "$PU/hooks/band.json.new"; ( cd "$PU" && git add -A && git commit -qm up2 )
out=$(cd "$CL" && pk collect up 2>&1); rc=$?
check "collect <name> again: the same --skip" '[ $rc -eq 0 ] && [ ! -e "$CL/plugins/up/hooks/band.json" ] && [ -f "$CL/plugins/up/hooks/band.json.new" ] && ! grep -q band.json\" "$CL/plugins/up/.claude-plugin/plugin.json"'
mkdir -p "$CL/skills/up"; printf -- '---\nname: up\ndescription: s\n---\nb\n' > "$CL/skills/up/SKILL.md"
out=$(cd "$CL" && pk collect up 2>&1); rc=$?
check "collect: a plugin and a skill may not share a name" '[ $rc -ne 0 ] && echo "$out" | grep -qF "同名的 skill:up"'
rm -rf "$CL/skills/up"
cd "$T"

finish
