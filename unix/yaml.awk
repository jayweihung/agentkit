# yaml.awk - read the small YAML subset kit uses, with POSIX awk only.
#
#   awk -f yaml.awk file.yaml
#
# Prints one line per value:  path<TAB>value
# List items print as        path[]<TAB>value
#
# Supported:
#   key: value              scalar (quotes "..." or '...' are removed)
#   key: [a, b, "c d"]      flow list on one line
#   key:                    then indented "key: ..." lines (a map)
#   key:                    then indented "- item" lines (a list)
#   key: |   or   key: >-  then more-indented lines: a block of text, printed
#                           joined into one line with spaces (kit only needs one line)
#   # comment               whole-line comments and " # comment" at the end
# Indent with spaces. Anything else is an error (exit 2).
#
# With -v frontmatter=1 only the block between the first two "---" lines is read
# (agent files: YAML on top, prompt below).

BEGIN { depth = 0; fm_state = frontmatter ? 0 : 1 }

{
    line = $0
    sub(/\r$/, "", line)
    if (in_block) {
        match(line, /^ */)
        if (line ~ /^[ \t]*$/ || RLENGTH > block_ind) {
            t = trim(line)
            if (t != "") block_text = block_text (block_text == "" ? "" : " ") t
            next
        }
        end_block()
    }
    if (frontmatter) {
        if (line == "---") { fm_state++; if (fm_state == 2) exit; next }
        if (fm_state == 0) { if (line ~ /^[ \t]*$/) next; err("expected --- at top") }
    }
    if (line ~ /^[ \t]*(#.*)?$/) next
    line = strip_comment(line)
    match(line, /^ */); ind = RLENGTH
    text = substr(line, ind + 1)

    # pop to the parent of this indentation
    while (depth > 0 && ind <= IND[depth]) depth--

    if (substr(text, 1, 2) == "- " || text == "-") {
        item = (text == "-") ? "" : substr(text, 3)
        out(path_at(depth) "[]", unquote(trim(item)))
        next
    }
    c = index(text, ":")
    if (c == 0) err("expected key: value")
    key = trim(substr(text, 1, c - 1))
    val = trim(substr(text, c + 1))
    p = (depth > 0 ? path_at(depth) "." : "") key
    if (val == "") {
        depth++; IND[depth] = ind; KEY[depth] = p
    } else if (val ~ /^[|>][-+]?[0-9]?$/) {
        in_block = 1; block_ind = ind; block_path = p; block_text = ""
    } else if (substr(val, 1, 1) == "[") {
        if (substr(val, length(val), 1) != "]") err("list must end with ]")
        flow_list(p, substr(val, 2, length(val) - 2))
    } else {
        out(p, unquote(val))
    }
}

END { if (failed) exit 2; if (in_block) end_block() }

function end_block() { out(block_path, block_text); in_block = 0 }

function path_at(d) { return d > 0 ? KEY[d] : "" }

function out(p, v) { printf "%s\t%s\n", p, v }

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function unquote(s) {
    if (length(s) >= 2 && ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") || (substr(s, 1, 1) == "'" && substr(s, length(s), 1) == "'")))
        return substr(s, 2, length(s) - 2)
    return s
}

# remove " # comment" that is not inside quotes
function strip_comment(s,    i, c, q) {
    q = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = "" ; continue }
        if (c == "\"" || c == "'") { q = c; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) == " " || substr(s, i - 1, 1) == "\t"))
            return substr(s, 1, i - 1)
    }
    return s
}

function flow_list(p, body,    i, c, q, cur, n) {
    q = ""; cur = ""; n = 0
    if (trim(body) == "") return
    for (i = 1; i <= length(body); i++) {
        c = substr(body, i, 1)
        if (q != "") { cur = cur c; if (c == q) q = ""; continue }
        if (c == "\"" || c == "'") { q = c; cur = cur c; continue }
        if (c == ",") { out(p "[]", unquote(trim(cur))); cur = ""; n++; continue }
        cur = cur c
    }
    if (trim(cur) != "") out(p "[]", unquote(trim(cur)))
}

function err(msg) {
    printf "yaml: %s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"
    failed = 1
    exit 2
}
