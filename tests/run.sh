#!/usr/bin/env bash
# End-to-end tests for the bash kit, in sections (tests/sh/<section>.sh). Each section runs in a throwaway HOME of its
# own, so your real ~/.claude is never touched and several sections run at once.
#   tests/run.sh                    every section (-j N: N at once; the default: one per core)
#   tests/run.sh <section>...       only those (tests/run.sh --list: the sections)
#   tests/run.sh --changed [<base>] the sections that test what changed since <base> (default: where this branch left
#                                   master), uncommitted changes too; tests/sections.txt says which
# The last line is always "kit: N passed, M failed".
set -u
HERE=$(cd "$(dirname "$0")" && pwd)

# (inside: one section, its output and "exit-code seconds" in a folder)
if [ "${1:-}" = --one ]; then
    s=$(date +%s); bash "$HERE/sh/$2.sh" > "$3/$2.out" 2>&1; rc=$?; t=$(( $(date +%s) - s ))
    echo "$rc $t" > "$3/$2.rc"
    r=$(awk '/^kit: [0-9]+ passed, [0-9]+ failed$/ { p = $2; f = $4 } END { if (p == "") print "stopped"; else if (f > 0) print f " failed"; else print "ok" }' "$3/$2.out")
    printf '  %-12s %5ss  %s\n' "$2" "$t" "$r"
    exit 0
fi

# the slowest first (measured), so the run is not left waiting on one started last
SLOW="place mcp context tools dir files list-json basics versions push-direct codex-block hook"
all() { ls "$HERE/sh" | sed -n 's/\.sh$//p'; }

# the functions a diff of unix/kit or windows/kit.ps1 touches: each hunk's old lines in the old file, new lines in the
# new one; a function is its "name() {" or "function Name" line to the next "}" at the start of a line (or that line
# alone when its braces close there); a line in none: "" (code outside any function)
HUNKS='
function regions(file, side,   n, name, open, line, o, c) {
    while ((getline line < file) > 0) {
        n++
        if (line ~ /^(function +[A-Za-z][A-Za-z0-9-]*|[A-Za-z_][A-Za-z0-9_]*\(\))/) {
            name = line; sub(/^function +/, "", name); sub(/[^A-Za-z0-9_-].*/, "", name)
            o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
            fn[side, n] = name; open = (o > c); continue
        }
        if (open) { fn[side, n] = name; if (line ~ /^\}/) open = 0 }
    }
    close(file)
}
BEGIN { regions(old, "o"); regions(new, "n") }
/^@@ / {
    split($2, a, ","); s = substr(a[1], 2) + 0; c = (2 in a) ? a[2] + 0 : 1
    for (i = s; i < s + c; i++) print f ":" fn["o", i]
    split($3, a, ","); s = substr(a[1], 2) + 0; c = (2 in a) ? a[2] + 0 : 1
    for (i = s; i < s + c; i++) print f ":" fn["n", i]
}'

# changed BASE: the sections for what changed since BASE, and why (on stderr)
changed() {
    local base=$1 root ks f k why
    root=$(cd "$HERE/.." && pwd)
    if [ -z "$base" ]; then base=$(git -C "$root" merge-base HEAD master 2>/dev/null || git -C "$root" merge-base HEAD origin/master 2>/dev/null) || { echo "--changed: 找不到 master（給一個 <base>）" >&2; return 1; }; fi
    git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "--changed: 沒有 $base 這個 commit" >&2; return 1; }
    # one key per changed file; per changed function in unix/kit and windows/kit.ps1 ("FILE:" for code outside one)
    ks=$( { git -C "$root" diff --name-only "$base" -- 2>/dev/null; git -C "$root" ls-files --others --exclude-standard 2>/dev/null; } | LC_ALL=C sort -u |
        while IFS= read -r f; do
            if [ "$f" = unix/kit ] || [ "$f" = windows/kit.ps1 ]; then
                git -C "$root" show "$base:$f" > "$O/old" 2>/dev/null || : > "$O/old"
                git -C "$root" diff -U0 "$base" -- "$f" 2>/dev/null | awk -v f="$f" -v old="$O/old" -v new="$root/$f" "$HUNKS" | LC_ALL=C sort -u
            else echo "$f"; fi
        done)
    [ -n "$ks" ] || { echo "--changed: 跟 $base 比沒有改東西" >&2; return 0; }
    printf '%s\n' "$ks" | awk -v all="$(all | tr '\n' ' ')" -v map="$HERE/sections.txt" '
    function glob(p) { gsub(/[.+^$(){}|\[\]]/, "\\\\&", p); gsub(/\*/, ".*", p); gsub(/\?/, ".", p); return "^" p "$" }
    function add(s, why) { if (s in ok && !(s in pick)) { pick[s] = why; order[++np] = s } }
    BEGIN {
        n = split(all, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1
        while ((getline l < map) > 0) {
            if (l ~ /^[ \t]*(#|$)/) continue
            if (l !~ /^[ \t]/) { i = index(l, " : "); cur = substr(l, 1, i - 1); l = substr(l, i + 3) }
            m = split(l, w, " "); for (j = 1; j <= m; j++) { pat[++np0] = w[j]; secs[np0] = cur }
        }
    }
    {
        k = $0; hit = 0; sec = ""
        if (k ~ /^tests\/sh\/[^\/]+\.sh$/) { s = k; sub(/^tests\/sh\//, "", s); sub(/\.sh$/, "", s); add(s, k); next }
        if (k ~ /^tests\/(ps\/|lib\.ps1$|run\.ps1$)/) next            # the other suite'"'"'s
        if (k ~ /^tests\/(lib\.sh|run\.sh|sections\.txt)$/ || k ~ /:$/) { everything = everything ? everything : k; next }
        for (i = 1; i <= np0; i++) if (pat[i] != "always" && k ~ glob(pat[i])) { hit = 1; m = split(secs[i], w, " "); for (j = 1; j <= m; j++) if (w[j] != "-") add(w[j], k) }
        if (!hit) everything = everything ? everything : k " (not in tests/sections.txt)"
    }
    END {
        if (everything != "") { print "every section: " everything > "/dev/stderr"; print "ALL"; exit }
        for (i = 1; i <= np0; i++) if (pat[i] == "always") { m = split(secs[i], w, " "); for (j = 1; j <= m; j++) add(w[j], "every change") }
        for (i = 1; i <= np; i++) { print order[i] " <- " pick[order[i]] > "/dev/stderr"; print order[i] }
    }'
}

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
sel=""; want_changed=""; base=""
while [ $# -gt 0 ]; do
    case $1 in
        -j) [ $# -ge 2 ] || usage; jobs=$2; shift 2;;
        -j[0-9]*) jobs=${1#-j}; shift;;
        --list) all; exit 0;;
        --changed) want_changed=1; shift; case ${1:-} in ""|-*) ;; *) [ -f "$HERE/sh/$1.sh" ] || { base=$1; shift; };; esac;;
        -h|--help|-*) usage;;
        *) [ -f "$HERE/sh/$1.sh" ] || { echo "沒有 $1 這個 section（tests/run.sh --list）" >&2; exit 2; }; sel="$sel $1"; shift;;
    esac
done
case $jobs in ''|*[!0-9]*|0) usage;; esac
O=$(mktemp -d); trap 'rm -rf "$O"' EXIT
if [ -n "$want_changed" ]; then
    c=$(changed "$base") || exit 2
    case " $c " in *" ALL "*) sel=$(all | tr '\n' ' ');; *) sel="$sel $c";; esac
    [ -n "$(echo $sel)" ] || { echo "kit: 0 passed, 0 failed"; exit 0; }
fi
[ -n "$(echo $sel)" ] || sel=$(all | tr '\n' ' ')
# each once, the slowest first
run=$(printf '%s\n' $sel | awk -v slow="$SLOW" 'BEGIN { n = split(slow, w, " ") } { in_sel[$0] = 1; rest[++m] = $0 }
    END { for (i = 1; i <= n; i++) if (w[i] in in_sel && !seen[w[i]]++) print w[i]; for (i = 1; i <= m; i++) if (!seen[rest[i]]++) print rest[i] }')

start=$(date +%s)
echo "kit: $(printf '%s\n' "$run" | wc -l | tr -d ' ') 個 section，同時跑 $jobs 個"
printf '%s\n' "$run" | xargs -P "$jobs" -I{} bash "$HERE/run.sh" --one {} "$O"

pass=0; fail=0
for s in $run; do
    p=$(awk '/^kit: [0-9]+ passed, [0-9]+ failed$/ { p = $2 } END { print p }' "$O/$s.out" 2>/dev/null)
    f=$(awk '/^kit: [0-9]+ passed, [0-9]+ failed$/ { f = $4 } END { print f }' "$O/$s.out" 2>/dev/null)
    awk -v s="$s" '/^kit: [0-9]+ passed, [0-9]+ failed$/ { next } /^FAIL: / { print "FAIL: [" s "] " substr($0, 7); next } { print "[" s "] " $0 }' "$O/$s.out" 2>/dev/null
    if [ -z "$p" ]; then
        echo "FAIL: [$s] the section stopped before its end (exit $(cut -d' ' -f1 "$O/$s.rc" 2>/dev/null))"; fail=$((fail+1))
    else pass=$((pass+p)); fail=$((fail+f)); fi
done
echo "slowest: $(for s in $run; do echo "$(cut -d' ' -f2 "$O/$s.rc" 2>/dev/null) $s"; done | sort -rn | head -n 5 | awk '{ printf "%s%s %ss", (NR > 1 ? ", " : ""), $2, $1 }'); all: $(( $(date +%s) - start ))s"
echo "kit: $pass passed, $fail failed"
[ $fail -eq 0 ]
