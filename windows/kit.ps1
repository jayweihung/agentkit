# kit - manage rules, skills, MCP servers, tool permissions and agents
# for AI coding tools. Windows version: Windows PowerShell 5.1 or PowerShell 7.
# Same commands, files and behaviour as unix/kit.
#
# No network access except the git URLs you give it, and only to hosts
# allowed by the sources' kit.yaml (allowed_hosts).
#
# This file must stay UTF-8 *with* BOM: Windows PowerShell 5.1 reads a .ps1
# without BOM in the ANSI code page and the Chinese messages would break.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------- paths ----------
$script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path variable:IsWindows) -and $IsWindows)
$script:UserHome = if ($script:OnWindows -and $env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$script:KitLib = Split-Path -Parent $PSCommandPath
$script:KitVersion = 'dev'
foreach ($v in @((Join-Path $KitLib 'VERSION'), (Join-Path (Split-Path -Parent $KitLib) 'VERSION'))) {
    if (Test-Path -LiteralPath $v) { $script:KitVersion = ([IO.File]::ReadAllText($v)).Trim(); break }
}
function Env-Or($name, $default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v) { $v } else { $default } }
$script:KitConf = Env-Or 'AGENTKIT_CONFIG' (Join-Path $UserHome '.config/agentkit')
$script:KitSrc = Env-Or 'AGENTKIT_SOURCES' (Join-Path $UserHome 'agentkit')
$script:Machine = Join-Path $KitConf 'machine.yaml'
$script:State = Join-Path $KitConf 'state.tsv'
if ($env:CLAUDE_CONFIG_DIR) {
    $script:ClaudeDir = $env:CLAUDE_CONFIG_DIR; $script:ClaudeJson = Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json'
} else {
    $script:ClaudeDir = Join-Path $UserHome '.claude'; $script:ClaudeJson = Join-Path $UserHome '.claude.json'
}
$script:CodexDir = Env-Or 'CODEX_HOME' (Join-Path $UserHome '.codex')
$script:OmpDir = Env-Or 'PI_CODING_AGENT_DIR' (Join-Path $UserHome '.omp/agent')
$script:AgentsSkills = Join-Path $UserHome '.agents/skills'     # read by Codex and omp
$script:BeginMark = '<!-- agentkit:begin (managed by kit, do not edit) -->'
$script:EndMark = '<!-- agentkit:end -->'
$script:TomlBegin = '# agentkit:begin (managed by kit, do not edit)'
$script:TomlEnd = '# agentkit:end'
$script:Utf8 = New-Object System.Text.UTF8Encoding $false     # never write a BOM
$script:Quiet = $false
$script:Force = $false
$script:LogPath = $null
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------- small helpers ----------
function Say([string]$msg) {
    if ($script:Quiet) { return }
    if ($script:LogPath) { [IO.File]::AppendAllText($script:LogPath, "$msg`n", $Utf8) } else { [Console]::Out.WriteLine($msg) }
}
function Warn([string]$msg) {
    if ($script:LogPath) { [IO.File]::AppendAllText($script:LogPath, "kit: $msg`n", $Utf8) } else { [Console]::Error.WriteLine("kit: $msg") }
}
function Die([string]$msg) { Warn $msg; exit 1 }

function Read-Text([string]$path) {
    $t = [IO.File]::ReadAllText($path, $Utf8)
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    $t
}
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $Utf8) }
function Ensure-Dir([string]$path) { if (-not (Test-Path -LiteralPath $path)) { [void](New-Item -ItemType Directory -Force -Path $path) } }
function Uniq($items) { $seen = @{}; $out = New-Object System.Collections.Generic.List[string]; foreach ($i in $items) { if ($i -and -not $seen.ContainsKey($i)) { $seen[$i] = 1; $out.Add($i) } }; $out.ToArray() }
function Has-Command([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# ---------- YAML (the small subset kit uses; same rules as unix/yaml.awk) ----------
# Returns "path<TAB>value" lines; list items as "path[]<TAB>value".
function Yaml-Unquote([string]$s) {
    if ($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[-1] -eq '"') -or ($s[0] -eq "'" -and $s[-1] -eq "'"))) { return $s.Substring(1, $s.Length - 2) }
    $s
}
function Yaml-StripComment([string]$s) {
    $q = ''
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($q) { if ($c -eq $q) { $q = '' }; continue }
        if ($c -eq '"' -or $c -eq "'") { $q = $c; continue }
        if ($c -eq '#' -and ($i -eq 0 -or $s[$i - 1] -eq ' ' -or $s[$i - 1] -eq "`t")) { return $s.Substring(0, $i) }
    }
    $s
}
function Yaml-Lines([string]$path, [switch]$Frontmatter) {
    $out = New-Object System.Collections.Generic.List[string]
    $ind = @{}; $key = @{}; $depth = 0; $fm = if ($Frontmatter) { 0 } else { 1 }; $no = 0
    $inBlock = $false; $blockInd = 0; $blockPath = ''; $blockText = ''   # key: | or key: >- (joined into one line)
    foreach ($raw in (Read-Text $path) -split "`n") {
        $no++
        $line = $raw.TrimEnd("`r")
        if ($inBlock) {
            $bi = $line.Length - $line.TrimStart(' ').Length
            if ($line.Trim() -eq '' -or $bi -gt $blockInd) {
                $t = $line.Trim(); if ($t) { if ($blockText) { $blockText += ' ' }; $blockText += $t }
                continue
            }
            $out.Add("$blockPath`t$blockText"); $inBlock = $false
        }
        if ($Frontmatter) {
            if ($line -eq '---') { $fm++; if ($fm -eq 2) { break }; continue }
            if ($fm -eq 0) { if ($line -match '^\s*$') { continue }; throw "yaml: ${path}:${no}: expected --- at top" }
        }
        if ($line -match '^[ \t]*(#.*)?$') { continue }
        $line = Yaml-StripComment $line
        $n = $line.Length - $line.TrimStart(' ').Length
        $text = $line.Substring($n)
        while ($depth -gt 0 -and $n -le $ind[$depth]) { $depth-- }
        $parent = if ($depth -gt 0) { $key[$depth] } else { '' }
        if ($text.StartsWith('- ') -or $text -eq '-') {
            $item = if ($text -eq '-') { '' } else { $text.Substring(2) }
            $out.Add("$parent[]`t" + (Yaml-Unquote $item.Trim()))
            continue
        }
        $c = $text.IndexOf(':')
        if ($c -lt 0) { throw "yaml: ${path}:${no}: expected key: value" }
        $k = $text.Substring(0, $c).Trim(); $val = $text.Substring($c + 1).Trim()
        $p = if ($depth -gt 0) { "$parent.$k" } else { $k }
        if ($val -eq '') { $depth++; $ind[$depth] = $n; $key[$depth] = $p }
        elseif ($val -match '^[|>][-+]?[0-9]?$') { $inBlock = $true; $blockInd = $n; $blockPath = $p; $blockText = '' }
        elseif ($val.StartsWith('[')) {
            if (-not $val.EndsWith(']')) { throw "yaml: ${path}:${no}: list must end with ]" }
            $body = $val.Substring(1, $val.Length - 2)
            if ($body.Trim() -eq '') { continue }
            $q = ''; $cur = ''
            foreach ($ch in $body.ToCharArray()) {
                if ($q) { $cur += $ch; if ($ch -eq $q) { $q = '' }; continue }
                if ($ch -eq '"' -or $ch -eq "'") { $q = $ch; $cur += $ch; continue }
                if ($ch -eq ',') { $out.Add("$p[]`t" + (Yaml-Unquote $cur.Trim())); $cur = ''; continue }
                $cur += $ch
            }
            if ($cur.Trim() -ne '') { $out.Add("$p[]`t" + (Yaml-Unquote $cur.Trim())) }
        }
        else { $out.Add("$p`t" + (Yaml-Unquote $val)) }
    }
    if ($inBlock) { $out.Add("$blockPath`t$blockText") }
    $out.ToArray()
}
function YGet-From($lines, [string]$path) {
    $r = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        $t = $l.IndexOf("`t"); $p = $l.Substring(0, $t)
        if ($p -eq $path -or $p -eq "$path[]") { $r.Add($l.Substring($t + 1)) }
    }
    $r.ToArray()
}
function YGet([string]$file, [string]$path) {
    if (-not (Test-Path -LiteralPath $file)) { return }
    YGet-From (Yaml-Lines $file) $path
}

# ---------- JSON that keeps the file as it is ----------
# Like unix/json.awk: strings and numbers are kept byte for byte, key order is
# kept, output is formatted like JSON.stringify(value, null, 2).
$script:JsonRx = [regex]'"[^"\\]*(?:\\.[^"\\]*)*"|[{}\[\]:,]|[^\s{}\[\]:,"]+|\S'
function Json-Parse([string]$text) {
    if ($text.Trim() -eq '') { $text = '{}' }
    $script:jt = [string[]]@(foreach ($m in $JsonRx.Matches($text)) { $m.Value })
    $script:jp = 0
    $n = Json-Value
    if ($script:jp -lt $script:jt.Count) { throw 'json: extra data after the value' }
    $n
}
function Json-Next { if ($script:jp -ge $script:jt.Count) { throw 'json: unexpected end' }; $t = $script:jt[$script:jp]; $script:jp++; $t }
function Json-Value {
    $t = Json-Next
    if ($t -eq '{') {
        $o = @{ t = 'o'; k = (New-Object System.Collections.Generic.List[string]); v = (New-Object System.Collections.Generic.List[object]) }
        if ($script:jt[$script:jp] -eq '}') { $script:jp++; return $o }
        while ($true) {
            $k = Json-Next; if ($k.Length -lt 2 -or $k[0] -ne '"') { throw "json: expected a key, got $k" }
            if ((Json-Next) -ne ':') { throw 'json: expected :' }
            $o.k.Add($k); $o.v.Add((Json-Value))
            $s = Json-Next; if ($s -eq '}') { return $o }; if ($s -ne ',') { throw "json: expected , or } got $s" }
        }
    }
    if ($t -eq '[') {
        $a = @{ t = 'a'; v = (New-Object System.Collections.Generic.List[object]) }
        if ($script:jt[$script:jp] -eq ']') { $script:jp++; return $a }
        while ($true) {
            $a.v.Add((Json-Value))
            $s = Json-Next; if ($s -eq ']') { return $a }; if ($s -ne ',') { throw "json: expected , or ] got $s" }
        }
    }
    if ($t.Length -ge 2 -and $t[0] -eq '"') { return @{ t = 'v'; raw = $t } }
    if ($t -cmatch '^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)$') { return @{ t = 'v'; raw = $t } }
    throw "json: bad value $t"
}
function Json-Ser($n, [string]$ind = '') {
    if ($n.t -eq 'v') { return $n.raw }
    if ($n.v.Count -eq 0) { if ($n.t -eq 'o') { return '{}' } else { return '[]' } }
    $ind2 = "$ind  "
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($(if ($n.t -eq 'o') { "{`n" } else { "[`n" }))
    for ($i = 0; $i -lt $n.v.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append(",`n") }
        [void]$sb.Append($ind2)
        if ($n.t -eq 'o') { [void]$sb.Append($n.k[$i]).Append(': ') }
        [void]$sb.Append((Json-Ser $n.v[$i] $ind2))
    }
    [void]$sb.Append("`n$ind").Append($(if ($n.t -eq 'o') { '}' } else { ']' }))
    $sb.ToString()
}
function Json-Str([string]$s) {
    '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t').Replace("`n", '\n').Replace("`r", '\r') + '"'
}
function Json-Child($o, [string]$key) {
    if ($o.t -ne 'o') { return -1 }
    $q = Json-Str $key
    for ($i = 0; $i -lt $o.k.Count; $i++) { if ($o.k[$i] -ceq $q) { return $i } }
    -1
}
function Json-Find($root, [string]$path) {
    $n = $root
    foreach ($part in $path.Split('.')) { $i = Json-Child $n $part; if ($i -lt 0) { return $null }; $n = $n.v[$i] }
    $n
}
function Json-Parent($root, [string]$path) { # walk to the parent of PATH, creating objects on the way
    $parts = $path.Split('.'); $n = $root
    for ($j = 0; $j -lt $parts.Count - 1; $j++) {
        if ($n.t -ne 'o') { throw "json: not an object at $($parts[$j])" }
        $i = Json-Child $n $parts[$j]
        if ($i -lt 0) {
            $m = @{ t = 'o'; k = (New-Object System.Collections.Generic.List[string]); v = (New-Object System.Collections.Generic.List[object]) }
            $n.k.Add((Json-Str $parts[$j])); $n.v.Add($m); $n = $m
        } else { $n = $n.v[$i] }
    }
    if ($n.t -ne 'o') { throw "json: not an object at $($parts[-1])" }
    $n
}
function Json-Set($root, [string]$path, $node) {
    $p = Json-Parent $root $path; $last = $path.Split('.')[-1]; $i = Json-Child $p $last
    if ($i -ge 0) { $p.v[$i] = $node } else { $p.k.Add((Json-Str $last)); $p.v.Add($node) }
}
function Json-Del($root, [string]$path) {
    $parts = $path.Split('.')
    $p = if ($parts.Count -gt 1) { Json-Find $root ($parts[0..($parts.Count - 2)] -join '.') } else { $root }
    if ($null -eq $p) { return }
    $i = Json-Child $p $parts[-1]
    if ($i -ge 0) { $p.k.RemoveAt($i); $p.v.RemoveAt($i) }
}
function Json-Array($root, [string]$path, [bool]$create) {
    $a = Json-Find $root $path
    if ($null -eq $a) { if (-not $create) { return $null }; $a = @{ t = 'a'; v = (New-Object System.Collections.Generic.List[object]) }; Json-Set $root $path $a }
    if ($a.t -ne 'a') { throw "json: $path is not an array" }
    $a
}
function Json-AddItem($root, [string]$path, $node) { # append unless an equal item exists
    $a = Json-Array $root $path $true; $s = Json-Ser $node
    foreach ($x in $a.v) { if ((Json-Ser $x) -ceq $s) { return } }
    $a.v.Add($node)
}
function Json-RmItem($root, [string]$path, $node) {
    $a = Json-Array $root $path $false; if ($null -eq $a) { return }
    $s = Json-Ser $node
    for ($i = $a.v.Count - 1; $i -ge 0; $i--) { if ((Json-Ser $a.v[$i]) -ceq $s) { $a.v.RemoveAt($i) } }
}
function Json-ItemIs($c, [string]$key, [string]$raw) { # is node c an object whose KEY is the raw string?
    if ($c.t -ne 'o') { return $false }
    $m = Json-Find $c $key
    ($null -ne $m) -and $m.t -eq 'v' -and $m.raw -ceq $raw
}
function Json-RmWhere($n, [string]$key, [string]$raw) { # anywhere: remove array items whose KEY is the string
    if ($n.t -eq 'v') { return }
    for ($i = $n.v.Count - 1; $i -ge 0; $i--) {
        if ($n.t -eq 'a' -and (Json-ItemIs $n.v[$i] $key $raw)) { $n.v.RemoveAt($i); continue }
        Json-RmWhere $n.v[$i] $key $raw
    }
}
function Json-AddNear($n, [string]$key, [string]$raw, [string]$json) { # anywhere: append JSON to each array with an item whose KEY is the string
    if ($n.t -eq 'v') { return }
    $hit = $false
    $count = $n.v.Count
    for ($i = 0; $i -lt $count; $i++) {
        if ($n.t -eq 'a' -and (Json-ItemIs $n.v[$i] $key $raw)) { $hit = $true }
        Json-AddNear $n.v[$i] $key $raw $json
    }
    if (-not $hit) { return }
    $item = Json-Parse $json; $s = Json-Ser $item
    foreach ($x in $n.v) { if ((Json-Ser $x) -ceq $s) { return } }
    $n.v.Add($item)
}
function Json-Apply($root, $ops) {
    foreach ($op in $ops) {
        switch ($op[0]) {
            'set'     { Json-Set $root $op[1] (Json-Parse $op[2]) }
            'del'     { Json-Del $root $op[1] }
            'addstr'  { Json-AddItem $root $op[1] @{ t = 'v'; raw = (Json-Str $op[2]) } }
            'rmstr'   { Json-RmItem $root $op[1] @{ t = 'v'; raw = (Json-Str $op[2]) } }
            'addjson' { Json-AddItem $root $op[1] (Json-Parse $op[2]) }
            'rmjson'  { Json-RmItem $root $op[1] (Json-Parse $op[2]) }
            'rmwhere' { Json-RmWhere $root $op[1] (Json-Str $op[2]) }
            'addnear' { Json-AddNear $root $op[1] (Json-Str $op[2]) $op[3] }
            default   { throw "json: unknown op $($op[0])" }
        }
    }
}
function Json-Text($root, [string]$orig) { # keep a trailing newline only if the file had one
    $s = Json-Ser $root
    if ($orig.EndsWith("`n")) { $s += "`n" }
    $s
}
function Json-Get([string]$file, [string]$path) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $n = Json-Find (Json-Parse (Read-Text $file)) $path
    if ($null -eq $n) { return $null }
    Json-Ser $n
}

function Json-Edit([string]$f, $ops) { # edit FILE, keep a backup
    # Other programs (a running Claude) may write FILE at any time, so: edit a
    # snapshot, and swap the result in only if FILE did not change meanwhile.
    $new = $false
    if (-not (Test-Path -LiteralPath $f)) { Ensure-Dir (Split-Path -Parent $f); Write-Text $f "{}`n"; $new = $true }
    for ($try = 1; $try -le 5; $try++) {
        $snap = [IO.File]::ReadAllBytes($f)
        $orig = $Utf8.GetString($snap); $bom = ($orig.Length -gt 0 -and $orig[0] -eq [char]0xFEFF); if ($bom) { $orig = $orig.Substring(1) }
        try {
            $root = Json-Parse $orig
            Json-Apply $root $ops
            $text = Json-Text $root $orig
            [void](Json-Parse $text)
        } catch { Die "沒辦法更新 ${f}（檔案沒有被改動）：$($_.Exception.Message)" }
        $tmp = "$f.kit.tmp"
        $bytes = $Utf8.GetBytes($text); if ($bom) { $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $bytes }
        [IO.File]::WriteAllBytes($tmp, $bytes)
        $now = [IO.File]::ReadAllBytes($f)
        if ([Convert]::ToBase64String($now) -ceq [Convert]::ToBase64String($snap)) {
            Swap-In $tmp $f (-not $new)
            return
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1                                # someone else wrote it; retry
    }
    Die "沒辦法更新 ${f}：別的程式一直在寫它（檔案沒有被改動）"
}
function Swap-In([string]$tmp, [string]$f, [bool]$backup) { # put TMP in place of F
    $b = if ($backup) { "$f.kit-backup" } else { [NullString]::Value }   # a plain $null would become ""
    try { [IO.File]::Replace($tmp, $f, $b); return }                     # atomic, keeps the file's permissions
    catch { $why = $_.Exception.Message }
    # some network drives and file systems cannot replace: copy instead (not atomic)
    try {
        if ($backup) { Copy-Item -LiteralPath $f -Destination "$f.kit-backup" -Force }
        Copy-Item -LiteralPath $tmp -Destination $f -Force
        Remove-Item -LiteralPath $tmp -Force
    } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; Die "沒辦法寫入 ${f}：$why / $($_.Exception.Message)" }
}
function Prune-Empty([string]$f, [string[]]$paths) { # delete each PATH whose value is [] or {}
    if (-not (Test-Path -LiteralPath $f)) { return }
    foreach ($p in $paths) {
        $v = Json-Get $f $p
        if ($v -eq '[]' -or $v -eq '{}') { Json-Edit $f @(, @('del', $p)) }
    }
}
function Prune-Deny { Prune-Empty (Join-Path $ClaudeDir 'settings.json') @('permissions.deny', 'permissions', 'hooks.SessionStart', 'hooks') }

function Text-Hash([string]$s) {
    $sha = [Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes($s)))).Replace('-', '').Substring(0, 16)
}
function Dir-Hash([string]$dir) { # content hash of a directory
    $base = (Resolve-Path -LiteralPath $dir).ProviderPath.TrimEnd('\', '/')
    $sha = [Security.Cryptography.SHA256]::Create()
    $lines = foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -Force | Where-Object { $_.Name -ne '.DS_Store' })) {
        $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
        $rel + ' ' + [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f.FullName)))
    }
    $sorted = [string[]]@($lines); [Array]::Sort($sorted, [StringComparer]::Ordinal)
    Text-Hash ($sorted -join "`n")
}

# ---------- state ----------
# state.tsv lines: kind<TAB>name<TAB>detail
function State-Rows { if (Test-Path -LiteralPath $State) { @((Read-Text $State) -split "`n" | Where-Object { $_ }) } else { @() } }
function State-Get([string]$k, [string]$n) {
    foreach ($r in State-Rows) { $f = $r.Split("`t"); if ($f[0] -eq $k -and $f[1] -eq $n) { if ($f.Count -gt 2) { return $f[2] } else { return '' } } }
    $null
}
function State-List([string]$k) { @(foreach ($r in State-Rows) { $f = $r.Split("`t"); if ($f[0] -eq $k) { $f[1] } }) }
function State-Set([string]$k, [string]$n, $v) {
    Ensure-Dir $KitConf
    $rows = @(foreach ($r in State-Rows) { $f = $r.Split("`t"); if (-not ($f[0] -eq $k -and $f[1] -eq $n)) { $r } })
    if ($null -ne $v) { $rows += "$k`t$n`t$v" }
    Write-Text $State (($rows | ForEach-Object { "$_`n" }) -join '')
}
function State-Del([string]$k, [string]$n) { if (Test-Path -LiteralPath $State) { State-Set $k $n $null } }

# ---------- machine.yaml ----------
function M-Sources { YGet $Machine 'sources' }
function M-Added { YGet $Machine 'added' }
function M-Removed { YGet $Machine 'removed' }
function Write-Machine($sources, $added, $removed) {
    Ensure-Dir $KitConf
    $t = "# written by kit - use kit add / kit rm instead of editing`n"
    $t += "sources:            # earlier sources win when names repeat`n"
    foreach ($s in $sources) { if ($s) { $t += "  - $s`n" } }
    $t += 'added: [' + ((@($added) | Where-Object { $_ }) -join ', ') + "]`n"
    $t += 'removed: [' + ((@($removed) | Where-Object { $_ }) -join ', ') + "]    # kit rm; sync will not add these back`n"
    Write-Text $Machine $t
}

# ---------- sources ----------
function Is-Url([string]$s) { $s -match '://' -or $s -match '^[^/\\]*@[^/\\]*:' }
function Url-Host([string]$u) { (($u -replace '^[a-z+]+://', '') -replace '^[^@/]*@', '') -replace '[:/].*$', '' }
function Src-Name([string]$s) { [IO.Path]::GetFileName($s.TrimEnd('/', '\')) -replace '\.git$', '' }
function Src-Dir([string]$s) {
    if (Is-Url $s) { return Join-Path $KitSrc (Src-Name $s) }
    if (Test-Path -LiteralPath $s) { return (Resolve-Path -LiteralPath $s).ProviderPath }
    $s
}
function Src-Dirs { @(foreach ($s in M-Sources) { Src-Dir $s }) }
$script:PushDir = $null
function Allowed-Hosts { # from the configured sources (+ the source kit push sends from)
    $dirs = @(Src-Dirs); if ($script:PushDir) { $dirs += $script:PushDir }
    Uniq @(foreach ($d in $dirs) { YGet (Join-Path $d 'kit.yaml') 'allowed_hosts' })
}

function Git-Safe { # git without prompts, submodules or LFS downloads
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GIT_LFS_SKIP_SMUDGE = '1'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git @args 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
}
function Check-Host([string]$url) { # refuse URLs whose host is not allowed
    if (-not (Is-Url $url)) { return }
    $hosts = @(Allowed-Hosts)
    if ($hosts.Count -eq 0) { return }
    $h = Url-Host $url
    if ($hosts -notcontains $h) { Die "$h 不在允許的主機清單：$($hosts -join ' ')" }
    # git config "insteadOf" rules can rewrite a URL; check where git really goes
    $real = (Git-Safe ls-remote --get-url $url | Select-Object -First 1)
    if ($real -and $real -ne $url) { $h = Url-Host $real; if ($hosts -notcontains $h) { Die "git 設定把網址改到 ${h}，不在允許的主機清單" } }
}
function Fetch-Source([string]$s) { # clone or fast-forward one source
    if (-not (Is-Url $s)) { if (-not (Test-Path -LiteralPath $s -PathType Container)) { Die "找不到來源資料夾：$s" }; return }
    Check-Host $s
    $d = Src-Dir $s
    if (Test-Path -LiteralPath (Join-Path $d '.git')) {
        [void](Git-Safe -C $d pull --ff-only --quiet --no-recurse-submodules)
        if ($LASTEXITCODE -ne 0) { Warn "沒辦法更新 $(Src-Name $s)（沒網路？）" }
    } else {
        Ensure-Dir $KitSrc
        [void](Git-Safe clone --quiet --no-recurse-submodules $s $d)
        if ($LASTEXITCODE -ne 0) { Die "沒辦法 clone $s" }
    }
}

function Item-Path([string]$dir, [string]$kind, [string]$name) {
    switch ($kind) {
        'rule' { Join-Path $dir "rules/$name.md" }
        'skill' { Join-Path $dir "skills/$name/SKILL.md" }
        'mcp' { Join-Path $dir "mcp/$name.yaml" }
        'agent' { Join-Path $dir "agents/$name.md" }
    }
}
function Find-Item([string]$kind, [string]$name) { # path in the first source that has it
    foreach ($d in Src-Dirs) { $p = Item-Path $d $kind $name; if (Test-Path -LiteralPath $p -PathType Leaf) { return $p } }
    $null
}
function Names-In([string]$dir, [string]$filter, [switch]$Dirs) {
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $items = if ($Dirs) { Get-ChildItem -LiteralPath $dir -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object { $_.Name } }
             else { Get-ChildItem -LiteralPath $dir -File -Filter $filter | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } }
    $a = [string[]]@($items); [Array]::Sort($a, [StringComparer]::Ordinal); $a
}
function Available { # all kind:name in all sources
    Uniq @(foreach ($d in Src-Dirs) {
        foreach ($n in Names-In (Join-Path $d 'rules') '*.md') { "rule:$n" }
        foreach ($n in Names-In (Join-Path $d 'skills') '' -Dirs) { "skill:$n" }
        foreach ($n in Names-In (Join-Path $d 'mcp') '*.yaml') { "mcp:$n" }
        foreach ($n in Names-In (Join-Path $d 'agents') '*.md') { "agent:$n" }
    })
}
function Kit-Items([string]$section) {
    Uniq @(foreach ($d in Src-Dirs) { foreach ($k in 'rule', 'skill', 'mcp') { foreach ($n in YGet (Join-Path $d 'kit.yaml') "$section.${k}s") { "${k}:$n" } } })
}
function Required-Deny { Uniq @(foreach ($d in Src-Dirs) { YGet (Join-Path $d 'kit.yaml') 'required.tools.deny' }) }
function Wanted { # required + added - removed
    $removed = M-Removed
    Uniq (@(Kit-Items 'required') + @(M-Added | Where-Object { $removed -notcontains $_ }))
}
function Of-Kind($items, [string]$kind) { @(foreach ($i in $items) { if ($i.StartsWith("${kind}:")) { $i.Substring($kind.Length + 1) } }) }

# ---------- MCP yaml -> JSON / TOML ----------
function Mcp-Env($lines) { foreach ($l in $lines) { if ($l.StartsWith('env.')) { $t = $l.IndexOf("`t"); , @($l.Substring(4, $t - 4), $l.Substring($t + 1)) } } }   # pairs; callers wrap in @()
function Mcp-Json([string]$f) { # {"command":..,"args":[..],"env":{..}}
    $y = Yaml-Lines $f
    $cmd = @(YGet-From $y 'command')
    if ($cmd.Count -eq 0 -or -not $cmd[0]) { Warn "$f has no command"; return $null }
    $out = '{"command":' + (Json-Str $cmd[0]) + ',"args":[' + ((@(YGet-From $y 'args') | ForEach-Object { Json-Str $_ }) -join ',') + ']'
    $envs = @(Mcp-Env $y)
    if ($envs.Count -gt 0) { $out += ',"env":{' + ((@($envs) | ForEach-Object { (Json-Str $_[0]) + ':' + (Json-Str $_[1]) }) -join ',') + '}' }
    $out + '}'
}
function Toml-Key([string]$k) { if ($k -match '^[A-Za-z0-9_-]+$') { $k } else { Json-Str $k } }
function Codex-Mcp-Toml($names) { # [mcp_servers.x] tables for Codex
    $cfg = Join-Path $CodexDir 'config.toml'; $user = @()
    if (Test-Path -LiteralPath $cfg) {
        $in = $false
        $user = @(foreach ($l in (Read-Text $cfg) -split "`n") { $l = $l.TrimEnd("`r"); if ($l -eq $TomlBegin) { $in = $true }; if (-not $in) { $l }; if ($l -eq $TomlEnd) { $in = $false } })
    }
    $deny = Required-Deny
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in @($names | Where-Object { $_ })) {
        $p = Find-Item 'mcp' $n; if (-not $p) { Warn "mcp $n not found in any source"; continue }
        $y = Yaml-Lines $p; $cmd = @(YGet-From $y 'command')
        if ($cmd.Count -eq 0 -or -not $cmd[0]) { Warn "$p has no command"; continue }
        $pat = '^\s*\[mcp_servers\."?' + [regex]::Escape($n) + '"?[\]. ]'
        if (@($user | Where-Object { $_ -match $pat }).Count -gt 0) { Warn "Codex 的 config.toml 已經有自己的 mcp_servers.${n}，kit 不動它"; continue }
        [void]$sb.Append("[mcp_servers.$(Toml-Key $n)]`ncommand = $(Json-Str $cmd[0])`n")
        $args2 = @(YGet-From $y 'args'); if ($args2.Count -gt 0) { [void]$sb.Append('args = [' + (($args2 | ForEach-Object { Json-Str $_ }) -join ', ') + "]`n") }
        # team deny rules for this server's tools (mcp__<server>__<tool>) become disabled_tools
        $tools = @(foreach ($d in $deny) { if ($d.StartsWith("mcp__${n}__")) { Json-Str $d.Substring("mcp__${n}__".Length) } })
        if ($tools.Count -gt 0) { [void]$sb.Append('disabled_tools = [' + ($tools -join ', ') + "]`n") }
        $envs = @(Mcp-Env $y)
        if ($envs.Count -gt 0) {
            [void]$sb.Append("`n[mcp_servers.$(Toml-Key $n).env]`n")
            foreach ($e in $envs) { [void]$sb.Append("$(Toml-Key $e[0]) = $(Json-Str $e[1])`n") }
        }
        [void]$sb.Append("`n")
    }
    $sb.ToString()
}

# ---------- write into Claude Code, Codex, omp ----------
function Has-Codex { (Test-Path -LiteralPath $CodexDir) -or (Has-Command 'codex') }
function Has-Omp { (Test-Path -LiteralPath $OmpDir) -or (Test-Path -LiteralPath (Join-Path $UserHome '.omp')) -or (Has-Command 'omp') }
function Targets { $t = 'Claude'; if (Has-Codex) { $t += '、Codex' }; if (Has-Omp) { $t += '、omp' }; $t }

function Replace-Block([string]$f, [string]$begin, [string]$end, [string]$body) { # put BODY between the markers, at the end of FILE
    $exists = Test-Path -LiteralPath $f
    if (-not $exists -and -not $body) { return }
    $orig = if ($exists) { Read-Text $f } else { '' }
    $nl = if ($orig.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]; $skip = $false
    if ($orig -ne '') {
        $parts = $orig -split "`n"; if ($orig.EndsWith("`n")) { $parts = $parts[0..($parts.Count - 2)] }
        foreach ($l in $parts) { $l = $l.TrimEnd("`r"); if ($l -eq $begin) { $skip = $true; continue }; if ($l -eq $end) { $skip = $false; continue }; if (-not $skip) { $lines.Add($l) } }
    }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $lines) { [void]$sb.Append($l).Append($nl) }
    if ($body) {
        if (-not $body.EndsWith("`n")) { $body += "`n" }
        if ($lines.Count -gt 0) { [void]$sb.Append($nl) }
        [void]$sb.Append($begin).Append($nl).Append($body.Replace("`r`n", "`n").Replace("`n", $nl)).Append($end).Append($nl)
    }
    $new = $sb.ToString()
    if ($exists -and $new -ceq $orig) { return }
    if ($new -eq '') { Remove-Item -LiteralPath $f -Force; return }   # nothing left: kit made it
    Ensure-Dir (Split-Path -Parent $f)
    Write-Text "$f.kit.tmp" $new
    if ($exists) { Swap-In "$f.kit.tmp" $f $false } else { Move-Item -LiteralPath "$f.kit.tmp" -Destination $f }
}
function Rules-Body($names, [string]$mode) { # text for the instructions file
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in @($names | Where-Object { $_ })) {
        $p = Find-Item 'rule' $n; if (-not $p) { Warn "rule $n not found in any source"; continue }
        if ($mode -eq 'import') { [void]$sb.Append("@$p`n") }
        else { $t = Read-Text $p; [void]$sb.Append("<!-- rule: $n -->`n").Append($t); if (-not $t.EndsWith("`n")) { [void]$sb.Append("`n") } }
    }
    $sb.ToString()
}
function Set-Rules([string]$f, $names, [string]$mode) { Replace-Block $f $BeginMark $EndMark (Rules-Body $names $mode) }

function Sync-Skills([string]$dir, [string]$kind, $names) { # copy wanted skills into DIR
    $names = @($names | Where-Object { $_ })
    if ($names.Count -gt 0) { Ensure-Dir $dir }
    foreach ($n in $names) {
        $p = Find-Item 'skill' $n; if (-not $p) { Warn "skill $n not found in any source"; continue }
        $src = Split-Path -Parent $p; $dst = Join-Path $dir $n; $h = Dir-Hash $src
        $old = State-Get $kind $n
        if ((Test-Path -LiteralPath $dst) -and -not $old) {
            # someone else's folder: say it once, not at every sync
            if ($null -eq (State-Get 'skipped' $dst)) { Warn "$dst 已經存在，不是 kit 放的，跳過（只提醒這一次）"; State-Set 'skipped' $dst 1 }
            continue
        }
        if ($null -ne (State-Get 'skipped' $dst)) { State-Del 'skipped' $dst }
        if ($old -and (Test-Path -LiteralPath $dst) -and (Dir-Hash $dst) -ne $old -and -not $script:Force) {
            Warn "skill ${n}（${dir}）被手動改過，跳過（kit sync --force 會蓋掉）"; continue
        }
        if ($h -eq $old -and (Test-Path -LiteralPath $dst)) { continue }
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse
        State-Set $kind $n $h; Say "  skill $n → $dir"
    }
    foreach ($n in State-List $kind) {
        if ($names -contains $n) { continue }
        $dst = Join-Path $dir $n
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        State-Del $kind $n; Say "  removed skill $n ← $dir"
    }
}
function Sync-McpJson([string]$f, [string]$kind, $names) { # wanted MCP -> FILE's mcpServers
    $names = @($names | Where-Object { $_ }); $ops = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        $p = Find-Item 'mcp' $n; if (-not $p) { Warn "mcp $n not found in any source"; continue }
        $k = Mcp-Json $p; if (-not $k) { continue }
        $sum = Text-Hash $k
        if ((State-Get $kind $n) -eq $sum) { continue }
        $ops.Add(@('set', "mcpServers.$n", $k)); State-Set $kind $n $sum; Say "  mcp $n → $f"
    }
    foreach ($n in State-List $kind) {
        if ($names -contains $n) { continue }
        $ops.Add(@('del', "mcpServers.$n")); State-Del $kind $n; Say "  removed mcp $n ← $f"
    }
    if ($ops.Count -gt 0) { Json-Edit $f $ops.ToArray(); Prune-Empty $f @('mcpServers') }
}

function Hook-Json { # the SessionStart hook entry kit adds to settings.json
    $exe = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
    $cmd = "$exe -NoProfile -ExecutionPolicy Bypass -File `"$($PSCommandPath.Replace('\', '/'))`" sync --hook"
    '{"hooks":[{"type":"command","command":' + (Json-Str $cmd) + ',"timeout":10}]}'
}

function Apply-All {
    $want = Wanted
    $rules = Of-Kind $want 'rule'; $skills = Of-Kind $want 'skill'; $mcps = Of-Kind $want 'mcp'

    # Claude: rules as @imports, skills, MCP in ~/.claude.json
    Set-Rules (Join-Path $ClaudeDir 'CLAUDE.md') $rules 'import'
    Sync-Skills (Join-Path $ClaudeDir 'skills') 'skill' $skills
    Sync-McpJson $ClaudeJson 'mcp' $mcps

    # Codex and omp share ~/.agents/skills; their AGENTS.md get the rule text itself
    $codex = Has-Codex; $omp = Has-Omp
    if ($codex -or $omp) { Sync-Skills $AgentsSkills 'skill.agents' $skills }
    if ($codex) {
        Set-Rules (Join-Path $CodexDir 'AGENTS.md') $rules 'inline'
        Replace-Block (Join-Path $CodexDir 'config.toml') $TomlBegin $TomlEnd (Codex-Mcp-Toml $mcps)
    }
    if ($omp) {
        Set-Rules (Join-Path $OmpDir 'AGENTS.md') $rules 'inline'
        Sync-McpJson (Join-Path $OmpDir 'mcp.json') 'mcp.omp' $mcps
    }

    # tool deny rules and the auto-sync hook -> ~/.claude/settings.json
    $ops = New-Object System.Collections.Generic.List[object]
    $deny = Required-Deny
    foreach ($n in $deny) {
        if ($null -ne (State-Get 'deny' $n)) { continue }
        $ops.Add(@('addstr', 'permissions.deny', $n)); State-Set 'deny' $n 1; Say "  deny $n"
    }
    foreach ($n in State-List 'deny') {
        if ($deny -contains $n) { continue }
        $ops.Add(@('rmstr', 'permissions.deny', $n)); State-Del 'deny' $n; Say "  removed deny $n"
    }
    $hj = Hook-Json; $old = State-Get 'hook' 'SessionStart'
    if ($hj -ne $old) {
        if ($old) { $ops.Add(@('rmjson', 'hooks.SessionStart', $old)) }
        $ops.Add(@('addjson', 'hooks.SessionStart', $hj)); State-Set 'hook' 'SessionStart' $hj
    }
    if ($ops.Count -gt 0) { Json-Edit (Join-Path $ClaudeDir 'settings.json') $ops.ToArray(); Prune-Deny }
}

# ---------- commands ----------
function Need-Init { if (-not (Test-Path -LiteralPath $Machine)) { Die '還沒設定：先打  kit init <網址或資料夾>' } }
function Seen-All { foreach ($i in Available) { if ($null -eq (State-Get 'seen' $i)) { State-Set 'seen' $i 1 } } }
function Ver-Num([string]$v) { # sortable text for x.y.z ("+build" ignored); $null for a dev build or anything else
    $v = ($v -replace '\+.*$', '').Trim()
    if ($v -notmatch '^\d+(\.\d+){0,2}$') { return $null }
    $p = @($v.Split('.')) + @('0', '0')
    '{0:D9}{1:D9}{2:D9}' -f [long]$p[0], [long]$p[1], [long]$p[2]
}
function Wanted-Version { # the newest kit_version the sources ask for, when it is newer than this kit ('' otherwise)
    $best = Ver-Num $KitVersion; if (-not $best) { return '' }
    $need = ''
    foreach ($d in Src-Dirs) {
        foreach ($v in @(YGet (Join-Path $d 'kit.yaml') 'kit_version')) {
            $n = Ver-Num $v
            if ($n -and [string]::CompareOrdinal($n, $best) -gt 0) { $best = $n; $need = $v.Trim() }
        }
    }
    $need
}
function Version-Nag { # tell once when a source's kit.yaml wants a newer kit (not in the background, not when quiet)
    if ($script:Quiet -or $script:LogPath) { return }
    $need = Wanted-Version
    if (-not $need) { if ($null -ne (State-Get 'nag' 'kit_version')) { State-Del 'nag' 'kit_version' }; return }
    if ((State-Get 'nag' 'kit_version') -eq "${need} ${KitVersion}") { return }
    Say "kit：團隊要 kit ${need} 以上，你的是 ${KitVersion}。請打  kit self-update"
    State-Set 'nag' 'kit_version' "${need} ${KitVersion}"
}

function Cmd-Init($srcs) {
    if (@($srcs).Count -lt 1) { Die '用法：kit init <網址或資料夾> [更多來源...]' }
    $list = @(foreach ($s in $srcs) {
        if (Is-Url $s) { $s }
        elseif (Test-Path -LiteralPath $s -PathType Container) { (Resolve-Path -LiteralPath $s).ProviderPath }
        else { Die "找不到資料夾：$s" }
    })
    Write-Machine $list @() @()
    foreach ($s in M-Sources) { Fetch-Source $s }
    Add-Includes $true
    Write-Machine (M-Sources) (Kit-Items 'recommended') @()
    Say "kit：設定好 $(@(M-Sources).Count) 個來源"
    Apply-All
    Seen-All
    Say 'kit：完成。打  kit list  看有哪些'
}
function Includes { # include: entries of every source; a local path is relative to the source that lists it
    Uniq @(foreach ($d in Src-Dirs) {
        foreach ($i in @(YGet (Join-Path $d 'kit.yaml') 'include')) {
            if (-not $i) { continue }
            if (Is-Url $i) { $i; continue }
            $p = if ([IO.Path]::IsPathRooted($i)) { $i } else { Join-Path $d $i }
            if (Test-Path -LiteralPath $p -PathType Container) { (Resolve-Path -LiteralPath $p).ProviderPath } else { $p }
        }
    })
}
function Add-Includes([bool]$quietly = $false) { # add sources that a source includes but machine.yaml does not list yet (also chains)
    for ($n = 0; $n -lt 5; $n++) {
        $have = @(M-Sources); $dirs = @(Src-Dirs)
        # skip includes that are already a source (same URL, or the same folder as a clone)
        $more = @(@(Includes) | Where-Object { $_ -and $have -notcontains $_ -and $dirs -notcontains (Src-Dir $_) })
        if ($more.Count -eq 0) { return }
        Write-Machine (Uniq (@($have) + @($more))) @(M-Added) @(M-Removed)
        foreach ($s in $more) {
            Fetch-Source $s
            if (-not $quietly) { Say "kit：加了來源 ${s}（某個來源的 kit.yaml 引用它）" }
        }
    }
}
function Cmd-Sync {
    Need-Init
    foreach ($s in M-Sources) { Fetch-Source $s }
    Add-Includes
    Apply-All
    $new = @(foreach ($i in Available) { if ($null -eq (State-Get 'seen' $i)) { $i } })
    if ($new.Count -gt 0) { Say "kit：新： $($new -join ' ')  （要用就 kit add <種類> <名字>）" }
    Seen-All
    Version-Nag
}
function Sync-Hook { # run by Claude at start: sync in the background, at most every 10 minutes
    if (-not (Test-Path -LiteralPath $Machine)) { exit 0 }
    $stamp = Join-Path $KitConf 'last-sync'; $lock = Join-Path $KitConf 'sync.lock'
    if ((Test-Path -LiteralPath $stamp) -and (Get-Item -LiteralPath $stamp).LastWriteTime -gt (Get-Date).AddMinutes(-10)) { exit 0 }
    if ((Test-Path -LiteralPath $lock) -and (Get-Item -LiteralPath $lock).LastWriteTime -lt (Get-Date).AddMinutes(-10)) { Remove-Item -LiteralPath $lock -Force -Recurse }
    try { [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop) } catch { exit 0 }   # another sync is running
    Write-Text $stamp ''
    $exe = (Get-Process -Id $PID).Path
    $argline = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" sync --bg"
    if ($OnWindows) { Start-Process -FilePath $exe -ArgumentList $argline -WindowStyle Hidden }
    else { Start-Process -FilePath $exe -ArgumentList $argline }
    exit 0
}
function Sync-Bg { # the background half of Sync-Hook
    $lock = Join-Path $KitConf 'sync.lock'; $log = Join-Path $KitConf 'sync.log'
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 100000) { Move-Item -LiteralPath $log -Destination "$log.old" -Force }
    $script:LogPath = $log
    try {
        Say "== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $env:GIT_HTTP_LOW_SPEED_LIMIT = '1000'; $env:GIT_HTTP_LOW_SPEED_TIME = '20'
        Cmd-Sync
    } catch { Warn $_.Exception.Message }
    finally { Remove-Item -LiteralPath $lock -Force -Recurse -ErrorAction SilentlyContinue }
}

function Json-S([string]$s) { # a JSON string: \ " TAB LF CR escaped, other control characters dropped (the same as unix/kit)
    $s = [regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    Json-Str $s
}
function Item-Desc([string]$kind, [string]$f) { # the description of a skill or agent (frontmatter) or of an MCP yaml
    try {
        if ($kind -eq 'skill' -or $kind -eq 'agent') {
            if (((Read-Text $f) -split "`n")[0].TrimEnd("`r") -ne '---') { return '' }
            $v = @(YGet-From (Yaml-Lines $f -Frontmatter) 'description')
        } elseif ($kind -eq 'mcp') { $v = @(YGet $f 'description') }
        else { return '' }
    } catch { return '' }
    if ($v.Count -gt 0) { [string]$v[0] } else { '' }
}
function Json-Keys([string]$file, [string[]]$path) { # the keys of the object at PATH (a list of keys), one per item
    try { $n = Json-Parse (Read-Text $file) } catch { return @() }
    foreach ($part in $path) { $i = Json-Child $n $part; if ($i -lt 0) { return @() }; $n = $n.v[$i] }
    if ($n.t -ne 'o') { return @() }
    @(foreach ($k in $n.k) { $k.Substring(1, $k.Length - 2) })
}
function Real-Dir([string]$d) { # the folder with links resolved (like pwd -P), as Claude names its projects
    $f = Full-Path $d
    if (-not $OnWindows) { $r = "$(& /bin/sh -c 'if cd "$1"; then pwd -P; fi' sh $f 2>$null)".Trim(); if ($r) { return $r } }
    $f
}
function Here-Short([string]$dir, [string]$f) { # inside DIR relative to it, else with ~ for the home folder
    $sep = [IO.Path]::DirectorySeparatorChar
    if ($f.StartsWith($dir + $sep)) { return $f.Substring($dir.Length + 1) }
    if ($f.StartsWith($UserHome + $sep)) { return '~' + $f.Substring($UserHome.Length) }
    $f
}
function Sorted-Names($items) { $a = [string[]]@($items | ForEach-Object { $_.Name }); [Array]::Sort($a, [StringComparer]::Ordinal); $a }
function Here-Rows([string]$dir) { # what an agent started in DIR gets that kit does not manage: @(scope, kind, name, path, tools)
    $rows = New-Object System.Collections.Generic.List[object]
    $cd = Join-Path $ClaudeDir 'CLAUDE.md'
    $a = $dir
    while ($a) {
        foreach ($f in @((Join-Path $a 'CLAUDE.md'), (Join-Path $a 'CLAUDE.local.md'), (Join-Path (Join-Path $a '.claude') 'CLAUDE.md'))) {
            if ((Test-Path -LiteralPath $f -PathType Leaf) -and $f -ne $cd) { $rows.Add(@('dir', 'rule', (Here-Short $dir $f), $f, 'claude')) }
        }
        $dc = Join-Path $a '.claude'
        if ($dc -ne $ClaudeDir) {
            $rd = Join-Path $dc 'rules'
            if (Test-Path -LiteralPath $rd -PathType Container) {
                foreach ($n in Sorted-Names (Get-ChildItem -LiteralPath $rd -File -Filter '*.md')) { $f = Join-Path $rd $n; $rows.Add(@('dir', 'rule', (Here-Short $dir $f), $f, 'claude')) }
            }
            $sd = Join-Path $dc 'skills'
            if (Test-Path -LiteralPath $sd -PathType Container) {
                foreach ($n in Sorted-Names (Get-ChildItem -LiteralPath $sd -Directory)) { $f = Join-Path (Join-Path $sd $n) 'SKILL.md'; if (Test-Path -LiteralPath $f -PathType Leaf) { $rows.Add(@('dir', 'skill', $n, $f, 'claude')) } }
            }
        }
        $f = Join-Path $a 'AGENTS.md'
        if (Test-Path -LiteralPath $f -PathType Leaf) { $rows.Add(@('dir', 'rule', (Here-Short $dir $f), $f, 'codex omp')) }
        $up = Split-Path -Parent $a
        if (-not $up -or $up -eq $a) { break }
        $a = $up
    }
    $f = Join-Path $dir '.mcp.json'
    if (Test-Path -LiteralPath $f -PathType Leaf) { foreach ($n in Json-Keys $f @('mcpServers')) { $rows.Add(@('dir', 'mcp', $n, $f, 'claude')) } }
    if (Test-Path -LiteralPath $ClaudeJson -PathType Leaf) {
        foreach ($n in Json-Keys $ClaudeJson @('projects', $dir, 'mcpServers')) { $rows.Add(@('dir', 'mcp', $n, $ClaudeJson, 'claude')) }
    }
    $sd = Join-Path $ClaudeDir 'skills'
    if (Test-Path -LiteralPath $sd -PathType Container) {
        foreach ($n in Sorted-Names (Get-ChildItem -LiteralPath $sd -Directory)) {
            $f = Join-Path (Join-Path $sd $n) 'SKILL.md'
            if ((Test-Path -LiteralPath $f -PathType Leaf) -and $null -eq (State-Get 'skill' $n)) { $rows.Add(@('user', 'skill', $n, $f, 'claude')) }
        }
    }
    if (Test-Path -LiteralPath $ClaudeJson -PathType Leaf) {
        foreach ($n in Json-Keys $ClaudeJson @('mcpServers')) { if ($null -eq (State-Get 'mcp' $n)) { $rows.Add(@('user', 'mcp', $n, $ClaudeJson, 'claude')) } }
    }
    $rows
}
function Other-User([string]$top) { # the user of a process under PID that is not me (an agent started with sudo -i), if any
    if ($OnWindows) { return '' }
    $me = "$(& id -un 2>$null)".Trim(); if (-not $me) { return '' }
    $u = @{}; $p = @{}
    foreach ($l in @(& ps -A -o user= -o pid= -o ppid= -o comm= 2>$null)) {
        $f = @("$l".Trim() -split '\s+')
        if ($f.Count -lt 4 -or $f[1] -notmatch '^[0-9]+$' -or $f[3] -match '(^|/)ps$') { continue }
        $u[$f[1]] = $f[0]; $p[$f[1]] = $f[2]
    }
    foreach ($x in $p.Keys) {
        $y = $x; $i = 0
        while ($i -lt 64 -and $y -ne $top -and $p.ContainsKey($y)) { $y = $p[$y]; $i++ }
        if ($y -eq $top -and $x -ne $top -and $u[$x] -ne $me) { return $u[$x] }
    }
    ''
}
function Here-Json([string]$dir, [string]$hpid) { # the "here" part of kit list --json --dir
    $user = if ($hpid) { Other-User $hpid } else { '' }
    $out = ",`n  `"here`": {`"dir`": $(Json-S $dir), `"user`": $(if ($user) { Json-S $user } else { 'null' })"
    if ($user) { return $out + ', "items": []}' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $out + ", `"error`": $(Json-S '找不到這個資料夾'), `"items`": []}" }
    $out += ', "items": ['
    $first = $true
    foreach ($r in Here-Rows $dir) {
        $d = ''
        if ($r[1] -eq 'skill') { $d = Item-Desc 'skill' $r[3] }
        elseif ($r[1] -eq 'rule') {
            try { $h = @((Read-Text $r[3]) -split "`n" | Where-Object { $_.StartsWith('# ') } | Select-Object -First 1); if ($h.Count) { $d = $h[0] -replace '^# *', '' } } catch { }
        }
        if (-not $first) { $out += ',' }; $first = $false
        $out += "`n    {`"scope`": $(Json-S $r[0]), `"kind`": $(Json-S $r[1]), `"name`": $(Json-S $r[2]), `"path`": $(Json-S $r[3]), `"tools`": $(Json-S $r[4]), `"description`": $(Json-S $d)}"
    }
    $out + "`n  ]}"
}
function Cmd-ListJson([string]$hereDir = '', [string]$herePid = '') { # what kit list shows, as JSON for programs (the Herdr panel); unix/kit prints the same
    $want = Wanted; $req = Kit-Items 'required'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`n  `"kit`": $(Json-S $KitVersion),`n  `"sources`": [")
    $first = $true
    foreach ($s in @(M-Sources)) {
        if (-not $s) { continue }
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append("`n    {`"name`": $(Json-S (Src-Name $s)), `"source`": $(Json-S $s), `"dir`": $(Json-S (Src-Dir $s))}")
    }
    $tools = '"claude"'; if (Has-Codex) { $tools += ', "codex"' }; if (Has-Omp) { $tools += ', "omp"' }
    [void]$sb.Append("`n  ],`n  `"tools`": [$tools],`n  `"items`": [")
    $first = $true
    foreach ($i in Available) {
        $c = $i.IndexOf(':'); $k = $i.Substring(0, $c); $n = $i.Substring($c + 1)
        $p = $null; $dir = $null
        foreach ($d in Src-Dirs) { $q = Item-Path $d $k $n; if (Test-Path -LiteralPath $q -PathType Leaf) { $p = $q; $dir = $d; break } }
        if (-not $p) { continue }
        $status = 'unused'
        if ($want -contains $i) { $status = 'used' }
        if ($req -contains $i) { $status = 'required' }
        if ($k -eq 'agent') { $status = 'agent' }
        $new = if ($null -eq (State-Get 'seen' $i)) { 'true' } else { 'false' }
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append("`n    {`"kind`": $(Json-S $k), `"name`": $(Json-S $n), `"status`": $(Json-S $status), `"new`": $new, `"source`": $(Json-S (Split-Path -Leaf $dir)), `"description`": $(Json-S (Item-Desc $k $p))}")
    }
    [void]$sb.Append("`n  ],`n  `"kit_version_wanted`": $(Json-S (Wanted-Version))")
    if ($hereDir) { [void]$sb.Append((Here-Json $hereDir $herePid)) }
    [void]$sb.Append("`n}")
    Say $sb.ToString()
}
function Cmd-List($rest) {
    $rest = @($rest | Where-Object { $null -ne $_ })
    if ($rest.Count -ge 1 -and $rest[0] -eq '--json') {
        $hd = ''; $hp = ''
        for ($i = 1; $i -lt $rest.Count; $i++) {
            switch -CaseSensitive ($rest[$i]) {
                '--dir' { if ($i + 1 -ge $rest.Count) { Die '--dir 後面要接資料夾' }; $i++; $hd = $rest[$i]; if (Test-Path -LiteralPath $hd -PathType Container) { $hd = Real-Dir $hd } }
                '--pid' { if ($i + 1 -ge $rest.Count -or $rest[$i + 1] -notmatch '^[0-9]+$') { Die '--pid 後面要接數字' }; $i++; $hp = $rest[$i] }
                default { Die '用法：kit list --json [--dir 資料夾] [--pid 程式編號]' }
            }
        }
        Need-Init; Cmd-ListJson $hd $hp; return
    }
    if ($rest.Count -gt 0) { Die '用法：kit list [--json [--dir 資料夾] [--pid 程式編號]]' }
    Need-Init
    $want = Wanted; $req = Kit-Items 'required'
    foreach ($i in Available) {
        $mark = '  '
        if ($want -contains $i) { $mark = '* ' }
        if ($req -contains $i) { $mark = 'R ' }
        if ($i.StartsWith('agent:')) { $mark = '  ' }
        if ($null -eq (State-Get 'seen' $i)) { $mark = $mark.Substring(0, 1) + 'N' }
        Say "$mark $i"
    }
    Say ''
    Say '* 在用   R 團隊必備   N 新的   agent 用  kit run <名字>  開'
    Say "寫到：$(Targets)"
    Version-Nag
}
function Cmd-AddRm([string]$verb, $rest) {
    $rest = @($rest)
    if ($rest.Count -ne 2) { Die "用法：kit $verb rule|skill|mcp <名字>" }
    Need-Init
    $k = $rest[0]; $n = $rest[1]; $i = "${k}:$n"
    if (@('rule', 'skill', 'mcp') -notcontains $k) { Die '種類只能是 rule、skill、mcp' }
    if (-not (Find-Item $k $n)) { Die "找不到 ${i}（打 kit list 看有哪些）" }
    $added = @(M-Added); $removed = @(M-Removed)
    if ($verb -eq 'add') {
        $added = Uniq ($added + $i); $removed = @($removed | Where-Object { $_ -ne $i })
    } else {
        if ((Kit-Items 'required') -contains $i) { Die "$i 是團隊必備，拿不掉" }
        $added = @($added | Where-Object { $_ -ne $i }); $removed = Uniq ($removed + $i)
    }
    Write-Machine (M-Sources) $added $removed
    Apply-All
}
function Arg-TomlStr([string]$s) { # a TOML string safe to pass as ONE argument on every Windows shell:
    # no spaces, quotes, backslashes or % inside (all written as \uXXXX); outer quotes as \" for the C runtime
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -gt 127 -or $ch -match '[A-Za-z0-9_.,:/()\[\]{}=+@#-]') { [void]$sb.Append($ch) }
        else { [void]$sb.Append(('\u{0:X4}' -f [int]$ch)) }
    }
    '\"' + $sb.ToString() + '\"'
}
function Arg-TomlKey([string]$k) { if ($k -match '^[A-Za-z0-9_-]+$') { $k } else { Arg-TomlStr $k } }
function Cmd-Run($rest) {
    $rest = @($rest)
    if ($rest.Count -lt 1) { Die '用法：kit run <agent> [--tool claude|codex|omp] [工具的參數...]' }
    Need-Init
    $name = $rest[0]; $extra = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }
    $tool = 'claude'
    if ($extra.Count -gt 0 -and $extra[0] -eq '--tool') {
        if ($extra.Count -lt 2) { Die '--tool 後面要接 claude、codex 或 omp' }
        $tool = $extra[1]; $extra = if ($extra.Count -gt 2) { @($extra[2..($extra.Count - 1)]) } else { @() }
    }
    if (@('claude', 'codex', 'omp') -notcontains $tool) { Die '--tool 只能是 claude、codex 或 omp' }
    $f = Find-Item 'agent' $name; if (-not $f) { Die "找不到 agent ${name}（打 kit list 看有哪些）" }
    $script:Quiet = $true; try { Cmd-Sync } catch { }; $script:Quiet = $false

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('kit-run.' + [IO.Path]::GetRandomFileName())
    $skdir = if ($tool -eq 'claude') { Join-Path $tmp '.claude/skills' } else { Join-Path $tmp 'skills' }
    Ensure-Dir $skdir
    $fm = $null
    try { $fm = Yaml-Lines $f -Frontmatter } catch { Die "bad header in $f" }
    $skills = @()
    foreach ($n in YGet-From $fm 'skills') {
        $p = Find-Item 'skill' $n; if (-not $p) { Warn "skill $n not found"; continue }
        Copy-Item -LiteralPath (Split-Path -Parent $p) -Destination (Join-Path $skdir $n) -Recurse
        $skills += $n
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in YGet-From $fm 'rules') {
        $p = Find-Item 'rule' $n; if (-not $p) { Warn "rule $n not found"; continue }
        [void]$sb.Append((Read-Text $p)).Append("`n")
    }
    $c = 0; foreach ($l in (Read-Text $f) -split "`n") { if ($c -ge 2) { [void]$sb.Append($l.TrimEnd("`r")).Append("`n") }; if ($l.TrimEnd("`r") -eq '---') { $c++ } }
    if ($tool -eq 'codex' -and $skills.Count -gt 0) {
        # Codex cannot load skills from an extra folder: list them, it reads one when needed
        [void]$sb.Append("`n## Skills`nSkills you have. Before doing a task one of them covers, read its SKILL.md and follow it.`n")
        foreach ($n in $skills) {
            $sk = Join-Path (Join-Path $skdir $n) 'SKILL.md'; $desc = ''
            try { $desc = @(YGet-From (Yaml-Lines $sk -Frontmatter) 'description')[0] } catch { }
            [void]$sb.Append("- ${n}: $desc ($sk)`n")
        }
    }
    $prompt = $sb.ToString()
    Write-Text (Join-Path $tmp 'prompt.md') $prompt
    $only = @(YGet-From $fm 'tools.only'); $deny = @(YGet-From $fm 'tools.deny')
    $mcpNames = @(YGet-From $fm 'mcp')

    $a = New-Object System.Collections.Generic.List[string]
    switch ($tool) {
        'claude' {
            $mcps = @(foreach ($n in $mcpNames) {
                $p = Find-Item 'mcp' $n; if (-not $p) { Warn "mcp $n not found"; continue }
                $k = Mcp-Json $p; if ($k) { (Json-Str $n) + ':' + $k }
            })
            Write-Text (Join-Path $tmp 'mcp.json') ('{"mcpServers":{' + ($mcps -join ',') + "}}`n")
            $a.AddRange([string[]]@('--add-dir', $tmp, '--append-system-prompt-file', (Join-Path $tmp 'prompt.md'), '--mcp-config', (Join-Path $tmp 'mcp.json')))
            if ($only.Count -gt 0) { $a.Add('--tools'); $a.Add($only -join ',') }
            foreach ($d in $deny) { $a.Add('--disallowedTools'); $a.Add($d) }
        }
        'codex' {
            $a.Add('-c'); $a.Add('developer_instructions=' + (Arg-TomlStr $prompt))
            foreach ($n in $mcpNames) {
                $p = Find-Item 'mcp' $n; if (-not $p) { Warn "mcp $n not found"; continue }
                $y = Yaml-Lines $p; $cmd = @(YGet-From $y 'command')
                if ($cmd.Count -eq 0 -or -not $cmd[0]) { Warn "$p has no command"; continue }
                $v = '{command=' + (Arg-TomlStr $cmd[0])
                $args2 = @(YGet-From $y 'args'); if ($args2.Count -gt 0) { $v += ',args=[' + ((@($args2) | ForEach-Object { Arg-TomlStr $_ }) -join ',') + ']' }
                $envs = @(Mcp-Env $y); if ($envs.Count -gt 0) { $v += ',env={' + ((@($envs) | ForEach-Object { (Arg-TomlKey $_[0]) + '=' + (Arg-TomlStr $_[1]) }) -join ',') + '}' }
                $tools = @(foreach ($d in $deny) { if ($d.StartsWith("mcp__${n}__")) { Arg-TomlStr $d.Substring("mcp__${n}__".Length) } })
                if ($tools.Count -gt 0) { $v += ',disabled_tools=[' + ($tools -join ',') + ']' }
                $a.Add('-c'); $a.Add("mcp_servers.$(Arg-TomlKey $n)=$v}")
            }
            if ($only.Count -gt 0) { Warn 'Codex 不能只開某些內建工具，tools.only 這次不套用' }
            if (@($deny | Where-Object { -not $_.StartsWith('mcp__') }).Count -gt 0) { Warn 'Codex 只能禁用 MCP 的工具，其他的 tools.deny 這次不套用' }
        }
        'omp' {
            Write-Text (Join-Path $tmp 'omp.yml') ("skills:`n  customDirectories:`n    - " + (Json-Str $skdir) + "`n")
            $a.AddRange([string[]]@('--config', (Join-Path $tmp 'omp.yml'), '--append-system-prompt', (Join-Path $tmp 'prompt.md')))
            if ($only.Count -gt 0) { $a.Add('--tools'); $a.Add(($only -join ',').ToLowerInvariant()) }
            if ($mcpNames.Count -gt 0) { Warn 'omp 不能在啟動時加 MCP：這個 agent 的 MCP 請用  kit add mcp <名字>  加到全域' }
            if ($deny.Count -gt 0) { Warn 'omp 不能禁用單一工具，tools.deny 這次不套用' }
        }
    }
    foreach ($x in $extra) { $a.Add($x) }
    if ($env:KIT_DRY_RUN) { Say $tool; foreach ($x in $a) { Say $x }; Say "tmp=$tmp"; return }
    # the same quoting rules on PowerShell 5.1 and 7 (Arg-TomlStr is written for them)
    $PSNativeCommandArgumentPassing = 'Legacy'
    & $tool @($a.ToArray())
    $rc = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit $rc
}
function Cmd-Uninstall($rest) {
    $self = (@($rest) -contains '--self')
    foreach ($f in @((Join-Path $ClaudeDir 'CLAUDE.md'), (Join-Path $CodexDir 'AGENTS.md'), (Join-Path $OmpDir 'AGENTS.md'))) { Replace-Block $f $BeginMark $EndMark '' }
    Replace-Block (Join-Path $CodexDir 'config.toml') $TomlBegin $TomlEnd ''
    $script:Quiet = $true
    Sync-Skills (Join-Path $ClaudeDir 'skills') 'skill' @()
    Sync-Skills $AgentsSkills 'skill.agents' @()
    Sync-McpJson $ClaudeJson 'mcp' @()
    Sync-McpJson (Join-Path $OmpDir 'mcp.json') 'mcp.omp' @()
    $script:Quiet = $false
    $ops = New-Object System.Collections.Generic.List[object]
    foreach ($r in State-Rows) {
        $f = $r.Split("`t")
        if ($f[0] -eq 'deny') { $ops.Add(@('rmstr', 'permissions.deny', $f[1])) }
        if ($f[0] -eq 'hook') { $ops.Add(@('rmjson', "hooks.$($f[1])", $f[2])) }
    }
    if ($ops.Count -gt 0) { Json-Edit (Join-Path $ClaudeDir 'settings.json') $ops.ToArray(); Prune-Deny }
    foreach ($f in @($State, $Machine)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    Say 'kit：已移除 kit 放進 Claude、Codex、omp 的東西（你自己的檔案沒動）'
    Say "     來源的 clone 還留在 $KitSrc"
    if ($self) {
        $dir = if ((Split-Path -Leaf $KitLib) -eq 'lib') { Split-Path -Parent $KitLib } else { $KitLib }
        if ($OnWindows) {
            $p = [Environment]::GetEnvironmentVariable('Path', 'User')
            if ($p) { [Environment]::SetEnvironmentVariable('Path', ((@($p.Split(';') | Where-Object { $_ -and $_.TrimEnd('\') -ne $dir.TrimEnd('\') })) -join ';'), 'User') }
        }
        if (Test-Path -LiteralPath (Join-Path $KitLib '.repo')) { Remove-Item -LiteralPath $dir -Recurse -Force }   # only an installed copy
        Say 'kit：kit 本身也移除了'
    }
}
function Cmd-SelfUpdate { # pull the clone kit was installed from, then reinstall
    $rp = Join-Path $KitLib '.repo'
    if (-not (Test-Path -LiteralPath $rp)) { Die '不知道 kit 是從哪個 clone 裝的；請到 clone 裡 git pull 後重跑 windows\install.ps1' }
    $repo = (Read-Text $rp).Trim()
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { Die "找不到 clone：$repo" }
    $url = (Git-Safe -C $repo remote get-url origin | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $url) { Check-Host $url }
    $before = "$(& git -C $repo rev-parse --short=12 HEAD 2>$null)".Trim()
    [void](Git-Safe -C $repo pull --ff-only -q)
    if ($LASTEXITCODE -ne 0) { Die "沒辦法更新 ${repo}（沒網路，或 clone 裡有自己的改動？）" }
    $exe = (Get-Process -Id $PID).Path
    & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'windows/install.ps1') -Quiet
    if ($LASTEXITCODE -ne 0) { Die '重新安裝失敗' }
    $ver = (Read-Text (Join-Path $KitLib 'VERSION')).Trim(); $now = "$(& git -C $repo rev-parse --short=12 HEAD 2>$null)".Trim()
    if ($before -and $before -eq $now) { Say "kit：已經是最新（$ver，$now）" } else { Say "kit：已更新到 $ver（$now）" }
}
# ---------- authoring: new / diff / update (local folders only, never the network) ----------
$script:Kinds = @('rule', 'skill', 'mcp', 'agent')
function Valid-Name([string]$n) { $n -cmatch '^[a-z0-9][a-z0-9-]*$' }
function Is-Link($e) { [bool]($e.Attributes -band [IO.FileAttributes]::ReparsePoint) }
function Walk-Tree([string]$base) { # every entry under BASE; .git folders and links are listed but not entered
    $stack = New-Object System.Collections.Stack; $stack.Push($base)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        foreach ($e in @(Get-ChildItem -LiteralPath $d -Force)) {
            $e
            if ($e.PSIsContainer -and $e.Name -ne '.git' -and -not (Is-Link $e)) { $stack.Push($e.FullName) }
        }
    }
}
function Full-Path([string]$p) { (Get-Item -LiteralPath $p -Force).FullName.TrimEnd('\', '/') }
function Rel-Path([string]$base, [string]$full) { $full.Substring($base.Length + 1).Replace('\', '/') }
function File-Hash([string]$f) {
    $sha = [Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f)))).Replace('-', '').Substring(0, 16)
}
function Item-Hash([string]$kind, [string]$file) { if ($kind -eq 'skill') { Dir-Hash (Split-Path -Parent $file) } else { File-Hash $file } }
function Target-Dir([string]$to) { # --to <source name|folder>, else the folder you are in if it has kit.yaml, else the first source
    if ($to) {
        if (Test-Path -LiteralPath $Machine) { foreach ($d in Src-Dirs) { if ((Split-Path -Leaf $d) -eq $to) { return $d } } }
        if (-not (Test-Path -LiteralPath $to -PathType Container)) { Die "找不到 --to ${to}（要是來源名字或資料夾）" }
        return (Full-Path $to)
    }
    if (Test-Path -LiteralPath 'kit.yaml' -PathType Leaf) { return (Get-Location).ProviderPath }
    Need-Init
    @(Src-Dirs)[0]
}
function Stage-From([string]$kind, [string]$name, [string]$from, [string]$out) { # copy what kit accepts into OUT; returns the item file
    if (Is-Url $from) { Die '--from 只吃本機的資料夾或檔案（先自己 git clone 到暫存資料夾）' }
    if (-not (Test-Path -LiteralPath $from)) { Die "找不到 $from" }
    $from = Full-Path $from
    if ($kind -eq 'skill') {
        $sk = Join-Path $from 'SKILL.md'
        if (-not (Test-Path -LiteralPath $from -PathType Container) -or -not (Test-Path -LiteralPath $sk -PathType Leaf)) { Die "$from 要是有 SKILL.md 的資料夾" }
        $scripts = (Read-Text $sk).Contains('scripts/')
        $dst = Join-Path $out $name; Ensure-Dir $dst
        $skipped = 0
        foreach ($e in @(Walk-Tree $from)) {
            if ($e.Name -eq '.git' -or $e.Name -eq '.DS_Store') { continue }
            $link = Is-Link $e
            if ($e.PSIsContainer -and -not $link) { continue }
            $rel = Rel-Path $from $e.FullName
            if ($link -or $e.Name -cmatch '^(LICENSE|LICENCE|COPYING|README|CHANGELOG)') { $skipped++; continue }
            if ($rel.StartsWith('scripts/')) { if (-not $scripts) { $skipped++; continue } }
            elseif (-not $rel.EndsWith('.md', [StringComparison]::Ordinal)) { $skipped++; continue }
            $t = Join-Path $dst $rel; Ensure-Dir (Split-Path -Parent $t)
            Copy-Item -LiteralPath $e.FullName -Destination $t
        }
        if ($skipped -gt 0) { Warn ("跳過 $skipped 個檔案（只帶 .md" + $(if ($scripts) { '、scripts/' } else { '' }) + '；不帶 LICENSE、README、.git）') }
        return (Join-Path $dst 'SKILL.md')
    }
    $ext = if ($kind -eq 'mcp') { 'yaml' } else { 'md' }
    $f = $from; if (Test-Path -LiteralPath $f -PathType Container) { $f = Join-Path $from "$name.$ext" }
    if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Is-Link (Get-Item -LiteralPath $f -Force)) -or -not $f.EndsWith(".$ext")) { Die "$from 要是一個 .$ext 檔（或有 $name.$ext 的資料夾）" }
    $t = Join-Path $out "$name.$ext"; Copy-Item -LiteralPath $f -Destination $t
    $t
}
function Put-Item([string]$kind, [string]$name, [string]$staged, [string]$dir) { # replace the item in DIR with the staged copy
    $dst = Item-Path $dir $kind $name
    if ($kind -eq 'skill') {
        $dd = Split-Path -Parent $dst
        if (Test-Path -LiteralPath $dd) { Remove-Item -LiteralPath $dd -Recurse -Force }
        Ensure-Dir (Split-Path -Parent $dd)
        Copy-Item -LiteralPath (Split-Path -Parent $staged) -Destination $dd -Recurse
    } else { Ensure-Dir (Split-Path -Parent $dst); Copy-Item -LiteralPath $staged -Destination $dst -Force }
    $dst
}
function Skeleton([string]$kind, [string]$name) {
    switch ($kind) {
        'rule' { "# $name`n`n（在這裡寫規則，一條一行。）`n" }
        'skill' { "---`nname: $name`ndescription: （什麼時候用這個 skill，一句話）`n---`n`n（在這裡寫步驟。）`n" }
        'mcp' { "command: （啟動 MCP server 的程式，例如 uvx）`nargs: []`n# env:`n#   KEY: value      # 不要放密碼`n" }
        'agent' { "---`nname: $name`ndescription: （這個 agent 做什麼）`nrules: []`nskills: []`nmcp: []`n# tools:`n#   only: [Read, Grep, Glob]`n#   deny: []`n---`n（在這裡寫 agent 的角色和做法。）`n" }
    }
}
function Parse-ItemArgs($rest) {
    $o = @{ Kind = ''; Name = ''; From = ''; To = ''; Force = $false }
    $rest = @($rest)
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $a = [string]$rest[$i]
        switch -CaseSensitive ($a) {
            '--from' { if ($i + 1 -ge $rest.Count) { Die '--from 後面要接資料夾' }; $i++; $o.From = [string]$rest[$i] }
            '--to' { if ($i + 1 -ge $rest.Count) { Die '--to 後面要接來源' }; $i++; $o.To = [string]$rest[$i] }
            '--force' { $o.Force = $true }
            default {
                if (-not $o.Name -and -not $o.Kind -and ($Kinds -ccontains $a)) { $o.Kind = $a }
                elseif (-not $o.Name) { $o.Name = $a }
                else { Die "多了一個參數：$a" }
            }
        }
    }
    $o
}
function Guess-Kind([string]$dir, [string]$name) {
    $found = @(foreach ($k in $Kinds) { if (Test-Path -LiteralPath (Item-Path $dir $k $name) -PathType Leaf) { $k } })
    if ($found.Count -eq 0) { Die "$(Split-Path -Leaf $dir) 裡沒有 $name" }
    if ($found.Count -gt 1) { Die "$name 有好幾種（$($found -join ' ')），請寫出種類，例：kit diff skill $name" }
    $found[0]
}
function New-TempDir([string]$prefix) { $t = Join-Path ([IO.Path]::GetTempPath()) ($prefix + [IO.Path]::GetRandomFileName()); Ensure-Dir $t; $t }

function Cmd-New($rest) {
    $o = Parse-ItemArgs $rest
    if (-not $o.Kind -or -not $o.Name) { Die '用法：kit new rule|skill|mcp|agent <名字> [--from 本機資料夾] [--to 來源]' }
    if (-not (Valid-Name $o.Name)) { Die "名字只能用小寫英文、數字和 -：$($o.Name)" }
    $dir = Target-Dir $o.To
    $dst = Item-Path $dir $o.Kind $o.Name
    if (Test-Path -LiteralPath $dst) { Die "$(Split-Path -Leaf $dir) 已經有 $($o.Kind):$($o.Name)（要更新用 kit update）" }
    if (Test-Path -LiteralPath $Machine) { $f = Find-Item $o.Kind $o.Name; if ($f) { Die "名字重複：別的來源已經有 $($o.Kind):$($o.Name)（$f）" } }
    if ($o.From) {
        $tmp = New-TempDir 'kit-new.'
        try { $f = Stage-From $o.Kind $o.Name $o.From $tmp; $dst = Put-Item $o.Kind $o.Name $f $dir }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        State-Set 'from' "$($o.Kind):$($o.Name)@$dir" (Item-Hash $o.Kind $dst)
        Say "已從 $($o.From) 帶進 $(Rel-Path $dir $dst)（在 $(Split-Path -Leaf $dir)）"
        Say "記得刪掉暫存的資料夾：$($o.From)"
    } else {
        Ensure-Dir (Split-Path -Parent $dst); Write-Text $dst (Skeleton $o.Kind $o.Name)
        Say "已建立 $(Rel-Path $dir $dst)（在 $(Split-Path -Leaf $dir)），打開它寫內容"
    }
    $script:Quiet2 = $true
    if (-not (Check-Dirs @($dir) $false)) { Warn 'kit check 有問題，送出前請先打  kit check  看看' }
}
function Cmd-DiffUpdate([string]$mode, $rest) {
    $o = Parse-ItemArgs $rest
    if (-not $o.Name -or -not $o.From) { Die "用法：kit $mode [種類] <名字> --from 本機資料夾 [--to 來源]" }
    $dir = Target-Dir $o.To
    $kind = if ($o.Kind) { $o.Kind } else { Guess-Kind $dir $o.Name }
    $dst = Item-Path $dir $kind $o.Name
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { Die "$(Split-Path -Leaf $dir) 裡沒有 ${kind}:$($o.Name)（新的用 kit new）" }
    $tmp = New-TempDir 'kit-diff.'
    try {
        $f = Stage-From $kind $o.Name $o.From $tmp
        $a = $dst; $b = $f; if ($kind -eq 'skill') { $a = Split-Path -Parent $dst; $b = Split-Path -Parent $f }
        $same = (Item-Hash $kind $dst) -eq (Item-Hash $kind $f)
        if ($mode -eq 'diff') {
            if ($same) { Say '一樣，沒有要更新的' } else { & git --no-pager diff --no-index --no-color -- $a $b | ForEach-Object { Say "$_" } }
            return
        }
        $old = State-Get 'from' "${kind}:$($o.Name)@$dir"; $now = Item-Hash $kind $dst
        if (-not $o.Force -and $old -ne $now) {
            if (-not $old) { Die "${kind}:$($o.Name) 不是這台用 kit new --from 帶進來的，不知道有沒有人改過。先 kit diff 看清楚，確定要蓋掉再加 --force" }
            Die "${kind}:$($o.Name) 在 $(Split-Path -Leaf $dir) 被改過（跟上次帶進來的不一樣）。先 kit diff 看差在哪；要保留別人的修改就手動合併，確定要蓋掉再加 --force"
        }
        if ($same) { Say '一樣，沒有要更新的'; return }
        $dst = Put-Item $kind $o.Name $f $dir
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    State-Set 'from' "${kind}:$($o.Name)@$dir" (Item-Hash $kind $dst)
    Say "已更新 $(Rel-Path $dir $dst)（在 $(Split-Path -Leaf $dir)）。記得刪掉暫存的資料夾：$($o.From)"
}

# ---------- check ----------
$script:Problems = $null
$script:CheckCi = $false
$script:Quiet2 = $false
$script:ProblemTag = 'kit check'
function Problem([string]$msg) { $script:Problems.Add($msg); if (-not $script:Quiet2) { [Console]::Error.WriteLine("$($script:ProblemTag): $msg") } }
function Is-Binary([string]$f) { $b = [IO.File]::ReadAllBytes($f); [Array]::IndexOf($b, [byte]0) -ge 0 }
function Private-Words($extra) { # the private word lists of this machine, the sources and the folders in $extra
    $files = @(Join-Path $KitConf 'private-words.txt')
    if (Test-Path -LiteralPath $Machine) { $files += @(foreach ($d in Src-Dirs) { Join-Path $d 'private-words.txt' }) }
    foreach ($d in @($extra | Where-Object { $_ })) { $files += @(Join-Path $d 'private-words.txt') }
    Uniq @(foreach ($f in $files) { if (Test-Path -LiteralPath $f -PathType Leaf) { foreach ($l in (Read-Text $f) -split "`n") { ($l -replace '#.*$', '').Trim() } } })
}
function Has-Word([string]$text, $words) { foreach ($w in $words) { if ($text.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }; $false }
function Check-Dirs($dirs, [bool]$loud = $true) { # print problems; $true when there are none
    $script:Problems = New-Object System.Collections.Generic.List[string]
    if ($loud) { $script:Quiet2 = $false }
    $dirs = @($dirs)
    # every item name, from the folders checked and the configured sources
    $all = @($dirs); if (Test-Path -LiteralPath $Machine) { $all += @(Src-Dirs) }
    $where = [ordered]@{}; $seenDir = @{}
    foreach ($d in $all) {
        if (-not (Test-Path -LiteralPath $d -PathType Container) -or $seenDir.ContainsKey($d)) { continue }; $seenDir[$d] = 1
        $items = @(foreach ($n in Names-In (Join-Path $d 'rules') '*.md') { "rule:$n" }
                   foreach ($n in Names-In (Join-Path $d 'skills') '' -Dirs) { "skill:$n" }
                   foreach ($n in Names-In (Join-Path $d 'mcp') '*.yaml') { "mcp:$n" }
                   foreach ($n in Names-In (Join-Path $d 'agents') '*.md') { "agent:$n" })
        foreach ($i in $items) { if (-not $where.Contains($i)) { $where[$i] = New-Object System.Collections.Generic.List[string] }; $where[$i].Add($d) }
    }
    foreach ($k in $where.Keys) { if ($where[$k].Count -gt 1) { Problem "名字重複：$k 在 $($where[$k] -join ' ')" } }
    $pw = @(Private-Words)
    foreach ($d0 in $dirs) {
        if (-not (Test-Path -LiteralPath $d0 -PathType Container)) { Problem "找不到資料夾 $d0"; continue }
        $d = Full-Path $d0
        $kitYaml = Join-Path $d 'kit.yaml'
        # format of each item
        $heads = @(foreach ($n in Names-In (Join-Path $d 'skills') '' -Dirs) { ,@("skills/$n/SKILL.md", $n) }) + @(foreach ($n in Names-In (Join-Path $d 'agents') '*.md') { ,@("agents/$n.md", $n) })
        foreach ($h in $heads) {
            $rel = $h[0]; $n = $h[1]; $f = Join-Path $d $rel
            if (-not (Valid-Name $n)) { Problem "${rel}: 名字只能用小寫英文、數字和 -" }
            $first = ((Read-Text $f) -split "`n")[0].TrimEnd("`r")
            $fm = $null
            if ($first -eq '---') { try { $fm = Yaml-Lines $f -Frontmatter } catch { $fm = $null } }
            if ($null -eq $fm) { Problem "${rel}: 開頭要有 --- 包起來的 name、description"; continue }
            if (@(YGet-From $fm 'name')[0] -ne $n) { Problem "${rel}: name 要寫 $n" }
            if (-not @(YGet-From $fm 'description')[0]) { Problem "${rel}: 少了 description" }
            if ($rel.StartsWith('agents/')) {
                foreach ($k in 'rule', 'skill', 'mcp') { foreach ($r in @(YGet-From $fm "${k}s")) { if ($r -and -not $where.Contains("${k}:$r")) { Problem "${rel}: 找不到 ${k}:$r" } } }
            }
        }
        foreach ($n in Names-In (Join-Path $d 'rules') '*.md') {
            if (-not (Valid-Name $n)) { Problem "rules/${n}.md: 名字只能用小寫英文、數字和 -" }
            if ((Get-Item -LiteralPath (Join-Path $d "rules/$n.md")).Length -eq 0) { Problem "rules/${n}.md: 是空的" }
        }
        foreach ($n in Names-In (Join-Path $d 'mcp') '*.yaml') {
            $rel = "mcp/$n.yaml"; $f = Join-Path $d $rel
            if (-not (Valid-Name $n)) { Problem "${rel}: 名字只能用小寫英文、數字和 -" }
            $cmd = @(YGet $f 'command')
            if ($cmd.Count -eq 0 -or -not $cmd[0]) { Problem "${rel}: 少了 command" }
            foreach ($v in @($cmd) + @(YGet $f 'args')) {
                if ($v -match '^(git\+|github:|git@)' -or $v.Contains('://')) { Problem "${rel}: MCP 只能從公司允許的套件來源裝，不能用 $v 這種寫法" }
            }
        }
        if (Test-Path -LiteralPath $kitYaml -PathType Leaf) {
            foreach ($k in 'rule', 'skill', 'mcp') {
                foreach ($r in @(YGet $kitYaml "required.${k}s") + @(YGet $kitYaml "recommended.${k}s")) {
                    if (-not $r -or $where.Contains("${k}:$r")) { continue }
                    if ($script:CheckCi -and @(YGet $kitYaml 'include').Count -gt 0) { Warn "kit.yaml: ${k}:$r 不在這個 repo（應該在 include 的來源）" } else { Problem "kit.yaml: 找不到 ${k}:$r" }
                }
            }
        }
        # files: no git inside, no links, text only
        $entries = @(Walk-Tree $d)
        $textFiles = New-Object System.Collections.Generic.List[object]
        foreach ($e in $entries) {
            $rel = Rel-Path $d $e.FullName
            if ($e.Name -eq '.git') { if ($rel -ne '.git') { Problem "${rel}: 裡面不能有別的 git repo" }; continue }
            if (Is-Link $e) { Problem "${rel}: 不能放捷徑（symlink）"; continue }
            if ($e.PSIsContainer) { continue }
            if ($e.Name -eq '.gitmodules') { Problem "${rel}: 不能用 git submodule" }
            if ($e.Length -gt 0 -and (Is-Binary $e.FullName)) { Problem "${rel}: 只能放文字檔"; continue }
            $textFiles.Add(@($rel, $e.FullName))
        }
        # URLs only to content_hosts (when the sources list them)
        $hosts = @(YGet $kitYaml 'content_hosts'); if (Test-Path -LiteralPath $Machine) { foreach ($sd in Src-Dirs) { $hosts += @(YGet (Join-Path $sd 'kit.yaml') 'content_hosts') } }
        $hosts = @(Uniq $hosts)
        foreach ($tf in $textFiles) {
            $lines = (Read-Text $tf[1]) -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($hosts.Count -gt 0) {
                    foreach ($m in [regex]::Matches($lines[$i], '(https?|ssh|git)://[^\]\[ "<>()`'']+|git@[A-Za-z0-9.-]+:')) {
                        $h = Url-Host $m.Value
                        if ($hosts -notcontains $h) { Problem "$($tf[0]):$($i + 1): 網址 $h 不在 content_hosts" }
                    }
                }
                if ($pw.Count -gt 0 -and (Split-Path -Leaf $tf[1]) -ne 'private-words.txt' -and (Has-Word $lines[$i] $pw)) { Problem "$($tf[0]):$($i + 1): 有不該公開的字" }
            }
        }
        if ($pw.Count -gt 0) { foreach ($e in $entries) { $rel = Rel-Path $d $e.FullName; if (Has-Word $rel $pw) { Problem "${rel}: 檔名有不該公開的字" } } }
        # --ci: commit author emails
        if ($script:CheckCi -and (Test-Path -LiteralPath (Join-Path $d '.git'))) {
            $doms = @(YGet $kitYaml 'author_domains')
            if ($doms.Count -gt 0) {
                $range = if ($env:KIT_CI_BASE) { "$($env:KIT_CI_BASE)..HEAD" } else { '-1' }
                foreach ($l in @(& git -C $d log --format='%h %ae' $range 2>$null)) {
                    $parts = "$l".Split(' '); if ($parts.Count -lt 2) { continue }
                    $dom = $parts[1].Substring($parts[1].LastIndexOf('@') + 1)
                    if ($doms -notcontains $dom) { Problem "commit $($parts[0]): 作者 email 不是公司網域" }
                }
            }
        }
    }
    $script:Problems.Count -eq 0
}
function Cmd-Check($rest) {
    $dirs = @()
    foreach ($a in @($rest | Where-Object { $_ })) {
        if ($a -eq '--ci') { $script:CheckCi = $true }
        elseif ("$a".StartsWith('-')) { Die "不認得 $a" }
        else { $dirs += $(if (Test-Path -LiteralPath $a) { Full-Path $a } else { $a }) }
    }
    if ($dirs.Count -eq 0) {
        if ((Test-Path -LiteralPath 'kit.yaml' -PathType Leaf) -or $script:CheckCi) { $dirs = @((Get-Location).ProviderPath) }
        else { Need-Init; $dirs = @(Src-Dirs) }
    }
    if (Check-Dirs $dirs) { Say "kit check：沒問題（$($dirs.Count) 個來源）" }
    else { [Console]::Error.WriteLine("kit check：$($script:Problems.Count) 個問題"); exit 1 }
}
function Cmd-CiTemplate($rest) { # print (or write to FILE, no BOM) the Gitea Actions workflow that runs kit check --ci on pull requests
    $to = @(@($rest) | Where-Object { $_ })
    foreach ($f in @((Join-Path $KitLib 'templates/gitea-kit-check.yaml'), (Join-Path (Split-Path -Parent $KitLib) 'templates/gitea-kit-check.yaml'))) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        if ($to.Count -gt 0) {
            $p = $to[0]; $dir = Split-Path -Parent $p; if ($dir) { Ensure-Dir $dir }
            Write-Text $p (Read-Text $f); Say "已寫到 $p"
        } else { [Console]::Out.Write((Read-Text $f)) }
        return
    }
    Die '找不到範本 gitea-kit-check.yaml（請重跑 windows\install.ps1）'
}

# ---------- export-self: a clean copy of kit's own source, for a company git server ----------
function Kit-Repo { # the clone kit was installed from, else the repo this kit runs from
    $rp = Join-Path $KitLib '.repo'
    if (Test-Path -LiteralPath $rp -PathType Leaf) {
        $d = (Read-Text $rp).Trim()
        if ($d -and (Test-Path -LiteralPath (Join-Path $d 'unix/kit') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $d 'windows/kit.ps1') -PathType Leaf)) { return $d }
    }
    $d = $KitLib
    while ($d) {
        if ((Test-Path -LiteralPath (Join-Path $d 'unix/kit') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $d 'windows/kit.ps1') -PathType Leaf)) { return $d }
        $p = Split-Path -Parent $d
        if (-not $p -or $p -eq $d) { break }
        $d = $p
    }
    $null
}
function Export-Skip([string]$rel) { # files that stay out of the export
    if ("/$rel".Contains('/.github/')) { return $true }
    $b = ($rel -split '/')[-1]
    ($b -match '^(README|CHANGELOG|LICENSE|LICENCE)') -or $b -eq 'private-words.txt'
}
function Install-Md { # INSTALL.md of the export (no URLs; the same text as unix/kit writes)
    $t = @'
# 安裝 kit

先把公司的 agentkit repo clone 下來（網址問管理這個 repo 的人），再照你的系統做。

## Windows

在 clone 的資料夾裡打：

    powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1

不用管理員權限。開新的終端機後，在 cmd 和 PowerShell 都能打 `kit`。

## Linux / Mac

需要 bash、awk、git。Mac 還沒有 git 的話，先打 `xcode-select --install`。
在 clone 的資料夾裡打：

    sh unix/install.sh

開新的終端機後就能打 `kit`。

## 裝好以後

    kit init <團隊來源的網址>
    kit help
'@
    ($t -replace "`r`n", "`n") + "`n"
}
function Mask-Path([string]$rel, $words) { # each part of the path with a word in it shown as <不公開>
    (@(foreach ($p in $rel.Split('/')) { if (Has-Word $p $words) { '<不公開>' } else { $p } })) -join '/'
}
function Cmd-ExportSelf($rest) {
    $out = ''; $ver = ''
    $a = @($rest | Where-Object { $null -ne $_ })
    for ($i = 0; $i -lt $a.Count; $i++) {
        $x = [string]$a[$i]
        if ($x -eq '--version') { if ($i + 1 -ge $a.Count -or -not $a[$i + 1]) { Die '--version 後面要接版本，例：0.4.0+gitea.12' }; $i++; $ver = [string]$a[$i] }
        elseif ($x.StartsWith('-')) { Die "不認得 $x" }
        elseif ($out) { Die "多了一個參數：$x" }
        else { $out = $x }
    }
    if (-not $out) { Die '用法：kit export-self <資料夾> [--version <版本>]' }
    if ($ver -and $ver -notmatch '^[A-Za-z0-9.+_-]+$') { Die "版本只能用英文、數字和 . + - _：$ver" }
    $repo = Kit-Repo
    if (-not $repo) { Die '找不到 kit 的原始碼（有 unix/kit 和 windows/kit.ps1 的 git clone）' }
    [void](Git-Safe -C $repo rev-parse --git-dir)
    if ($LASTEXITCODE -ne 0) { Die "$repo 不是 git repo" }
    if (Test-Path -LiteralPath $out) {
        $e = Get-Item -LiteralPath $out -Force
        if (-not $e.PSIsContainer -or (Is-Link $e) -or @(Get-ChildItem -LiteralPath $out -Force).Count -gt 0) { Die "$out 已經存在而且不是空的；請給一個新的資料夾" }
    }
    Ensure-Dir $out
    $out = Full-Path $out
    $dirty = @(Git-Safe -C $repo status --porcelain --untracked-files=no | Where-Object { $_ })
    if ($dirty.Count -gt 0) { Warn "$repo 有還沒 commit 的改動，匯出的是資料夾裡現在的檔案" }

    $script:Problems = New-Object System.Collections.Generic.List[string]
    $script:Quiet2 = $false; $script:ProblemTag = 'kit export-self'
    # only files git tracks (the index), taken from the working folder
    $raw = (@(Git-Safe -C $repo -c core.quotepath=off ls-files -s -z) -join "`n")
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $out -Recurse -Force; Die "沒辦法讀 $repo 的檔案清單" }
    foreach ($line in $raw.Split([char]0)) {
        if (-not $line) { continue }
        $tab = $line.IndexOf("`t"); if ($tab -lt 0) { continue }
        $mode = $line.Substring(0, $line.IndexOf(' ')); $rel = $line.Substring($tab + 1)
        if (Export-Skip $rel) { continue }
        if ($mode -eq '120000') { Problem "${rel}: 不能放捷徑（symlink）"; continue }
        if ($mode -eq '160000') { Problem "${rel}: 不能用 git submodule"; continue }
        $src = Join-Path $repo $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf) -or (Is-Link (Get-Item -LiteralPath $src -Force))) { Warn "$rel 在 git 裡有、資料夾裡沒有，跳過"; continue }
        $dst = Join-Path $out $rel
        Ensure-Dir (Split-Path -Parent $dst)
        [IO.File]::Copy($src, $dst, $true)
        if ($mode -eq '100755' -and -not $script:OnWindows) { & chmod 755 $dst }
    }
    Write-Text (Join-Path $out 'INSTALL.md') (Install-Md)
    if ($ver) { Write-Text (Join-Path $out 'VERSION') "$ver`n" }

    # nothing that points back to GitHub or names private things; text files only
    $gh = @(('github' + '.com'), ('github' + 'usercontent'), ('noreply' + '.github'))   # split so the export does not flag itself
    $pw = @(Private-Words @($repo))
    $files = [string[]]@(Walk-Tree $out | Where-Object { -not $_.PSIsContainer } | ForEach-Object { Rel-Path $out $_.FullName })
    [Array]::Sort($files, [StringComparer]::Ordinal)
    $bad = '\.(exe|dll|so|dylib|msi|bin|jar|class|pyc|o|a|lib|zip|gz|tgz|7z|rar)$'
    foreach ($rel in $files) {
        $f = Join-Path $out $rel
        if ($rel -match $bad) { Problem "${rel}: 不能放執行檔或壓縮檔"; continue }
        if ((Get-Item -LiteralPath $f -Force).Length -gt 0 -and (Is-Binary $f)) { Problem "${rel}: 只能放文字檔"; continue }
        $lines = (Read-Text $f) -split "`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (Has-Word $lines[$i] $gh) { Problem "${rel}:$($i + 1): 有 GitHub 的字" }
        }
        if ($pw.Count -gt 0) { for ($i = 0; $i -lt $lines.Count; $i++) { if (Has-Word $lines[$i] $pw) { Problem "${rel}:$($i + 1): 有不該公開的字" } } }
    }
    foreach ($rel in $files) { if (Has-Word $rel $gh) { Problem "$(Mask-Path $rel $gh): 檔名有 GitHub 的字" } }
    if ($pw.Count -gt 0) { foreach ($rel in $files) { if (Has-Word $rel $pw) { Problem "$(Mask-Path $rel $pw): 檔名有不該公開的字" } } }
    $script:ProblemTag = 'kit check'
    if ($script:Problems.Count -gt 0) {
        Remove-Item -LiteralPath $out -Recurse -Force
        Die "匯出失敗：$($script:Problems.Count) 個問題，已刪掉 ${out}。在 kit 的 repo 改好再匯出一次"
    }
    if (-not $ver) { $vf = Join-Path $out 'VERSION'; if (Test-Path -LiteralPath $vf) { $ver = (Read-Text $vf).Trim() } }
    if (-not $ver) { $ver = '（沒有 VERSION）' }
    Say "kit：已匯出 $($files.Count) 個檔案到 ${out}（版本 ${ver}）"
    Say '下一步（在公司）：在 Gitea 的 agentkit repo clone 裡，刪掉 .git 以外的舊檔案，'
    Say "  放進這個資料夾的內容後 commit，訊息只寫：kit ${ver}"
}

# ---------- push: send your changes in a source to Gitea as a pull request ----------
function Git-Q { # git, stderr dropped, output as strings; $LASTEXITCODE is git's
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git @args 2>$null | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
}
function Url-Path([string]$u) { # owner/repo of a git URL or folder (last two parts, no .git)
    $p = (($u -replace '^[a-z+]+://[^/]*/', '') -replace '^[^/\\]*@[^:/\\]*:', '').Replace('\', '/').TrimEnd('/') -replace '\.git$', ''
    $parts = @($p.Split('/') | Where-Object { $_ })
    if ($parts.Count -ge 2) { "$($parts[$parts.Count - 2])/$($parts[$parts.Count - 1])" } else { $parts[0] }
}
function Push-Items([string]$dir, $files) { # changed item files -> @(verb, kind:name) per item
    $seen = @{}
    foreach ($f in $files) {
        if ($f -match '^rules/([^/]+)\.md$') { $k = 'rule'; $n = $Matches[1]; $p = $f }
        elseif ($f -match '^skills/([^/]+)/') { $k = 'skill'; $n = $Matches[1]; $p = "skills/$n/SKILL.md" }
        elseif ($f -match '^mcp/([^/]+)\.yaml$') { $k = 'mcp'; $n = $Matches[1]; $p = $f }
        elseif ($f -match '^agents/([^/]+)\.md$') { $k = 'agent'; $n = $Matches[1]; $p = $f }
        else { continue }
        if ($seen.ContainsKey("${k}:$n")) { continue }; $seen["${k}:$n"] = 1
        [void](Git-Q -C $dir cat-file -e "HEAD:$p")
        $v = if ($LASTEXITCODE -ne 0) { 'add' } elseif (Test-Path -LiteralPath (Join-Path $dir $p)) { 'update' } else { 'remove' }
        , @($v, "${k}:$n")
    }
}
function Cmd-Push($rest) {
    $to = ''; $dry = $false; $r = @($rest | Where-Object { $_ })
    for ($i = 0; $i -lt $r.Count; $i++) {
        if ($r[$i] -eq '--to') { if ($i + 1 -ge $r.Count) { Die '--to 後面要接來源' }; $i++; $to = $r[$i] }
        elseif ($r[$i] -eq '--dry-run') { $dry = $true }
        else { Die '用法：kit push [--to 來源] [--dry-run]' }
    }
    $dir = Target-Dir $to
    $leaf = Split-Path -Leaf $dir
    $top = @(Git-Q -C $dir rev-parse --show-toplevel)
    $prefix = @(Git-Q -C $dir rev-parse --show-prefix | Where-Object { $_ })
    if ($top.Count -eq 0 -or $prefix.Count -gt 0) { Die "$leaf 不是 git repo（要先 git clone 團隊來源）" }
    $script:PushDir = $dir

    # what changed: only item files are sent
    $all = @(Git-Q -C $dir -c core.quotePath=false status --porcelain --untracked-files=all | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3) -replace '^.* -> ', '' })
    $files = @($all | Where-Object { $_ -match '^(rules/[^/]+\.md|skills/[^/]+/.+|mcp/[^/]+\.yaml|agents/[^/]+\.md|third_party\.lock)$' })
    $other = @($all | Where-Object { $files -notcontains $_ })
    if ($files.Count -eq 0) { Say "沒有要送的（$leaf 裡沒有改過的 rule、skill、mcp、agent）"; return }
    $items = @(Push-Items $dir $files)
    if ($other.Count -gt 0) { Warn "這些不是 rule、skill、mcp、agent，不會送：$($other -join ' ')" }

    # checks: any problem stops everything
    if (-not (Check-Dirs @($dir))) { Die 'kit check 有問題，什麼都沒送（改好再 kit push）' }
    $doms = @(YGet (Join-Path $dir 'kit.yaml') 'author_domains')
    if ($doms.Count -gt 0) {
        $email = "$(@(Git-Q -C $dir config user.email) -join '')"
        if ($doms -notcontains $email.Substring($email.LastIndexOf('@') + 1)) { Die "git 的 user.email 不是公司網域（要是 $($doms -join ' ')），什麼都沒送。請打  git config user.email 你的公司信箱" }
    }
    $origin = "$(@(Git-Q -C $dir remote get-url origin) -join '')"
    if ($LASTEXITCODE -ne 0 -or -not $origin) { Die "$leaf 沒有 origin，不知道要送到哪" }
    Check-Host $origin
    $ownerRepo = Url-Path $origin
    $api = ''; $web = ''
    if ($env:KIT_GITEA_API) { $api = $env:KIT_GITEA_API.TrimEnd('/'); Check-Host $api; $web = $api -replace '/api/v1$', '' }
    elseif (Is-Url $origin) { $web = "https://$(Url-Host $origin)"; $api = "$web/api/v1" }

    # branch: kit/<names>-YYYYMMDD, -2, -3 ... when taken
    $names = (@($items | ForEach-Object { $_[1].Substring($_[1].IndexOf(':') + 1) }) -join '-')
    if ($names.Length -gt 40) { $names = $names.Substring(0, 40) }
    $base = "kit/$($names.TrimEnd('-'))-$(Get-Date -Format yyyyMMdd)"; $b = $base; $n = 1
    $remote = @(Git-Safe -C $dir ls-remote --heads origin | Where-Object { $_ -match "`trefs/heads/" } | ForEach-Object { $_.Substring($_.IndexOf("`trefs/heads/") + 12) })
    while ($true) {
        [void](Git-Q -C $dir show-ref --verify -q "refs/heads/$b")
        if ($LASTEXITCODE -ne 0 -and $remote -notcontains $b) { break }
        $n++; $b = "$base-$n"
    }
    $into = "$(@(Git-Q -C $dir symbolic-ref --short -q refs/remotes/origin/HEAD) -join '')" -replace '^origin/', ''
    if (-not $into) { $into = 'main' }
    $parts = @(foreach ($v in 'add', 'update', 'remove') { $l = @($items | Where-Object { $_[0] -eq $v } | ForEach-Object { $_[1] }); if ($l.Count -gt 0) { "$v $($l -join ', ')" } })
    $msg = "kit: $($parts -join '; ')"

    Say "要送的檔案（$leaf）："
    foreach ($f in $files) { Say "  $f" }
    Say "分支：${b}（PR 到 ${into}）"
    Say "commit：$msg"
    if ($dry) { Say '（--dry-run：沒有 commit，沒有送）'; return }

    # the branch starts from origin's base, so unpushed local commits are never sent
    $orig = "$(@(Git-Q -C $dir symbolic-ref --short -q HEAD) -join '')"
    if (-not $orig) { $orig = "$(@(Git-Q -C $dir rev-parse HEAD) -join '')" }
    [void](Git-Safe -C $dir fetch -q --no-recurse-submodules origin "+refs/heads/${into}:refs/remotes/origin/$into")
    if ($LASTEXITCODE -ne 0) { Warn "沒辦法更新 origin/${into}（沒網路？）" }
    $start = 'HEAD'
    [void](Git-Q -C $dir rev-parse -q --verify "refs/remotes/origin/$into"); if ($LASTEXITCODE -eq 0) { $start = "refs/remotes/origin/$into" }
    [void](Git-Q -C $dir checkout -q -b $b $start)
    if ($LASTEXITCODE -ne 0) { Die "沒辦法開分支 ${b}（你改的檔案跟 origin/$into 有衝突？），什麼都沒送" }
    [void](Git-Q -C $dir add -A -- @files); $ok = $LASTEXITCODE -eq 0
    if ($ok) { [void](Git-Q -C $dir commit -q -m $msg -- @files); $ok = $LASTEXITCODE -eq 0 }
    if (-not $ok) { [void](Git-Q -C $dir checkout -q $orig); [void](Git-Q -C $dir branch -q -D $b); Die 'commit 失敗，什麼都沒送' }
    [void](Git-Q -C $dir checkout -q $orig)
    if ($LASTEXITCODE -ne 0) { Warn "沒辦法切回 ${orig}，你現在在 $b" }
    [void](Git-Safe -C $dir push -q --no-recurse-submodules origin "refs/heads/${b}:refs/heads/$b")
    if ($LASTEXITCODE -ne 0) { Die "沒辦法 push 分支 ${b}（沒網路？）。commit 留在本機的 $b" }
    Say "已送出分支 ${b}。改的檔案已從這裡移到那個分支，PR 合併後打 git pull 就會回來；想先看可以  git checkout $b"

    # pull request
    $tok = ''; $tf = Join-Path $KitConf 'gitea-token'
    $compare = if ($web) { "$web/$ownerRepo/compare/$into...$b" } else { '' }
    if ($env:KIT_GITEA_TOKEN) { $tok = $env:KIT_GITEA_TOKEN }
    elseif (Test-Path -LiteralPath $tf -PathType Leaf) {
        if (-not $script:OnWindows) { $m = "$(& ls -l $tf)"; if ($m.Length -lt 10 -or $m.Substring(4, 6) -ne '------') { Warn "$tf 的權限太開放了，請打  chmod 600 $tf" } }
        $tok = (Read-Text $tf) -replace '\s', ''
    }
    if ($tok -and $api) {
        $body = "由 kit push 送出：`n" + ((@($items | ForEach-Object { "- $($_[0]) $($_[1])" })) -join "`n")
        $json = '{"title":' + (Json-Str $msg) + ',"head":' + (Json-Str $b) + ',"base":' + (Json-Str $into) + ',"body":' + (Json-Str $body) + '}'
        $code = ''
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $resp = Invoke-RestMethod -Method Post -Uri "$api/repos/$ownerRepo/pulls" -Headers @{ Authorization = "token $tok" } `
                -ContentType 'application/json; charset=utf-8' -Body ($Utf8.GetBytes($json)) -TimeoutSec 30 -UseBasicParsing
            $pr = ''; if ($resp -and ($resp.PSObject.Properties.Name -contains 'html_url')) { $pr = [string]$resp.html_url }
            if ($pr) { Say "已開 PR：$pr"; return }
        } catch { try { $code = [string][int]$_.Exception.Response.StatusCode } catch { } }
        Warn "沒辦法自動開 PR（Gitea 回 $(if ($code) { $code } else { '沒回應' })）"
    } elseif (-not $tok) {
        Say "沒有 Gitea token（KIT_GITEA_TOKEN 或 ${tf}），PR 請自己開"
    }
    if ($compare) { Say "開 PR：$compare" } else { Say "請到 Gitea 用分支 $b 開 PR" }
}

# ---------- collect / outdated: other people's skills, from their own repos ----------
# third_party.lock: name<TAB>url<TAB>path<TAB>ref<TAB>commit<TAB>license<TAB>date
$script:LockHead = '# third_party.lock - written by kit collect; name url path ref commit license date'
function Url-Id([string]$u) { # host/path of a git URL, without scheme, user, .git or trailing /
    ((($u -replace '^[a-z+]+://', '') -replace '^[^@/]*@', '') -replace '^([^/:]+):', '$1/').TrimEnd('/') -replace '\.git$', ''
}
function Collect-Allowed([string]$url, [string]$dir) {
    $id = Url-Id $url
    $dirs = @($dir); if (Test-Path -LiteralPath $Machine) { $dirs += @(Src-Dirs) }
    foreach ($d in $dirs) {
        foreach ($e in @(YGet (Join-Path $d 'kit.yaml') 'collect_sources')) {
            if (-not $e) { continue }
            $e = Url-Id $e
            if ($id -eq $e -or $id.StartsWith("$e/")) { return $true }
        }
    }
    $false
}
function Check-Maintainer([string]$dir) {
    $m = @(YGet (Join-Path $dir 'kit.yaml') 'maintainers' | Where-Object { $_ })
    if ($m.Count -eq 0) { return }
    $me = "$(& git -C $dir config user.email 2>$null)"
    $who = @($me, ($me -replace '@.*$', ''), $env:USERNAME, $env:USER) | Where-Object { $_ }
    foreach ($w in $who) { if ($m -contains $w) { return } }
    Die '只有維護者能用 collect／outdated（kit.yaml 的 maintainers）'
}
function License-Kind([string]$f) {
    $t = Read-Text $f
    if ($t -match '(?i)Apache License') { 'Apache-2.0' }
    elseif ($t -match '(?i)MIT License|Permission is hereby granted, free of charge') { 'MIT' }
    elseif ($t -match '(?i)Mozilla Public License') { 'MPL-2.0' }
    elseif ($t -match '(?i)GNU (AFFERO|LESSER)? *GENERAL PUBLIC LICENSE') { 'GPL' }
    elseif ($t -match '(?i)Redistribution and use in source and binary forms') { 'BSD' }
    elseif ($t -match '(?i)CC0|Creative Commons') { 'CC' }
    else { 'unknown' }
}
function Lock-Rows([string]$dir) {
    $f = Join-Path $dir 'third_party.lock'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    @((Read-Text $f) -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
function Lock-Get([string]$dir, [string]$name) { foreach ($r in Lock-Rows $dir) { if ($r.Split("`t")[0] -eq $name) { return $r } }; $null }
function Lock-Set([string]$dir, [string]$line) {
    $n = $line.Split("`t")[0]
    $rows = [string[]]@(@(Lock-Rows $dir | Where-Object { $_.Split("`t")[0] -ne $n }) + @($line))
    [Array]::Sort($rows, [StringComparer]::Ordinal)
    Write-Text (Join-Path $dir 'third_party.lock') ($LockHead + "`n" + ($rows -join "`n") + "`n")
}
function Cmd-Collect($rest) {
    $arg = ''; $path = ''; $name = ''; $ref = ''; $to = ''; $force = $false
    $r = @($rest | Where-Object { $_ })
    for ($i = 0; $i -lt $r.Count; $i++) {
        switch -CaseSensitive ($r[$i]) {
            '--path' { if ($i + 1 -ge $r.Count) { Die '--path 後面要接 repo 裡的資料夾' }; $i++; $path = $r[$i] }
            '--name' { if ($i + 1 -ge $r.Count) { Die '--name 後面要接名字' }; $i++; $name = $r[$i] }
            '--ref' { if ($i + 1 -ge $r.Count) { Die '--ref 後面要接分支或 tag' }; $i++; $ref = $r[$i] }
            '--to' { if ($i + 1 -ge $r.Count) { Die '--to 後面要接來源' }; $i++; $to = $r[$i] }
            '--force' { $force = $true }
            default { if ($r[$i].StartsWith('-')) { Die "不認得 $($r[$i])" }; if ($arg) { Die "多了一個參數：$($r[$i])" }; $arg = $r[$i] }
        }
    }
    if (-not $arg) { Die '用法：kit collect <原作者的 repo 網址> [--path repo 裡的資料夾] [--name 名字] [--ref 分支或 tag]，或 kit collect <名字>（再收一次）' }
    $dir = Target-Dir $to
    Check-Maintainer $dir
    if (Is-Url $arg) { $url = $arg }
    else {
        $line = Lock-Get $dir $arg; if (-not $line) { Die "$(Split-Path -Leaf $dir) 的 third_party.lock 裡沒有 ${arg}（第一次收要給網址）" }
        $f = $line.Split("`t"); $name = $arg; $url = $f[1]
        if (-not $path -and $f[2] -ne '.') { $path = $f[2] }
        if (-not $ref -and $f[3] -ne '-') { $ref = $f[3] }
    }
    if (-not (Collect-Allowed $url $dir)) { Die "$(Url-Id $url) 不在 collect_sources（$(Split-Path -Leaf $dir)/kit.yaml），不能收" }
    $real = "$(& git ls-remote --get-url $url 2>$null)"
    if ($real -and $real -ne $url -and -not (Collect-Allowed $real $dir)) { Die "git 設定把 $url 改到 ${real}，不在 collect_sources" }
    $path = $path.Replace('\', '/').Trim('/')
    if ("/$path/" -match '/\.\.?/') { Die '--path 不能有 .. 或 .' }

    $tmp = New-TempDir 'kit-collect.'
    try {
        $repo = Join-Path $tmp 'repo'
        Say "從 $(Url-Id $url) 下載$(if ($ref) { "（$ref）" })…"
        $ga = @('clone', '-q', '--depth', '1', '--no-recurse-submodules'); if ($ref) { $ga += @('--branch', $ref) }
        $out = Git-Safe @($ga + @($url, $repo))
        if ($LASTEXITCODE -ne 0) { foreach ($l in @($out)) { Warn "  $l" }; Die "沒辦法下載 $url" }
        $sha = "$(& git -C $repo rev-parse HEAD)".Trim()
        $repo = Full-Path $repo
        $src = if ($path) { Join-Path $repo $path } else { $repo }
        if (Test-Path -LiteralPath $src -PathType Container) { $src = Full-Path $src }
        if (-not ($src + [IO.Path]::DirectorySeparatorChar).StartsWith($repo + [IO.Path]::DirectorySeparatorChar) -and $src -ne $repo) { Die '--path 要在 repo 裡面' }
        if (-not (Test-Path -LiteralPath (Join-Path $src 'SKILL.md') -PathType Leaf)) { Die "$(Url-Id $url)$(if ($path) { "/$path" }) 裡沒有 SKILL.md（用 --path 指出 skill 的資料夾）" }
        if (-not $name) { try { $name = @(YGet-From (Yaml-Lines (Join-Path $src 'SKILL.md') -Frontmatter) 'name')[0] } catch { $name = '' } }
        if (-not $name) { $name = Split-Path -Leaf $src }
        if (-not (Valid-Name $name)) { Die "名字 $name 不行（只能小寫英文、數字和 -），用 --name 給一個" }
        $dst = Join-Path (Join-Path $dir 'skills') $name
        if ((Test-Path -LiteralPath $dst) -and -not (Lock-Get $dir $name) -and -not $force) { Die "$(Split-Path -Leaf $dir) 已經有 skill:${name}，而且不是 collect 收的（要整份換掉加 --force，或用 --name 換名字）" }
        $lic = $null
        foreach ($d in @($src, $repo)) {
            if ($lic) { break }
            $lic = @(Get-ChildItem -LiteralPath $d -File -Force | Where-Object { $_.Name -cmatch '^(LICENSE|LICENCE|COPYING)' } | Sort-Object Name | Select-Object -First 1 | ForEach-Object { $_.FullName })[0]
        }
        if (-not $lic) { Die "$(Url-Id $url) 沒有 LICENSE，不知道能不能用，不收" }
        $kind = License-Kind $lic
        $outDir = Join-Path $tmp 'out'; Ensure-Dir $outDir
        $scripts = @()
        foreach ($e in @(Walk-Tree $src)) {
            $rel = Rel-Path $src $e.FullName
            if ("/$rel" -match '/\.') { continue }   # .github/, .claude-plugin/ ...: for other tools, not the skill
            if (Is-Link $e) { Warn "跳過捷徑 $rel"; continue }
            if ($e.PSIsContainer) { continue }
            if ($e.Length -gt 0 -and (Is-Binary $e.FullName)) { Warn "跳過非文字檔 $rel"; continue }
            $t = Join-Path $outDir $rel; Ensure-Dir (Split-Path -Parent $t); Copy-Item -LiteralPath $e.FullName -Destination $t
            if ($rel -match '\.(sh|py|js|mjs|cjs|ts|ps1|rb|pl|bat|cmd)$') { $scripts += $rel }
        }
        $licName = Split-Path -Leaf $lic
        if (-not (Test-Path -LiteralPath (Join-Path $outDir $licName))) { Copy-Item -LiteralPath $lic -Destination (Join-Path $outDir $licName) }
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Ensure-Dir (Join-Path $dir 'skills')
        Copy-Item -LiteralPath $outDir -Destination $dst -Recurse
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $p2 = if ($path) { $path } else { '.' }; $r2 = if ($ref) { $ref } else { '-' }
    Lock-Set $dir ((@($name, $url, $p2, $r2, $sha, $kind, (Get-Date -Format 'yyyy-MM-dd'))) -join "`t")
    Say "已收 skill:$name ← $(Url-Id $url)$(if ($path) { "/$path" }) @ $($sha.Substring(0, 12))（授權 $kind）"
    if ($kind -eq 'unknown') { Warn "認不出授權種類，請自己看 skills/$name/$licName" }
    if ($kind -eq 'GPL') { Warn 'GPL 類授權：改了再發布要公開原始碼，請確認可以用' }
    if ($scripts.Count -gt 0) { Warn "這個 skill 有會執行的檔案，送出前請看過： $($scripts -join ' ')" }
    $script:Quiet2 = $true
    if (-not (Check-Dirs @($dir) $false)) { Warn 'kit check 有問題，送出前請先打  kit check  看看' }
    Say '下一步：kit diff 看不到第三方的差異，請用 git diff 看；沒問題就  kit push  開 PR'
}
function Cmd-Outdated($rest) {
    $to = ''; $r = @($rest | Where-Object { $_ })
    for ($i = 0; $i -lt $r.Count; $i++) { if ($r[$i] -eq '--to' -and $i + 1 -lt $r.Count) { $i++; $to = $r[$i] } else { Die '用法：kit outdated [--to 來源]' } }
    $dir = Target-Dir $to
    Check-Maintainer $dir
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'third_party.lock'))) { Say "$(Split-Path -Leaf $dir) 沒有 third_party.lock（還沒用 kit collect 收過東西）"; return }
    $new = 0
    foreach ($row in Lock-Rows $dir) {
        $f = $row.Split("`t"); $n = $f[0]; $url = $f[1]; $ref = $f[3]; $sha = $f[4]
        if (-not (Collect-Allowed $url $dir)) { Warn "${n}：$(Url-Id $url) 已經不在 collect_sources，不檢查"; continue }
        $now = ''
        if ($ref -eq '-') {
            foreach ($l in @(Git-Safe ls-remote $url HEAD)) { $p = "$l".Split("`t"); if ($p.Count -ge 2 -and $p[1] -eq 'HEAD') { $now = $p[0]; break } }
        } else {
            $b = ''; $t = ''; $pe = ''
            foreach ($l in @(Git-Safe ls-remote $url "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}")) {
                $p = "$l".Split("`t"); if ($p.Count -lt 2) { continue }
                if ($p[1] -eq "refs/heads/$ref") { $b = $p[0] } elseif ($p[1] -eq "refs/tags/$ref^{}") { $pe = $p[0] } elseif ($p[1] -eq "refs/tags/$ref") { $t = $p[0] }
            }
            $now = if ($b) { $b } elseif ($pe) { $pe } else { $t }
        }
        if (-not $now) { Warn "${n}：連不到 $(Url-Id $url)" }
        elseif ($now -eq $sha) { Say "  ${n}：最新（$($sha.Substring(0, 12))）" }
        else { Say "  ${n}：有新版本 $($sha.Substring(0, 12)) → $($now.Substring(0, 12))，打  kit collect $n  收新的"; $new++ }
    }
    if ($new -gt 0) { Say "kit：$new 個有新版本" }
}

# ---------- the Herdr panel (a Herdr mod that runs kit list --json / add / rm / sync / run) ----------
$script:ShippedLayouts = @('main', 'terminals', 'win98')     # Herdr's own layouts: Herdr puts them back when edited
$script:PanelToggle = '{"id":"kit-toggle","type":"block","content":{"mod":"kit","props":{"role":"toggle"}},"size":{"px":56}}'
$script:PanelNode = '{"id":"kit-panel","type":"column","children":[{"id":"kit","type":"block","content":{"mod":"kit"}}],"size":{"px":420},"min":320,"max":800}'
function Herdr-Home { # the same rule as Herdr: $HERDR_APP_HOME, else $XDG_CONFIG_HOME/herdr-app, else ~/.config/herdr-app (also on Windows)
    if ($env:HERDR_APP_HOME) { return $env:HERDR_APP_HOME }
    if ($env:XDG_CONFIG_HOME) { return (Join-Path $env:XDG_CONFIG_HOME 'herdr-app') }
    Join-Path $UserHome '.config/herdr-app'
}
function Panel-Src { # the panel's files: next to the installed kit, else in the repo kit runs from
    $cands = @((Join-Path $KitLib 'herdr/kit-panel'))
    $r = Kit-Repo; if ($r) { $cands += (Join-Path $r 'herdr/kit-panel') }
    foreach ($d in $cands) { if (Test-Path -LiteralPath (Join-Path $d 'main.js') -PathType Leaf) { return $d } }
    $null
}
function Layout-Edit([string]$f, $ops) { # the layout text with OPS applied (the panel's old blocks removed first)
    $text = Read-Text $f
    $root = Json-Parse $text
    Json-Apply $root (@(@('rmwhere', 'content.mod', 'kit'), @('rmwhere', 'id', 'kit-toggle'), @('rmwhere', 'id', 'kit-panel')) + @($ops | Where-Object { $_ }))
    Json-Text $root $text
}
function Swap-Layout([string]$f, [string]$text) { # FILE (backed up first) gets TEXT
    $b = "$f.kit-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $f -Destination $b -Force
    Write-Text $f $text
    Say "kit：改了版面 $(Split-Path -Leaf $f)（原本的備份在 $(Split-Path -Leaf $b)）"
}
function Cmd-HerdrPanel($rest) {
    $rest = @($rest | Where-Object { $null -ne $_ })
    $hh = Herdr-Home; $mods = Join-Path $hh 'mods'; $dest = Join-Path $mods 'kit'
    $mine = Test-Path -LiteralPath (Join-Path $dest '.kit-panel')
    $verb = if ($rest.Count -gt 0) { $rest[0] } else { '' }
    if ($verb -eq 'install') {
        $keep = $rest -contains '--keep-env'
        if ($keep -and $OnWindows) { Die '--keep-env 只能在 Mac／Linux 用（測試用）' }
        $src = Panel-Src; if (-not $src) { Die '找不到 panel 的檔案（herdr/kit-panel）；請重裝 kit' }
        if (-not (Test-Path -LiteralPath $mods -PathType Container)) { Die "找不到 Herdr 的 mods 資料夾：${mods}（Herdr 有裝、開過一次嗎？）" }
        if ((Test-Path -LiteralPath $dest) -and -not $mine) { Die "$dest 已經有東西，不是 kit 放的，不動它" }
        # where the panel goes: a button in the tab bar of the shown layout + the panel beside the work area
        $name = ''
        try { $v = Json-Get (Join-Path $hh 'shared.json') 'layout'; if ($v -and $v.StartsWith('"')) { $name = $v.Trim('"') } } catch { }
        if (-not $name) { $name = 'main' }
        $lf = Join-Path $hh "layouts/$name.json"; $newLayout = $null; $place = 'none'
        if ($ShippedLayouts -contains $name) {
            $place = 'right'
            Say "kit：現在的版面（${name}）是 Herdr 內建的，不能直接改：panel 會先出現在右邊，按 panel 上的「放進上排」會複製一份版面再放進去"
        } elseif (-not (Test-Path -LiteralPath $lf -PathType Leaf)) { $place = 'right' }
        elseif (-not (Read-Text $lf).Contains('"kit-toggle"')) {
            $t = $null
            try { $t = Layout-Edit $lf @(@('addnear', 'content.mod', 'tabs', $PanelToggle), @('addnear', 'content.tab', 'active', $PanelNode)) } catch { if ($env:KIT_DEBUG) { Warn "$($_.Exception.Message) $($_.ScriptStackTrace)" }; $t = $null }
            if ($t -and $t.Contains('"kit-toggle"') -and $t.Contains('"kit-panel"')) { $newLayout = $t }
            else { $place = 'right'; Say "kit：版面 $name 找不到分頁列（tabs）或工作區，沒改它：panel 會先出現在右邊" }
        }
        # the files (main.js etc.), then mod.json and the panel's config (how to run kit here)
        Ensure-Dir $dest
        Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
        Write-Text (Join-Path $dest 'mod.json') "{ `"place`": `"$place`", `"size`": 420, `"title`": `"kit`" }`n"
        if ($OnWindows) {
            $cmdPath = Join-Path (Split-Path -Parent $KitLib) 'kit.cmd'
            $kit = if ((Split-Path -Leaf $KitLib) -eq 'lib' -and (Test-Path -LiteralPath $cmdPath)) { @($cmdPath) } else { @('kit.cmd') }
        } else { $kit = @((Get-Process -Id $PID).Path, '-NoProfile', '-File', $PSCommandPath) }
        $envs = @()
        if ($keep) {
            foreach ($k in 'HOME', 'AGENTKIT_CONFIG', 'AGENTKIT_SOURCES', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'PI_CODING_AGENT_DIR') {
                $v = [Environment]::GetEnvironmentVariable($k); if ($v) { $envs += "$(Json-S $k): $(Json-S $v)" }
            }
        }
        Write-Text (Join-Path $dest 'config.json') "{`n  `"kit`": [$((@($kit | ForEach-Object { Json-S $_ })) -join ', ')],`n  `"env`": {$($envs -join ', ')}`n}`n"
        Write-Text (Join-Path $dest '.kit-panel') ''
        if ($newLayout) { Swap-Layout $lf $newLayout }
        Say "kit：Herdr 的 kit panel 裝好了（${dest}）"
    } elseif ($verb -eq 'uninstall') {
        if (Test-Path -LiteralPath $dest) {
            if (-not $mine) { Die "$dest 不是 kit 放的，不動它" }
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        $ld = Join-Path $hh 'layouts'
        if (Test-Path -LiteralPath $ld) {
            foreach ($f in @(Get-ChildItem -LiteralPath $ld -File -Filter '*.json' | Where-Object { $_.Extension -eq '.json' })) {
                if ($ShippedLayouts -contains [IO.Path]::GetFileNameWithoutExtension($f.Name)) { continue }
                $text = Read-Text $f.FullName
                if (-not ($text.Contains('"kit-toggle"') -or $text.Contains('"kit-panel"') -or $text.Contains('"mod": "kit"'))) { continue }
                try { $t = Layout-Edit $f.FullName @() } catch { Warn "沒辦法讀 $($f.FullName)，沒改它"; continue }
                Swap-Layout $f.FullName $t
            }
        }
        Say 'kit：Herdr 的 kit panel 拿掉了'
    } else { Die '用法：kit herdr-panel install|uninstall' }
}

# ---------- agents: the definitions (agents/<name>.md), for the Herdr agent panel ----------
function Json-Arr($vals) { '[' + ((@($vals | Where-Object { $_ }) | ForEach-Object { Json-S $_ }) -join ', ') + ']' }
function Git-State([string]$dir, [string]$file) { # "new", "changed" or "" (or "no-git")
    & git -C $dir rev-parse --git-dir *> $null; if ($LASTEXITCODE -ne 0) { return 'no-git' }
    $st = "$(& git -C $dir status --porcelain --untracked-files=all -- $file 2>$null | Select-Object -First 1)"
    if (-not $st) { return '' }
    $c = $st.Substring(0, [Math]::Min(2, $st.Length))
    if ($c -eq ('?' + '?') -or $c.StartsWith('A')) { 'new' } else { 'changed' }
}
function Agent-Body([string]$f) { # the lines after the frontmatter
    $lines = (Read-Text $f) -split "`n"; $c = 0; $out = @()
    foreach ($l in $lines) { if ($c -ge 2) { $out += $l }; if ($l -eq '---') { $c++ } }
    ($out -join "`n").TrimEnd("`n")
}
function Cmd-Agents($rest) {
    $rest = @($rest | Where-Object { $null -ne $_ })
    if ($rest.Count -ne 1 -or $rest[0] -ne '--json') { Die '用法：kit agents --json' }
    Need-Init
    $items = @(Available)
    $pick = { param($k) @($items | Where-Object { $_.StartsWith("${k}:") } | ForEach-Object { $_.Substring($k.Length + 1) }) }
    $tools = '"claude"'; if (Has-Codex) { $tools += ', "codex"' }; if (Has-Omp) { $tools += ', "omp"' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`n  `"kit`": $(Json-S $KitVersion),`n  `"tools`": [$tools],`n  `"available`": {`"rule`": $(Json-Arr (& $pick 'rule')), `"skill`": $(Json-Arr (& $pick 'skill')), `"mcp`": $(Json-Arr (& $pick 'mcp'))},`n  `"agents`": [")
    $first = $true
    foreach ($n in (& $pick 'agent')) {
        $f = Find-Item 'agent' $n; if (-not $f) { continue }
        $d = Split-Path -Parent (Split-Path -Parent $f)
        $fm = $null; try { $fm = Yaml-Lines $f -Frontmatter } catch { $fm = @() }
        $desc = @(YGet-From $fm 'description'); $desc = if ($desc.Count) { [string]$desc[0] } else { '' }
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append("`n    {`"name`": $(Json-S $n), `"description`": $(Json-S $desc), `"source`": $(Json-S (Split-Path -Leaf $d)), `"path`": $(Json-S $f), `"git`": $(Json-S (Git-State $d "agents/$n.md")),")
        [void]$sb.Append("`n     `"rules`": $(Json-Arr (YGet-From $fm 'rules')), `"skills`": $(Json-Arr (YGet-From $fm 'skills')), `"mcp`": $(Json-Arr (YGet-From $fm 'mcp')), `"tools_only`": $(Json-Arr (YGet-From $fm 'tools.only')), `"tools_deny`": $(Json-Arr (YGet-From $fm 'tools.deny')),")
        [void]$sb.Append("`n     `"prompt`": $(Json-S (Agent-Body $f))}")
    }
    [void]$sb.Append("`n  ]`n}")
    Say $sb.ToString()
}
function Fm-SetList([string]$f, [string]$key, [string]$val) { # KEY: [val] in the frontmatter (block lists replaced, added if missing)
    $text = Read-Text $f; $nl = $text.EndsWith("`n")
    $lines = $text -split "`n"; if ($nl) { $lines = $lines[0..($lines.Count - 2)] }
    $out = New-Object System.Collections.Generic.List[string]
    $infm = $false; $skip = $false; $done = $false; $i = 0
    foreach ($l in $lines) {
        $i++
        if ($i -eq 1 -and $l -eq '---') { $infm = $true; $out.Add($l); continue }
        if ($infm -and $skip) { if ($l -match '^[ \t]*-([ \t]|$)') { continue }; $skip = $false }
        if ($infm -and $l -eq '---') { if (-not $done) { $out.Add("${key}: [$val]") }; $done = $true; $infm = $false; $out.Add($l); continue }
        if ($infm -and $l.StartsWith("${key}:")) { $out.Add("${key}: [$val]"); $done = $true; if ($l.Substring($key.Length + 1) -match '^[ \t]*$') { $skip = $true }; continue }
        $out.Add($l)
    }
    Write-Text $f (($out -join "`n") + $(if ($nl) { "`n" } else { '' }))
}
function Cmd-Agent($rest) { # kit agent <name> add|rm rule|skill|mcp <item>
    $r = @($rest | Where-Object { $null -ne $_ })
    $use = '用法：kit agent <名字> add|rm rule|skill|mcp <東西>'
    if ($r.Count -ne 4) { Die $use }
    Need-Init
    $n = $r[0]; $verb = $r[1]; $k = $r[2]; $item = $r[3]
    if (@('add', 'rm') -notcontains $verb) { Die $use }
    $key = switch -CaseSensitive ($k) { 'rule' { 'rules' } 'skill' { 'skills' } 'mcp' { 'mcp' } default { $null } }
    if (-not $key) { Die '種類只能是 rule、skill、mcp' }
    $f = Find-Item 'agent' $n; if (-not $f) { Die "找不到 agent ${n}（打 kit list 看有哪些）" }
    if (((Read-Text $f) -split "`n")[0].TrimEnd("`r") -ne '---') { Die "$f 沒有開頭的 --- 區塊" }
    $cur = @(); try { $cur = @(YGet-From (Yaml-Lines $f -Frontmatter) $key | Where-Object { $_ }) } catch { }
    if ($verb -eq 'add') {
        if (-not (Find-Item $k $item)) { Die "找不到 ${k}:${item}（kit 的來源裡沒有）" }
        if ($cur -contains $item) { Say "agent $n 已經有 ${k}:${item}"; return }
        $new = @($cur + $item)
    } else {
        if ($cur -notcontains $item) { Say "agent $n 本來就沒有 ${k}:${item}"; return }
        $new = @($cur | Where-Object { $_ -ne $item })
    }
    Fm-SetList $f $key ($new -join ', ')
    Say "agent ${n}：$(if ($verb -eq 'add') { '加上' } else { '拿掉' }) ${k}:${item}（改了 ${f}，還沒送出：用 kit push 開 PR）"
}

function Usage {
    Say @'
kit - 管理 AI 寫程式工具的 rule、skill、MCP 和 agent

  kit init <網址|資料夾> [更多...]   第一次：設定來源，加上預設的東西
  kit list [--json]                 有哪些、你在用哪些、哪些是新的（--json 給程式讀）
  kit agents --json                 每個 agent 用了哪些 rule、skill、MCP（給 Herdr 的 Agent 面板）
  kit agent <名字> add|rm rule|skill|mcp <東西>   改 agent 用的東西（改來源裡的檔案，再用 kit push 送出）
     --json --dir 資料夾              再列出在那個資料夾開的 agent 另外會讀到的（不是 kit 管的）
  kit add rule|skill|mcp <名字>     開始用
  kit rm  rule|skill|mcp <名字>     不用了（之後 sync 也不會加回來）
  kit run <agent> [--tool codex|omp] [參數]   開一個做好的 agent
  kit sync [--force]                現在更新（kit run 會自動做）

寫內容的人用（只吃本機資料夾，不連網）：
  kit new rule|skill|mcp|agent <名字> [--from 本機資料夾] [--to 來源]
  kit diff   [種類] <名字> --from 本機資料夾   比較
  kit update [種類] <名字> --from 本機資料夾   更新；別人改過會停下來（--force 硬蓋）
  kit check [--ci] [資料夾...]      檢查格式、引用、名字重複、網址、不該公開的字

維護者用（只收 kit.yaml 的 collect_sources 列的原作者）：
  kit collect <原作者 repo 網址> [--path 資料夾] [--name 名字] [--ref 分支]   收別人的 skill（保留 LICENSE）
  kit collect <名字>                再收一次＝整份換成原作者的新版
  kit outdated                      看收過的 skill 原作者有沒有新版
  kit export-self <資料夾> [--version <版本>]   匯出 kit 的原始碼（給公司的 git server）
  kit ci-template [檔案]            Gitea Actions 範本（PR 自動跑 kit check --ci），例：
                                      kit ci-template .gitea/workflows/kit-check.yaml
  kit push [--to 來源] [--dry-run]  檢查後把改的東西送到 Gitea 開 PR

  kit herdr-panel install|uninstall 在 Herdr 加上（或拿掉）kit 的面板
  kit self-update                   更新 kit 本身
  kit uninstall [--self]            拿掉 kit 加的東西（--self 連 kit 也移除）
  kit --version
'@
}

# ---------- main ----------
$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
$rest = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }
try {
    switch ($cmd) {
        'init' { Cmd-Init $rest }
        'sync' {
            if ($rest -contains '--force') { $script:Force = $true }
            if ($rest -contains '--hook') { Sync-Hook }
            if ($rest -contains '--bg') { Sync-Bg; exit 0 }
            Cmd-Sync
        }
        { $_ -in 'list', 'ls' } { Cmd-List $rest }
        'add' { Cmd-AddRm 'add' $rest }
        { $_ -in 'rm', 'remove' } { Cmd-AddRm 'rm' $rest }
        'run' { Cmd-Run $rest }
        'agents' { Cmd-Agents $rest }
        'agent' { Cmd-Agent $rest }
        'new' { Cmd-New $rest }
        'diff' { Cmd-DiffUpdate 'diff' $rest }
        'update' { Cmd-DiffUpdate 'update' $rest }
        'check' { Cmd-Check $rest }
        'collect' { Cmd-Collect $rest }
        'outdated' { Cmd-Outdated $rest }
        'export-self' { Cmd-ExportSelf $rest }
        'ci-template' { Cmd-CiTemplate $rest }
        'push' { Cmd-Push $rest }
        'uninstall' { Cmd-Uninstall $rest }
        'self-update' { Cmd-SelfUpdate }
        'herdr-panel' { Cmd-HerdrPanel $rest }
        { $_ -in '--version', 'version' } { Say "kit $KitVersion" }
        { $_ -in '', '-h', '--help', 'help' } { Usage }
        '__json-get' { $v = Json-Get $rest[0] $rest[1]; if ($null -eq $v) { exit 1 }; Say $v }   # for tests
        default { Die "沒有這個指令：${cmd}（打 kit help）" }
    }
} catch {
    if ($env:KIT_DEBUG) { Warn $_.ScriptStackTrace }
    Die $_.Exception.Message
}
exit 0
