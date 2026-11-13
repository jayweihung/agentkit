# mcp.awk - kit's MCP servers: read a pasted setup, take the secrets out, write kit's yaml; find the package.
# POSIX awk only (BSD awk, gawk, mawk, BusyBox awk). Run with LC_ALL=C. windows/kit.ps1 does the same.
#
#   awk -f json.awk -v leaves=1 paste.json | awk -f mcp.awk -v mode=json   ({"mcpServers": {...}}, {"x": {...}}, {...})
#   awk -f mcp.awk -v mode=cmd paste.txt      (claude mcp add ... / codex mcp add ... lines)
#   awk -f mcp.awk -v mode=toml paste.toml    (Codex: [mcp_servers.x])
#   awk -f yaml.awk x.yaml | awk -f mcp.awk -v mode=yaml -v name=x    (an MCP yaml kit has)
#   -v name=NAME  kit's name (with several servers in the paste: the one to take)
#   -v pin=VER    the version its package gets (kit looked it up: npm view, PyPI)
# Prints, a TAB between fields:
#   E code message      the paste cannot be used (then nothing else, only L lines)
#   L name              (with E several_servers or not_found) the servers in the paste
#   N name              kit's name for it
#   T type              stdio, http or sse
#   Y line              the yaml, a line at a time
#   X where var         a secret: now ${var} (mode yaml: a value that looks like one, still written as it is)
#   V var               an environment variable it needs (${var} without a default)
#   W message           a warning
#   R tool              a program it needs (node, uv, python, docker)
#   G spec              (before P, npm) the range or tag the paste asked for (^1, next): kit looks up the newest
#                       version that matches it (npm view "package@spec" version) and pins that
#   P kind package version argno bin first bad
#                       its package: kind npm (npx) or pip (uvx, the package with its [extras]); version empty: not
#                       pinned; argno: the argument
#                       naming it; bin: the program to run (empty: the package's own); first: the server's own
#                       arguments start there; bad: why kit does not install it (it is still downloaded at start)
# An MCP yaml kit has (mode yaml) may name, in a top-level not_secret: [args[2], url], fields that are not secrets
# (where, as the X lines name them): kit leaves them as they are and gives no X line for them (kit check passes).

BEGIN { NS = 0; ERRC = ""; NL = 0 }
{ sub(/\r$/, ""); LN[++NL] = $0 }

END {
    if (mode == "json") load_json()
    else if (mode == "cmd") load_cmd()
    else if (mode == "toml") load_toml()
    else if (mode == "yaml") load_yaml()
    if (ERRC != "") { print "E\t" ERRC "\t" ERRM; exit }
    if (NS == 0) fail("bad_config", "貼上的內容裡找不到 MCP server 的設定")
    J = 0
    if (NS > 1) {
        if (name == "") { print "E\tseveral_servers\t貼上的設定有 " NS " 個 MCP server，請在 kit new mcp 後面寫要哪一個的名字"; lst(); exit }
        for (j = 1; j <= NS; j++) if (SNAME[j] == name || norm(SNAME[j]) == name) J = j
        if (!J) { print "E\tnot_found\t貼上的設定裡沒有 " name; lst(); exit }
    } else J = 1
    N = name; if (N == "") N = norm(SNAME[J])
    if (N == "") fail("no_name", "這個設定沒有名字：請寫成 kit new mcp <名字> --config …")
    if (N !~ /^[a-z0-9][a-z0-9-]*$/) fail("bad_name", "名字只能用小寫英文、數字和 -：" N)
    if (ERRC != "") { print "E\t" ERRC "\t" ERRM; exit }
    SV = toupper(N); gsub(/[^A-Z0-9]+/, "_", SV); if (SV ~ /^[0-9]/) SV = "MCP_" SV   # (a variable never starts with a digit)
    finish(J)
    if (ERRC != "") { print "E\t" ERRC "\t" ERRM; exit }
    printf "%s", OUT
}

function fail(c, m) { if (ERRC == "") { ERRC = c; ERRM = m } }
function lst(   j) { for (j = 1; j <= NS; j++) print "L\t" SNAME[j] }
function emit(s) { OUT = OUT s "\n" }
function norm(s) { s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); gsub(/^-+|-+$/, "", s); return s }

# ---------- the servers, as read ----------
function srv(nm,   j) {
    if (nm in SI) return SI[nm]
    j = ++NS; SI[nm] = j; SNAME[j] = nm; AN[j] = 0; EN[j] = 0; HN[j] = 0; CN[j] = 0; WN[j] = 0
    return j
}
function setenv(j, k, v,   i) {
    if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { wn(j, "env 的 " k " 不是環境變數的名字，略過"); return }
    for (i = 1; i <= EN[j]; i++) if (EK[j, i] == k) { EV[j, i] = v; return }
    EN[j]++; EK[j, EN[j]] = k; EV[j, EN[j]] = v
}
function sethdr(j, k, v,   i) {
    sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
    if (k !~ /^[A-Za-z0-9_-]+$/) { wn(j, "header " k " 的名字 kit 寫不下，略過"); return }
    for (i = 1; i <= HN[j]; i++) if (tolower(HK[j, i]) == tolower(k)) { HV[j, i] = v; return }
    HN[j]++; HK[j, HN[j]] = k; HV[j, HN[j]] = v
}
function settype(j, t,   l) {
    l = tolower(t)
    if (l == "stdio" || l == "http" || l == "sse") F[j, "type"] = l
    else if (l == "streamable-http" || l == "streamable_http" || l == "streamablehttp" || l == "https") F[j, "type"] = "http"
    else fail("bad_config", "不認得的 type：" t "（只能是 stdio、http、sse）")
}
function wn(j, w) { if (!((j, w) in WS)) { WS[j, w] = 1; WN[j]++; WL[j, WN[j]] = w } }
function ctl(s) { if (s ~ /[\001-\037\177]/) fail("bad_config", "值裡有控制字元（換行、TAB 這些），kit 不收") ; return s }

# ---------- JSON (json.awk leaves: keys TAB-joined, TAB, raw value) ----------
function load_json(   i, n, K, top, form, j, nm, p) {
    form = ""
    for (i = 1; i <= NL; i++) {
        n = split(LN[i], K, "\t"); if (n < 2) continue
        if (K[1] == "mcpServers" || K[1] == "servers" || K[1] == "mcp_servers") form = "wrap"
        else if (form == "" && K[1] ~ /^(command|url|type|args|env|headers|serverUrl|httpUrl|transport)$/) form = "bare"
    }
    if (form == "") form = "map"
    for (i = 1; i <= NL; i++) {
        n = split(LN[i], K, "\t"); if (n < 2) continue
        if (form == "wrap") { if (K[1] !~ /^(mcpServers|servers|mcp_servers)$/ || n < 4) continue; nm = K[2]; p = 3 }
        else if (form == "map") { if (n < 3) continue; nm = K[1]; p = 2 }
        else { nm = ""; p = 1 }
        j = srv(nm)
        jfield(j, K, p, n)
    }
}
function jfield(j, K, p, n,   f, raw, v, d) {
    f = K[p]; raw = K[n]; d = n - p        # d: keys under the field
    if (raw ~ /^[\[{]/) { if (f !~ /^(args|env|headers|command)$/) wn(j, "略過 " f "（kit 不帶這個設定）"); return }
    v = jval(raw)
    if (f == "type" || f == "transport") { if (d == 1) settype(j, v) }
    else if (f == "command") { if (d == 1) F[j, "command"] = v; else if (d == 2) { CA[j, K[p + 1] + 0] = v; if (K[p + 1] + 0 > CN[j]) CN[j] = K[p + 1] + 0 } }
    else if (f == "args") { if (d == 2) { A[j, K[p + 1] + 0] = v; if (K[p + 1] + 0 > AN[j]) AN[j] = K[p + 1] + 0 } }
    else if (f == "env") { if (d == 2) setenv(j, K[p + 1], v) }
    else if (f == "headers") { if (d == 2) sethdr(j, K[p + 1], v) }
    else if (f == "url" || f == "serverUrl" || f == "httpUrl") { if (d == 1) F[j, "url"] = v }
    else if (f == "description") { if (d == 1) F[j, "description"] = v }
    else if (f == "disabled" && v == "true") wn(j, "原本是停用的（disabled），kit 照樣帶進來")
    else wn(j, "略過 " f "（kit 不帶這個設定）")
}
function jval(raw) {
    if (substr(raw, 1, 1) != "\"") return raw == "null" ? "" : raw
    return ctl(junq(substr(raw, 2, length(raw) - 2)))
}
function hexv(s,   i, n) { n = 0; for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1; return n }
function utf8(n) {
    if (n < 128) return sprintf("%c", n)
    if (n < 2048) return sprintf("%c%c", 192 + int(n / 64), 128 + n % 64)
    if (n < 65536) return sprintf("%c%c%c", 224 + int(n / 4096), 128 + int(n / 64) % 64, 128 + n % 64)
    return sprintf("%c%c%c%c", 240 + int(n / 262144), 128 + int(n / 4096) % 64, 128 + int(n / 64) % 64, 128 + n % 64)
}
function junq(s,   o, i, c, n, lo) {
    o = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c != "\\") { o = o c; continue }
        c = substr(s, ++i, 1)
        if (c == "u") {
            n = hexv(substr(s, i + 1, 4)); i += 4
            if (n >= 55296 && n < 56320 && substr(s, i + 1, 2) == "\\u") { lo = hexv(substr(s, i + 3, 4)); n = 65536 + (n - 55296) * 1024 + (lo - 56320); i += 6 }
            o = o (n < 32 ? "\001" : utf8(n))
        } else if (c == "n" || c == "r" || c == "t" || c == "b" || c == "f") o = o "\001"
        else o = o c
    }
    return o
}

# ---------- claude mcp add / codex mcp add lines ----------
function load_cmd(   i, l, e) {
    l = ""
    for (i = 1; i <= NL; i++) {
        e = LN[i]; sub(/[ \t]+$/, "", e)
        if (e ~ /(\\|`|\^)$/) { l = l substr(e, 1, length(e) - 1) " "; continue }
        l = l e
        if (l ~ /^[ \t]*(#.*)?$/ || l ~ /^[ \t]*(\$|>|PS[^>]*>)[ \t]*$/) { l = ""; continue }
        cmdline(l); l = ""
        if (ERRC != "") return
    }
    if (l != "") cmdline(l)
}
function dollar(s, i,   r) {   # at a $: sets DV (what it means) and DI (where to go on)
    r = substr(s, i)
    if (r ~ /^\$\(/) { fail("bad_config", "不接受 $( ) 指令替換"); DV = ""; DI = length(s) + 1; return }
    if (match(r, /^\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}/)) { DV = substr(r, 1, RLENGTH); DI = i + RLENGTH; return }
    if (match(r, /^\$env:[A-Za-z_][A-Za-z0-9_]*/)) { DV = "${" substr(r, 6, RLENGTH - 5) "}"; DI = i + RLENGTH; return }
    if (match(r, /^\$[A-Za-z_][A-Za-z0-9_]*/)) { DV = "${" substr(r, 2, RLENGTH - 1) "}"; DI = i + RLENGTH; return }
    DV = "$"; DI = i + 1
}
function tokenize(s,   i, c, w, inw, j, n) {
    TN = 0; w = ""; inw = 0; n = length(s)
    for (i = 1; i <= n; ) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t") { if (inw) { T[++TN] = w; w = ""; inw = 0 }; i++; continue }
        inw = 1
        if (c == "'") {
            j = index(substr(s, i + 1), "'"); if (!j) { fail("bad_config", "引號沒有關好"); return }
            w = w substr(s, i + 1, j - 1); i += j + 1; continue
        }
        if (c == "\"") {
            i++
            while (i <= n && (c = substr(s, i, 1)) != "\"") {
                if (c == "\\" && index("\"\\$`", substr(s, i + 1, 1))) { w = w substr(s, i + 1, 1); i += 2; continue }
                if (c == "`") { fail("bad_config", "不接受 ` 指令替換"); return }
                if (c == "$") { dollar(s, i); w = w DV; i = DI; continue }
                w = w c; i++
            }
            if (i > n) { fail("bad_config", "引號沒有關好"); return }
            i++; continue
        }
        if (c == "\\" && index(" \"'\\$", substr(s, i + 1, 1))) { w = w substr(s, i + 1, 1); i += 2; continue }
        if (c == "`") { fail("bad_config", "不接受 ` 指令替換"); return }
        if (c == "$") { dollar(s, i); w = w DV; i = DI; continue }
        if (c == "%" && match(substr(s, i), /^%[A-Za-z_][A-Za-z0-9_]*%/)) { w = w "${" substr(s, i + 1, RLENGTH - 2) "}"; i += RLENGTH; continue }
        if (index(";&|<>()", c)) { fail("bad_config", "只接受 claude mcp add 或 codex mcp add（不接受 ; & | < > 這些）"); return }
        w = w c; i++
    }
    if (inw) T[++TN] = w
}
function cmdline(s,   p, prog) {
    tokenize(s); if (ERRC != "" || TN == 0) return
    p = 1
    if (T[p] ~ /^(\$|>)$/) p++
    prog = T[p]; sub(/^.*[\/\\]/, "", prog); sub(/\.(exe|cmd)$/, "", prog)
    if ((prog != "claude" && prog != "codex") || T[p + 1] != "mcp") { fail("bad_config", "看不懂貼上的內容：只接受 JSON、Codex 的 config.toml、claude mcp add 或 codex mcp add"); return }
    if (T[p + 2] == "add-json") { fail("bad_config", "claude mcp add-json：請直接貼它的 JSON（存成檔案）"); return }
    if (T[p + 2] != "add") { fail("bad_config", "只接受 " prog " mcp add"); return }
    if (prog == "claude") claude_add(p + 3); else codex_add(p + 3)
}
function opt(t) { OV = ""; OH = 0; OO = t; if (t ~ /^--[^=]*=/) { OV = substr(t, index(t, "=") + 1); OO = substr(t, 1, index(t, "=") - 1); OH = 1 } }
function kv_env(j, s,   e) { e = index(s, "="); if (!e) { fail("bad_config", "--env 要寫成 名字=值"); return }; setenv(j, substr(s, 1, e - 1), substr(s, e + 1)) }
function kv_hdr(j, s,   e) { e = index(s, ":"); if (!e) { fail("bad_config", "--header 要寫成 \"名字: 值\""); return }; sethdr(j, substr(s, 1, e - 1), substr(s, e + 1)) }
function claude_add(p,   t, np, P, j, i, tr, nl, L) {
    np = 0; tr = ""; j = 0; NE2 = 0; NH2 = 0
    for (; p <= TN; p++) {
        t = T[p]
        if (t == "--") { p++; break }
        # its options anywhere before -- (after the program: only its own, the rest are the program's)
        if (t ~ /^-/) opt(t)
        if (t ~ /^-/ && (np < 2 || OO ~ /^(-t|--transport|-s|--scope|-e|--env|-H|--header)$/)) {
            if (OO == "-t" || OO == "--transport") tr = OH ? OV : T[++p]
            else if (OO == "-s" || OO == "--scope") { if (!OH) p++ }
            else if (OO == "-e" || OO == "--env") { if (OH) PE[++NE2] = OV; else while (p < TN && T[p + 1] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) PE[++NE2] = T[++p] }
            else if (OO == "-H" || OO == "--header") { if (OH) PH[++NH2] = OV; else while (p < TN && T[p + 1] ~ /^[A-Za-z0-9_-]+:/) PH[++NH2] = T[++p] }
            else if (OO == "--client-id" || OO == "--callback-port") { if (!OH) p++; PW = PW OO " " }
            else if (OO == "--client-secret") PW = PW OO " "
            else { fail("bad_config", "claude mcp add 的 " OO " kit 不認得"); return }
            continue
        }
        P[++np] = t
    }
    nl = 0; for (i = 2; i <= np; i++) L[++nl] = P[i]
    for (; p <= TN; p++) L[++nl] = T[p]
    if (np < 1 || nl < 1) { fail("bad_config", "claude mcp add 要有名字和要跑的程式（或網址）"); return }
    j = srv(P[1])
    for (i = 1; i <= NE2; i++) kv_env(j, PE[i])
    for (i = 1; i <= NH2; i++) kv_hdr(j, PH[i])
    if (PW != "") { wn(j, "略過 " PW "（OAuth 的設定 kit 不帶，第一次連線時 Claude 會自己問）"); PW = "" }
    if (tr != "") settype(j, tr); else if (L[1] ~ /^https?:\/\//) F[j, "type"] = "http"
    if (F[j, "type"] == "http" || F[j, "type"] == "sse") { F[j, "url"] = L[1]; if (nl > 1) wn(j, "網址後面多的參數略過") }
    else { F[j, "command"] = L[1]; for (i = 2; i <= nl; i++) A[j, ++AN[j]] = L[i] }
}
function codex_add(p,   t, j, nm, i, url, bv, NE3, E3) {
    nm = ""; url = ""; bv = ""; NE3 = 0
    for (; p <= TN; p++) {
        t = T[p]
        if (t == "--") { p++; break }
        if (t ~ /^-/) {
            opt(t)
            if (OO == "--env") E3[++NE3] = OH ? OV : T[++p]
            else if (OO == "--url") url = OH ? OV : T[++p]
            else if (OO == "--bearer-token-env-var") bv = OH ? OV : T[++p]
            else { fail("bad_config", "codex mcp add 的 " OO " kit 不認得"); return }
            continue
        }
        if (nm == "") { nm = t; continue }
        break
    }
    if (nm == "") { fail("bad_config", "codex mcp add 要有名字"); return }
    j = srv(nm)
    for (i = 1; i <= NE3; i++) kv_env(j, E3[i])
    if (url != "") {
        F[j, "type"] = "http"; F[j, "url"] = url
        if (bv != "") sethdr(j, "Authorization", "Bearer ${" bv "}")
        if (p <= TN) wn(j, "網址後面多的參數略過")
        return
    }
    if (p > TN) { fail("bad_config", "codex mcp add 要有 -- 後面要跑的程式（或 --url）"); return }
    F[j, "command"] = T[p++]
    for (; p <= TN; p++) A[j, ++AN[j]] = T[p]
}

# ---------- Codex config.toml ----------
function load_toml(   i, c, k, n, K, tbl, TK, tn) {
    S = ""; for (i = 1; i <= NL; i++) S = S LN[i] "\n"
    P = 1; tn = 0
    while (P <= length(S)) {
        tws(); if (P > length(S)) break
        c = substr(S, P, 1)
        if (c == "\n") { P++; continue }
        if (c == "#") { teol(); continue }
        if (c == "[") {
            P++; if (substr(S, P, 1) == "[") { fail("bad_config", "config.toml 的 [[ ]] kit 看不懂"); return }
            tn = tkeys(TK); tws(); if (substr(S, P, 1) != "]") { fail("bad_config", "config.toml 的 [ ] 沒寫好"); return }
            P++; teol(); continue
        }
        n = tkeys(K); tws()
        if (substr(S, P, 1) != "=") { fail("bad_config", "config.toml 看不懂（要是 名字 = 值）"); return }
        P++; tws(); tval(); if (ERRC != "") return
        for (i = n; i >= 1; i--) K[i + tn] = K[i]
        for (i = 1; i <= tn; i++) K[i] = TK[i]
        tassign(K, n + tn)
        teol()
    }
}
function tws() { while (P <= length(S) && index(" \t\r", substr(S, P, 1))) P++ }
function teol() { while (P <= length(S) && substr(S, P, 1) != "\n") P++ }
function tgap() { while (P <= length(S)) { if (index(" \t\r\n,", substr(S, P, 1))) P++; else if (substr(S, P, 1) == "#") teol(); else break } }
function tkeys(K,   n, c) {
    n = 0
    while (1) {
        tws(); c = substr(S, P, 1)
        if (c == "\"" || c == "'") K[++n] = tstr()
        else if (match(substr(S, P), /^[A-Za-z0-9_-]+/)) { K[++n] = substr(S, P, RLENGTH); P += RLENGTH }
        else return n
        tws(); if (substr(S, P, 1) != ".") return n
        P++
    }
}
function tstr(   q, o, c, n) {
    q = substr(S, P, 1); P++; o = ""
    if (substr(S, P, 2) == q q) { fail("bad_config", "config.toml 的多行字串 kit 看不懂"); return "" }
    while (P <= length(S)) {
        c = substr(S, P, 1)
        if (c == q) { P++; return ctl(o) }
        if (c == "\n") break
        if (q == "\"" && c == "\\") {
            c = substr(S, ++P, 1)
            if (c == "u" || c == "U") { n = (c == "u") ? 4 : 8; o = o utf8(hexv(substr(S, P + 1, n))); P += n + 1; continue }
            if (index("nrtbf", c)) o = o "\001"; else o = o c
            P++; continue
        }
        o = o c; P++
    }
    fail("bad_config", "config.toml 的引號沒有關好"); return ""
}
function tscalar(   c) {
    c = substr(S, P, 1)
    if (c == "\"" || c == "'") return tstr()
    if (match(substr(S, P), /^[A-Za-z0-9_.:+-]+/)) { c = substr(S, P, RLENGTH); P += RLENGTH; return c }
    fail("bad_config", "config.toml 有 kit 看不懂的值"); return ""
}
function tval(   c, k) {   # VT: s (VS), a (VN, VI[]), t (VN, VK[], VV[])
    c = substr(S, P, 1); VN = 0
    if (c == "[") {
        VT = "a"; P++
        while (1) { tgap(); if (substr(S, P, 1) == "]") { P++; return }; if (P > length(S) || ERRC != "") { fail("bad_config", "config.toml 的 [ ] 沒寫好"); return }; VI[++VN] = tscalar() }
    }
    if (c == "{") {
        VT = "t"; P++
        while (1) {
            tgap(); if (substr(S, P, 1) == "}") { P++; return }
            if (P > length(S) || ERRC != "") { fail("bad_config", "config.toml 的 { } 沒寫好"); return }
            tkeys(TK2); k = TK2[1]; tws(); if (substr(S, P, 1) != "=") { fail("bad_config", "config.toml 的 { } 沒寫好"); return }
            P++; tws(); VK[++VN] = k; VV[VN] = tscalar()
        }
    }
    VT = "s"; VS = tscalar()
}
function tassign(K, n,   j, f, i) {
    if (K[1] != "mcp_servers" || n < 3) return
    j = srv(K[2]); f = K[3]
    if (n == 4 && VT == "s") { if (f == "env") setenv(j, K[4], VS); else if (f == "http_headers") sethdr(j, K[4], VS); else if (f == "env_http_headers") sethdr(j, K[4], "${" VS "}"); else wn(j, "略過 " f "（kit 不帶這個設定）"); return }
    if (n != 3) return
    if (f == "command" && VT == "s") F[j, "command"] = VS
    else if (f == "args" && VT == "a") for (i = 1; i <= VN; i++) A[j, ++AN[j]] = VI[i]
    else if (f == "url" && VT == "s") F[j, "url"] = VS
    else if (f == "env" && VT == "t") for (i = 1; i <= VN; i++) setenv(j, VK[i], VV[i])
    else if (f == "env_vars" && VT == "a") for (i = 1; i <= VN; i++) setenv(j, VI[i], "${" VI[i] "}")
    else if (f == "http_headers" && VT == "t") for (i = 1; i <= VN; i++) sethdr(j, VK[i], VV[i])
    else if (f == "env_http_headers" && VT == "t") for (i = 1; i <= VN; i++) sethdr(j, VK[i], "${" VV[i] "}")
    else if (f == "bearer_token_env_var" && VT == "s") sethdr(j, "Authorization", "Bearer ${" VS "}")
    else if (f == "enabled" && VS == "false") wn(j, "原本是停用的（enabled = false），kit 照樣帶進來")
    else wn(j, "略過 " f "（kit 不帶這個設定）")
}

# ---------- a yaml kit has (yaml.awk lines) ----------
function load_yaml(   i, e, k, v, j) {
    j = srv(name)
    for (i = 1; i <= NL; i++) {
        e = index(LN[i], "\t"); if (!e) continue
        k = substr(LN[i], 1, e - 1); v = substr(LN[i], e + 1)
        if (k == "args[]") A[j, ++AN[j]] = v
        else if (k ~ /^env\./) { EN[j]++; EK[j, EN[j]] = substr(k, 5); EV[j, EN[j]] = v }
        else if (k ~ /^headers\./) { HN[j]++; HK[j, HN[j]] = substr(k, 9); HV[j, HN[j]] = v }
        else if (k == "type") F[j, "type"] = v
        else if (k == "command" || k == "url" || k == "description") F[j, k] = v
        else if (k == "not_secret[]" || k == "not_secret") NOTSEC[v] = 1
    }
}

# ---------- secrets ----------
function sec_name(k,   s, i, c, n, Q, p) {   # a name that holds a secret: API_KEY, apiKey, X-Auth-Token, PAT, DB_PASS ...
    s = ""
    for (i = 1; i <= length(k); i++) { c = substr(k, i, 1); if (c ~ /[A-Z]/ && i > 1 && substr(k, i - 1, 1) ~ /[a-z0-9]/) s = s "_"; s = s c }
    n = split(toupper(s), Q, /[^A-Z0-9]+/)
    for (i = 1; i <= n; i++) {
        p = Q[i]
        if (p ~ /KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|CREDENTIAL|COOKIE|SESSION/ || p ~ /^(PAT|PASS|PWD|PW)$/) return 1
        if (p ~ /AUTH/ && p != "AUTHOR" && p != "AUTHORS") return 1
    }
    return 0
}
function sec_plain(v) {   # a value that is not a secret, whatever its name: empty, ${VAR}, yes/no, a number, a path
    return v == "" || index(v, "${") > 0 || tolower(v) ~ /^(true|false|yes|no|on|off|null|none)$/ || v ~ /^[0-9][0-9.]*$/ || v ~ /^(\/|~\/|\.\/|\.\.\/|[A-Za-z]:[\\\/])/ || v ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//
}
function sec_token(v,   n, t) {   # a value that looks like a token by itself
    if (index(v, "${") || v !~ /^[A-Za-z0-9_+=\/.-]+$/) return 0
    n = length(v)
    if (match(v, /^(sk-|sk_live_|sk_test_|rk_live_|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xox[abprs]-|AKIA|ASIA|AIza|eyJ)/) && n - RLENGTH >= 8) return 1
    # long and random: upper and lower case and digits, mixed up (words are not: AcmeCorpProduction2024 is 7 runs in 22)
    if (n >= 20 && substr(v, 1, 1) != "/" && v ~ /[A-Z]/ && v ~ /[a-z]/ && v ~ /[0-9]/ && runs(v) * 5 >= n * 2) { t = v; if (gsub(/[._\/-]/, "", t) <= 3) return 1 }
    if (n >= 32 && v ~ /^[0-9A-Fa-f]+$/ && v ~ /[0-9]/ && v ~ /[A-Fa-f]/) return 1
    return 0
}
function runs(v,   i, c, k, p, r) {   # how many runs of one kind of character (upper, lower, digit, other) v has
    r = 0; p = ""
    for (i = 1; i <= length(v); i++) {
        c = substr(v, i, 1); k = (c ~ /[A-Z]/) ? "u" : (c ~ /[a-z]/) ? "l" : (c ~ /[0-9]/) ? "d" : "o"
        if (k != p) r++
        p = k
    }
    return r
}
function vname(k) { sub(/^-+/, "", k); k = toupper(k); gsub(/[^A-Z0-9]+/, "_", k); gsub(/^_+|_+$/, "", k); return k }
function newvar(base,   v, i) {
    v = base; i = 2
    while (v in USED) v = base "_" i++
    USED[v] = 1; return v
}
function secret(where, base,   v) { v = newvar(base); if (!(where in NOTSEC)) emit("X\t" where "\t" v); return v }
function defaults(v, where,   o, r, e, nm, d) {   # ${VAR:-default} with a secret as the default -> ${VAR} (an X line)
    o = ""
    while (match(v, /\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}/)) {
        r = substr(v, RSTART, RLENGTH); o = o substr(v, 1, RSTART - 1); v = substr(v, RSTART + RLENGTH)
        e = index(r, ":-"); nm = substr(r, 3, e - 3); d = substr(r, e + 2, length(r) - e - 2)
        if ((sec_name(nm) && !sec_plain(d)) || sec_token(d)) {
            r = "${" nm "}"; if (!(where in NOTSEC)) emit("X\t" where "\t" nm)
        }
        o = o r
    }
    return o v
}
function used_vars(s,   r) {
    while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*/)) { r = substr(s, RSTART + 2, RLENGTH - 2); USED[r] = 1; s = substr(s, RSTART + RLENGTH) }
}
function url_strip(u, where,   sch, rest, i, q, hq, frag, auth, path, at, ui, c, pw, n, Q, k, v, out) {
    if (!match(u, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//)) return u
    sch = substr(u, 1, RLENGTH); rest = substr(u, RLENGTH + 1)
    frag = ""; i = index(rest, "#"); if (i) { frag = substr(rest, i); rest = substr(rest, 1, i - 1) }
    q = ""; hq = 0; i = index(rest, "?"); if (i) { q = substr(rest, i + 1); rest = substr(rest, 1, i - 1); hq = 1 }
    i = index(rest, "/"); if (i) { auth = substr(rest, 1, i - 1); path = substr(rest, i) } else { auth = rest; path = "" }
    at = 0; for (i = length(auth); i > 0; i--) if (substr(auth, i, 1) == "@") { at = i; break }
    if (at) {
        ui = substr(auth, 1, at - 1); c = index(ui, ":")
        if (c) { pw = substr(ui, c + 1); if (pw != "" && !index(pw, "${")) ui = substr(ui, 1, c) "${" secret(where, SV "_PASSWORD") "}" }
        else if (sec_token(ui)) ui = "${" secret(where, SV "_TOKEN") "}"
        auth = ui substr(auth, at)
    }
    n = split(path, Q, "/"); out = ""
    for (i = 1; i <= n; i++) { if (sec_token(Q[i])) Q[i] = "${" secret(where, SV "_SECRET") "}"; out = out (i > 1 ? "/" : "") Q[i] }
    path = out
    if (hq) {
        n = split(q, Q, "&"); out = ""
        for (i = 1; i <= n; i++) {
            c = index(Q[i], "=")
            if (c) { k = substr(Q[i], 1, c - 1); v = substr(Q[i], c + 1); if (v != "" && !index(v, "${") && (sec_name(k) || sec_token(v))) Q[i] = k "=${" secret(where, SV "_" vname(k)) "}" }
            out = out (i > 1 ? "&" : "") Q[i]
        }
        q = "?" out
    }
    return sch auth path q frag
}
function strip(j,   i, k, v, w, e, prev, lk, B) {
    # first a secret as the default of a ${VAR:-…}; a field the yaml calls not_secret is put back as it was at the end
    for (i = 1; i <= EN[j]; i++) { B["env." EK[j, i]] = EV[j, i]; EV[j, i] = defaults(EV[j, i], "env." EK[j, i]) }
    for (i = 1; i <= HN[j]; i++) { B["headers." HK[j, i]] = HV[j, i]; HV[j, i] = defaults(HV[j, i], "headers." HK[j, i]) }
    for (i = 1; i <= AN[j]; i++) { B["args[" i "]"] = A[j, i]; A[j, i] = defaults(A[j, i], "args[" i "]") }
    B["url"] = F[j, "url"]; F[j, "url"] = defaults(F[j, "url"], "url")
    for (i = 1; i <= EN[j]; i++) {
        k = EK[j, i]; v = EV[j, i]; w = "env." k
        if (index(v, "${")) continue
        if (v ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) EV[j, i] = url_strip(v, w)
        else if ((sec_name(k) && !sec_plain(v)) || sec_token(v)) EV[j, i] = "${" secret(w, k) "}"
    }
    for (i = 1; i <= HN[j]; i++) {
        k = HK[j, i]; v = HV[j, i]; w = "headers." k; lk = tolower(k)
        if (index(v, "${") || v == "") continue
        if (lk == "authorization" || lk == "proxy-authorization") {
            if (match(v, /^(Bearer|Basic|Token|Bot|bearer|basic|token) +/)) HV[j, i] = substr(v, 1, RLENGTH) "${" secret(w, SV "_TOKEN") "}"
            else HV[j, i] = "${" secret(w, SV "_TOKEN") "}"
        } else if (lk == "cookie") HV[j, i] = "${" secret(w, SV "_COOKIE") "}"
        else if ((sec_name(k) && !sec_plain(v)) || sec_token(v)) { k = vname(k); sub(/^X_/, "", k); HV[j, i] = "${" secret(w, SV "_" k) "}" }
    }
    if (F[j, "url"] != "") F[j, "url"] = url_strip(F[j, "url"], "url")
    prev = ""
    for (i = 1; i <= AN[j]; i++) {
        v = A[j, i]; w = "args[" i "]"
        if (index(v, "${")) { prev = v; continue }
        if (v ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) A[j, i] = url_strip(v, w)
        else if (v ~ /^--?[A-Za-z0-9][A-Za-z0-9_-]*=/ || v ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            e = index(v, "="); k = substr(v, 1, e - 1); v = substr(v, e + 1)
            if (v ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) A[j, i] = k "=" url_strip(v, w)
            else if ((sec_name(k) && !sec_plain(v)) || sec_token(v)) A[j, i] = k "=${" secret(w, k ~ /^-/ ? SV "_" vname(k) : k) "}"
        }
        else if (prev ~ /^--?[A-Za-z]/ && prev !~ /=/ && v !~ /^-/ && sec_name(prev) && !sec_plain(v)) A[j, i] = "${" secret(w, SV "_" vname(prev)) "}"
        else if (sec_token(v)) A[j, i] = "${" secret(w, SV "_SECRET") "}"
        prev = A[j, i]
    }
    for (i = 1; i <= EN[j]; i++) if (("env." EK[j, i]) in NOTSEC) EV[j, i] = B["env." EK[j, i]]
    for (i = 1; i <= HN[j]; i++) if (("headers." HK[j, i]) in NOTSEC) HV[j, i] = B["headers." HK[j, i]]
    for (i = 1; i <= AN[j]; i++) if (("args[" i "]") in NOTSEC) A[j, i] = B["args[" i "]"]
    if ("url" in NOTSEC) F[j, "url"] = B["url"]
}

# ---------- the package (npx, uvx) ----------
function need(t) { if (!(t in RQ)) { RQ[t] = 1; emit("R\t" t) } }
function pkg(j,   c, i, a, spec, nm, ver, bad, argno, pre, bin, kind, at, ex, fno, fpre, fi, raw, rng) {
    c = F[j, "command"]; sub(/^.*[\/\\]/, "", c); c = tolower(c); sub(/\.(exe|cmd|bat)$/, "", c)
    if (c == "npx" || c == "node" || c == "npm") need("node")
    else if (c == "uvx" || c == "uv") need("uv")
    else if (c ~ /^python(3(\.[0-9]+)?)?$/ || c == "py") need("python")
    else if (c == "docker") need("docker")
    bad = ""; nm = ""; ver = ""; bin = ""; pre = ""; argno = 0
    if (c == "npx") {
        kind = "npm"; spec = ""
        for (i = 1; i <= AN[j]; i++) {
            a = A[j, i]
            if (a == "-y" || a == "--yes" || a == "-q" || a == "--quiet") continue
            if (a == "-p" || a == "--package") { i++; spec = A[j, i]; argno = i; continue }
            if (a ~ /^--package=/) { spec = substr(a, 11); argno = i; pre = "--package="; continue }
            if (a ~ /^-/) { bad = "npx 的 " a " kit 不認得"; break }
            if (spec == "") { spec = a; argno = i } else bin = a
            fi = i + 1; break
        }
        if (bad == "" && spec == "") return
        if (spec != "") {
            at = 0; for (c = length(spec); c > 1; c--) if (substr(spec, c, 1) == "@") { at = c; break }
            if (at) { nm = substr(spec, 1, at - 1); ver = substr(spec, at + 1) } else nm = spec
            if (bad == "" && nm !~ /^(@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/) bad = "套件 " nm " 不是 npm registry 上的名字"
        }
        # a range or tag (^1, ~1.2, next): kit pins the newest version that matches it (a G line says what to look up)
        if (ver !~ /^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$/) {
            raw = ver; ver = ""
            if (raw ~ /^[0-9A-Za-z.^~<>=*+ |-]+$/ && bad == "") { rng = 1; emit("G\t" raw) }
        }
    } else if (c == "uvx" || (c == "uv" && A[j, 1] == "tool" && A[j, 2] == "run")) {
        kind = "pip"; spec = ""; fno = 0
        for (i = (c == "uv") ? 3 : 1; i <= AN[j]; i++) {
            a = A[j, i]
            if (a == "-q" || a == "--quiet") continue
            if (a == "--from") { i++; spec = A[j, i]; fno = i; fpre = ""; continue }
            if (a ~ /^--from=/) { spec = substr(a, 8); fno = i; fpre = "--from="; continue }
            if (a == "--python" || a == "-p") { i++; continue }
            if (a ~ /^--python=/) continue
            if (a ~ /^-/) { bad = "uvx 的 " a " kit 不幫它裝（照樣在啟動時下載）"; break }
            bin = a; argno = i; fi = i + 1; break
        }
        if (bad == "" && bin == "") return
        if (fno) { argno = fno; pre = fpre; sub(/@.*$/, "", bin) } else { spec = bin; bin = "" }
        if (spec != "") {
            if ((c = index(spec, "==")) > 0) { nm = substr(spec, 1, c - 1); ver = substr(spec, c + 2) }
            else if ((c = index(spec, "@")) > 0) { nm = substr(spec, 1, c - 1); ver = substr(spec, c + 1) }
            else nm = spec
            ex = ""; if (match(nm, /\[[A-Za-z0-9._,-]*\]$/)) { ex = substr(nm, RSTART); nm = substr(nm, 1, RSTART - 1) }
            if (bad == "" && nm !~ /^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/) bad = "套件 " nm " 不是 PyPI 上的名字"
            if (ver !~ /^[0-9][0-9A-Za-z.!+]*$/) ver = ""
            if (bin == "") bin = nm
        }
    } else return
    if (pin != "" && bad == "" && ver == "" && argno) {
        ver = pin
        A[j, argno] = pre nm (kind == "pip" ? ex : "") ((kind == "pip" && fno) ? "==" : "@") ver
        if (rng) wn(j, "套件 " nm " 原本寫 @" raw "：固定在 " pin " 版（符合 " raw " 的最新版本）")
        else if (raw != "") wn(j, "套件 " nm " 原本寫 @" raw "（kit 看不懂這種寫法）：改成固定在 " pin " 版（現在最新的版本）")
    }
    emit("P\t" kind "\t" nm (kind == "pip" ? ex : "") "\t" ver "\t" argno "\t" bin "\t" (fi ? fi : 0) "\t" bad)
}

# ---------- the yaml ----------
function yq(v) {
    if (v ~ /^[A-Za-z0-9_$.\/=+-][A-Za-z0-9_$.\/=+:{}@%~,-]*$/ && v != "-" && v !~ /:$/ && tolower(v) !~ /^(true|false|yes|no|on|off|null|none|y|n)$/ && v !~ /^[-+.]?[0-9]/) return v
    if (v !~ /["\\]/) return "\"" v "\""
    if (v !~ /'/) return "'" v "'"
    fail("bad_config", "有個值同時有 ' 和 \" 或 \\，kit 的 yaml 寫不下"); return ""
}
function finish(j,   i, t, vars, y, s, r, nv, VL) {
    if (CN[j] > 0) {   # "command": ["npx", "-y", "x"]
        for (i = AN[j]; i >= 1; i--) A[j, i + CN[j] - 1] = A[j, i]
        for (i = 2; i <= CN[j]; i++) A[j, i - 1] = CA[j, i]
        AN[j] += CN[j] - 1; F[j, "command"] = CA[j, 1]
    }
    t = F[j, "type"]
    if (t == "") t = (F[j, "url"] != "" && F[j, "command"] == "") ? "http" : "stdio"
    if (mode == "yaml") {
        emit("T\t" t)
        for (i = 1; i <= EN[j]; i++) used_vars(EV[j, i])
        for (i = 1; i <= HN[j]; i++) used_vars(HV[j, i])
        for (i = 1; i <= AN[j]; i++) used_vars(A[j, i])
        used_vars(F[j, "url"])
        strip(j); if (t == "stdio") pkg(j)
        vars = ""; for (i = 1; i <= EN[j]; i++) vars = vars " " EV[j, i]
        for (i = 1; i <= HN[j]; i++) vars = vars " " HV[j, i]
        for (i = 1; i <= AN[j]; i++) vars = vars " " A[j, i]
        vlist(vars " " F[j, "url"] " " F[j, "command"])
        return
    }
    if (t == "stdio") {
        if (F[j, "command"] == "") { fail("bad_config", "少了要跑的程式（command）"); return }
        if (F[j, "url"] != "") wn(j, "有 command 也有 url：kit 只帶 command")
        if (HN[j] > 0) { wn(j, "要跑程式的 MCP 不用 headers，略過"); HN[j] = 0 }
    } else {
        if (F[j, "url"] == "") { fail("bad_config", "少了網址（url）"); return }
        if (F[j, "command"] != "") wn(j, "有 url 也有 command：kit 只帶 url")
        if (EN[j] > 0) { wn(j, "網址的 MCP 不用 env，略過"); EN[j] = 0 }
        AN[j] = 0; F[j, "command"] = ""
    }
    for (i = 1; i <= EN[j]; i++) { ctl(EV[j, i]); used_vars(EV[j, i]) }
    for (i = 1; i <= HN[j]; i++) { ctl(HV[j, i]); used_vars(HV[j, i]) }
    for (i = 1; i <= AN[j]; i++) { ctl(A[j, i]); used_vars(A[j, i]) }
    ctl(F[j, "url"]); ctl(F[j, "command"]); ctl(F[j, "description"]); used_vars(F[j, "url"])
    if (ERRC != "") return
    emit("N\t" N); emit("T\t" t)
    if (t == "stdio") pkg(j)
    strip(j)
    y = ""
    if (F[j, "description"] != "") y = y "description: " yq(F[j, "description"]) "\n"
    if (t != "stdio") {
        y = y "type: " t "\nurl: " yq(F[j, "url"]) "\n"
        if (HN[j] > 0) { y = y "headers:\n"; for (i = 1; i <= HN[j]; i++) y = y "  " HK[j, i] ": " yq(HV[j, i]) "\n" }
    } else {
        y = y "command: " yq(F[j, "command"]) "\n"
        if (AN[j] == 0) y = y "args: []\n"
        else { y = y "args:\n"; for (i = 1; i <= AN[j]; i++) y = y "  - " yq(A[j, i]) "\n" }
        if (EN[j] > 0) { y = y "env:\n"; for (i = 1; i <= EN[j]; i++) y = y "  " EK[j, i] ": " yq(EV[j, i]) "\n" }
    }
    nv = vlist(y)
    s = "# 用 kit new mcp --config 從貼上的設定建立。${名字} 是環境變數：值不放在這裡，每台電腦自己設定。\n"
    if (nv != "") s = s "# 要先設定的環境變數：" nv "\n"
    y = s y
    while ((i = index(y, "\n")) > 0) { emit("Y\t" substr(y, 1, i - 1)); y = substr(y, i + 1) }
    for (i = 1; i <= WN[j]; i++) emit("W\t" WL[j, i])
}
function vlist(s,   r, l, seen) {   # V lines for ${VAR} without a default; returns them joined by 、
    l = ""
    while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}/)) {
        r = substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
        if (index(r, ":-")) continue
        if (!(r in VSEEN)) { VSEEN[r] = 1; emit("V\t" r); l = l (l == "" ? "" : "、") r }
    }
    return l
}
