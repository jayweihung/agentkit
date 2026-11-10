# json.awk - read and edit a JSON file with POSIX awk only.
# Works with BSD awk (macOS), gawk, mawk and BusyBox awk. Run with LC_ALL=C.
#
#   awk -f json.awk -v ops=OPSFILE input.json > output.json
#   awk -f json.awk -v get=PATH input.json        # print the raw value at PATH
#
# Output is formatted like JSON.stringify(value, null, 2): 2-space indent,
# key order kept, strings copied byte for byte. A trailing newline is kept
# only if the input had one. An empty input file counts as {}.
#
# OPSFILE has one operation per line, fields separated by a TAB:
#   set     PATH  JSON     put JSON at PATH (creates missing objects)
#   del     PATH           remove PATH if it exists
#   addstr  PATH  STRING   append "STRING" to the array at PATH if missing
#   rmstr   PATH  STRING   remove "STRING" from the array at PATH
# PATH is keys joined by "." (keys must not contain "." or TAB).
# STRING is plain text; " and \ are escaped by json.awk.
#
# Exit status: 0 ok, 2 parse error (nothing is written to stdout).

BEGIN {
    RS = "\""
    ntok = 0; instr = 0; buf = ""; had_nl = 0; total = 0
}

{
    total += length($0) + 1
    if (!instr) {
        lex_outside($0)
        instr = 1; buf = ""; lastout = 1
    } else {
        lastout = 0
        buf = (buf == "" && !cont) ? $0 : buf $0
        if (odd_backslashes(buf)) {
            buf = buf "\""; cont = 1
        } else {
            tok[++ntok] = "\"" buf "\""; instr = 0; buf = ""; cont = 0
        }
    }
}

END {
    # The last outside segment is not followed by a quote; only a string
    # that never closed is an error.
    if (instr && !lastout) fail("unterminated string")
    if (ntok == 0) { tok[++ntok] = "{"; tok[++ntok] = "}" }
    pos = 1
    root = parse_value()
    if (pos <= ntok) fail("extra data after JSON")

    if (get != "") {
        n = find_path(root, get)
        if (n == 0) exit 1
        printf "%s\n", ser(n, "")
        exit 0
    }
    if (ops != "") apply_ops(ops)
    printf "%s", ser(root, "")
    if (had_nl) printf "\n"
}

function odd_backslashes(s,    n) {
    n = 0
    while (length(s) > n && substr(s, length(s) - n, 1) == "\\") n++
    return n % 2
}

function lex_outside(s,    i, c, lit) {
    lit = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "{" || c == "}" || c == "[" || c == "]" || c == ":" || c == ",") {
            if (lit != "") { tok[++ntok] = lit; lit = "" }
            tok[++ntok] = c
        } else if (c == " " || c == "\t" || c == "\r" || c == "\n") {
            if (lit != "") { tok[++ntok] = lit; lit = "" }
        } else {
            lit = lit c
        }
    }
    if (lit != "") tok[++ntok] = lit
    had_nl = (substr(s, length(s), 1) == "\n")
}

function fail(msg) {
    printf "json.awk: %s\n", msg > "/dev/stderr"
    failed = 1
    exit 2
}

# ---------- tree ----------
# T[n]  type: o (object) a (array) v (string, number, true, false, null)
# V[n]  raw text of a scalar
# N[n]  number of children; K[n,i] raw key (with quotes); C[n,i] child node
function new_node(t) { nn++; T[nn] = t; N[nn] = 0; return nn }

function parse_value(    t, n) {
    if (failed) exit 2
    if (pos > ntok) fail("unexpected end")
    t = tok[pos]
    if (t == "{") return parse_object()
    if (t == "[") return parse_array()
    if (t == "}" || t == "]" || t == ":" || t == ",") fail("unexpected " t)
    if (substr(t, 1, 1) != "\"" && t !~ /^(true|false|null|-?[0-9][0-9.eE+-]*)$/) fail("bad literal " t)
    n = new_node("v"); V[n] = t; pos++
    return n
}

function parse_object(    n, k) {
    n = new_node("o"); pos++
    if (tok[pos] == "}") { pos++; return n }
    while (1) {
        k = tok[pos]
        if (substr(k, 1, 1) != "\"") fail("expected key")
        pos++
        if (tok[pos] != ":") fail("expected :")
        pos++
        N[n]++; K[n, N[n]] = k; C[n, N[n]] = parse_value()
        if (tok[pos] == ",") { pos++; continue }
        if (tok[pos] == "}") { pos++; return n }
        fail("expected , or }")
    }
}

function parse_array(    n) {
    n = new_node("a"); pos++
    if (tok[pos] == "]") { pos++; return n }
    while (1) {
        N[n]++; C[n, N[n]] = parse_value()
        if (tok[pos] == ",") { pos++; continue }
        if (tok[pos] == "]") { pos++; return n }
        fail("expected , or ]")
    }
}

# ---------- serialize ----------
function ser(n, ind,    out, i, ind2) {
    if (T[n] == "v") return V[n]
    if (N[n] == 0) return (T[n] == "o") ? "{}" : "[]"
    ind2 = ind "  "
    out = (T[n] == "o") ? "{\n" : "[\n"
    for (i = 1; i <= N[n]; i++) {
        if (C[n, i] == 0) continue          # deleted
        if (out != "{\n" && out != "[\n") out = out ",\n"
        out = out ind2
        if (T[n] == "o") out = out K[n, i] ": "
        out = out ser(C[n, i], ind2)
    }
    if (out == "{\n") return "{}"
    if (out == "[\n") return "[]"
    return out "\n" ind ((T[n] == "o") ? "}" : "]")
}

# ---------- paths and operations ----------
function child(n, key,    i) {
    if (T[n] != "o") return 0
    for (i = 1; i <= N[n]; i++) if (C[n, i] != 0 && K[n, i] == "\"" key "\"") return i
    return 0
}

function find_path(n, path,    parts, cnt, i, j) {
    cnt = split(path, parts, ".")
    for (i = 1; i <= cnt; i++) {
        j = child(n, parts[i]); if (j == 0) return 0
        n = C[n, j]
    }
    return n
}

# Walk to the parent of PATH, creating objects on the way. Sets LASTKEY.
function make_parent(path,    parts, cnt, i, j, n, m) {
    cnt = split(path, parts, ".")
    n = root
    for (i = 1; i < cnt; i++) {
        if (T[n] != "o") fail("not an object at " parts[i])
        j = child(n, parts[i])
        if (j == 0) {
            m = new_node("o"); N[n]++; K[n, N[n]] = "\"" parts[i] "\""; C[n, N[n]] = m; n = m
        } else n = C[n, j]
    }
    if (T[n] != "o") fail("not an object at " parts[cnt])
    LASTKEY = parts[cnt]
    return n
}

function set_path(path, value_node,    p, j) {
    p = make_parent(path)
    j = child(p, LASTKEY)
    if (j) C[p, j] = value_node
    else { N[p]++; K[p, N[p]] = "\"" LASTKEY "\""; C[p, N[p]] = value_node }
}

function json_str(s,    i, c, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" || c == "\"") out = out "\\"
        out = out c
    }
    return "\"" out "\""
}

function parse_text(s,    save_tok, save_n, save_pos, i, n) {
    # parse a small JSON text given on an ops line
    for (i = 1; i <= ntok; i++) save_tok[i] = tok[i]
    save_n = ntok; save_pos = pos
    ntok = 0; lex_small(s); pos = 1
    n = parse_value()
    if (pos <= ntok) fail("extra data in value")
    for (i = 1; i <= save_n; i++) tok[i] = save_tok[i]
    ntok = save_n; pos = save_pos
    return n
}

function lex_small(s,    i, c, lit, str, esc) {
    lit = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") {
            if (lit != "") { tok[++ntok] = lit; lit = "" }
            str = "\""; i++
            while (i <= length(s)) {
                c = substr(s, i, 1); str = str c
                if (c == "\\") { i++; str = str substr(s, i, 1) }
                else if (c == "\"") break
                i++
            }
            tok[++ntok] = str
        } else if (c == "{" || c == "}" || c == "[" || c == "]" || c == ":" || c == ",") {
            if (lit != "") { tok[++ntok] = lit; lit = "" }
            tok[++ntok] = c
        } else if (c == " " || c == "\t" || c == "\r" || c == "\n") {
            if (lit != "") { tok[++ntok] = lit; lit = "" }
        } else lit = lit c
    }
    if (lit != "") tok[++ntok] = lit
}

function apply_ops(file,    line, f, cnt, n, p, j, a, i, s, found) {
    RS = "\n"      # ops file is line based (the JSON input used RS = quote)
    while ((getline line < file) > 0) {
        if (line == "") continue
        cnt = split(line, f, "\t")
        if (f[1] == "set") {
            set_path(f[2], parse_text(f[3]))
        } else if (f[1] == "del") {
            cnt = split(f[2], parts_d, ".")
            n = (cnt > 1) ? find_path(root, substr(f[2], 1, length(f[2]) - length(parts_d[cnt]) - 1)) : root
            if (n && (j = child(n, parts_d[cnt]))) C[n, j] = 0
        } else if (f[1] == "addstr" || f[1] == "rmstr") {
            s = json_str(f[3])
            a = find_path(root, f[2])
            if (a == 0) {
                if (f[1] == "rmstr") continue
                a = new_node("a"); set_path(f[2], a)
            }
            if (T[a] != "a") fail(f[2] " is not an array")
            found = 0
            for (i = 1; i <= N[a]; i++) if (C[a, i] && T[C[a, i]] == "v" && V[C[a, i]] == s) { found = i; break }
            if (f[1] == "addstr" && !found) { n = new_node("v"); V[n] = s; N[a]++; C[a, N[a]] = n }
            if (f[1] == "rmstr" && found) C[a, found] = 0
        } else fail("unknown op " f[1])
    }
    close(file)
}
