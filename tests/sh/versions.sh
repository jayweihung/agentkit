#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- versions: kit list --json version, installed, held, loaded (kit api 1.14) ----------
# vj FILE KIND NAME A.B : that field of that item ("null", true/false as JSON)
vj() { python3 -Ic 'import json,sys
d = json.load(open(sys.argv[1])); v = [i for i in d["items"] if i["kind"] == sys.argv[2] and i["name"] == sys.argv[3]][0]
for k in sys.argv[4].split("."): v = None if v is None else v.get(k)
print("null" if v is None else json.dumps(v) if isinstance(v, bool) else v)' "$@" 2>/dev/null; }
HV="$T/homev"; VS="$T/versrc"; mkdir -p "$HV/.codex" "$VS/rules" "$VS/skills/vs/sub" "$VS/skills/vt" "$VS/plugins/vp/.claude-plugin" "$VS/plugins/vp/skills/x" "$T/vdir"
(
export HOME="$HV"
vc() { git -C "$VS" add -A && GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$VS" -c user.name=t -c user.email=t@t commit -qm "$2"; }
printf 'Be kind.\n' > "$VS/rules/vr.md"; echo x > "$VS/skills/vs/sub/a.txt"
printf '{"name": "vp", "description": "p"}\n' > "$VS/plugins/vp/.claude-plugin/plugin.json"; printf -- '---\nname: x\ndescription: x\n---\nx\n' > "$VS/plugins/vp/skills/x/SKILL.md"
printf -- '---\nname: vs\ndescription: v\n---\nv1\n' > "$VS/skills/vs/SKILL.md"; printf -- '---\nname: vt\ndescription: t\n---\nt1\n' > "$VS/skills/vt/SKILL.md"
{ printf '# third_party.lock\n'; printf 'vs\tfile:///a/vs\tskills/vs\t-\t%040d\tMIT\t2026-11-15\n' 1; printf 'vt\tfile:///a/vt\tskills/vt\t-\t%040d\tMIT\t2026-11-16\t-\t2026-11-10\n' 2; } > "$VS/third_party.lock"
git -C "$VS" init -q; vc 2026-11-01T10:00:00Z first
printf 'Be kind, always.\n' > "$VS/rules/vr.md"; vc 2026-11-02T09:00:00Z "rule a"
printf 'Be kind, always!\n' > "$VS/rules/vr.md"; vc 2026-11-02T11:00:00Z "rule b"
kit init "file://$VS" >/dev/null 2>&1; kit add rule vr >/dev/null 2>&1; kit add skill vs vt >/dev/null 2>&1
CL="$HV/agentkit/versrc"; J="$T/v1.json"; kit list --json > "$J" 2>/dev/null
rid=$(git -C "$VS" hash-object rules/vr.md); rid=${rid:0:8}
sid=$( { printf '%s SKILL.md\n' "$(git -C "$VS" hash-object skills/vs/SKILL.md)"; printf '%s sub/a.txt\n' "$(git -C "$VS" hash-object skills/vs/sub/a.txt)"; } | git hash-object --stdin); sid=${sid:0:8}
check "version: a rule's id is its file's blob, the last commit that changed it, n = how many that day" '[ "$(vj "$J" rule vr version.id)" = "$rid" ] && [ "$(vj "$J" rule vr version.date)" = 2026-11-02 ] && [ "$(vj "$J" rule vr version.n)" = 2 ] && [ "$(vj "$J" rule vr version.message)" = "rule b" ] && [ "$(vj "$J" rule vr version.commit)" = "$(git -C "$VS" rev-parse HEAD)" ] && [ "$(vj "$J" rule vr version.dirty)" = false ]'
plid=$( { printf '%s .claude-plugin/plugin.json\n' "$(git -C "$VS" hash-object plugins/vp/.claude-plugin/plugin.json)"; printf '%s skills/x/SKILL.md\n' "$(git -C "$VS" hash-object plugins/vp/skills/x/SKILL.md)"; } | git hash-object --stdin); plid=${plid:0:8}
check "version: a plugin's id is the blob of its listing too" '[ "$(vj "$J" plugin vp version.id)" = "$plid" ] && [ "$(vj "$J" plugin vp installed.claude)" = null ]'
# kit.ps1 (Windows): the same fingerprints and the same JSON for the same repo
if [ -n "$PWSH" ]; then
    kps list --json > "$T/v1p.json" 2>/dev/null
    check "version: kit.ps1 gives the same ids (a rule, a skill, a plugin) and prints the same" '[ "$(vj "$T/v1p.json" rule vr version.id)" = "$rid" ] && [ "$(vj "$T/v1p.json" skill vs version.id)" = "$sid" ] && [ "$(vj "$T/v1p.json" plugin vp version.id)" = "$plid" ] && cmp -s "$J" "$T/v1p.json"'
fi
check "version: a skill's id is the blob of its listing (files sorted, blob and path); its own last commit" '[ "$(vj "$J" skill vs version.id)" = "$sid" ] && [ "$(vj "$J" skill vs version.date)" = 2026-11-01 ] && [ "$(vj "$J" skill vs version.n)" = 1 ] && [ "$(vj "$J" skill vs version.message)" = first ]'
check "upstream: a collected one: the author's commit, its date (an old lock line: null), when collected; held null" '[ "$(vj "$J" skill vt upstream.commit)" = "$(printf %040d 2)" ] && [ "$(vj "$J" skill vt upstream.date)" = 2026-11-10 ] && [ "$(vj "$J" skill vt upstream.collected)" = 2026-11-16 ] && [ "$(vj "$J" skill vs upstream.date)" = null ] && [ "$(vj "$J" skill vs upstream.collected)" = 2026-11-15 ] && [ "$(vj "$J" rule vr upstream)" = null ] && [ "$(vj "$J" skill vs held)" = null ] && grep -q "\"held\": null}" "$J"'
check "installed: each tool that has it, the same id, a time; state.tsv keeps it" '[ "$(vj "$J" skill vs installed.claude.id)" = "$sid" ] && [ "$(vj "$J" skill vs installed.codex.id)" = "$sid" ] && [ "$(vj "$J" rule vr installed.claude.id)" = "$rid" ] && [ "$(vj "$J" rule vr installed.codex.id)" = "$rid" ] && [ "$(vj "$J" skill vs installed.claude.at)" -gt 1700000000 ] && grep -q "^ver	claude:skill:vs	$sid [0-9]* " "$HV/.config/agentkit/state.tsv"'
# the same content elsewhere (a folder, not git; with .DS_Store and Python caches): the same ids, no date or commit
mkdir -p "$T/vcopy"; cp -R "$VS/rules" "$VS/skills" "$VS/plugins" "$T/vcopy/"; touch "$T/vcopy/skills/vs/.DS_Store"; mkdir -p "$T/vcopy/skills/vs/sub/__pycache__"; echo c > "$T/vcopy/skills/vs/sub/__pycache__/a.pyc"
HOME="$T/homev2" kit init "$T/vcopy" >/dev/null 2>&1; HOME="$T/homev2" kit list --json > "$T/v2.json" 2>/dev/null
check "version: the same content in another source (not git, with .DS_Store and caches): the same ids, no date or commit" '[ "$(vj "$T/v2.json" skill vs version.id)" = "$sid" ] && [ "$(vj "$T/v2.json" rule vr version.id)" = "$rid" ] && [ "$(vj "$T/v2.json" plugin vp version.id)" = "$plid" ] && [ "$(vj "$T/v2.json" rule vr version.date)" = null ] && [ "$(vj "$T/v2.json" rule vr version.commit)" = null ] && [ "$(vj "$T/v2.json" rule vr version.n)" = null ]'
# a change not committed in the clone: dirty, the id of the files now; nothing installed yet
echo more >> "$CL/skills/vs/SKILL.md"; echo n > "$CL/skills/vs/notes.md"; kit list --json > "$T/v3.json" 2>/dev/null
did=$(cd "$CL/skills/vs" && for f in SKILL.md notes.md sub/a.txt; do printf '%s %s\n' "$(git hash-object "$f")" "$f"; done | git hash-object --stdin); did=${did:0:8}
check "version: a change not committed, with a new file: the listing sorted by path (git lists new files first)" '[ "$(vj "$T/v3.json" skill vs version.id)" = "$did" ]'
[ -z "$PWSH" ] || check "version (not git): kit.ps1 prints the same" 'HOME="$T/homev2" kps list --json 2>/dev/null | cmp -s - "$T/v2.json"'
check "version: a change not committed: dirty, commit null, the files' id; installed still the old one" '[ "$(vj "$T/v3.json" skill vs version.dirty)" = true ] && [ "$(vj "$T/v3.json" skill vs version.commit)" = null ] && [ "$(vj "$T/v3.json" skill vs version.id)" != "$sid" ] && [ "$(vj "$T/v3.json" skill vs installed.claude.id)" = "$sid" ] && [ "$(vj "$T/v3.json" skill vt version.dirty)" = false ]'
[ -z "$PWSH" ] || check "version (dirty): kit.ps1 prints the same" 'kps list --json 2>/dev/null | cmp -s - "$T/v3.json"'
git -C "$CL" checkout -q -- .; rm -f "$CL/skills/vs/notes.md"
# the source changes: the latest is what kit sync fetched (origin), not the clone's files
printf 'Be kind, really.\n' > "$VS/rules/vr.md"; printf -- '---\nname: vs\ndescription: v\n---\nv2\n' > "$VS/skills/vs/SKILL.md"; printf -- '---\nname: vt\ndescription: t\n---\nt2\n' > "$VS/skills/vt/SKILL.md"
vc 2026-11-03T10:00:00Z "rule c"; git -C "$CL" fetch -q
kit list --json > "$T/v4.json" 2>/dev/null; rid2=$(git -C "$VS" hash-object rules/vr.md); rid2=${rid2:0:8}
[ -z "$PWSH" ] || check "version (the remote ahead): kit.ps1 prints the same" 'kps list --json 2>/dev/null | cmp -s - "$T/v4.json"'
check "version: the latest is the remote branch kit sync fetched; the clone not pulled yet: installed is older" '[ "$(vj "$T/v4.json" rule vr version.id)" = "$rid2" ] && [ "$(vj "$T/v4.json" rule vr version.date)" = 2026-11-03 ] && [ "$(vj "$T/v4.json" rule vr installed.claude.id)" = "$rid" ] && [ "$(vj "$T/v4.json" rule vr installed.codex.id)" = "$rid" ]'
# loaded: an agent that started before kit sync changed them, one after (Claude: its session file and log)
vsess() { mkdir -p "$HV/.claude/sessions" "$HV/.claude/projects/$(printf '%s' "$T/vdir" | sed 's|[^A-Za-z0-9]|-|g')"
          printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$1" "$2" "$T/vdir" > "$HV/.claude/sessions/$1.json"; : > "$HV/.claude/projects/$(printf '%s' "$T/vdir" | sed 's|[^A-Za-z0-9]|-|g')/$2.jsonl"; }
sleep 600 & P1=$!; vsess $P1 5e55-1
printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x/skills/vs\\n\\nv1"}]},"isMeta":true,"timestamp":"2000-01-01T00:00:00.000Z"}\n' > "$HV/.claude/projects/$(printf '%s' "$T/vdir" | sed 's|[^A-Za-z0-9]|-|g')/5e55-1.jsonl"
sleep 2; at0=$(vj "$T/v4.json" skill vs installed.claude.at); kit sync >/dev/null 2>&1; sleep 2
sleep 600 & P2=$!; vsess $P2 5e55-2
kit list --json --dir "$T/vdir" --pid $P1 --tool claude > "$T/v5.json" 2>/dev/null; kit list --json --dir "$T/vdir" --pid $P2 --tool claude > "$T/v6.json" 2>/dev/null
kit list --json --dir "$T/vdir" --pid $P1 > "$T/v7.json" 2>/dev/null
[ -z "$PWSH" ] || check "loaded: kit.ps1 says the same (--pid with and without --tool)" 'kps list --json --dir "$T/vdir" --pid $P1 --tool claude 2>/dev/null | cmp -s - "$T/v5.json" && kps list --json --dir "$T/vdir" --pid $P2 --tool claude 2>/dev/null | cmp -s - "$T/v6.json" && kps list --json --dir "$T/vdir" --pid $P1 2>/dev/null | cmp -s - "$T/v7.json"'
check "installed: kit sync changed them: the new id, a new time" '[ "$(vj "$T/v5.json" rule vr installed.claude.id)" = "$rid2" ] && [ "$(vj "$T/v5.json" rule vr installed.codex.id)" = "$rid2" ] && [ "$(vj "$T/v5.json" skill vs installed.claude.at)" -gt "$at0" ] && [ "$(vj "$T/v5.json" skill vs installed.claude.id)" = "$(vj "$T/v5.json" skill vs version.id)" ]'
check "loaded: started before the change: a rule old; a skill it read before: old; one it never read: new" '[ "$(vj "$T/v5.json" rule vr loaded)" = old ] && [ "$(vj "$T/v5.json" skill vs loaded)" = old ] && [ "$(vj "$T/v5.json" skill vt loaded)" = new ]'
check "loaded: started after the change: new; no --pid: no loaded" '[ "$(vj "$T/v6.json" rule vr loaded)" = new ] && [ "$(vj "$T/v6.json" skill vs loaded)" = new ] && ! grep -q "\"loaded\"" "$T/v4.json"'
check "loaded: not an agent kit can tell (no --tool, a sleep): unknown" '[ "$(vj "$T/v7.json" rule vr loaded)" = unknown ]'
# the conversation goes on: kit keeps how far it read each log (cache/used) and reads only the whole lines written since
LG="$HV/.claude/projects/$(printf '%s' "$T/vdir" | sed 's|[^A-Za-z0-9]|-|g')/5e55-1.jsonl"
vline() { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x/skills/%s\\n\\nv1"}]},"isMeta":true,"timestamp":"2000-01-0%sT00:00:00.000Z"}' "$1" "$2"; }
{ vline vt 2; printf '\n'; vline zz 3; } >> "$LG"                # (zz: a line still being written, no LF yet)
kit list --json --dir "$T/vdir" --pid $P1 --tool claude > "$T/v5b.json" 2>/dev/null
check "loaded: the log grew: what was written since is read (a skill read before the change: old), not a line still being written" '[ "$(vj "$T/v5b.json" skill vt loaded)" = old ] && [ "$(vj "$T/v5b.json" skill vs loaded)" = old ] && grep -q "	vt	" "$HV/.config/agentkit/cache/used/"* && ! grep -q zz "$HV/.config/agentkit/cache/used/"*'
[ -z "$PWSH" ] || check "loaded: the log grew: kit.ps1 says the same" 'kps list --json --dir "$T/vdir" --pid $P1 --tool claude 2>/dev/null | cmp -s - "$T/v5b.json"'
{ vline vt 2; printf '\n'; } > "$LG"                                # a shorter log under that name: read from the start
kit list --json --dir "$T/vdir" --pid $P1 --tool claude > "$T/v5c.json" 2>/dev/null
check "loaded: the log got shorter (a new one): read again from the start" '[ "$(vj "$T/v5c.json" skill vs loaded)" = new ] && [ "$(vj "$T/v5c.json" skill vt loaded)" = old ]'
[ -z "$PWSH" ] || check "loaded: the log got shorter: kit.ps1 says the same" 'kps list --json --dir "$T/vdir" --pid $P1 --tool claude 2>/dev/null | cmp -s - "$T/v5c.json"'
kill $P1 $P2 2>/dev/null; wait $P1 $P2 2>/dev/null
# a folder's own: its version and time for agents there
kit add --dir "$T/vdir" skill vt >/dev/null 2>&1; kit list --json --dir "$T/vdir" > "$T/v8.json" 2>/dev/null
fl=$(awk -F'\t' -v k="dir:$T/vdir:ver" '$1 == k && $2 == "claude:skill:vt" { print $3 }' "$HV/.config/agentkit/state.tsv")
check "installed --dir: the folder's own copy (its state.tsv line)" '[ -n "$fl" ] && [ "$(vj "$T/v8.json" skill vt installed.claude.id) $(vj "$T/v8.json" skill vt installed.claude.at)" = "${fl% *}" ]'
[ -z "$PWSH" ] || check "installed --dir: kit.ps1 prints the same" 'kps list --json --dir "$T/vdir" 2>/dev/null | cmp -s - "$T/v8.json"'
# kit 0.8.0's state.tsv (no ver lines): the first sync takes the time from the files kit wrote
awk -F'\t' '$1 != "ver" && $1 !~ /:ver$/' "$HV/.config/agentkit/state.tsv" > "$T/st" && cp "$T/st" "$HV/.config/agentkit/state.tsv"
touch -t 202001020304 "$HV/.claude/skills/vt"; kit sync >/dev/null 2>&1; kit list --json > "$T/v9.json" 2>/dev/null
check "installed: an old state.tsv: the first sync takes each one's time from its file" '[ "$(vj "$T/v9.json" skill vt installed.claude.at)" -lt 1600000000 ] && [ "$(vj "$T/v9.json" skill vt installed.claude.id)" = "$(vj "$T/v9.json" skill vt version.id)" ]'
if [ -n "$PWSH" ]; then   # kit.ps1's sync keeps its own ver lines (nothing changed), and fills them in the same way
    # (its marks are its own hash of the copy, not unix/kit's cksum: a machine has one kit, so the first kps sync writes its own)
    kps sync >/dev/null 2>&1; grep -E '^(ver|dir:.*:ver)	' "$HV/.config/agentkit/state.tsv" > "$T/vl1"; kps sync >/dev/null 2>&1; grep -E '^(ver|dir:.*:ver)	' "$HV/.config/agentkit/state.tsv" > "$T/vl2"
    check "kit.ps1 sync: the same ver lines kept" '[ -s "$T/vl1" ] && cmp -s "$T/vl1" "$T/vl2"'
    awk -F'\t' '$1 != "ver" && $1 !~ /:ver$/' "$HV/.config/agentkit/state.tsv" > "$T/st" && cp "$T/st" "$HV/.config/agentkit/state.tsv"
    touch -t 202001020304 "$HV/.claude/skills/vt"; kps sync >/dev/null 2>&1; kps list --json > "$T/v10.json" 2>/dev/null
    check "kit.ps1 sync with an old state.tsv: the time from each one's file, the same ids as unix/kit" '[ "$(vj "$T/v10.json" skill vt installed.claude.at)" -lt 1600000000 ] && [ "$(vj "$T/v10.json" skill vt installed.claude.id)" = "$(vj "$T/v9.json" skill vt installed.claude.id)" ] && [ "$(vj "$T/v10.json" rule vr installed.codex.id)" = "$(vj "$T/v9.json" rule vr installed.codex.id)" ]'
fi
echo "$pass $fail" > "$T/sub"
)
read pass fail < "$T/sub"

finish
