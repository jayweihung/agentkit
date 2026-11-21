#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# ---------- is Claude saving its transcript? (kit sync --hook under a fake claude started with a chosen environment) ----------
FC="$T/fake-claude"; mkdir -p "$FC" "$T/tch/.claude"
if [ "$(uname)" = Darwin ]; then   # ps -E shows no environment of Apple's own programs (bash, sh): a tiny one of our own
    printf '#include <stdlib.h>\nint main(int c, char **v) { return system(v[1]) == 0 ? 0 : 1; }\n' > "$FC/c.c"
    xcode-select -p >/dev/null 2>&1 && cc -o "$FC/claude" "$FC/c.c" 2>/dev/null
    fcl() { "$FC/claude" "$1"; }
else ln -s "$(command -v bash)" "$FC/claude"; fcl() { "$FC/claude" -c "$1; :"; }; fi   # (`; :`: it stays the parent)
tc() { ( unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE KIT_TRANSCRIPT_CHECK; export HOME="$T/tch" "$@"
         fcl "${HE:-} '$KIT' sync --hook" ); }   # HE: the hook's own environment
if [ -x "$FC/claude" ]; then
    out=$(tc); check "transcript: a normal claude: nothing said" '[ -z "$out" ]'
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1); rc=$?; printf '%s\n' "$out" > "$T/tc.json"
    check "transcript: claude started with CHILD_SESSION=1: warned, as JSON for Claude" '[ $rc -eq 0 ] && [ "$(jget "$T/tc.json" hookSpecificOutput.hookEventName)" = "\"SessionStart\"" ] && jget "$T/tc.json" systemMessage | grep -q /resume'
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1)
    check "transcript: ... and FORCE_SESSION_PERSISTENCE=1 too: nothing said" '[ -z "$out" ]'
    out=$(HE=CLAUDE_CODE_CHILD_SESSION=1 tc)
    check "transcript: the hook's own CHILD_SESSION=1 (Claude gives it to every hook) is not looked at" '[ -z "$out" ]'
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1 KIT_TRANSCRIPT_CHECK=0); check "transcript: KIT_TRANSCRIPT_CHECK=0: nothing said" '[ -z "$out" ]'
    printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/transcript-check.sh"}]}]}}\n' > "$T/tch/.claude/settings.json"
    out=$(tc CLAUDE_CODE_CHILD_SESSION=1); check "transcript: your own transcript-check hook: kit says nothing (no second warning)" '[ -z "$out" ]'
else echo "(transcript check: skipped, no C compiler on this Mac)"; fi

finish
