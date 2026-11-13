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
# what programs read (kit api): MAJOR.MINOR; MAJOR +1 when something changes incompatibly, MINOR +1 when fields or
# commands are added. unix/kit has the same.
$script:KitApi = '1.3'
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
$script:TopBegin = '# agentkit:top:begin (managed by kit, do not edit)'
$script:TopEnd = '# agentkit:top:end'
$script:DirsList = Join-Path $KitConf 'dirs'                 # the folders that have their own (kit add --dir), one per line
$script:DirFile = '.agentkit'                                # in such a folder: what it has; Codex also takes it as the project root
$script:Utf8 = New-Object System.Text.UTF8Encoding $false     # never write a BOM
$script:Quiet = $false
$script:Force = $false
$script:LogPath = $null
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------- small helpers ----------
# With --json (list, agents, push, files) or collect --look, stdout carries only JSON: kit's words go to stderr, and a stop is
# also told on stdout as {"error": {"code": CODE, "message": the same words}} (unix/kit prints the same).
$script:JsonOut = $false
$script:DieExtra = ''   # more of the error for programs (kit new mcp: the servers in the paste)
function Say([string]$msg) {
    if ($script:Quiet) { return }
    if ($script:LogPath) { [IO.File]::AppendAllText($script:LogPath, "$msg`n", $Utf8) }
    elseif ($script:JsonOut) { [Console]::Error.WriteLine($msg) }
    else { [Console]::Out.WriteLine($msg) }
}
function Out-Json([string]$s) { [Console]::Out.WriteLine($s) }   # the JSON programs read, on stdout
function Warn([string]$msg) {
    if ($script:LogPath) { [IO.File]::AppendAllText($script:LogPath, "kit: $msg`n", $Utf8) } else { [Console]::Error.WriteLine("kit: $msg") }
}
function Die([string]$msg, [string]$code = 'error') {
    Warn $msg
    if ($script:JsonOut) { [Console]::Out.WriteLine('{"error": {"code": ' + (Json-S $code) + ', "message": ' + (Json-S $msg) + $script:DieExtra + '}}') }
    exit 1
}
function Die-C([string]$code, [string]$msg) { Die $msg $code }   # the code programs read (README: 給程式讀的介面)
# one kit at a time changes state.tsv and the tools' files (the background sync takes the same lock); freed when kit ends
$script:LockMine = $false; $script:Locked = $false; $script:SshSet = $false
function Take-Lock([switch]$Soft) { # -Soft: give up quietly after a few seconds ($false) instead of stopping
    if ($script:Locked) { return $true }
    $lock = Join-Path $KitConf 'sync.lock'; $max = 60; if ($env:KIT_LOCK_WAIT) { $max = [int]$env:KIT_LOCK_WAIT }; if ($Soft) { $max = 5 }
    Ensure-Dir $KitConf
    for ($i = 0; ; $i++) {
        try { [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop); break } catch { }
        # left by a kit that was killed: older than 10 minutes
        if ((Test-Path -LiteralPath $lock) -and (Get-Item -LiteralPath $lock).LastWriteTime -lt (Get-Date).AddMinutes(-10)) { Remove-Item -LiteralPath $lock -Force -Recurse -ErrorAction SilentlyContinue; continue }
        if ($i -ge $max) { if ($Soft) { return $false }; Die-C busy "另一個 kit 正在跑（${lock}），等它跑完再試一次" }
        if ($i -eq 2 -and -not $Soft) { Warn '等另一個 kit 跑完…' }
        Start-Sleep -Seconds 1
    }
    $script:LockMine = $true; $script:Locked = $true
    $true
}
function Release-Lock {
    if ($script:LockMine) { Remove-Item -LiteralPath (Join-Path $KitConf 'sync.lock') -Force -Recurse -ErrorAction SilentlyContinue }
    $script:LockMine = $false; $script:Locked = $false
}
function Temp-Next([string]$f) { "$f.kit." + [IO.Path]::GetRandomFileName() }   # a temp file next to F, unique per kit

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
function Json-Apply($root, $ops) {
    foreach ($op in $ops) {
        switch ($op[0]) {
            'set'     { Json-Set $root $op[1] (Json-Parse $op[2]) }
            'del'     { Json-Del $root $op[1] }
            'addstr'  { Json-AddItem $root $op[1] @{ t = 'v'; raw = (Json-Str $op[2]) } }
            'rmstr'   { Json-RmItem $root $op[1] @{ t = 'v'; raw = (Json-Str $op[2]) } }
            'addjson' { Json-AddItem $root $op[1] (Json-Parse $op[2]) }
            'rmjson'  { Json-RmItem $root $op[1] (Json-Parse $op[2]) }
            default   { throw "json: unknown op $($op[0])" }
        }
    }
}
function Json-Text($root, [string]$orig) { # keep a trailing newline only if the file had one; CRLF files keep CRLF
    $s = Json-Ser $root
    if ($orig.EndsWith("`n")) { $s += "`n" }
    if ($orig.Contains("`r`n")) { $s = $s.Replace("`n", "`r`n") }
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
        $tmp = Temp-Next $f
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
    # the backup is the file as it was before kit first changed it (later edits do not replace it)
    if ($backup -and (Test-Path -LiteralPath "$f.kit-backup")) { $backup = $false }
    if ((Test-Path -LiteralPath $f) -and (Is-Link (Get-Item -LiteralPath $f -Force))) {   # keep the link (dotfiles)
        try {
            if ($backup) { Copy-Item -LiteralPath $f -Destination "$f.kit-backup" -Force }
            [IO.File]::WriteAllBytes($f, [IO.File]::ReadAllBytes($tmp)); Remove-Item -LiteralPath $tmp -Force; return
        } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; Die "沒辦法寫入 ${f}：$($_.Exception.Message)" }
    }
    $b = if ($backup) { "$f.kit-backup" } else { [NullString]::Value }   # a plain $null would become "
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
function Dir-Hash([string]$dir) { # content hash of a directory: its files, not what links (junctions) point at
    # (like find -type f; PowerShell 5.1 -Recurse goes into junctions: node_modules / .venv would count as hand edits)
    $base = (Resolve-Path -LiteralPath $dir).ProviderPath.TrimEnd('\', '/')
    $sha = [Security.Cryptography.SHA256]::Create()
    $stack = New-Object System.Collections.Stack; $stack.Push($base)
    $lines = while ($stack.Count -gt 0) {
        foreach ($e in @(Get-ChildItem -LiteralPath $stack.Pop() -Force)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.PSIsContainer) { $stack.Push($e.FullName); continue }
            if ($e.Name -eq '.DS_Store') { continue }
            $e.FullName.Substring($base.Length + 1).Replace('\', '/') + ' ' + [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($e.FullName)))
        }
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
    $t = Temp-Next $State
    Write-Text $t (($rows | ForEach-Object { "$_`n" }) -join '')
    Move-Item -LiteralPath $t -Destination $State -Force
}
function State-From-Old([string]$item, [string]$dir) { # a "from" entry written before 0.3.0 with the folder as typed (links in it)
    foreach ($r in State-Rows) {
        $f = $r.Split("`t")
        if ($f[0] -eq 'from' -and $f[1].StartsWith("$item@") -and (Canon-Dir $f[1].Substring($item.Length + 1)) -eq $dir) { if ($f.Count -gt 2) { return $f[2] } }
    }
    $null
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
    $tmp = Temp-Next $Machine; Write-Text $tmp $t; Move-Item -LiteralPath $tmp -Destination $Machine -Force
}

# ---------- sources ----------
function Is-Url([string]$s) { # a git URL: scheme://..., user@host:path, or host:path (git's scp form; a drive letter C: is a folder)
    if ($s -match '://' -or $s -match '^[^/\\]*@[^/\\]*:') { return $true }
    if ($s -match '^[A-Za-z]:([\\/]|$)' -or $s -match '^(/|\./|\.\./|~|\\)') { return $false }
    $s -match '^[^/\\:]+:'
}
function Url-Host([string]$u) { ((($u -replace '^[A-Za-z][A-Za-z0-9+.-]*://', '') -replace '^[^@/]*@', '') -replace '[:/].*$', '').ToLowerInvariant() }
function Url-Safe([string]$u) { $u -replace '^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@', '$1' }   # a URL without user:password@ (never printed or kept)
function Has-Creds([string]$u) { $u -match '^[Hh][Tt][Tt][Pp][Ss]?://[^/]*@' }   # an http(s) URL with user[:password]@ in it
function Src-Name([string]$s) { [IO.Path]::GetFileName($s.TrimEnd('/', '\')) -replace '\.git$', '' }
function Src-Dir([string]$s) { # local checkout of a source, links resolved: the same folder always has the same name
    if (Is-Url $s) { return Canon-Dir (Join-Path $KitSrc (Src-Name $s)) }
    Canon-Dir $s
}
$script:CanonDirs = @{}
function Canon-Dir([string]$d) { # one name per folder, links resolved (unix/kit: real_dir = pwd -P; on Windows also junctions, folder symlinks, subst drives)
    if (-not $d -or -not (Test-Path -LiteralPath $d)) { return $d }
    $f = Full-Path $d
    if (-not (Test-Path -LiteralPath $f -PathType Container)) { return $f }
    if (-not $script:CanonDirs.ContainsKey($f)) {
        $script:CanonDirs[$f] = if ($OnWindows) { try { Win-Real-Dir $f } catch { $f } } else { Real-Dir $f }
    }
    $script:CanonDirs[$f]
}
$script:SubstDrives = $null
function Subst-Drives { # subst drive letter -> the folder it stands for (X -> C:\work)
    if ($null -eq $script:SubstDrives) {
        $script:SubstDrives = @{}
        foreach ($l in @(& subst.exe 2>$null)) { if ("$l" -match '^([A-Za-z]):\\: => (.+)$') { $script:SubstDrives[$Matches[1].ToUpper()] = $Matches[2].Trim() } }
    }
    $script:SubstDrives
}
function Win-Real-Dir([string]$p) { # Windows: follow subst drives, junctions and symlinks anywhere along the path
    for ($hop = 0; $hop -lt 40; $hop++) {
        $sd = Subst-Drives
        if ($p -match '^([A-Za-z]):' -and $sd.ContainsKey($Matches[1].ToUpper())) { $p = $sd[$Matches[1].ToUpper()].TrimEnd('\') + $p.Substring(2); continue }
        $root = [IO.Path]::GetPathRoot($p); $cur = $root.TrimEnd('\'); $next = $null
        $parts = @($p.Substring($root.Length).Split('\') | Where-Object { $_ })
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $cur = "$cur\$($parts[$i])"
            $it = Get-Item -LiteralPath $cur -Force
            if ($it.LinkType -ne 'Junction' -and $it.LinkType -ne 'SymbolicLink') { continue }
            $t = "$(@($it.Target)[0])" -replace '^\\\?\?\\', '' -replace '^UNC\\', '\\'
            if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $cur) $t }
            $next = [IO.Path]::GetFullPath(((@($t) + @($parts | Select-Object -Skip ($i + 1))) -join '\')); break
        }
        if ($null -eq $next) { return $p.TrimEnd('\') }
        $p = $next
    }
    $p
}
function Src-Dirs { @(foreach ($s in M-Sources) { Src-Dir $s }) }
$script:PushDir = $null
function Allowed-Hosts { # kit push: the source's own list when it has one; else every configured source's (+ the source kit push sends from)
    if ($script:PushDir) {
        $own = @(YGet (Join-Path $script:PushDir 'kit.yaml') 'allowed_hosts' | Where-Object { $_ })
        if ($own.Count -gt 0) { return (Uniq @($own | ForEach-Object { $_.ToLowerInvariant() })) }
    }
    $dirs = @(Src-Dirs); if ($script:PushDir) { $dirs += $script:PushDir }
    Uniq @(foreach ($d in $dirs) { YGet (Join-Path $d 'kit.yaml') 'allowed_hosts' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } })
}

function Git-Safe { # git without prompts (no password question, no sign-in window, no ssh question), submodules or LFS downloads
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'; $env:GIT_LFS_SKIP_SMUDGE = '1'
    if (-not $env:GIT_SSH_COMMAND -and -not $script:SshSet) {
        $script:SshSet = $true
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $c = "$(& git config core.sshCommand 2>$null)" } finally { $ErrorActionPreference = $old }
        if (-not $c) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes' }
    }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git @args 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
}
function Check-Host([string]$url) { # refuse URLs whose host is not allowed
    if (-not (Is-Url $url)) { return }
    $hosts = @(Allowed-Hosts)
    if ($hosts.Count -eq 0) { return }
    if (-not $url.StartsWith('file:///', [StringComparison]::OrdinalIgnoreCase)) {   # file:///path: a folder on this machine, no host to ask
        $h = Url-Host $url
        if ($hosts -notcontains $h) { Die-C host_not_allowed "$h 不在允許的主機清單：$($hosts -join ' ')" }
    }
    # git config "insteadOf" rules can rewrite a URL; check where git really goes
    $real = (Git-Safe ls-remote --get-url $url | Select-Object -First 1)
    if ($real -and $real -ne $url -and (Is-Url $real)) { $h = Url-Host $real; if ($hosts -notcontains $h) { Die-C host_not_allowed "git 設定把網址改到 ${h}，不在允許的主機清單" } }
}
function Push-Urls([string]$dir, [string]$remote) { # every URL git may push REMOTE to (pushurl else url, insteadOf applied; pushInsteadOf too)
    $rules = @(Git-Q -C $dir config --get-regexp '^url\..*\.pushinsteadof$')
    foreach ($u in @(Git-Q -C $dir remote get-url --push --all $remote)) {
        if (-not $u) { continue }
        $u
        foreach ($r in $rules) {
            $i = $r.IndexOf(' '); if ($i -lt 0) { continue }
            $k = $r.Substring(0, $i); $v = $r.Substring($i + 1)
            if ($v -and $u.StartsWith($v)) { $k = $k.Substring(4); $k.Substring(0, $k.Length - 14) + $u.Substring($v.Length) }
        }
    }
}
function Check-PushUrls([string]$dir, [string]$remote) { foreach ($u in @(Push-Urls $dir $remote)) { Check-Host $u } }   # refuse when git would push REMOTE to a host that is not allowed
function Pull-Why([string]$d) { # why git pull --ff-only did not work there
    [void](Git-Safe -C $d fetch --quiet --no-recurse-submodules)
    if ($LASTEXITCODE -ne 0) { return '沒網路？' }
    if (@(Git-Q -C $d status --porcelain | Where-Object { $_ }).Count -gt 0) { return "$d 裡有自己改過、還沒送出的檔案；先送出或拿掉" }
    $n = "$(@(Git-Q -C $d rev-list --count '@{u}..HEAD') -join '')"
    if ($LASTEXITCODE -eq 0 -and $n -match '^[0-9]+$' -and $n -ne '0') { return "$d 有 $n 個來源沒有的 commit，跟來源分岔了" }
    "到 $d 打 git pull 看原因"
}
function Git-Err($out) { # the last lines git said (no user:password@), for the message
    foreach ($l in @(@($out | Where-Object { $_ }) | Select-Object -Last 3)) { Warn ("    " + ("$l" -replace '(://)[^/@ ]*@', '$1')) }
}
function Fetch-Source([string]$s) { # clone or fast-forward one source
    if (-not (Is-Url $s)) { if (-not (Test-Path -LiteralPath $s -PathType Container)) { Die "找不到來源資料夾：$s" }; return }
    Check-Host $s
    $d = Src-Dir $s
    if (Test-Path -LiteralPath (Join-Path $d '.git')) {
        $o = @(Git-Safe -C $d pull --ff-only --quiet --no-recurse-submodules)
        if ($LASTEXITCODE -ne 0) { Warn "沒辦法更新 $(Src-Name $s)（$(Pull-Why $d)）"; Git-Err $o }
    } else {
        Ensure-Dir $KitSrc
        $o = @(Git-Safe clone --quiet --no-recurse-submodules $s $d)
        if ($LASTEXITCODE -ne 0) { Warn "沒辦法 clone $(Url-Safe $s)，git 說："; Git-Err $o; exit 1 }
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

# ---------- MCP: read a pasted setup, take the secrets out, write kit's yaml; find the package ----------
# The same as unix/mcp.awk, line for line (read that for what each part does and for the lines it prints):
# Mcp-Read MODE LINES [NAME] [PIN] -> the lines mcp.awk prints (E L N T Y X V W R P). MODE: json (LINES: Json-Leaves
# joined by TAB), cmd, toml, yaml (LINES: Yaml-Lines of an MCP yaml kit has).
function Mr-New { New-Object System.Collections.Hashtable ([StringComparer]::Ordinal) }
function Mr-Fail([string]$c, [string]$m) { if (-not $script:Mr.errc) { $script:Mr.errc = $c; $script:Mr.errm = $m } }
function Mr-Emit([string]$s) { [void]$script:Mr.out.Append($s).Append("`n") }
function Mr-Norm([string]$s) { ([regex]::Replace($s.ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-') }
function Mr-Srv([string]$nm) {
    if ($script:Mr.si.ContainsKey($nm)) { return $script:Mr.si[$nm] }
    $j = @{ name = $nm; f = (Mr-New); a = (Mr-New); an = 0; ca = (Mr-New); cn = 0; ek = (New-Object System.Collections.Generic.List[string]); ev = (New-Object System.Collections.Generic.List[string])
            hk = (New-Object System.Collections.Generic.List[string]); hv = (New-Object System.Collections.Generic.List[string]); wl = (New-Object System.Collections.Generic.List[string]); ws = (Mr-New) }
    $script:Mr.si[$nm] = $j; $script:Mr.list.Add($j); $j
}
function Mr-F($j, [string]$k) { $v = $j.f[$k]; if ($null -eq $v) { '' } else { [string]$v } }
function Mr-A($j, [int]$i) { $v = $j.a["$i"]; if ($null -eq $v) { '' } else { [string]$v } }
function Mr-AddArg($j, [string]$v) { $j.an++; $j.a["$($j.an)"] = $v }
function Mr-Wn($j, [string]$w) { if (-not $j.ws.ContainsKey($w)) { $j.ws[$w] = 1; $j.wl.Add($w) } }
function Mr-SetEnv($j, [string]$k, [string]$v) {
    if ($k -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Mr-Wn $j "env 的 $k 不是環境變數的名字，略過"; return }
    for ($i = 0; $i -lt $j.ek.Count; $i++) { if ($j.ek[$i] -ceq $k) { $j.ev[$i] = $v; return } }
    $j.ek.Add($k); $j.ev.Add($v)
}
function Mr-SetHdr($j, [string]$k, [string]$v) {
    $v = $v.Trim(" `t".ToCharArray())
    if ($k -cnotmatch '^[A-Za-z0-9_-]+$') { Mr-Wn $j "header $k 的名字 kit 寫不下，略過"; return }
    for ($i = 0; $i -lt $j.hk.Count; $i++) { if ($j.hk[$i].ToLowerInvariant() -ceq $k.ToLowerInvariant()) { $j.hv[$i] = $v; return } }
    $j.hk.Add($k); $j.hv.Add($v)
}
function Mr-SetType($j, [string]$t) {
    $l = $t.ToLowerInvariant()
    if (@('stdio', 'http', 'sse') -ccontains $l) { $j.f['type'] = $l }
    elseif (@('streamable-http', 'streamable_http', 'streamablehttp', 'https') -ccontains $l) { $j.f['type'] = 'http' }
    else { Mr-Fail 'bad_config' "不認得的 type：$t（只能是 stdio、http、sse）" }
}
function Mr-Ctl([string]$s) { if ($s -cmatch '[\x01-\x1F\x7F]') { Mr-Fail 'bad_config' '值裡有控制字元（換行、TAB 這些），kit 不收' }; $s }
function Mr-Hex([string]$s) { $n = 0; foreach ($c in $s.ToLowerInvariant().ToCharArray()) { $n = $n * 16 + '0123456789abcdef'.IndexOf($c) }; $n }
function Mr-Chr([int]$n) { if ($n -ge 0x10000) { [char]::ConvertFromUtf32($n) } else { [string][char]$n } }

# JSON
function Mr-LoadJson($lines) {
    $form = ''
    foreach ($l in $lines) {
        $K = $l.Split("`t"); if ($K.Count -lt 2) { continue }
        if (@('mcpServers', 'servers', 'mcp_servers') -ccontains $K[0]) { $form = 'wrap' }
        elseif ($form -eq '' -and $K[0] -cmatch '^(command|url|type|args|env|headers|serverUrl|httpUrl|transport)$') { $form = 'bare' }
    }
    if ($form -eq '') { $form = 'map' }
    foreach ($l in $lines) {
        $K = @('') + $l.Split("`t"); $n = $K.Count - 1; if ($n -lt 2) { continue }
        if ($form -eq 'wrap') { if ($K[1] -cnotmatch '^(mcpServers|servers|mcp_servers)$' -or $n -lt 4) { continue }; $nm = $K[2]; $p = 3 }
        elseif ($form -eq 'map') { if ($n -lt 3) { continue }; $nm = $K[1]; $p = 2 }
        else { $nm = ''; $p = 1 }
        Mr-JField (Mr-Srv $nm) $K $p $n
    }
}
function Mr-JField($j, $K, [int]$p, [int]$n) {
    $f = $K[$p]; $raw = $K[$n]; $d = $n - $p
    if ($raw -cmatch '^[\[{]') { if ($f -cnotmatch '^(args|env|headers|command)$') { Mr-Wn $j "略過 $f（kit 不帶這個設定）" }; return }
    $v = Mr-JVal $raw
    if ($f -ceq 'type' -or $f -ceq 'transport') { if ($d -eq 1) { Mr-SetType $j $v } }
    elseif ($f -ceq 'command') {
        if ($d -eq 1) { $j.f['command'] = $v }
        elseif ($d -eq 2) { $i = Mr-Num $K[$p + 1]; $j.ca["$i"] = $v; if ($i -gt $j.cn) { $j.cn = $i } }
    }
    elseif ($f -ceq 'args') { if ($d -eq 2) { $i = Mr-Num $K[$p + 1]; $j.a["$i"] = $v; if ($i -gt $j.an) { $j.an = $i } } }
    elseif ($f -ceq 'env') { if ($d -eq 2) { Mr-SetEnv $j $K[$p + 1] $v } }
    elseif ($f -ceq 'headers') { if ($d -eq 2) { Mr-SetHdr $j $K[$p + 1] $v } }
    elseif (@('url', 'serverUrl', 'httpUrl') -ccontains $f) { if ($d -eq 1) { $j.f['url'] = $v } }
    elseif ($f -ceq 'description') { if ($d -eq 1) { $j.f['description'] = $v } }
    elseif ($f -ceq 'disabled' -and $v -ceq 'true') { Mr-Wn $j '原本是停用的（disabled），kit 照樣帶進來' }
    else { Mr-Wn $j "略過 $f（kit 不帶這個設定）" }
}
function Mr-Num([string]$s) { $m = [regex]::Match($s, '^[0-9]+'); if ($m.Success) { [int]$m.Value } else { 0 } }
function Mr-JVal([string]$raw) {
    if (-not $raw.StartsWith('"')) { if ($raw -ceq 'null') { return '' }; return $raw }
    Mr-Ctl (Mr-JUnq $raw.Substring(1, $raw.Length - 2))
}
function Mr-JUnq([string]$s) {
    $o = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($c -ne '\') { [void]$o.Append($c); continue }
        $i++; $c = if ($i -lt $s.Length) { $s[$i] } else { '' }
        if ($c -ceq 'u') {
            $n = Mr-Hex (Mr-Sub $s ($i + 1) 4); $i += 4
            if ($n -ge 55296 -and $n -lt 56320 -and (Mr-Sub $s ($i + 1) 2) -eq '\u') { $lo = Mr-Hex (Mr-Sub $s ($i + 3) 4); $n = 65536 + ($n - 55296) * 1024 + ($lo - 56320); $i += 6 }
            if ($n -lt 32) { [void]$o.Append([char]1) } else { try { [void]$o.Append((Mr-Chr $n)) } catch { [void]$o.Append([char]1) } }
        } elseif ('nrtbf'.IndexOf([string]$c) -ge 0 -and "$c" -ne '') { [void]$o.Append([char]1) }
        else { [void]$o.Append($c) }
    }
    $o.ToString()
}
function Mr-Sub([string]$s, [int]$i, [int]$n) { if ($i -ge $s.Length) { return '' }; if ($i + $n -gt $s.Length) { $n = $s.Length - $i }; $s.Substring($i, $n) }

# claude mcp add / codex mcp add lines
function Mr-LoadCmd($lines) {
    $l = ''
    foreach ($e0 in $lines) {
        $e = $e0 -replace '[ \t]+$', ''
        if ($e -cmatch '(\\|`|\^)$') { $l += $e.Substring(0, $e.Length - 1) + ' '; continue }
        $l += $e
        if ($l -cmatch '^[ \t]*(#.*)?$' -or $l -cmatch '^[ \t]*(\$|>|PS[^>]*>)[ \t]*$') { $l = ''; continue }
        Mr-CmdLine $l; $l = ''
        if ($script:Mr.errc) { return }
    }
    if ($l -ne '') { Mr-CmdLine $l }
}
function Mr-Dollar([string]$s, [int]$i) { # at a $ (index I): @(what it means, where to go on)
    $r = $s.Substring($i)
    if ($r.StartsWith('$(')) { Mr-Fail 'bad_config' '不接受 $( ) 指令替換'; return @('', $s.Length) }
    $m = [regex]::Match($r, '^\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}'); if ($m.Success) { return @($m.Value, ($i + $m.Length)) }
    $m = [regex]::Match($r, '^\$env:[A-Za-z_][A-Za-z0-9_]*'); if ($m.Success) { return @(('${' + $m.Value.Substring(5) + '}'), ($i + $m.Length)) }
    $m = [regex]::Match($r, '^\$[A-Za-z_][A-Za-z0-9_]*'); if ($m.Success) { return @(('${' + $m.Value.Substring(1) + '}'), ($i + $m.Length)) }
    @('$', ($i + 1))
}
function Mr-Tokenize([string]$s) {
    $T = New-Object System.Collections.Generic.List[string]
    $w = New-Object System.Text.StringBuilder; $inw = $false; $n = $s.Length; $i = 0
    while ($i -lt $n) {
        $c = $s[$i]
        if ($c -eq ' ' -or $c -eq "`t") { if ($inw) { $T.Add($w.ToString()); [void]$w.Clear(); $inw = $false }; $i++; continue }
        $inw = $true
        $nx = if ($i + 1 -lt $n) { [string]$s[$i + 1] } else { '' }
        if ($c -eq "'") {
            $j = $s.IndexOf("'", $i + 1); if ($j -lt 0) { Mr-Fail 'bad_config' '引號沒有關好'; return , $T }
            [void]$w.Append($s.Substring($i + 1, $j - $i - 1)); $i = $j + 1; continue
        }
        if ($c -eq '"') {
            $i++
            while ($i -lt $n -and $s[$i] -ne '"') {
                $c = $s[$i]; $nx = if ($i + 1 -lt $n) { [string]$s[$i + 1] } else { '' }
                if ($c -eq '\' -and $nx -ne '' -and '"\$`'.IndexOf($nx) -ge 0) { [void]$w.Append($nx); $i += 2; continue }
                if ($c -eq '`') { Mr-Fail 'bad_config' '不接受 ` 指令替換'; return , $T }
                if ($c -eq '$') { $d = Mr-Dollar $s $i; [void]$w.Append($d[0]); $i = $d[1]; continue }
                [void]$w.Append($c); $i++
            }
            if ($i -ge $n) { Mr-Fail 'bad_config' '引號沒有關好'; return , $T }
            $i++; continue
        }
        if ($c -eq '\' -and $nx -ne '' -and " `"'\`$".IndexOf($nx) -ge 0) { [void]$w.Append($nx); $i += 2; continue }
        if ($c -eq '`') { Mr-Fail 'bad_config' '不接受 ` 指令替換'; return , $T }
        if ($c -eq '$') { $d = Mr-Dollar $s $i; [void]$w.Append($d[0]); $i = $d[1]; continue }
        if ($c -eq '%') { $m = [regex]::Match($s.Substring($i), '^%[A-Za-z_][A-Za-z0-9_]*%'); if ($m.Success) { [void]$w.Append('${' + $m.Value.Substring(1, $m.Length - 2) + '}'); $i += $m.Length; continue } }
        if (';&|<>()'.IndexOf($c) -ge 0) { Mr-Fail 'bad_config' '只接受 claude mcp add 或 codex mcp add（不接受 ; & | < > 這些）'; return , $T }
        [void]$w.Append($c); $i++
    }
    if ($inw) { $T.Add($w.ToString()) }
    , $T
}
function Mr-Opt([string]$t) { # @(option, value, has a value)
    $m = [regex]::Match($t, '^--[^=]*='); if ($m.Success) { return @($t.Substring(0, $m.Length - 1), $t.Substring($m.Length), $true) }
    @($t, '', $false)
}
function Mr-T($T, [int]$p) { if ($p -ge 1 -and $p -le $T.Count) { $T[$p - 1] } else { '' } }
function Mr-KvEnv($j, [string]$s) { $e = $s.IndexOf('='); if ($e -lt 0) { Mr-Fail 'bad_config' '--env 要寫成 名字=值'; return }; Mr-SetEnv $j $s.Substring(0, $e) $s.Substring($e + 1) }
function Mr-KvHdr($j, [string]$s) { $e = $s.IndexOf(':'); if ($e -lt 0) { Mr-Fail 'bad_config' '--header 要寫成 "名字: 值"'; return }; Mr-SetHdr $j $s.Substring(0, $e) $s.Substring($e + 1) }
function Mr-CmdLine([string]$s) {
    $tk = Mr-Tokenize $s; if ($script:Mr.errc -or $tk.Count -eq 0) { return }
    $p = 1
    if ((Mr-T $tk $p) -cmatch '^(\$|>)$') { $p++ }
    $prog = (Mr-T $tk $p) -replace '^.*[/\\]', '' -replace '\.(exe|cmd)$', ''
    if (($prog -cne 'claude' -and $prog -cne 'codex') -or (Mr-T $tk ($p + 1)) -cne 'mcp') { Mr-Fail 'bad_config' '看不懂貼上的內容：只接受 JSON、Codex 的 config.toml、claude mcp add 或 codex mcp add'; return }
    if ((Mr-T $tk ($p + 2)) -ceq 'add-json') { Mr-Fail 'bad_config' 'claude mcp add-json：請直接貼它的 JSON（存成檔案）'; return }
    if ((Mr-T $tk ($p + 2)) -cne 'add') { Mr-Fail 'bad_config' "只接受 $prog mcp add"; return }
    if ($prog -ceq 'claude') { Mr-ClaudeAdd $tk ($p + 3) } else { Mr-CodexAdd $tk ($p + 3) }
}
function Mr-ClaudeAdd($tk, [int]$p) {
    $pos = New-Object System.Collections.Generic.List[string]; $tr = ''; $PE = @(); $PH = @(); $pw = ''; $TN = $tk.Count
    for (; $p -le $TN; $p++) {
        $t = Mr-T $tk $p
        if ($t -ceq '--') { $p++; break }
        $o = @('', '', $false); if ($t.StartsWith('-')) { $o = Mr-Opt $t }
        if ($t.StartsWith('-') -and ($pos.Count -lt 2 -or $o[0] -cmatch '^(-t|--transport|-s|--scope|-e|--env|-H|--header)$')) {
            switch -CaseSensitive ($o[0]) {
                { $_ -eq '-t' -or $_ -eq '--transport' } { if ($o[2]) { $tr = $o[1] } else { $p++; $tr = Mr-T $tk $p }; break }
                { $_ -eq '-s' -or $_ -eq '--scope' } { if (-not $o[2]) { $p++ }; break }
                { $_ -eq '-e' -or $_ -eq '--env' } { if ($o[2]) { $PE += $o[1] } else { while ($p -lt $TN -and (Mr-T $tk ($p + 1)) -cmatch '^[A-Za-z_][A-Za-z0-9_]*=') { $p++; $PE += (Mr-T $tk $p) } }; break }
                { $_ -eq '-H' -or $_ -eq '--header' } { if ($o[2]) { $PH += $o[1] } else { while ($p -lt $TN -and (Mr-T $tk ($p + 1)) -cmatch '^[A-Za-z0-9_-]+:') { $p++; $PH += (Mr-T $tk $p) } }; break }
                { $_ -eq '--client-id' -or $_ -eq '--callback-port' } { if (-not $o[2]) { $p++ }; $pw += $o[0] + ' '; break }
                '--client-secret' { $pw += $o[0] + ' '; break }
                default { Mr-Fail 'bad_config' "claude mcp add 的 $($o[0]) kit 不認得"; return }
            }
            continue
        }
        $pos.Add($t)
    }
    $L = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -lt $pos.Count; $i++) { $L.Add($pos[$i]) }
    for (; $p -le $TN; $p++) { $L.Add((Mr-T $tk $p)) }
    if ($pos.Count -lt 1 -or $L.Count -lt 1) { Mr-Fail 'bad_config' 'claude mcp add 要有名字和要跑的程式（或網址）'; return }
    $j = Mr-Srv $pos[0]
    foreach ($e in $PE) { Mr-KvEnv $j $e }
    foreach ($h in $PH) { Mr-KvHdr $j $h }
    if ($pw) { Mr-Wn $j "略過 $pw（OAuth 的設定 kit 不帶，第一次連線時 Claude 會自己問）" }
    if ($tr) { Mr-SetType $j $tr } elseif ($L[0] -cmatch '^https?://') { $j.f['type'] = 'http' }
    $ty = Mr-F $j 'type'
    if ($ty -ceq 'http' -or $ty -ceq 'sse') { $j.f['url'] = $L[0]; if ($L.Count -gt 1) { Mr-Wn $j '網址後面多的參數略過' } }
    else { $j.f['command'] = $L[0]; for ($i = 1; $i -lt $L.Count; $i++) { Mr-AddArg $j $L[$i] } }
}
function Mr-CodexAdd($tk, [int]$p) {
    $nm = ''; $url = ''; $bv = ''; $E3 = @(); $TN = $tk.Count
    for (; $p -le $TN; $p++) {
        $t = Mr-T $tk $p
        if ($t -ceq '--') { $p++; break }
        if ($t.StartsWith('-')) {
            $o = Mr-Opt $t
            if ($o[0] -ceq '--env') { if ($o[2]) { $E3 += $o[1] } else { $p++; $E3 += (Mr-T $tk $p) } }
            elseif ($o[0] -ceq '--url') { if ($o[2]) { $url = $o[1] } else { $p++; $url = Mr-T $tk $p } }
            elseif ($o[0] -ceq '--bearer-token-env-var') { if ($o[2]) { $bv = $o[1] } else { $p++; $bv = Mr-T $tk $p } }
            else { Mr-Fail 'bad_config' "codex mcp add 的 $($o[0]) kit 不認得"; return }
            continue
        }
        if ($nm -eq '') { $nm = $t; continue }
        break
    }
    if ($nm -eq '') { Mr-Fail 'bad_config' 'codex mcp add 要有名字'; return }
    $j = Mr-Srv $nm
    foreach ($e in $E3) { Mr-KvEnv $j $e }
    if ($url -ne '') {
        $j.f['type'] = 'http'; $j.f['url'] = $url
        if ($bv -ne '') { Mr-SetHdr $j 'Authorization' ('Bearer ${' + $bv + '}') }
        if ($p -le $TN) { Mr-Wn $j '網址後面多的參數略過' }
        return
    }
    if ($p -gt $TN) { Mr-Fail 'bad_config' 'codex mcp add 要有 -- 後面要跑的程式（或 --url）'; return }
    $j.f['command'] = Mr-T $tk $p; $p++
    for (; $p -le $TN; $p++) { Mr-AddArg $j (Mr-T $tk $p) }
}

# Codex config.toml (a cursor $script:Mr.p over the text $script:Mr.s, from 0)
function Mr-C { $m = $script:Mr; if ($m.p -lt $m.s.Length) { [string]$m.s[$m.p] } else { '' } }
function Mr-LoadToml($lines) {
    $m = $script:Mr; $m.s = (@($lines) -join "`n") + "`n"; $m.p = 0; $tn = 0; $TK = @()
    while ($m.p -lt $m.s.Length) {
        Mr-Tws; if ($m.p -ge $m.s.Length) { break }
        $c = Mr-C
        if ($c -eq "`n") { $m.p++; continue }
        if ($c -eq '#') { Mr-Teol; continue }
        if ($c -eq '[') {
            $m.p++; if ((Mr-C) -eq '[') { Mr-Fail 'bad_config' 'config.toml 的 [[ ]] kit 看不懂'; return }
            $TK = @(Mr-TKeys); $tn = $TK.Count; Mr-Tws; if ((Mr-C) -ne ']') { Mr-Fail 'bad_config' 'config.toml 的 [ ] 沒寫好'; return }
            $m.p++; Mr-Teol; continue
        }
        $K = @(Mr-TKeys); Mr-Tws
        if ((Mr-C) -ne '=') { Mr-Fail 'bad_config' 'config.toml 看不懂（要是 名字 = 值）'; return }
        $m.p++; Mr-Tws; Mr-TVal; if ($m.errc) { return }
        Mr-TAssign (@($TK | Select-Object -First $tn) + $K)
        Mr-Teol
    }
}
function Mr-Tws { $m = $script:Mr; while ($m.p -lt $m.s.Length -and " `t`r".IndexOf($m.s[$m.p]) -ge 0) { $m.p++ } }
function Mr-Teol { $m = $script:Mr; while ($m.p -lt $m.s.Length -and $m.s[$m.p] -ne "`n") { $m.p++ } }
function Mr-Tgap { $m = $script:Mr; while ($m.p -lt $m.s.Length) { if (" `t`r`n,".IndexOf($m.s[$m.p]) -ge 0) { $m.p++ } elseif ($m.s[$m.p] -eq '#') { Mr-Teol } else { break } } }
function Mr-TKeys {
    $m = $script:Mr; $K = New-Object System.Collections.Generic.List[string]
    while ($true) {
        Mr-Tws; $c = Mr-C
        if ($c -eq '"' -or $c -eq "'") { $K.Add((Mr-TStr)) }
        else { $x = [regex]::Match($m.s.Substring($m.p), '^[A-Za-z0-9_-]+'); if (-not $x.Success) { return $K.ToArray() }; $K.Add($x.Value); $m.p += $x.Length }
        Mr-Tws; if ((Mr-C) -ne '.') { return $K.ToArray() }
        $m.p++
    }
}
function Mr-TStr {
    $m = $script:Mr; $q = Mr-C; $m.p++; $o = New-Object System.Text.StringBuilder
    if ((Mr-Sub $m.s $m.p 2) -eq "$q$q") { Mr-Fail 'bad_config' 'config.toml 的多行字串 kit 看不懂'; return '' }
    while ($m.p -lt $m.s.Length) {
        $c = Mr-C
        if ($c -eq $q) { $m.p++; return (Mr-Ctl $o.ToString()) }
        if ($c -eq "`n") { break }
        if ($q -eq '"' -and $c -eq '\') {
            $m.p++; $c = Mr-C
            if ($c -ceq 'u' -or $c -ceq 'U') { $n = if ($c -ceq 'u') { 4 } else { 8 }; try { [void]$o.Append((Mr-Chr (Mr-Hex (Mr-Sub $m.s ($m.p + 1) $n)))) } catch { [void]$o.Append([char]1) }; $m.p += $n + 1; continue }
            if ($c -ne '' -and 'nrtbf'.IndexOf($c) -ge 0) { [void]$o.Append([char]1) } else { [void]$o.Append($c) }
            $m.p++; continue
        }
        [void]$o.Append($c); $m.p++
    }
    Mr-Fail 'bad_config' 'config.toml 的引號沒有關好'; ''
}
function Mr-TScalar {
    $m = $script:Mr; $c = Mr-C
    if ($c -eq '"' -or $c -eq "'") { return (Mr-TStr) }
    $x = [regex]::Match($m.s.Substring($m.p), '^[A-Za-z0-9_.:+-]+'); if ($x.Success) { $m.p += $x.Length; return $x.Value }
    Mr-Fail 'bad_config' 'config.toml 有 kit 看不懂的值'; ''
}
function Mr-TVal { # $script:Mr.vt: s (vs), a (vi), t (vk, vv)
    $m = $script:Mr; $c = Mr-C; $m.vi = New-Object System.Collections.Generic.List[string]; $m.vk = New-Object System.Collections.Generic.List[string]; $m.vv = New-Object System.Collections.Generic.List[string]
    if ($c -eq '[') {
        $m.vt = 'a'; $m.p++
        while ($true) { Mr-Tgap; if ((Mr-C) -eq ']') { $m.p++; return }; if ($m.p -ge $m.s.Length -or $m.errc) { Mr-Fail 'bad_config' 'config.toml 的 [ ] 沒寫好'; return }; $m.vi.Add((Mr-TScalar)) }
    }
    if ($c -eq '{') {
        $m.vt = 't'; $m.p++
        while ($true) {
            Mr-Tgap; if ((Mr-C) -eq '}') { $m.p++; return }
            if ($m.p -ge $m.s.Length -or $m.errc) { Mr-Fail 'bad_config' 'config.toml 的 { } 沒寫好'; return }
            $k = @(Mr-TKeys); Mr-Tws; if ((Mr-C) -ne '=') { Mr-Fail 'bad_config' 'config.toml 的 { } 沒寫好'; return }
            $m.p++; Mr-Tws; $m.vk.Add($(if ($k.Count) { $k[0] } else { '' })); $m.vv.Add((Mr-TScalar))
        }
    }
    $m.vt = 's'; $m.vs = Mr-TScalar
}
function Mr-TAssign($K) {
    $m = $script:Mr; $n = @($K).Count
    if ($n -lt 3 -or $K[0] -cne 'mcp_servers') { return }
    $j = Mr-Srv $K[1]; $f = $K[2]
    if ($n -eq 4 -and $m.vt -eq 's') {
        if ($f -ceq 'env') { Mr-SetEnv $j $K[3] $m.vs } elseif ($f -ceq 'http_headers') { Mr-SetHdr $j $K[3] $m.vs }
        elseif ($f -ceq 'env_http_headers') { Mr-SetHdr $j $K[3] ('${' + $m.vs + '}') } else { Mr-Wn $j "略過 $f（kit 不帶這個設定）" }
        return
    }
    if ($n -ne 3) { return }
    if ($f -ceq 'command' -and $m.vt -eq 's') { $j.f['command'] = $m.vs }
    elseif ($f -ceq 'args' -and $m.vt -eq 'a') { foreach ($v in $m.vi) { Mr-AddArg $j $v } }
    elseif ($f -ceq 'url' -and $m.vt -eq 's') { $j.f['url'] = $m.vs }
    elseif ($f -ceq 'env' -and $m.vt -eq 't') { for ($i = 0; $i -lt $m.vk.Count; $i++) { Mr-SetEnv $j $m.vk[$i] $m.vv[$i] } }
    elseif ($f -ceq 'env_vars' -and $m.vt -eq 'a') { foreach ($v in $m.vi) { Mr-SetEnv $j $v ('${' + $v + '}') } }
    elseif ($f -ceq 'http_headers' -and $m.vt -eq 't') { for ($i = 0; $i -lt $m.vk.Count; $i++) { Mr-SetHdr $j $m.vk[$i] $m.vv[$i] } }
    elseif ($f -ceq 'env_http_headers' -and $m.vt -eq 't') { for ($i = 0; $i -lt $m.vk.Count; $i++) { Mr-SetHdr $j $m.vk[$i] ('${' + $m.vv[$i] + '}') } }
    elseif ($f -ceq 'bearer_token_env_var' -and $m.vt -eq 's') { Mr-SetHdr $j 'Authorization' ('Bearer ${' + $m.vs + '}') }
    elseif ($f -ceq 'enabled' -and $m.vt -eq 's' -and $m.vs -ceq 'false') { Mr-Wn $j '原本是停用的（enabled = false），kit 照樣帶進來' }
    else { Mr-Wn $j "略過 $f（kit 不帶這個設定）" }
}

# a yaml kit has
function Mr-LoadYaml($lines, [string]$name) {
    $j = Mr-Srv $name
    foreach ($l in $lines) {
        $e = $l.IndexOf("`t"); if ($e -lt 0) { continue }
        $k = $l.Substring(0, $e); $v = $l.Substring($e + 1)
        if ($k -ceq 'args[]') { Mr-AddArg $j $v }
        elseif ($k.StartsWith('env.')) { $j.ek.Add($k.Substring(4)); $j.ev.Add($v) }
        elseif ($k.StartsWith('headers.')) { $j.hk.Add($k.Substring(8)); $j.hv.Add($v) }
        elseif ($k -ceq 'type') { $j.f['type'] = $v }
        elseif (@('command', 'url', 'description') -ccontains $k) { $j.f[$k] = $v }
    }
}

# secrets
function Mr-SecName([string]$k) {
    $s = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $k.Length; $i++) { $c = [string]$k[$i]; if ($c -cmatch '[A-Z]' -and $i -gt 0 -and ([string]$k[$i - 1]) -cmatch '[a-z0-9]') { [void]$s.Append('_') }; [void]$s.Append($c) }
    foreach ($p in [regex]::Split($s.ToString().ToUpperInvariant(), '[^A-Z0-9]+')) {
        if ($p -cmatch 'KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|COOKIE|SESSION' -or $p -ceq 'PAT') { return $true }
        if ($p -cmatch 'AUTH' -and $p -cne 'AUTHOR' -and $p -cne 'AUTHORS') { return $true }
    }
    $false
}
function Mr-SecPlain([string]$v) {
    $v -eq '' -or $v.Contains('${') -or $v.ToLowerInvariant() -cmatch '^(true|false|yes|no|on|off|null|none)$' -or $v -cmatch '^[0-9][0-9.]*$' -or $v -cmatch '^(/|~/|\./|\.\./|[A-Za-z]:[\\/])' -or $v -cmatch '^[A-Za-z][A-Za-z0-9+.-]*://'
}
function Mr-SecToken([string]$v) {
    if ($v.Contains('${') -or $v -cnotmatch '^[A-Za-z0-9_+=/.-]+$') { return $false }
    $n = $v.Length
    $m = [regex]::Match($v, '^(sk-|sk_live_|sk_test_|rk_live_|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xox[abprs]-|AKIA|ASIA|AIza|eyJ)')
    if ($m.Success -and $n - $m.Length -ge 8) { return $true }
    if ($n -ge 20 -and -not $v.StartsWith('/') -and $v -cmatch '[A-Z]' -and $v -cmatch '[a-z]' -and $v -cmatch '[0-9]') { if ([regex]::Matches($v, '[._/-]').Count -le 3) { return $true } }
    if ($n -ge 32 -and $v -cmatch '^[0-9A-Fa-f]+$' -and $v -cmatch '[0-9]' -and $v -cmatch '[A-Fa-f]') { return $true }
    $false
}
function Mr-VName([string]$k) { ([regex]::Replace(($k -replace '^-+', '').ToUpperInvariant(), '[^A-Z0-9]+', '_')).Trim('_') }
function Mr-NewVar([string]$base) { $v = $base; $i = 2; while ($script:Mr.used.ContainsKey($v)) { $v = "${base}_$i"; $i++ }; $script:Mr.used[$v] = 1; $v }
function Mr-Secret([string]$where, [string]$base) { $v = Mr-NewVar $base; Mr-Emit "X`t$where`t$v"; $v }
function Mr-UsedVars([string]$s) { foreach ($x in [regex]::Matches($s, '\$\{([A-Za-z_][A-Za-z0-9_]*)')) { $script:Mr.used[$x.Groups[1].Value] = 1 } }
function Mr-UrlStrip([string]$u, [string]$where) {
    $m = [regex]::Match($u, '^[A-Za-z][A-Za-z0-9+.-]*://'); if (-not $m.Success) { return $u }
    $sv = $script:Mr.sv
    $sch = $m.Value; $rest = $u.Substring($m.Length)
    $frag = ''; $i = $rest.IndexOf('#'); if ($i -ge 0) { $frag = $rest.Substring($i); $rest = $rest.Substring(0, $i) }
    $q = ''; $hq = $false; $i = $rest.IndexOf('?'); if ($i -ge 0) { $q = $rest.Substring($i + 1); $rest = $rest.Substring(0, $i); $hq = $true }
    $i = $rest.IndexOf('/'); if ($i -ge 0) { $auth = $rest.Substring(0, $i); $path = $rest.Substring($i) } else { $auth = $rest; $path = '' }
    $at = $auth.LastIndexOf('@')
    if ($at -ge 0) {
        $ui = $auth.Substring(0, $at); $c = $ui.IndexOf(':')
        if ($c -ge 0) { $pw = $ui.Substring($c + 1); if ($pw -ne '' -and -not $pw.Contains('${')) { $ui = $ui.Substring(0, $c + 1) + '${' + (Mr-Secret $where "${sv}_PASSWORD") + '}' } }
        elseif (Mr-SecToken $ui) { $ui = '${' + (Mr-Secret $where "${sv}_TOKEN") + '}' }
        $auth = $ui + $auth.Substring($at)
    }
    $parts = $path.Split('/'); if ($path -eq '') { $parts = @() }
    for ($i = 0; $i -lt $parts.Count; $i++) { if (Mr-SecToken $parts[$i]) { $parts[$i] = '${' + (Mr-Secret $where "${sv}_SECRET") + '}' } }
    $path = $parts -join '/'
    if ($hq) {
        $qs = $q.Split('&'); if ($q -eq '') { $qs = @() }
        for ($i = 0; $i -lt $qs.Count; $i++) {
            $c = $qs[$i].IndexOf('=')
            if ($c -ge 0) { $k = $qs[$i].Substring(0, $c); $v = $qs[$i].Substring($c + 1); if ($v -ne '' -and -not $v.Contains('${') -and ((Mr-SecName $k) -or (Mr-SecToken $v))) { $qs[$i] = $k + '=${' + (Mr-Secret $where "${sv}_$(Mr-VName $k)") + '}' } }
        }
        $q = '?' + ($qs -join '&')
    }
    $sch + $auth + $path + $q + $frag
}
function Mr-Strip($j) {
    $sv = $script:Mr.sv
    for ($i = 0; $i -lt $j.ek.Count; $i++) {
        $k = $j.ek[$i]; $v = $j.ev[$i]; $w = "env.$k"
        if ($v.Contains('${')) { continue }
        if ($v -cmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $j.ev[$i] = Mr-UrlStrip $v $w }
        elseif (((Mr-SecName $k) -and -not (Mr-SecPlain $v)) -or (Mr-SecToken $v)) { $j.ev[$i] = '${' + (Mr-Secret $w $k) + '}' }
    }
    for ($i = 0; $i -lt $j.hk.Count; $i++) {
        $k = $j.hk[$i]; $v = $j.hv[$i]; $w = "headers.$k"; $lk = $k.ToLowerInvariant()
        if ($v.Contains('${') -or $v -eq '') { continue }
        if ($lk -ceq 'authorization' -or $lk -ceq 'proxy-authorization') {
            $m = [regex]::Match($v, '^(Bearer|Basic|Token|Bot|bearer|basic|token) +')
            if ($m.Success) { $j.hv[$i] = $m.Value + '${' + (Mr-Secret $w "${sv}_TOKEN") + '}' } else { $j.hv[$i] = '${' + (Mr-Secret $w "${sv}_TOKEN") + '}' }
        } elseif ($lk -ceq 'cookie') { $j.hv[$i] = '${' + (Mr-Secret $w "${sv}_COOKIE") + '}' }
        elseif (((Mr-SecName $k) -and -not (Mr-SecPlain $v)) -or (Mr-SecToken $v)) { $k = (Mr-VName $k) -replace '^X_', ''; $j.hv[$i] = '${' + (Mr-Secret $w "${sv}_$k") + '}' }
    }
    if ((Mr-F $j 'url') -ne '') { $j.f['url'] = Mr-UrlStrip (Mr-F $j 'url') 'url' }
    $prev = ''
    for ($i = 1; $i -le $j.an; $i++) {
        $v = Mr-A $j $i; $w = "args[$i]"
        if ($v.Contains('${')) { $prev = $v; continue }
        if ($v -cmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $j.a["$i"] = Mr-UrlStrip $v $w }
        elseif ($v -cmatch '^--?[A-Za-z0-9][A-Za-z0-9_-]*=' -or $v -cmatch '^[A-Za-z_][A-Za-z0-9_]*=') {
            $e = $v.IndexOf('='); $k = $v.Substring(0, $e); $v = $v.Substring($e + 1)
            if ($v -cmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $j.a["$i"] = $k + '=' + (Mr-UrlStrip $v $w) }
            elseif (((Mr-SecName $k) -and -not (Mr-SecPlain $v)) -or (Mr-SecToken $v)) { $b = if ($k.StartsWith('-')) { "${sv}_$(Mr-VName $k)" } else { $k }; $j.a["$i"] = $k + '=${' + (Mr-Secret $w $b) + '}' }
        }
        elseif ($prev -cmatch '^--?[A-Za-z]' -and -not $prev.Contains('=') -and -not $v.StartsWith('-') -and (Mr-SecName $prev) -and -not (Mr-SecPlain $v)) { $j.a["$i"] = '${' + (Mr-Secret $w "${sv}_$(Mr-VName $prev)") + '}' }
        elseif (Mr-SecToken $v) { $j.a["$i"] = '${' + (Mr-Secret $w "${sv}_SECRET") + '}' }
        $prev = Mr-A $j $i
    }
}

# the package (npx, uvx)
function Mr-Need([string]$t) { if (-not $script:Mr.rq.ContainsKey($t)) { $script:Mr.rq[$t] = 1; Mr-Emit "R`t$t" } }
function Mr-Pkg($j, [string]$pin) {
    $c = ((Mr-F $j 'command') -replace '^.*[/\\]', '').ToLowerInvariant() -replace '\.(exe|cmd|bat)$', ''
    if (@('npx', 'node', 'npm') -ccontains $c) { Mr-Need 'node' }
    elseif ($c -ceq 'uvx' -or $c -ceq 'uv') { Mr-Need 'uv' }
    elseif ($c -cmatch '^python(3(\.[0-9]+)?)?$' -or $c -ceq 'py') { Mr-Need 'python' }
    elseif ($c -ceq 'docker') { Mr-Need 'docker' }
    $bad = ''; $nm = ''; $ver = ''; $bin = ''; $pre = ''; $argno = 0; $fi = 0; $ex = ''; $fno = 0; $fpre = ''
    if ($c -ceq 'npx') {
        $kind = 'npm'; $spec = ''
        for ($i = 1; $i -le $j.an; $i++) {
            $a = Mr-A $j $i
            if (@('-y', '--yes', '-q', '--quiet') -ccontains $a) { continue }
            if ($a -ceq '-p' -or $a -ceq '--package') { $i++; $spec = Mr-A $j $i; $argno = $i; continue }
            if ($a.StartsWith('--package=')) { $spec = $a.Substring(10); $argno = $i; $pre = '--package='; continue }
            if ($a.StartsWith('-')) { $bad = "npx 的 $a kit 不認得"; break }
            if ($spec -eq '') { $spec = $a; $argno = $i } else { $bin = $a }
            $fi = $i + 1; break
        }
        if ($bad -eq '' -and $spec -eq '') { return }
        if ($spec -ne '') {
            $at = $spec.LastIndexOf('@')
            if ($at -gt 0) { $nm = $spec.Substring(0, $at); $ver = $spec.Substring($at + 1) } else { $nm = $spec }
            if ($bad -eq '' -and $nm -cnotmatch '^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$') { $bad = "套件 $nm 不是 npm registry 上的名字" }
        }
        if ($ver -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$') { $ver = '' }
    } elseif ($c -ceq 'uvx' -or ($c -ceq 'uv' -and (Mr-A $j 1) -ceq 'tool' -and (Mr-A $j 2) -ceq 'run')) {
        $kind = 'pip'; $spec = ''
        for ($i = $(if ($c -ceq 'uv') { 3 } else { 1 }); $i -le $j.an; $i++) {
            $a = Mr-A $j $i
            if ($a -ceq '-q' -or $a -ceq '--quiet') { continue }
            if ($a -ceq '--from') { $i++; $spec = Mr-A $j $i; $fno = $i; $fpre = ''; continue }
            if ($a.StartsWith('--from=')) { $spec = $a.Substring(7); $fno = $i; $fpre = '--from='; continue }
            if ($a -ceq '--python' -or $a -ceq '-p') { $i++; continue }
            if ($a.StartsWith('--python=')) { continue }
            if ($a.StartsWith('-')) { $bad = "uvx 的 $a kit 不幫它裝（照樣在啟動時下載）"; break }
            $bin = $a; $argno = $i; $fi = $i + 1; break
        }
        if ($bad -eq '' -and $bin -eq '') { return }
        if ($fno) { $argno = $fno; $pre = $fpre; $bin = $bin -replace '@.*$', '' } else { $spec = $bin; $bin = '' }
        if ($spec -ne '') {
            $x = $spec.IndexOf('==')
            if ($x -ge 0) { $nm = $spec.Substring(0, $x); $ver = $spec.Substring($x + 2) }
            elseif (($x = $spec.IndexOf('@')) -ge 0) { $nm = $spec.Substring(0, $x); $ver = $spec.Substring($x + 1) }
            else { $nm = $spec }
            $m = [regex]::Match($nm, '\[[A-Za-z0-9._,-]*\]$'); if ($m.Success) { $ex = $m.Value; $nm = $nm.Substring(0, $m.Index) }
            if ($bad -eq '' -and $nm -cnotmatch '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$') { $bad = "套件 $nm 不是 PyPI 上的名字" }
            if ($ver -cnotmatch '^[0-9][0-9A-Za-z.!+]*$') { $ver = '' }
            if ($bin -eq '') { $bin = $nm }
        }
    } else { return }
    if ($pin -ne '' -and $bad -eq '' -and $ver -eq '' -and $argno) {
        $ver = $pin
        $j.a["$argno"] = $pre + $nm + $(if ($kind -eq 'pip') { $ex } else { '' }) + $(if ($kind -eq 'pip' -and $fno) { '==' } else { '@' }) + $ver
    }
    $pk = $nm + $(if ($kind -eq 'pip') { $ex } else { '' })
    Mr-Emit "P`t$kind`t$pk`t$ver`t$argno`t$bin`t$fi`t$bad"
}

# the yaml
function Mr-Yq([string]$v) {
    if ($v -cmatch '^[A-Za-z0-9_$./=+-][A-Za-z0-9_$./=+:{}@%~,-]*$' -and $v -cne '-' -and -not $v.EndsWith(':') -and $v.ToLowerInvariant() -cnotmatch '^(true|false|yes|no|on|off|null|none|y|n)$' -and $v -cnotmatch '^[-+.]?[0-9]') { return $v }
    if ($v -cnotmatch '["\\]') { return '"' + $v + '"' }
    if (-not $v.Contains("'")) { return "'" + $v + "'" }
    Mr-Fail 'bad_config' '有個值同時有 '' 和 " 或 \，kit 的 yaml 寫不下'; ''
}
function Mr-VList([string]$s) {
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($x in [regex]::Matches($s, '\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}')) {
        $r = $x.Value.Substring(2, $x.Length - 3)
        if ($r.Contains(':-')) { continue }
        if (-not $script:Mr.vseen.ContainsKey($r)) { $script:Mr.vseen[$r] = 1; Mr-Emit "V`t$r"; $l.Add($r) }
    }
    $l -join '、'
}
function Mr-Finish($j, [string]$mode, [string]$N, [string]$pin) {
    if ($j.cn -gt 0) {
        $A = Mr-New
        for ($i = 2; $i -le $j.cn; $i++) { $v = $j.ca["$i"]; $A["$($i - 1)"] = $(if ($null -eq $v) { '' } else { $v }) }
        for ($i = 1; $i -le $j.an; $i++) { $A["$($i + $j.cn - 1)"] = Mr-A $j $i }
        $j.a = $A; $j.an += $j.cn - 1; $v = $j.ca['1']; $j.f['command'] = $(if ($null -eq $v) { '' } else { $v })
    }
    $t = Mr-F $j 'type'
    if ($t -eq '') { $t = if ((Mr-F $j 'url') -ne '' -and (Mr-F $j 'command') -eq '') { 'http' } else { 'stdio' } }
    if ($mode -eq 'yaml') {
        Mr-Emit "T`t$t"
        foreach ($v in $j.ev) { Mr-UsedVars $v }; foreach ($v in $j.hv) { Mr-UsedVars $v }
        for ($i = 1; $i -le $j.an; $i++) { Mr-UsedVars (Mr-A $j $i) }
        Mr-UsedVars (Mr-F $j 'url')
        Mr-Strip $j; if ($t -eq 'stdio') { Mr-Pkg $j $pin }
        $vars = ''; foreach ($v in $j.ev) { $vars += " $v" }; foreach ($v in $j.hv) { $vars += " $v" }
        for ($i = 1; $i -le $j.an; $i++) { $vars += ' ' + (Mr-A $j $i) }
        [void](Mr-VList ($vars + ' ' + (Mr-F $j 'url') + ' ' + (Mr-F $j 'command')))
        return
    }
    if ($t -eq 'stdio') {
        if ((Mr-F $j 'command') -eq '') { Mr-Fail 'bad_config' '少了要跑的程式（command）'; return }
        if ((Mr-F $j 'url') -ne '') { Mr-Wn $j '有 command 也有 url：kit 只帶 command' }
        if ($j.hk.Count -gt 0) { Mr-Wn $j '要跑程式的 MCP 不用 headers，略過'; $j.hk.Clear(); $j.hv.Clear() }
    } else {
        if ((Mr-F $j 'url') -eq '') { Mr-Fail 'bad_config' '少了網址（url）'; return }
        if ((Mr-F $j 'command') -ne '') { Mr-Wn $j '有 url 也有 command：kit 只帶 url' }
        if ($j.ek.Count -gt 0) { Mr-Wn $j '網址的 MCP 不用 env，略過'; $j.ek.Clear(); $j.ev.Clear() }
        $j.an = 0; $j.f['command'] = ''
    }
    foreach ($v in $j.ev) { [void](Mr-Ctl $v); Mr-UsedVars $v }
    foreach ($v in $j.hv) { [void](Mr-Ctl $v); Mr-UsedVars $v }
    for ($i = 1; $i -le $j.an; $i++) { [void](Mr-Ctl (Mr-A $j $i)); Mr-UsedVars (Mr-A $j $i) }
    foreach ($k in 'url', 'command', 'description') { [void](Mr-Ctl (Mr-F $j $k)) }; Mr-UsedVars (Mr-F $j 'url')
    if ($script:Mr.errc) { return }
    Mr-Emit "N`t$N"; Mr-Emit "T`t$t"
    if ($t -eq 'stdio') { Mr-Pkg $j $pin }
    Mr-Strip $j
    $y = New-Object System.Text.StringBuilder
    if ((Mr-F $j 'description') -ne '') { [void]$y.Append('description: ' + (Mr-Yq (Mr-F $j 'description')) + "`n") }
    if ($t -ne 'stdio') {
        [void]$y.Append("type: $t`nurl: " + (Mr-Yq (Mr-F $j 'url')) + "`n")
        if ($j.hk.Count -gt 0) { [void]$y.Append("headers:`n"); for ($i = 0; $i -lt $j.hk.Count; $i++) { [void]$y.Append('  ' + $j.hk[$i] + ': ' + (Mr-Yq $j.hv[$i]) + "`n") } }
    } else {
        [void]$y.Append('command: ' + (Mr-Yq (Mr-F $j 'command')) + "`n")
        if ($j.an -eq 0) { [void]$y.Append("args: []`n") }
        else { [void]$y.Append("args:`n"); for ($i = 1; $i -le $j.an; $i++) { [void]$y.Append('  - ' + (Mr-Yq (Mr-A $j $i)) + "`n") } }
        if ($j.ek.Count -gt 0) { [void]$y.Append("env:`n"); for ($i = 0; $i -lt $j.ek.Count; $i++) { [void]$y.Append('  ' + $j.ek[$i] + ': ' + (Mr-Yq $j.ev[$i]) + "`n") } }
    }
    $nv = Mr-VList $y.ToString()
    $s = '# 用 kit new mcp --config 從貼上的設定建立。${名字} 是環境變數：值不放在這裡，每台電腦自己設定。' + "`n"
    if ($nv -ne '') { $s += "# 要先設定的環境變數：$nv`n" }
    foreach ($l in ($s + $y.ToString()).TrimEnd("`n").Split("`n")) { Mr-Emit "Y`t$l" }
    foreach ($w in $j.wl) { Mr-Emit "W`t$w" }
}
function Mcp-Read([string]$mode, $lines, [string]$name = '', [string]$pin = '') {
    $script:Mr = @{ si = (Mr-New); list = (New-Object System.Collections.Generic.List[object]); errc = ''; errm = ''; out = (New-Object System.Text.StringBuilder); used = (Mr-New); vseen = (Mr-New); rq = (Mr-New); sv = ''; s = ''; p = 0; vt = ''; vs = '' }
    $lines = @(foreach ($l in @($lines)) { ([string]$l) -replace "`r$", '' })
    switch ($mode) { 'json' { Mr-LoadJson $lines } 'cmd' { Mr-LoadCmd $lines } 'toml' { Mr-LoadToml $lines } 'yaml' { Mr-LoadYaml $lines $name } }
    $m = $script:Mr; $ns = $m.list.Count
    $lst = @(foreach ($j in $m.list) { "L`t$($j.name)" })
    if ($m.errc) { return @("E`t$($m.errc)`t$($m.errm)") }
    if ($ns -eq 0) { Mr-Fail 'bad_config' '貼上的內容裡找不到 MCP server 的設定' }
    $pick = $null
    if ($ns -gt 1) {
        if ($name -eq '') { return @("E`tseveral_servers`t貼上的設定有 $ns 個 MCP server，請在 kit new mcp 後面寫要哪一個的名字") + $lst }
        foreach ($j in $m.list) { if ($j.name -ceq $name -or (Mr-Norm $j.name) -ceq $name) { $pick = $j } }
        if (-not $pick) { return @("E`tnot_found`t貼上的設定裡沒有 $name") + $lst }
    } elseif ($ns -eq 1) { $pick = $m.list[0] }
    $N = $name; if ($N -eq '' -and $pick) { $N = Mr-Norm $pick.name }
    if ($N -eq '') { Mr-Fail 'no_name' '這個設定沒有名字：請寫成 kit new mcp <名字> --config …' }
    if ($N -cnotmatch '^[a-z0-9][a-z0-9-]*$') { Mr-Fail 'bad_name' "名字只能用小寫英文、數字和 -：$N" }
    if ($m.errc) { return @("E`t$($m.errc)`t$($m.errm)") }
    $m.sv = [regex]::Replace($N.ToUpperInvariant(), '[^A-Z0-9]+', '_')
    Mr-Finish $pick $mode $N $pin
    if ($m.errc) { return @("E`t$($m.errc)`t$($m.errm)") }
    $o = $m.out.ToString(); if ($o -eq '') { return @() }
    $o.TrimEnd("`n").Split("`n")
}
# ---------- MCP yaml -> what the tools read (the same as unix/kit: read its notes) ----------
function Mcp-Env($lines) { foreach ($l in $lines) { if ($l.StartsWith('env.')) { $t = $l.IndexOf("`t"); , @($l.Substring(4, $t - 4), $l.Substring($t + 1)) } } }   # pairs; callers wrap in @()
function Mcp-Map($lines, [string]$key) { $p = "$key."; foreach ($l in $lines) { if ($l.StartsWith($p)) { $t = $l.IndexOf("`t"); , @($l.Substring($p.Length, $t - $p.Length), $l.Substring($t + 1)) } } }
function Mcp-MapJson($lines, [string]$key) { # ,"KEY":{..} when the yaml has that map
    $m = @(Mcp-Map $lines $key); if ($m.Count -eq 0) { return '' }
    ",`"$key`":{" + ((@($m) | ForEach-Object { (Json-Str $_[0]) + ':' + (Json-Str $_[1]) }) -join ',') + '}'
}
function Mcp-Argv($y) { # command + args of an MCP yaml; on Windows a .cmd / .bat (npx, npm, pnpm, yarn ...) runs through cmd /c
    $cmd = @(YGet-From $y 'command'); if ($cmd.Count -eq 0 -or -not $cmd[0]) { return $null }
    Mcp-Shim (@([string]$cmd[0]) + @(YGet-From $y 'args'))
}
function Mcp-Shim($argv) {
    $c = [string]$argv[0]; $a = @(if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] })
    if ($script:OnWindows -and $c -notmatch '^(cmd|cmd\.exe)$' -and -not [IO.Path]::GetExtension($c)) {
        $shim = @('npx', 'npm', 'pnpm', 'pnpx', 'yarn', 'bunx') -contains $c.ToLowerInvariant()
        if (-not $shim) { $g = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($g -and $g.Path -match '\.(cmd|bat)$') { $shim = $true } }
        if ($shim) { return , (@('cmd', '/c', $c) + $a) }
    }
    , (@($c) + $a)
}
function Mcp-Name([string]$f) { [IO.Path]::GetFileNameWithoutExtension($f) }
function Mcp-Info([string]$f) { $y = @(); try { $y = @(Yaml-Lines $f) } catch { }; @(Mcp-Read 'yaml' $y (Mcp-Name $f)) }   # Mcp-Read's T X V R P lines
function Mcp-Lines($out, [string]$t) { @(foreach ($l in @($out)) { if ($l.StartsWith("$t`t")) { $l.Substring($t.Length + 1) } }) }
function Mcp-Type([string]$f) { $t = @(YGet $f 'type'); if ($t.Count -gt 0 -and $t[0]) { [string]$t[0] } else { 'stdio' } }
function Mcp-Store([string]$n) { Join-Path (Join-Path $KitConf 'mcp-deps') $n }
function Mcp-Pkg($info) { $p = @(Mcp-Lines $info 'P'); if ($p.Count -eq 0) { return $null }; , ($p[0].Split("`t")) }   # kind package version argno bin first bad
function Mcp-PkgJson([string]$n, [string]$pkg, [string]$ver) { "{`"name`": `"kit-mcp-$n`", `"private`": true, `"dependencies`": {$(Json-Str $pkg): $(Json-Str $ver)}}`n" }
function Venv-Bin([string]$venv, [string]$b) { if ($OnWindows) { Join-Path (Join-Path $venv 'Scripts') "$b.exe" } else { Join-Path (Join-Path $venv 'bin') $b } }
function Mcp-NpmBin([string]$d, [string]$want) { # the file its package.json "bin" names (WANT, or its own name, or the only one)
    $lv = Json-LeavesOf (Join-Path $d 'package.json'); if ($null -eq $lv) { return $null }
    $s = ''; $ks = @(); $vs = @(); $own = Split-Path -Leaf $d
    foreach ($x in $lv) { if ($x[0] -ceq 'bin' -and $x.Count -eq 2) { $s = $x[1] } elseif ($x[0] -ceq 'bin' -and $x.Count -eq 3) { $ks += $x[1]; $vs += $x[2] } }
    if ($s -eq '') {
        for ($i = 0; $i -lt $ks.Count; $i++) { if ($ks[$i] -ceq $want -or ($want -eq '' -and $ks[$i] -ceq $own)) { $s = $vs[$i] } }
        if ($s -eq '' -and $ks.Count -eq 1 -and $want -eq '') { $s = $vs[0] }
    }
    if ($s -cnotmatch '^"[^"\\]+"$') { return $null }
    $s = $s.Substring(1, $s.Length - 2) -replace '^\./', ''
    if ($s -cmatch '(^|/)\.\.(/|$)' -or $s.StartsWith('/')) { return $null }
    $p = Join-Path $d $s; if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { $null }
}
function Mcp-Installed([string]$n, $pk) { # the program to run, when kit installed exactly this package ($null: it did not)
    if (-not $pk -or -not $pk[2]) { return $null }
    $s = Mcp-Store $n; $src = Join-Path $s '.kit-src'
    if ($pk[0] -eq 'npm') {
        if (-not (Test-Path -LiteralPath (Join-Path $s 'node_modules') -PathType Container)) { return $null }
        $f = Join-Path $src 'package.json'; if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Read-Text $f) -cne (Mcp-PkgJson $n $pk[1] $pk[2])) { return $null }
        return (Mcp-NpmBin (Join-Path (Join-Path $s 'node_modules') $pk[1]) $pk[4])
    }
    if ($pk[0] -eq 'pip') {
        if (-not (Test-Path -LiteralPath (Venv-Python (Join-Path $s 'venv')) -PathType Leaf)) { return $null }
        $f = Join-Path $src 'requirements.txt'; if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Read-Text $f) -cne "$($pk[1])==$($pk[2])`n") { return $null }
        $b = Venv-Bin (Join-Path $s 'venv') $pk[4]; if (Test-Path -LiteralPath $b -PathType Leaf) { return $b }
    }
    $null
}
function Mcp-Run([string]$f, $y) { # command + args (the package kit installed, when it did); $null without a command
    $pk = Mcp-Pkg (Mcp-Info $f)
    $x = Mcp-Installed (Mcp-Name $f) $pk
    if ($x) {
        $a = @(YGet-From $y 'args'); $first = [int]$pk[5]
        $rest = @(for ($i = $first; $i -le $a.Count; $i++) { $a[$i - 1] })
        if ($pk[0] -eq 'npm') { return , (@('node', $x) + $rest) }
        return , (@($x) + $rest)
    }
    Mcp-Argv $y
}
function Mcp-Json([string]$f) { # {"command":..,"args":[..],"env":{..}} or {"type":"http","url":..,"headers":{..}} (Claude Code, omp)
    $y = Yaml-Lines $f; $t = Mcp-Type $f
    if ($t -eq 'http' -or $t -eq 'sse') {
        $u = @(YGet-From $y 'url'); if ($u.Count -eq 0 -or -not $u[0]) { Warn "$f has no url"; return $null }
        return "{`"type`":`"$t`",`"url`":$(Json-Str $u[0])$(Mcp-MapJson $y 'headers')}"
    }
    if ($t -ne 'stdio') { Warn "${f}：type 只能是 stdio、http 或 sse"; return $null }
    $argv = Mcp-Run $f $y
    if (-not $argv) { Warn "$f has no command"; return $null }
    $rest = @(if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] })
    '{"command":' + (Json-Str $argv[0]) + ',"args":[' + ((@($rest) | ForEach-Object { Json-Str $_ }) -join ',') + ']' + (Mcp-MapJson $y 'env') + '}'
}
function Mcp-VarsWarn($names) { # tell once about each ${VAR} the wanted MCP need that this machine has not set
    foreach ($n in @($names | Where-Object { $_ })) {
        $p = Find-Item 'mcp' $n; if (-not $p) { continue }
        foreach ($v in @(Mcp-Lines (Mcp-Info $p) 'V')) {
            if ([Environment]::GetEnvironmentVariable($v)) { if ($null -ne (State-Get 'told' "var:$v")) { State-Del 'told' "var:$v" } }
            elseif ($null -eq (State-Get 'told' "var:$v")) { Warn "MCP $n 要用環境變數 ${v}，這台電腦還沒設定：設定好再重開 agent（只提醒這一次）"; State-Set 'told' "var:$v" 1 }
        }
    }
}
function Toml-Key([string]$k) { if ($k -match '^[A-Za-z0-9_-]+$') { $k } else { Json-Str $k } }
function Toml-User([string]$cfg) { # FILE without kit's blocks (what the user wrote), as lines
    if (-not (Test-Path -LiteralPath $cfg)) { return @() }
    $in = $false
    @(foreach ($l in (Read-Text $cfg) -split "`n") { $l = $l.TrimEnd("`r"); if ($l -eq $TomlBegin -or $l -eq $TopBegin) { $in = $true }; if (-not $in) { $l }; if ($l -eq $TomlEnd -or $l -eq $TopEnd) { $in = $false } })
}
function Codex-Told([string]$k, [string]$msg) { if ($null -eq (State-Get 'told' "codex-mcp:$k")) { Warn "$msg（只提醒這一次）"; State-Set 'told' "codex-mcp:$k" 1 } }
function Codex-Mcp-Fields([string]$f, [string]$n, [scriptblock]$q, [scriptblock]$kq, [string]$eq, [string]$cm) { # Codex's fields: @(key, value) (env.K: its env); $null: Codex cannot use it
    # (the same as codex_mcp_fields in unix/kit; Q quotes a string, KQ a key; EQ and CM: " = " and ", " in config.toml)
    $y = Yaml-Lines $f; $t = Mcp-Type $f
    $out = New-Object System.Collections.Generic.List[object]
    $ob = if ($eq -eq ' = ') { '{ ' } else { '{' }; $cb = if ($eq -eq ' = ') { ' }' } else { '}' }
    if ($t -eq 'sse') { Codex-Told "${n}:sse" "Codex 不能用 SSE 的 MCP：$n 不放進 Codex（Claude Code 和 omp 照樣有）"; return $null }
    if ($t -eq 'http') {
        $u = @(YGet-From $y 'url'); if ($u.Count -eq 0 -or -not $u[0]) { Warn "$f has no url"; return $null }
        if ($u[0].Contains('${')) { Codex-Told "${n}:url" "Codex 的網址不能用 `${…}：$n 不放進 Codex"; return $null }
        $out.Add(@('url', (& $q $u[0])))
        $bear = ''; $lit = @(); $envh = @()
        foreach ($h in @(Mcp-Map $y 'headers')) {
            $k = $h[0]; $v = $h[1]
            if ($k.ToLowerInvariant() -eq 'authorization' -and $v -cmatch '^Bearer \$\{([A-Za-z_][A-Za-z0-9_]*)\}$') { $bear = $Matches[1] }
            elseif ($v -cmatch '^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$') { $envh += (& $kq $k) + $eq + (& $q $Matches[1]) }
            elseif ($v.Contains('${')) { Codex-Told "${n}:header:$k" "Codex 的 header 只能整個是 `${變數}：$n 的 $k 不放進 Codex" }
            else { $lit += (& $kq $k) + $eq + (& $q $v) }
        }
        if ($bear) { $out.Add(@('bearer_token_env_var', (& $q $bear))) }
        if ($lit.Count -gt 0) { $out.Add(@('http_headers', ($ob + ($lit -join $cm) + $cb))) }
        if ($envh.Count -gt 0) { $out.Add(@('env_http_headers', ($ob + ($envh -join $cm) + $cb))) }
        return , $out
    }
    if ($t -ne 'stdio') { Warn "${f}：type 只能是 stdio、http 或 sse"; return $null }
    $argv = Mcp-Run $f $y; if (-not $argv) { Warn "$f has no command"; return $null }
    $out.Add(@('command', (& $q $argv[0])))
    $rest = @(if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] })
    if ($rest.Count -gt 0) { $out.Add(@('args', ('[' + ((@($rest) | ForEach-Object { & $q $_ }) -join $cm) + ']'))) }
    if (@($rest | Where-Object { "$_".Contains('${') }).Count -gt 0) { Codex-Told "${n}:args" "Codex 不會展開參數裡的 `${…}：$n 的參數照字面放進 Codex" }
    $vars = @(); $envs = @()
    foreach ($e in @(Mcp-Map $y 'env')) {
        if ($e[1] -ceq ('${' + $e[0] + '}')) { $vars += (& $q $e[0]); continue }
        if ($e[1].Contains('${')) { Codex-Told "${n}:env:$($e[0])" "Codex 不會展開 env 裡的 `${…}：$n 的 $($e[0]) 照字面放進 Codex" }
        $envs += , @("env.$($e[0])", (& $q $e[1]))
    }
    if ($vars.Count -gt 0) { $out.Add(@('env_vars', ('[' + ($vars -join $cm) + ']'))) }
    foreach ($e in $envs) { $out.Add($e) }
    , $out
}
function Codex-Mcp-Toml($names, [string]$cfg = '') { # [mcp_servers.x] tables for Codex (CFG: whose config.toml to check for the user's own)
    if (-not $cfg) { $cfg = Join-Path $CodexDir 'config.toml' }
    $user = @(Toml-User $cfg)
    $deny = Required-Deny
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in @($names | Where-Object { $_ })) {
        $p = Find-Item 'mcp' $n; if (-not $p) { Warn "mcp $n not found in any source"; continue }
        $pat = '^\s*\[mcp_servers\."?' + [regex]::Escape($n) + '"?[\]. ]'
        if (@($user | Where-Object { $_ -match $pat }).Count -gt 0) { Warn "Codex 的 config.toml 已經有自己的 mcp_servers.${n}，kit 不動它"; continue }
        $fl = Codex-Mcp-Fields $p $n ${function:Json-Str} ${function:Toml-Key} ' = ' ', '
        if ($null -eq $fl) { continue }
        [void]$sb.Append("[mcp_servers.$(Toml-Key $n)]`n")
        $envs = @()
        foreach ($x in $fl) { if ($x[0].StartsWith('env.')) { $envs += , $x } else { [void]$sb.Append("$($x[0]) = $($x[1])`n") } }
        # team deny rules for this server's tools (mcp__<server>__<tool>) become disabled_tools
        $tools = @(foreach ($d in $deny) { if ($d.StartsWith("mcp__${n}__")) { Json-Str $d.Substring("mcp__${n}__".Length) } })
        if ($tools.Count -gt 0) { [void]$sb.Append('disabled_tools = [' + ($tools -join ', ') + "]`n") }
        if ($envs.Count -gt 0) {
            [void]$sb.Append("`n[mcp_servers.$(Toml-Key $n).env]`n")
            foreach ($e in $envs) { [void]$sb.Append("$(Toml-Key $e[0].Substring(4)) = $($e[1])`n") }
        }
        [void]$sb.Append("`n")
    }
    $sb.ToString()
}
function Mcp-ListJson([string]$f, [string]$n) { # ', "type": .., "vars": [..], "needs": [..], "packages": [..]' (the same as unix/kit)
    Tool-Cache
    $info = Mcp-Info $f; $t = @(Mcp-Lines $info 'T'); $t = if ($t.Count -gt 0 -and $t[0]) { $t[0] } else { 'stdio' }
    $vars = @(foreach ($v in @(Mcp-Lines $info 'V')) { "{`"name`": $(Json-S $v), `"set`": $(if ([Environment]::GetEnvironmentVariable($v)) { 'true' } else { 'false' })}" })
    $needs = New-Object System.Collections.Generic.List[object]; $seen = @{}
    foreach ($r in @(Mcp-Lines $info 'R')) { if (-not $seen.ContainsKey($r)) { $seen[$r] = 1; $needs.Add(@($r, '')) } }
    foreach ($r in @(YGet $f 'requires')) {
        $x = "$r".Split(@('>='), 2, [StringSplitOptions]::None); $nm = $x[0] -replace '[ \t]', ''; $mn = if ($x.Count -gt 1) { $x[1] -replace '[ \t]', '' } else { '' }
        if ($nm -cmatch '^[a-z0-9][a-z0-9-]*$' -and -not $seen.ContainsKey($nm)) { $seen[$nm] = 1; $needs.Add(@($nm, $mn)) }
    }
    $nj = @(foreach ($x in $needs) {
        $nm = $x[0]; $m = $x[1]; $c = $script:ToolCache[$nm]
        $h = if ($c) { $c.have } else { '' }; $tt = if ($c) { $c.title } else { $nm }
        $ok = [bool]$h -and (-not $m -or (Ver-Ge $h $m))
        $i = if ($ok -or -not $c) { '' } elseif ($h) { $c.upgrade } else { $c.install }
        "{`"tool`": $(Json-S $nm), `"title`": $(Json-S $tt), `"min`": $(Json-S $m), `"have`": $(Json-S $h), `"ok`": $(if ($ok) { 'true' } else { 'false' }), `"install`": $(Json-S $i)}"
    })
    $pj = ''
    $pk = Mcp-Pkg $info
    if ($pk) {
        $s = Mcp-Store $n
        $ok = if (Mcp-Installed $n $pk) { 'true' } else { 'false' }
        $had = if ((Test-Path -LiteralPath (Join-Path $s 'node_modules') -PathType Container) -or (Test-Path -LiteralPath (Join-Path $s 'venv') -PathType Container)) { 'true' } else { 'false' }
        $bad = $pk[6]; if (-not $bad -and -not $pk[2]) { $bad = "沒有固定版本：kit 只裝固定的版本（寫成 $($pk[1])@版本）" }
        if ($pk[0] -eq 'npm') { $c = if (Npm-Path) { 'npm install --ignore-scripts --omit=dev --no-audit --no-fund' } else { '' } }
        else {
            $vp = if ($OnWindows) { 'venv\Scripts\python.exe' } else { 'venv/bin/python' }; $pn = if ($OnWindows) { 'python' } else { 'python3' }
            $c = if (Py-Path) { "$pn -m venv venv; $vp $($PipArgs -join ' ')" } else { '' }
        }
        $pj = "{`"kind`": $(Json-S $pk[0]), `"package`": $(Json-S $pk[1]), `"version`": $(Json-S $pk[2]), `"ok`": $ok, `"had`": $had, `"install`": $(Json-S $c), `"bad`": $(Json-S $bad)}"
    }
    ", `"type`": $(Json-S $t), `"vars`": [$($vars -join ', ')], `"needs`": [$($nj -join ', ')], `"packages`": [$pj]"
}
function Mcp-Install([string]$n) { # kit install-deps mcp <name> : its npm or Python package, the pinned version, in kit's mcp-deps\<name>
    $p = Find-Item 'mcp' $n; if (-not $p) { Die "找不到 mcp ${n}（打 kit list 看有哪些）" }
    $pk = Mcp-Pkg (Mcp-Info $p)
    if (-not $pk) { Say "kit：mcp $n 不用另外裝套件"; return }
    if ($pk[6]) { Die "kit 不幫 mcp $n 裝套件：$($pk[6])（它照樣在啟動時下載）" }
    if (-not $pk[2]) { Die "mcp $n 的套件 $($pk[1]) 沒有固定版本：kit 只裝固定的版本（在 mcp/$n.yaml 寫成 $($pk[1])@版本）" }
    $s = Mcp-Store $n
    if (Mcp-Installed $n $pk) { Say "kit：mcp $n 的套件已經裝好了（$($pk[1]) $($pk[2])）" }
    else {
        $stage = New-TempDir 'kit-mcp.'
        try {
            if ($pk[0] -eq 'npm') { Write-Text (Join-Path $stage 'package.json') (Mcp-PkgJson $n $pk[1] $pk[2]); Install-Npm $stage $s }
            else { Write-Text (Join-Path $stage 'requirements.txt') "$($pk[1])==$($pk[2])`n"; Install-Pip $stage $s }
        } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        if ($env:KIT_DRY_RUN) { return }
        if (-not (Mcp-Installed $n $pk)) { Die "裝好了，但找不到 $($pk[1]) 要跑的程式（$(if ($pk[4]) { $pk[4] } else { 'package.json 的 bin' })）：照樣在啟動時下載" }
        Say "kit：mcp $n 的套件裝好了（$($pk[1]) $($pk[2])）"
    }
    if (-not (Test-Path -LiteralPath $Machine)) { return }
    Apply-Dirs; Apply-All
}
function Mcp-Latest([string]$kind, [string]$pkg, [string]$tmp) { # its newest version (npm view; PyPI's JSON API), '' when kit cannot tell
    $v = ''
    if ($kind -eq 'npm') {
        $npm = Npm-Path; if (-not $npm) { return '' }
        if ($OnWindows) { $o = Tool-Version $env:ComSpec ('/d /s /c ""' + $npm + '" view ' + $pkg + ' version"') 30000 $tmp } else { $o = Tool-Version $npm "view $pkg version" 30000 $tmp }
        foreach ($l in "$o" -split "`n") { $l = $l.Trim(); if ($l -cmatch '^[0-9][0-9A-Za-z.+!-]*$') { $v = $l } }
    } else {
        $u = if ($env:KIT_PYPI_URL) { $env:KIT_PYPI_URL } else { 'https://pypi.org/pypi' }; $u = $u.TrimEnd('/') + '/' + ($pkg -replace '\[.*$', '') + '/json'
        $h = Url-Host $u; $hosts = @(Allowed-Hosts)
        if ($hosts.Count -gt 0 -and $hosts -notcontains $h) { Warn "$h 不在 allowed_hosts：不查最新版本"; return '' }
        try {
            $f = Join-Path $tmp 'pypi.json'
            Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20 -OutFile $f -ErrorAction Stop
            $v = "$(Json-Get $f 'info.version')".Trim('"')
        } catch { return '' }
    }
    if ($v -cmatch '^[0-9][0-9A-Za-z.+!-]*$') { $v } else { '' }
}
function Mcp-PasteErr($out) { # Mcp-Read stopped (an E line): stop kit with its code (the servers' names too)
    $o = @($out); if ($o.Count -eq 0 -or -not $o[0].StartsWith("E`t")) { return }
    $x = $o[0].Split("`t", 3); $msg = $x[2]
    $names = @(Mcp-Lines $o 'L')
    if ($names.Count -gt 0) { $script:DieExtra = ', "servers": ' + (Json-Arr $names); $msg = "${msg}：" + ($names -join '、') }
    Die-C $x[1] $msg
}
function Mcp-NewConfig($o) { # kit new mcp [NAME] --config FILE|- [--to SOURCE] [--look] : a pasted setup -> mcp/<name>.yaml, secrets as ${VAR}
    if ($o.Name -and -not (Valid-Name $o.Name)) { Die-C bad_name "名字只能用小寫英文、數字和 -：$($o.Name)" }
    # the paste may hold secrets: it is read here, never written anywhere or printed
    if ($o.Config -eq '-') { $text = [Console]::In.ReadToEnd() }
    else { if (-not (Test-Path -LiteralPath $o.Config -PathType Leaf)) { Die-C usage "找不到 $($o.Config)" }; $text = Read-Text $o.Config }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = @($text -split "`n"); if ($text.EndsWith("`n")) { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    $c = ((@($lines | Where-Object { $_ -notmatch '^[ \t\r]*#' }) -join '') -replace '[ \t\r\n]', ''); $c = if ($c.Length -gt 0) { $c.Substring(0, 1) } else { '' }
    if ($c -eq '') { Die-C bad_config '貼上的內容是空的' }
    elseif ($c -eq '{') {
        $form = 'json'
        $lv = New-Object System.Collections.Generic.List[object]
        try { Json-Leaves (Json-Parse $text) @() $lv } catch { Die-C bad_config 'JSON 讀不懂（是不是少了括號、逗號或引號？）' }
        $in = @(foreach ($x in $lv) { $x -join "`t" })
    } elseif ($c -eq '[') { $form = 'toml'; $in = $lines } else { $form = 'cmd'; $in = $lines }
    $out = @(Mcp-Read $form $in $o.Name); Mcp-PasteErr $out
    $tmp = New-TempDir 'kit-mcp.'; $notes = ''
    try {
        $pk = Mcp-Pkg $out
        if ($pk -and $pk[1] -and -not $pk[2] -and -not $pk[6]) {
            $v = Mcp-Latest $pk[0] $pk[1] $tmp
            if ($v) { $out = @(Mcp-Read $form $in $o.Name $v); Mcp-PasteErr $out }
            else { $notes = "查不到 $($pk[1]) 的最新版本（沒網路，或沒有 $(if ($pk[0] -eq 'npm') { 'npm' } else { 'curl' })？）：先不固定版本，每次啟動時下載最新的" }
        }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $n = @(Mcp-Lines $out 'N')[0]; $t = @(Mcp-Lines $out 'T')[0]
    $dir = Target-Dir $o.To; $dst = Item-Path $dir 'mcp' $n
    $exists = Test-Path -LiteralPath $dst
    if (Test-Path -LiteralPath $Machine) { $f = Find-Item 'mcp' $n; if ($f) { $exists = $true; $dst = $f } }
    $yaml = (@(Mcp-Lines $out 'Y') -join "`n") + "`n"
    if ($o.Look) {
        $sec = @(foreach ($x in @(Mcp-Lines $out 'X')) { $p = $x.Split("`t"); "{`"where`": $(Json-S $p[0]), `"var`": $(Json-S $p[1])}" })
        $pks = @(foreach ($x in @(Mcp-Lines $out 'P')) { $p = $x.Split("`t"); "{`"kind`": $(Json-S $p[0]), `"package`": $(Json-S $p[1]), `"version`": $(Json-S $p[2]), `"bad`": $(Json-S $p[6])}" })
        $warn = @(Mcp-Lines $out 'W'); if ($notes) { $warn += $notes }
        Out-Json ("{`"name`": $(Json-S $n), `"source`": $(Json-S (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $dst)))), `"path`": $(Json-S $dst), `"exists`": $(if ($exists) { 'true' } else { 'false' }), `"type`": $(Json-S $t), `"yaml`": $(Json-S $yaml), " +
            "`"secrets`": [$($sec -join ', ')], `"vars`": $(Json-Arr (Mcp-Lines $out 'V')), `"requires`": $(Json-Arr (Mcp-Lines $out 'R')), `"packages`": [$($pks -join ', ')], `"warnings`": $(Json-Arr $warn)}")
        return
    }
    if ($exists) { Die-C exists "已經有 mcp:${n}（${dst}）：換個名字（kit new mcp 新名字 --config …），或先刪掉它" }
    Ensure-Dir (Split-Path -Parent $dst); Write-Text $dst $yaml
    Say "已建立 $(Rel-Path $dir $dst)（在 $(Split-Path -Leaf $dir)）"
    foreach ($x in @(Mcp-Lines $out 'X')) { $p = $x.Split("`t"); Say "  $($p[0]) 像是密碼或 token：檔案裡寫成 `${$($p[1])}（值沒有寫進去）" }
    $v = @(Mcp-Lines $out 'V'); if ($v.Count -gt 0) { Say "  每台電腦要先設定環境變數：$($v -join '、')" }
    foreach ($w in @(Mcp-Lines $out 'W')) { Warn $w }
    if ($notes) { Warn $notes }
    $pk = Mcp-Pkg $out
    if ($pk -and $pk[2] -and -not $pk[6]) { Say "  套件 $($pk[1]) 固定在 $($pk[2]) 版。先裝好（不然每次啟動時下載）：kit install-deps mcp $n" }
    Say "要用它：kit add mcp $n"
    $script:Quiet2 = $true
    if (-not (Check-Dirs @($dir) $false)) { Warn 'kit check 有問題，送出前請先打  kit check  看看' }
}

# ---------- write into Claude Code, Codex, omp ----------
function Has-Codex { (Test-Path -LiteralPath $CodexDir) -or (Has-Command 'codex') }
function Has-Omp { (Test-Path -LiteralPath $OmpDir) -or (Test-Path -LiteralPath (Join-Path $UserHome '.omp')) -or (Has-Command 'omp') }
function Targets { $t = 'Claude'; if (Has-Codex) { $t += '、Codex' }; if (Has-Omp) { $t += '、omp' }; $t }

function Replace-Block([string]$f, [string]$begin, [string]$end, [string]$body) { # put BODY between the markers, at the end of FILE
    $exists = Test-Path -LiteralPath $f
    if (-not $exists -and -not $body) { return $true }
    $orig = if ($exists) { Read-Text $f } else { '' }
    $nl = if ($orig.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]; $skip = $false
    if ($orig -ne '') {
        $parts = $orig -split "`n"; if ($orig.EndsWith("`n")) { $parts = $parts[0..($parts.Count - 2)] }
        foreach ($l in $parts) { $l = $l.TrimEnd("`r"); if ($l -eq $begin) { $skip = $true; continue }; if ($l -eq $end) { $skip = $false; continue }; if (-not $skip) { $lines.Add($l) } }
    }
    if ($skip) { Warn "$f 裡有 kit 的開始標記，但找不到結束標記（$end）：kit 不動這個檔案，請手動修好（刪掉開始那行，或補上結束那行）"; return $false }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $lines) { [void]$sb.Append($l).Append($nl) }
    if ($body) {
        if (-not $body.EndsWith("`n")) { $body += "`n" }
        if ($lines.Count -gt 0) { [void]$sb.Append($nl) }
        [void]$sb.Append($begin).Append($nl).Append($body.Replace("`r`n", "`n").Replace("`n", $nl)).Append($end).Append($nl)
    }
    $new = $sb.ToString()
    if ($exists -and $new -ceq $orig) { return $true }
    if ($new -eq '') { Remove-Item -LiteralPath $f -Force; return $true }   # nothing left: kit made it
    Ensure-Dir (Split-Path -Parent $f)
    $tmp = Temp-Next $f
    Write-Text $tmp $new
    if ($exists) { Swap-In $tmp $f $false } else { Move-Item -LiteralPath $tmp -Destination $f }
    $true
}
function Rules-Body($names, [string]$mode) { # text for the instructions file
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in @($names | Where-Object { $_ })) {
        $p = Find-Item 'rule' $n; if (-not $p) { Warn "rule $n not found in any source"; continue }
        if ($mode -eq 'import') { [void]$sb.Append('@' + $p.Replace('\', '/').Replace(' ', '\ ') + "`n") }
        else { $t = Read-Text $p; [void]$sb.Append("<!-- rule: $n -->`n").Append($t); if (-not $t.EndsWith("`n")) { [void]$sb.Append("`n") } }
    }
    $sb.ToString()
}
function Set-Rules([string]$f, $names, [string]$mode, [string]$more = '') { [void](Replace-Block $f $BeginMark $EndMark ((Rules-Body $names $mode) + $more)) }   # MORE: text after the rules
function Apply-Rules($want) { # the account's instructions (Claude, Codex, omp): the rules, and the python line when one of
    # the skills has kit's venv (a folder's own instructions never get it: kit only adds what it was asked to)
    $rules = Of-Kind $want 'rule'; $hint = Py-Hint (Of-Kind $want 'skill')
    Set-Rules (Join-Path $ClaudeDir 'CLAUDE.md') $rules 'import' $hint
    if (Has-Codex) { Set-Rules (Join-Path $CodexDir 'AGENTS.md') $rules 'inline' $hint }
    if (Has-Omp) { Set-Rules (Join-Path $OmpDir 'AGENTS.md') $rules 'inline' $hint }
}

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
        if ($h -eq $old -and (Test-Path -LiteralPath $dst)) { Link-Deps $n $dst; continue }
        if (Test-Path -LiteralPath $dst) { Drop-DepsLink $dst; Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse
        State-Set $kind $n $h; Say "  skill $n → $dir"
        Link-Deps $n $dst
    }
    foreach ($n in State-List $kind) {
        if ($names -contains $n) { continue }
        $dst = Join-Path $dir $n
        if (Test-Path -LiteralPath $dst) { Drop-DepsLink $dst; Remove-Item -LiteralPath $dst -Recurse -Force }
        State-Del $kind $n; Say "  removed skill $n ← $dir"
    }
}
function Sync-McpJson([string]$f, [string]$kind, $names) { # wanted MCP -> FILE's mcpServers
    # A server the user already has under that name (not kit's) is never replaced, so never removed either.
    # state.tsv changes only after FILE was written: if that fails, the next sync tries again.
    $names = @($names | Where-Object { $_ }); $ops = New-Object System.Collections.Generic.List[object]
    $sets = @(); $dels = @()
    foreach ($n in $names) {
        $p = Find-Item 'mcp' $n; if (-not $p) { Warn "mcp $n not found in any source"; continue }
        $k = Mcp-Json $p; if (-not $k) { continue }
        $sum = Text-Hash $k; $old = State-Get $kind $n
        if ($old -eq $sum) { continue }
        if (-not $old -and $null -ne (Json-Get $f "mcpServers.$n")) {
            if ($null -eq (State-Get 'skipped' "$f#mcp.$n")) { Warn "$f 已經有自己的 MCP ${n}，不是 kit 放的，kit 不動它（只提醒這一次）"; State-Set 'skipped' "$f#mcp.$n" 1 }
            continue
        }
        $ops.Add(@('set', "mcpServers.$n", $k)); $sets += , @($n, $sum); Say "  mcp $n → $f"
    }
    foreach ($n in State-List $kind) {
        if ($names -contains $n) { continue }
        $ops.Add(@('del', "mcpServers.$n")); $dels += $n; Say "  removed mcp $n ← $f"
    }
    if ($ops.Count -gt 0) {
        Json-Edit $f $ops.ToArray(); Prune-Empty $f @('mcpServers')
        foreach ($x in $sets) { State-Set $kind $x[0] $x[1]; if ($null -ne (State-Get 'skipped' "$f#mcp.$($x[0])")) { State-Del 'skipped' "$f#mcp.$($x[0])" } }
        foreach ($n in $dels) { State-Del $kind $n }
    }
}

function Hook-Json { # the SessionStart hook entry kit adds to settings.json
    $exe = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
    $cmd = "$exe -NoProfile -ExecutionPolicy Bypass -File `"$($PSCommandPath.Replace('\', '/'))`" sync --hook"
    '{"hooks":[{"type":"command","command":' + (Json-Str $cmd) + ',"timeout":10}]}'
}

function Statusline-Json { # the statusLine kit puts in settings.json
    $exe = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
    $cmd = "$exe -NoProfile -ExecutionPolicy Bypass -File `"$($PSCommandPath.Replace('\', '/'))`" statusline"
    '{"type":"command","command":' + (Json-Str $cmd) + ',"padding":0}'
}
function Flat-Json([string]$s) { if ($null -eq $s) { '' } else { $s -replace '[ \t\r\n]', '' } }

function Apply-All {
    $want = Wanted
    $rules = Of-Kind $want 'rule'; $skills = Of-Kind $want 'skill'; $mcps = Of-Kind $want 'mcp'

    # Claude: rules as @imports (Codex and omp: AGENTS.md gets the rule text itself), skills, MCP in ~/.claude.json
    Apply-Rules $want
    Sync-Skills (Join-Path $ClaudeDir 'skills') 'skill' $skills
    Sync-McpJson $ClaudeJson 'mcp' $mcps; Mcp-VarsWarn $mcps

    # Codex and omp share ~/.agents/skills
    $codex = Has-Codex; $omp = Has-Omp
    if ($codex -or $omp) { Sync-Skills $AgentsSkills 'skill.agents' $skills }
    if ($codex) {
        [void](Replace-Block (Join-Path $CodexDir 'config.toml') $TomlBegin $TomlEnd ((Codex-Mcp-Toml $mcps) + (Codex-Trust)).TrimEnd("`n"))
        [void](Replace-TopBlock (Join-Path $CodexDir 'config.toml') $TopBegin $TopEnd (Codex-Top))
    }
    if ($omp) {
        Sync-McpJson (Join-Path $OmpDir 'mcp.json') 'mcp.omp' $mcps
    }

    # tool deny rules and the auto-sync hook -> ~/.claude/settings.json
    # (state.tsv only after settings.json was written)
    $ops = New-Object System.Collections.Generic.List[object]
    $deny = Required-Deny; $add = @(); $del = @()
    foreach ($n in $deny) {
        if ($null -ne (State-Get 'deny' $n)) { continue }
        $ops.Add(@('addstr', 'permissions.deny', $n)); $add += $n; Say "  deny $n"
    }
    foreach ($n in State-List 'deny') {
        if ($deny -contains $n) { continue }
        $ops.Add(@('rmstr', 'permissions.deny', $n)); $del += $n; Say "  removed deny $n"
    }
    $hj = Hook-Json; $old = State-Get 'hook' 'SessionStart'
    if ($hj -ne $old) {
        if ($old) { $ops.Add(@('rmjson', 'hooks.SessionStart', $old)) }
        $ops.Add(@('addjson', 'hooks.SessionStart', $hj))
    }
    # Claude's status line: kit statusline keeps the numbers kit context shows (only when there is no status line of
    # your own; kit's is replaced when its command changes). Taken out by you: kit leaves it out (kit sync --force
    # puts it back).
    $sj = Statusline-Json; $sold = State-Get 'statusline' 'claude'; $snew = $false
    $sf = Join-Path $ClaudeDir 'settings.json'
    $scur = if (Test-Path -LiteralPath $sf) { Flat-Json (Json-Get $sf 'statusLine') } else { '' }
    if (-not $scur -and $sold -and -not $script:Force) {
        State-Del 'statusline' 'claude'; State-Set 'told' 'statusline-removed' 1
        Warn '你拿掉了 kit 放的 statusLine：kit 不會再加回來，畫面程式看 Claude 的 context 用量改從對話紀錄估（要加回來：kit sync --force）'
    } elseif (-not $scur -and $null -ne (State-Get 'told' 'statusline-removed') -and -not $script:Force) {
    } elseif (-not $scur -or ($sold -and $scur -eq (Flat-Json $sold))) {
        if (-not $scur -or $sj -ne $sold) { $ops.Add(@('set', 'statusLine', $sj)); $snew = $true }
    } elseif ($null -eq (State-Get 'told' 'statusline')) {
        Warn 'Claude 已經有自己的 statusLine：kit 不動它，畫面程式看 Claude 的 context 用量改從對話紀錄估（只提醒這一次）'; State-Set 'told' 'statusline' 1
    }
    if ($ops.Count -gt 0) {
        Json-Edit (Join-Path $ClaudeDir 'settings.json') $ops.ToArray(); Prune-Deny
        if ($snew) { State-Set 'statusline' 'claude' $sj; State-Del 'told' 'statusline-removed' }
        foreach ($n in $add) { State-Set 'deny' $n 1 }
        foreach ($n in $del) { State-Del 'deny' $n }
        if ($hj -ne $old) { State-Set 'hook' 'SessionStart' $hj }
    }
}

function Replace-TopBlock([string]$f, [string]$begin, [string]$end, [string]$body) { # Replace-Block, but at the top of FILE
    # TOML keys outside any table must come before the tables. Kit's block is followed by one empty line, which goes with it again.
    $exists = Test-Path -LiteralPath $f
    if (-not $exists -and -not $body) { return $true }
    $orig = if ($exists) { Read-Text $f } else { '' }
    $nl = if ($orig.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]; $skip = $false; $after = $false
    $endsNl = $true
    if ($orig -ne '') {
        $parts = $orig -split "`n"; if ($orig.EndsWith("`n")) { $parts = $parts[0..($parts.Count - 2)] } else { $endsNl = $false }
        foreach ($l in $parts) {
            $l = $l.TrimEnd("`r")
            if ($l -eq $begin) { $skip = $true; continue }
            if ($l -eq $end) { $skip = $false; $after = $true; continue }
            if ($after) { $after = $false; if ($l -eq '') { continue } }
            if (-not $skip) { $lines.Add($l) }
        }
    }
    if ($skip) { Warn "$f 裡有 kit 的開始標記，但找不到結束標記（$end）：kit 不動這個檔案，請手動修好"; return $false }
    $sb = New-Object System.Text.StringBuilder
    if ($body) {
        if (-not $body.EndsWith("`n")) { $body += "`n" }
        [void]$sb.Append($begin).Append($nl).Append($body.Replace("`r`n", "`n").Replace("`n", $nl)).Append($end).Append($nl)
        if ($lines.Count -gt 0) { [void]$sb.Append($nl) }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) { [void]$sb.Append($lines[$i]); if ($i -lt $lines.Count - 1 -or $endsNl) { [void]$sb.Append($nl) } }
    $new = $sb.ToString()
    if ($exists -and $new -ceq $orig) { return $true }
    if ($new -eq '') { Remove-Item -LiteralPath $f -Force; return $true }
    Ensure-Dir (Split-Path -Parent $f)
    $tmp = Temp-Next $f
    Write-Text $tmp $new
    if ($exists) { Swap-In $tmp $f $false } else { Move-Item -LiteralPath $tmp -Destination $f }
    $true
}

# ---------- a folder's own (kit add --dir) ----------
# Only agents started in that folder (or below it) get these; the account and other folders do not.
# The folder's .agentkit lists them; kit puts them where each tool looks in a project:
#   Claude: CLAUDE.md, .claude/skills, .mcp.json (+ .claude/settings.local.json so it does not ask each time)
#   Codex:  AGENTS.md, .agents/skills, .codex/config.toml (Codex reads it only in a trusted folder: kit trusts it)
#   omp:    reads Claude's and Codex's; its MCP only from the account (kit does not turn on omp's project MCP)
function Home-Real { if (Test-Path -LiteralPath $UserHome -PathType Container) { Real-Dir $UserHome } else { $UserHome } }
function Is-RootDir([string]$d) { $p = Split-Path -Parent $d; -not $p -or $p -eq $d }
function Dir-WhyNot([string]$d) { # why D cannot have its own ('' when it can)
    $h = Home-Real; $sep = [IO.Path]::DirectorySeparatorChar
    if ((Is-RootDir $d) -or $d -eq $h) { return '這是家目錄（或根目錄）：放在這裡等於整個帳號，請用「加到整個帳號」，或換一個資料夾' }
    if ($h.StartsWith($d.TrimEnd('\', '/') + $sep, [StringComparison]::OrdinalIgnoreCase)) { return '家目錄在這個資料夾裡面：放在這裡等於整個帳號，請換一個資料夾' }
    ''
}
function Dir-Root([string]$d) { # the folder kit uses for D: the nearest one at or above it with .agentkit, else D
    $d = Real-Dir $d; $h = Home-Real; $a = $d
    while ($a -and -not (Is-RootDir $a) -and $a -ne $h) {
        if (Test-Path -LiteralPath (Join-Path $a $DirFile) -PathType Leaf) { return $a }
        $a = Split-Path -Parent $a
    }
    $d
}
function Dir-Items([string]$d) {
    $f = Join-Path $d $DirFile
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @() }
    Uniq @(foreach ($l in (Read-Text $f) -split "`n") { $l = $l.TrimEnd("`r"); if ($l -match '^(rule|skill|mcp):[^ ]+$') { $l } })
}
function Dir-Kind([string]$d, [string]$k) { "dir:${d}:$k" }   # state.tsv kind for a folder's own (kit keeps it with the rest)
function Dirs-Registered { if (Test-Path -LiteralPath $DirsList) { Uniq @((Read-Text $DirsList) -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ }) } else { @() } }
function Dirs-Set([string]$d, [string]$how) { # the list of folders kit has to keep up to date
    $rows = @(Dirs-Registered | Where-Object { $_ -ne $d }); if ($how -eq 'add') { $rows += $d }
    if ($rows.Count -eq 0) { if (Test-Path -LiteralPath $DirsList) { Remove-Item -LiteralPath $DirsList -Force }; return }
    Ensure-Dir $KitConf; $t = Temp-Next $DirsList
    Write-Text $t (($rows | ForEach-Object { "$_`n" }) -join ''); Move-Item -LiteralPath $t -Destination $DirsList -Force
}
function Dir-Write([string]$d, $items) { # the folder's .agentkit (gone when nothing is left)
    $f = Join-Path $d $DirFile; $items = @($items | Where-Object { $_ })
    if ($items.Count -eq 0) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }; return }
    $t = "# kit：這個資料夾自己的規則、skill、MCP。只有在這裡（含子資料夾）開的 agent 會讀到，整個帳號和別的資料夾不受影響。`n"
    $t += "# 用  kit add --dir <資料夾> 種類 名字  /  kit rm --dir …  改。`n"
    Write-Text $f ($t + (($items | ForEach-Object { "$_`n" }) -join ''))
}
function Drop-Made([string]$f) { # a JSON file kit made that is empty again goes away
    if ($null -eq (State-Get 'made' $f)) { return }
    if ((Test-Path -LiteralPath $f) -and ((Read-Text $f) -replace '\s', '') -eq '{}') {
        Remove-Item -LiteralPath $f -Force
        if (Test-Path -LiteralPath "$f.kit-backup") { Remove-Item -LiteralPath "$f.kit-backup" -Force }
    }
    if (-not (Test-Path -LiteralPath $f)) { State-Del 'made' $f }
}
function Dir-ClaudeAllow([string]$dir, $names) { # MCP names -> .claude/settings.local.json enabledMcpjsonServers
    $f = Join-Path (Join-Path $dir '.claude') 'settings.local.json'
    $km = Dir-Kind $dir 'mcp'; $ka = Dir-Kind $dir 'allow'
    $names = @($names | Where-Object { $_ }); $ops = New-Object System.Collections.Generic.List[object]; $add = @(); $del = @()
    foreach ($n in $names) {
        if ($null -eq (State-Get $km $n)) { continue }       # only the servers kit put in .mcp.json
        if ($null -ne (State-Get $ka $n)) { continue }
        $ops.Add(@('addstr', 'enabledMcpjsonServers', $n)); $add += $n
    }
    foreach ($n in State-List $ka) {
        if ($names -contains $n -and $null -ne (State-Get $km $n)) { continue }
        $ops.Add(@('rmstr', 'enabledMcpjsonServers', $n)); $del += $n
    }
    if ($ops.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $f)) { State-Set 'made' $f 1 }
        Json-Edit $f $ops.ToArray(); Prune-Empty $f @('enabledMcpjsonServers')
        foreach ($n in $add) { State-Set $ka $n 1 }
        foreach ($n in $del) { State-Del $ka $n }
    }
    Drop-Made $f
}
function Apply-Dir([string]$dir) { # the folder's .agentkit -> the tools' files in it
    $want = @(Dir-Items $dir)
    $rules = Of-Kind $want 'rule'; $skills = Of-Kind $want 'skill'; $mcps = Of-Kind $want 'mcp'
    $mj = Join-Path $dir '.mcp.json'
    Set-Rules (Join-Path $dir 'CLAUDE.md') $rules 'import'
    Sync-Skills (Join-Path (Join-Path $dir '.claude') 'skills') (Dir-Kind $dir 'skill') $skills
    if (-not (Test-Path -LiteralPath $mj) -and @($mcps).Count -gt 0) { State-Set 'made' $mj 1 }
    Sync-McpJson $mj (Dir-Kind $dir 'mcp') $mcps; Mcp-VarsWarn $mcps
    Drop-Made $mj
    Dir-ClaudeAllow $dir $mcps
    # kit's backups of the user's own files go when kit has nothing left in them
    if (@(State-List (Dir-Kind $dir 'mcp')).Count -eq 0 -and (Test-Path -LiteralPath "$mj.kit-backup")) { Remove-Item -LiteralPath "$mj.kit-backup" -Force }
    $sl = Join-Path (Join-Path $dir '.claude') 'settings.local.json.kit-backup'
    if (@(State-List (Dir-Kind $dir 'allow')).Count -eq 0 -and (Test-Path -LiteralPath $sl)) { Remove-Item -LiteralPath $sl -Force }
    if ((Has-Codex) -or (Has-Omp) -or @(State-List (Dir-Kind $dir 'skill.agents')).Count -gt 0) {
        Set-Rules (Join-Path $dir 'AGENTS.md') $rules 'inline'
        Sync-Skills (Join-Path (Join-Path $dir '.agents') 'skills') (Dir-Kind $dir 'skill.agents') $skills
    }
    $ct = Join-Path (Join-Path $dir '.codex') 'config.toml'
    if ((Has-Codex) -or (Test-Path -LiteralPath $ct)) { [void](Replace-Block $ct $TomlBegin $TomlEnd (Codex-Mcp-Toml $mcps $ct).TrimEnd("`n")) }
    if (@($mcps).Count -gt 0 -and (Has-Omp) -and $null -eq (State-Get 'told' 'omp-mcp')) {
        Warn 'omp 只讀整個帳號的 MCP：資料夾自己的 MCP 只有 Claude Code 和 Codex 會用'; State-Set 'told' 'omp-mcp' 1
    }
    foreach ($x in @('.claude/skills', '.agents/skills', '.claude', '.agents', '.codex')) {
        $p = Join-Path $dir $x
        if ((Test-Path -LiteralPath $p -PathType Container) -and -not (Get-ChildItem -LiteralPath $p -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $p -Force }
    }
}
function Apply-Dirs { # kit sync: every folder with its own; a folder that is gone (or has no .agentkit any more) leaves the list
    foreach ($d in @(Dirs-Registered)) {
        if (Test-Path -LiteralPath $d -PathType Container) { Apply-Dir $d }
        if (@(Dir-Items $d).Count -eq 0) { Dirs-Set $d 'rm' }
    }
}
function Codex-Trust { # [projects."DIR"] trust for each folder with its own MCP (Codex reads a folder's config.toml only then)
    $user = @(Toml-User (Join-Path $CodexDir 'config.toml')); $out = ''
    foreach ($d in @(Dirs-Registered)) {
        if (-not (@(Dir-Items $d) | Where-Object { $_.StartsWith('mcp:') })) { continue }
        $head = "[projects.$(Json-Str $d)]"
        if (@($user | Where-Object { $_.Contains($head) }).Count -gt 0) { continue }
        $out += "$head`ntrust_level = `"trusted`"`n`n"
    }
    $out
}
function Codex-Top { # project_root_markers with .agentkit, so Codex started in a sub-folder still finds the folder's own
    if (@(Dirs-Registered).Count -eq 0) { return '' }
    if (@(Toml-User (Join-Path $CodexDir 'config.toml') | Where-Object { $_ -match '^\s*project_root_markers\s*=' }).Count -gt 0) {
        if ($null -eq (State-Get 'told' 'codex-markers')) { Warn 'Codex 的 config.toml 已經有自己的 project_root_markers：請自己加上 ".agentkit"，不然在子資料夾開 Codex 讀不到資料夾自己的'; State-Set 'told' 'codex-markers' 1 }
        return ''
    }
    "project_root_markers = [`".git`", `"$DirFile`"]`n"
}
function Dir-AddRm([string]$verb, [string]$dir, [string]$k, [string]$n) { # only that folder (and below it) gets it, or no longer
    $i = "${k}:$n"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Die "找不到資料夾 $dir" }
    $root = Dir-Root $dir
    $why = Dir-WhyNot $root; if ($why) { Die "${root}：$why" }
    $items = @(Dir-Items $root)
    if ($verb -eq 'add') {
        if (-not (Find-Item $k $n)) { Die "找不到 ${i}（打 kit list 看有哪些）" }
        if ($items -contains $i) { Say "kit：$root 已經有 $i"; return }
        $items += $i
    } else {
        if ($items -notcontains $i) { Die "$root 沒有加 ${i}（這個資料夾自己加的才拿得掉）" }
        $items = @($items | Where-Object { $_ -ne $i })
    }
    Dir-Write $root $items
    if ($items.Count -gt 0) { Dirs-Set $root 'add' } else { Dirs-Set $root 'rm' }
    Apply-Dir $root
    if (Has-Codex) { Apply-All }                              # Codex: the folder's trust and the root marker
    if ($verb -eq 'add') { Say "kit：$i 加到 ${root}（只有在這裡和子資料夾開的 agent 讀得到，開新的才會讀到）" }
    else { Say "kit：$i 從 $root 拿掉了" }
}

# ---------- the programs a skill needs (node, python, ...) and how to install them ----------
# A recipe is kit's own tools/<name>.yaml (node, python, git: a source cannot replace these) or tools/<name>.yaml in a
# source, for other programs. It names the program (bin) and, per system, "manager package" pairs; kit tries them in
# order, the ones this machine can use. The command itself is always kit's own: a recipe can only pick a manager kit
# knows (brew, apt as root, winget, scoop, pip) and a plain package name (no path, file, tap, URL or option).
# Only programs with a recipe are looked at (their --version run, at most 4 KB of it, for a few seconds).
function Tool-Os { if ($OnWindows) { 'windows' } elseif ((Test-Path variable:IsMacOS) -and $IsMacOS) { 'mac' } else { 'linux' } }
function Tool-OkName([string]$n) { $n -cmatch '^[a-z0-9][a-z0-9-]*$' }
function Bin-Ok([string]$b) { $b -cmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' }   # a program name, never a path
function Pkg-Ok([string]$m, [string]$p) { # a plain package name for that manager
    # (brew: no tap/formula path, so node@20 but not user/tap/node; scoop: name or main|extras|versions/name)
    if ($m -eq 'scoop' -and $p -cmatch '^(main|extras|versions)/') { $p = $p.Substring($p.IndexOf('/') + 1) }
    if ($m -eq 'brew') { return $p -cmatch '^[A-Za-z0-9][A-Za-z0-9@._+-]*$' }
    $p -cmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$'
}
$script:Clt = $null
function Clt-Stub([string]$p) { # a Mac without the Command Line Tools, where /usr/bin/git and python3 only open an install window
    if ((Tool-Os) -ne 'mac' -or ($p -cne '/usr/bin/git' -and $p -cne '/usr/bin/python3')) { return $false }
    if ($null -eq $script:Clt) { $script:Clt = $false; try { [void](& xcode-select -p 2>$null); $script:Clt = ($LASTEXITCODE -eq 0) } catch { } }
    -not $script:Clt
}
function Prog-Path([string]$name) { # the program NAME on PATH (not the Windows Store stub, not the Mac's install stub)
    $c = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' })
    if ($c.Count -eq 0 -or (Clt-Stub $c[0].Source)) { return $null }
    $c[0].Source
}
function Tool-File([string]$n) { # its recipe: kit's own first, else a source's tools/NAME.yaml
    if (-not (Tool-OkName $n)) { return $null }
    foreach ($d in @((Join-Path $KitLib 'tools'), (Join-Path (Split-Path -Parent $KitLib) 'tools'))) { $f = Join-Path $d "$n.yaml"; if (Test-Path -LiteralPath $f -PathType Leaf) { return $f } }
    if (Test-Path -LiteralPath $Machine) { foreach ($d in Src-Dirs) { $f = Join-Path (Join-Path $d 'tools') "$n.yaml"; if (Test-Path -LiteralPath $f -PathType Leaf) { return $f } } }
    $null
}
function Tool-Names { # every program kit has a recipe for
    $dirs = @(); if (Test-Path -LiteralPath $Machine) { $dirs += @(foreach ($d in Src-Dirs) { Join-Path $d 'tools' }) }
    $dirs += @((Join-Path $KitLib 'tools'), (Join-Path (Split-Path -Parent $KitLib) 'tools'))
    $all = @(foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        $names = [string[]]@(Get-ChildItem -LiteralPath $d -File -Filter '*.yaml' | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
        [Array]::Sort($names, [StringComparer]::Ordinal); $names
    })
    @(Uniq $all | Where-Object { Tool-OkName $_ })
}
function Tool-Title([string]$n) { $f = Tool-File $n; if ($f) { $t = @(YGet $f 'title'); if ($t.Count -gt 0 -and $t[0]) { return [string]$t[0] } }; $n }
function Tool-Version([string]$exe, [string]$argline = '--version', [int]$ms = 0, [string]$cwd = '') { # what EXE --version says: at most 4 KB, given up after KIT_PROBE_WAIT seconds
    # (ARGLINE, MS and CWD: another command line, how long to wait, the folder it runs in)
    if ($ms -le 0) { $ms = 5000; if ("$env:KIT_PROBE_WAIT" -match '^[0-9]+$') { $ms = 1000 * [int]$env:KIT_PROBE_WAIT } }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $argline; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    try { $p = [Diagnostics.Process]::Start($psi) } catch { return '' }
    try {
        $p.StandardInput.Close()
        $bo = New-Object char[] 4096; $be = New-Object char[] 4096
        $to = $p.StandardOutput.ReadBlockAsync($bo, 0, 4096); $te = $p.StandardError.ReadBlockAsync($be, 0, 4096)
        [void]$to.Wait($ms)
        if (-not $p.HasExited) { try { $p.Kill($true) } catch { try { $p.Kill() } catch { } } }   # it waits, or never stops talking (like yes); with what it started (PowerShell 7)
        [void]$to.Wait(1000); [void]$te.Wait(1000)
        $out = ''
        if ($to.IsCompleted -and -not $to.IsFaulted) { $out += [string]::new($bo, 0, $to.Result) }
        if ($te.IsCompleted -and -not $te.IsFaulted) { $out += [string]::new($be, 0, $te.Result) }
        $out
    } catch { '' } finally { $p.Dispose() }
}
function Tool-Have([string]$n) { # the version this machine has ('' when not there, or kit has no recipe for N)
    $f = Tool-File $n; if (-not $f) { return '' }
    $bins = @(YGet $f 'bin'); if ($bins.Count -eq 0) { $bins = @($n) }
    foreach ($b in $bins) {
        if (-not (Bin-Ok $b)) { continue }
        $p = Prog-Path $b; if (-not $p) { continue }
        $m = [regex]::Match((Tool-Version $p), '[0-9]+(\.[0-9]+)+'); if ($m.Success) { return $m.Value }
    }
    ''
}
function Ver-Ge([string]$a, [string]$b) { # A is B or newer (numbers compared part by part)
    $x = $a.Split('.'); $y = $b.Split('.'); $n = [Math]::Max($x.Count, $y.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $p = if ($i -lt $x.Count) { [long]("0" + ($x[$i] -replace '[^0-9]', '')) } else { 0 }; $q = if ($i -lt $y.Count) { [long]("0" + ($y[$i] -replace '[^0-9]', '')) } else { 0 }
        if ($p -gt $q) { return $true }; if ($p -lt $q) { return $false }
    }
    $true
}
function Tool-Picks([string]$n) { # @(manager, package) pairs: the ones in the recipe this machine can use, in order
    $f = Tool-File $n; if (-not $f) { return @() }
    @(foreach ($l in @(YGet $f "install.$(Tool-Os)")) {
        $w = @("$l".Trim() -split '\s+'); if ($w.Count -ne 2 -or -not (Pkg-Ok $w[0] $w[1])) { continue }
        $ok = switch ($w[0]) {
            { $_ -in 'brew', 'scoop', 'winget' } { Has-Command $w[0]; break }
            'apt' { (-not $OnWindows) -and (Has-Command 'apt-get') -and "$(& id -u 2>$null)".Trim() -eq '0'; break }
            'pip' { [bool](Py-Path); break }
            default { $false }
        }
        if ($ok) { , $w }
    })
}
function Tool-Argv([string]$mode, [string]$m, [string]$pkg) { # install|upgrade|machine: the command (kit's own, never the recipe's)
    # (machine: winget again without --scope user, for a package that only has an installer for the whole machine)
    $up = ($mode -eq 'upgrade')
    switch ($m) {
        'brew' { , @('brew', $(if ($up) { 'upgrade' } else { 'install' }), $pkg) }
        'apt' { , @('apt-get', 'install', '-y', $pkg) }                       # installs or upgrades
        'pip' { $py = if ($OnWindows) { 'python' } else { 'python3' }; , @(@($py, '-m', 'pip', 'install', '--user', '--only-binary=:all:') + @(if ($up) { '--upgrade' }) + @($pkg)) }   # wheels only: no setup.py runs
        'winget' {
            if ($up) { , @('winget', 'upgrade', '--id', $pkg, '-e', '--accept-source-agreements', '--accept-package-agreements') }
            elseif ($mode -eq 'machine') { , @('winget', 'install', '--id', $pkg, '-e', '--accept-source-agreements', '--accept-package-agreements') }
            else { , @('winget', 'install', '--id', $pkg, '-e', '--scope', 'user', '--accept-source-agreements', '--accept-package-agreements') }
        }
        'scoop' { , @('scoop', $(if ($up) { 'update' } else { 'install' }), $pkg) }
    }
}
function Tool-Cmd([string]$n, [string]$mode = 'install') { $mp = @(Tool-Picks $n); if ($mp.Count -eq 0) { return '' }; (Tool-Argv $mode $mp[0][0] $mp[0][1]) -join ' ' }
function Skill-Needs([string]$d, [string]$src = '') { # @(name, min) per program the skill needs (min may be '')
    # written: SKILL.md "requires: [node>=18, python]", or the source's kit.yaml "requires: {<skill>: [...]}"
    # seen: what SKILL.md tells the agent to run (node x.mjs, npx, python3 x.py, pip install ...), requirements.txt /
    # pyproject.toml; package.json's engines.node gives the lowest Node (files alone say nothing: often only for the author)
    # (the same order and the same line-by-line, case-sensitive look as unix/kit)
    $sk = Join-Path $d 'SKILL.md'; $raw = New-Object System.Collections.Generic.List[string]; $low = @{}
    $has = Test-Path -LiteralPath $sk -PathType Leaf
    if ($has) { try { foreach ($v in @(YGet-From (Yaml-Lines $sk -Frontmatter) 'requires')) { $raw.Add([string]$v) } } catch { } }
    if ($src) { foreach ($v in @(YGet (Join-Path $src 'kit.yaml') "requires.$(Split-Path -Leaf $d)")) { $raw.Add([string]$v) } }
    if ($has) {
        $node = $false; $py = $false
        foreach ($l in (Read-Text $sk) -split "`n") {
            if (-not $node -and $l -cmatch '(^|[^A-Za-z0-9_-])(node[ \t]+(-[A-Za-z-]+[ \t]+)*[./A-Za-z0-9_-]+\.(mjs|cjs|js)([^A-Za-z0-9]|$)|npx[ \t]+[A-Za-z@]|npm[ \t]+(run|install|ci|exec)([^A-Za-z]|$))') { $node = $true }
            if (-not $py -and $l -cmatch '(^|[^A-Za-z0-9_-])(python3?[ \t]+(-m[ \t]+[A-Za-z]|[./A-Za-z0-9_-]+\.py([^A-Za-z0-9]|$))|pip3?[ \t]+install|uv[ \t]+run)') { $py = $true }
        }
        if ($node) { $raw.Add('node') }; if ($py) { $raw.Add('python') }
    }
    $pj = Join-Path $d 'package.json'
    if (Test-Path -LiteralPath $pj -PathType Leaf) { $e = Json-Get $pj 'engines.node'; if ($e) { $m = [regex]::Match($e, '[0-9]+(\.[0-9]+)*'); if ($m.Success) { $low['node'] = $m.Value } } }
    if ((Test-Path -LiteralPath (Join-Path $d 'requirements.txt')) -or (Test-Path -LiteralPath (Join-Path $d 'pyproject.toml'))) { $raw.Add('python') }
    $ord = New-Object System.Collections.Generic.List[string]; $min = @{}
    foreach ($r in $raw) {
        $parts = $r -split '>=', 2; $n = ($parts[0] -replace '\s', ''); $m = if ($parts.Count -gt 1) { $parts[1] -replace '\s', '' } else { '' }
        if (-not (Tool-OkName $n)) { continue }
        if (-not $min.ContainsKey($n)) { $ord.Add($n); $min[$n] = '' }
        if ($m -match '^[0-9]+(\.[0-9]+)*$' -and (-not $min[$n] -or -not (Ver-Ge $min[$n] $m) -or $min[$n] -eq '')) { if (-not $min[$n] -or (Ver-Ge $m $min[$n])) { $min[$n] = $m } }
    }
    @(foreach ($n in $ord) { $m = $min[$n]; if ($low.ContainsKey($n) -and (-not $m -or ((Ver-Ge $low[$n] $m) -and $low[$n] -ne $m))) { $m = $low[$n] }; , @($n, $m) })
}
$script:ToolCache = $null
function Tool-Cache { # every program kit has a recipe for: its title, what this machine has, kit's install / upgrade commands (once a run)
    if ($null -ne $script:ToolCache) { return }
    $script:ToolCache = @{}
    foreach ($n in Tool-Names) {
        $mp = @(Tool-Picks $n); $c = @{ have = (Tool-Have $n); title = (Tool-Title $n); install = ''; upgrade = '' }
        if ($mp.Count -gt 0) { $c.install = (Tool-Argv 'install' $mp[0][0] $mp[0][1]) -join ' '; $c.upgrade = (Tool-Argv 'upgrade' $mp[0][0] $mp[0][1]) -join ' ' }
        $script:ToolCache[$n] = $c
    }
}
function Needs-Json([string]$d, [string]$src) { # [{"tool", "title", "min", "have", "ok", "install"}]
    Tool-Cache
    $parts = @(foreach ($x in @(Skill-Needs $d $src)) {
        $n = $x[0]; $m = $x[1]; $c = $script:ToolCache[$n]                  # no recipe: not looked at
        $h = if ($c) { $c.have } else { '' }; $t = if ($c) { $c.title } else { $n }
        $ok = [bool]$h -and (-not $m -or (Ver-Ge $h $m))
        $i = if ($ok -or -not $c) { '' } elseif ($h) { $c.upgrade } else { $c.install }
        "{`"tool`": $(Json-S $n), `"title`": $(Json-S $t), `"min`": $(Json-S $m), `"have`": $(Json-S $h), `"ok`": $(if ($ok) { 'true' } else { 'false' }), `"install`": $(Json-S $i)}"
    })
    '[' + ($parts -join ', ') + ']'
}
function Cmd-Tools($rest) { # kit tools : the programs kit knows how to install, what this machine has
    foreach ($n in Tool-Names) {
        $h = Tool-Have $n; $c = Tool-Cmd $n
        Say ('{0,-8} {1,-12} {2}' -f $n, $(if ($h) { $h } else { '（沒有）' }), $(if ($c) { $c } else { '（這台沒有可以用的安裝方式）' }))
    }
}
function Cmd-InstallTool($rest) { # kit install-tool <name> : install a program with kit's recipe (what the panel's 安裝 runs)
    $rest = @($rest); $n = ''; $min = ''; $mode = 'install'
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $a = [string]$rest[$i]
        if ($a -eq '--min') { if ($i + 1 -ge $rest.Count) { Die '--min 後面要接版本' }; $i++; $min = [string]$rest[$i]; if ($min -notmatch '^[0-9.]+$') { Die '--min 後面要接版本（像 18 或 3.10）' } }
        elseif ($a.StartsWith('-') -or $n) { Die '用法：kit install-tool <程式名> [--min 版本]' }
        else { $n = $a }
    }
    if (-not $n) { Die '用法：kit install-tool <程式名> [--min 版本]（打 kit tools 看有哪些）' }
    $f = Tool-File $n; if (-not $f) { Die "kit 不知道怎麼裝 ${n}（打 kit tools 看有哪些；要加就在來源倉放 tools/${n}.yaml）" }
    $h = Tool-Have $n
    if ($h) { if (-not $min -or (Ver-Ge $h $min)) { Say "kit：這台已經有 $(Tool-Title $n) $h"; return }; $mode = 'upgrade' }
    $picks = @(Tool-Picks $n); if ($picks.Count -eq 0) { Die "這台沒有可以用的安裝方式：請自己裝 $(Tool-Title $n)$(if ($min) { " $min 以上" })（$(Tool-Os) 的裝法寫在 $f）" }
    # each way in the recipe in turn, until one works
    $ok = $false; $last = ''
    foreach ($mp in $picks) {
        $tries = @(, [string[]](Tool-Argv $mode $mp[0] $mp[1]))
        if ($mp[0] -eq 'winget' -and $mode -eq 'install') { $tries += , [string[]](Tool-Argv 'machine' $mp[0] $mp[1]) }
        for ($t = 0; $t -lt $tries.Count; $t++) {
            $argv = $tries[$t]
            if ($t -eq 0) { Say "kit：執行 $($argv -join ' ')" } else { Say "kit：winget 沒有只裝給這個帳號的版本，改成一般安裝：$($argv -join ' ')" }
            if ($env:KIT_DRY_RUN) { return }
            $rest2 = @(if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] })
            $rc = 1; try { & $argv[0] @rest2; $rc = $LASTEXITCODE } catch { Warn $_.Exception.Message }
            if ($rc -eq 0) { $ok = $true; break }
        }
        if ($ok) { break }
        $last = $mp[0]; Warn "用 $($mp[0]) 裝失敗（上面是它說的原因）"
    }
    if (-not $ok) { Die "安裝失敗：$(Tool-Title $n) 的每一種裝法都沒有成功（最後是 ${last}）" }
    # a new program may be on a PATH this process has not seen yet: read the user's and the machine's again
    if ($OnWindows) { $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
    $h = Tool-Have $n
    if (-not $h) { Die "裝完了，但還是找不到 $(Tool-Title $n)：開一個新的終端機再試，或檢查 PATH" }
    if ($min -and -not (Ver-Ge $h $min)) { Die "裝完了，但 $(Tool-Title $n) 還是 ${h}，不到 ${min}：可能有別的舊版排在 PATH 前面" }
    Say "kit：$(Tool-Title $n) $h 裝好了"
}

# ---------- a skill's own packages (npm, pip) ----------
# The same as unix/kit: installed only when asked (kit install-deps, the panel's 安裝), in kit's own folders, never in
# the source. npm: $KitConf/deps/<skill>/node_modules, --ignore-scripts --omit=dev, without the skill's .npmrc;
# package.json may only ask for versions from the registry (no git, URL, file, link, workspace), and a lock must point
# every package at a registry tarball with its integrity. pip: $KitConf/pydeps/<skill>/venv, --only-binary=:all:
# (nothing is built, no setup.py runs), requirements.txt with only package names and versions. Each copy of the skill
# gets node_modules / .venv as a link (on Windows a junction: no admin needed); the account's instructions block tells
# agents to run the skill's .py with that .venv's python.
function Deps-Store([string]$n) { Join-Path (Join-Path $KitConf 'deps') $n }
function PyDeps-Store([string]$n) { Join-Path (Join-Path $KitConf 'pydeps') $n }
$script:PipArgs = @('-m', 'pip', 'install', '--only-binary=:all:', '--no-input', '--disable-pip-version-check', '-r', 'requirements.txt')
function Pkgs-Need([string]$d) { # it has npm packages to install (and does not bring them itself)
    $pj = Join-Path $d 'package.json'
    if (-not (Test-Path -LiteralPath $pj -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $d 'node_modules') -PathType Container)) { return $false }
    $v = $null; try { $v = Json-Get $pj 'dependencies' } catch { }
    if ($null -eq $v) { return $false }
    $v = $v -replace '\s', ''
    [bool]$v -and $v -ne '{}'
}
function PyPkgs-Need([string]$d) { # a requirements.txt naming something (and no .venv of its own)
    $rq = Join-Path $d 'requirements.txt'
    if (-not (Test-Path -LiteralPath $rq -PathType Leaf)) { return $false }
    $i = Get-Item -LiteralPath (Join-Path $d '.venv') -Force -ErrorAction SilentlyContinue
    if ($i -and -not $i.LinkType) { return $false }
    @((Read-Text $rq) -split "`n" | Where-Object { $_ -notmatch '^\s*(#.*)?$' }).Count -gt 0
}
function Py-ReqsBad([string]$f) { # the first line that is not a plain requirement (name[extras] versions ; markers)
    # markers only with marker characters, and no option anywhere (pip takes "--no-binary" and such on a line too)
    $v = '(===|==|>=|<=|~=|!=|<|>)[ \t]*[A-Za-z0-9.*+!_-]+'
    $re = '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?[ \t]*(\[[A-Za-z0-9._, -]*\])?[ \t]*(' + $v + '([ \t]*,[ \t]*' + $v + ')*)?[ \t]*(;[A-Za-z0-9_.<>=!~"() \t'']*)?\z'
    $ls = (Read-Text $f) -split "`n"; if ($ls.Count -gt 0 -and $ls[-1] -eq '') { $ls = @($ls[0..($ls.Count - 2)]) }
    for ($i = 0; $i -lt $ls.Count; $i++) {
        $l = $ls[$i].TrimEnd("`r") -replace '(^|[ \t])#.*$', ''; $l = $l.Trim(" `t")
        if ($l -eq '') { continue }
        if ($l -cmatch '(^|[ \t])-' -or $l -cnotmatch $re) { return "$($i + 1): $($ls[$i].TrimEnd("`r"))" }
    }
    ''
}
function Json-Leaves($n, [string[]]$path, $out) { # like json.awk -v leaves=1: @(keys..., raw text) per value, and per empty {} / []
    if ($n.t -eq 'v' -or $n.v.Count -eq 0) {
        $raw = if ($n.t -eq 'v') { $n.raw } elseif ($n.t -eq 'o') { '{}' } else { '[]' }
        if ($path.Count -eq 0) { $path = @('') }
        $out.Add([string[]]@($path + $raw)); return
    }
    for ($i = 0; $i -lt $n.v.Count; $i++) {
        $k = if ($n.t -eq 'o') { $n.k[$i].Substring(1, $n.k[$i].Length - 2) } else { [string]($i + 1) }
        Json-Leaves $n.v[$i] ([string[]]@($path + $k)) $out
    }
}
function Json-LeavesOf([string]$f) { # $null when the file is not JSON
    $out = New-Object System.Collections.Generic.List[object]
    try { Json-Leaves (Json-Parse (Read-Text $f)) @() $out } catch { return $null }
    , $out
}
function Npm-Registry { # the registry in your own ~/.npmrc (an https URL, ending in /), if you set one
    $f = Join-Path $UserHome '.npmrc'; $r = ''
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return '' }
    foreach ($l in (Read-Text $f) -split "`n") {
        $l = $l.TrimEnd("`r")
        if ($l -cmatch '^[ \t]*registry[ \t]*=') { $r = ($l -replace '^[^=]*=[ \t]*', '') -replace '[ \t]+$', '' }
    }
    if ($r -cnotmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?\z') { return '' }
    if (-not $r.EndsWith('/')) { $r += '/' }
    $r
}
function Npm-Unq([string]$v) { if ($v -cmatch '^".*"\z') { $v.Substring(1, $v.Length - 2) } else { $v } }
function Npm-SpecOk([string]$v) { # a version, range or dist-tag from the registry (an alias npm:name@version too)
    if ($v -cnotmatch '^".*"\z') { return $false }
    $s = Npm-Unq $v
    if ($s.StartsWith('npm:', [StringComparison]::Ordinal)) {
        $s = $s.Substring(4); $j = if ($s.Length -gt 1) { $s.IndexOf('@', 1) } else { -1 }
        if ($j -lt 0) { $nm = $s; $s = '' } else { $nm = $s.Substring(0, $j); $s = $s.Substring($j + 1) }
        if ($nm -cnotmatch '^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+\z' -or $nm -cmatch '^[._]') { return $false }
    }
    ($s -cmatch '^[A-Za-z0-9 .*^~<>=|+-]*\z') -and -not $s.StartsWith('.')
}
function Npm-TarballOk([string]$v, [string]$reg) {
    if ($v -cnotmatch '^".*"\z') { return $false }
    $s = Npm-Unq $v
    if ($s.StartsWith('https://registry.npmjs.org/', [StringComparison]::Ordinal)) { $s = $s.Substring(27) }
    elseif ($reg -and $s.StartsWith($reg, [StringComparison]::Ordinal)) { $s = $s.Substring($reg.Length) }
    else { return $false }
    ($s -cmatch '^[A-Za-z0-9@._~%+/-]+\.tgz\z') -and $s.Contains('/-/')
}
function Npm-Bad([string]$d) { # why kit does not install its npm packages (the first reason; '': fine), the same as unix/kit
    # dependencies, optionalDependencies, peerDependencies (npm 7+ installs them) and overrides: versions or dist-tags
    # from the registry only (an alias npm:name@version too); never git, github:, user/repo, a URL, file:, link:,
    # workspace: or a path
    $rows = Json-LeavesOf (Join-Path $d 'package.json')
    if ($null -eq $rows) { return 'package.json: 讀不懂' }
    foreach ($r in $rows) {
        $val = $r[-1]
        if (@('dependencies', 'optionalDependencies', 'peerDependencies') -ccontains $r[0] -and -not ($r.Count -eq 2 -and $val -cmatch '^(\{\}|\[\])\z')) {
            if ($r.Count -ne 3 -or -not (Npm-SpecOk $val)) { return "package.json: $($r[0]).$($r[1]) = $(Npm-Unq $val)" }
        }
        if ($r[0] -ceq 'overrides' -and $r.Count -ge 3 -and -not (Npm-SpecOk $val) -and (Npm-Unq $val) -cnotmatch '^\$[A-Za-z0-9@._/~-]+\z') {
            return "package.json: $($r[0..($r.Count - 2)] -join '.') = $(Npm-Unq $val)"
        }
    }
    $lock = Join-Path $d 'package-lock.json'
    if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return '' }
    $rows = Json-LeavesOf $lock
    if ($null -eq $rows) { return 'package-lock.json: 讀不懂' }
    # every package (lockfile v2/v3 "packages", or v1 "dependencies"): a tarball on registry.npmjs.org (or your
    # ~/.npmrc registry), with integrity; never a link; bundled ones come inside their parent's tarball
    $reg = Npm-Registry; $lab = @{}; $ord = New-Object System.Collections.Generic.List[string]; $f = @{}; $has = $false
    foreach ($r in $rows) {
        if ($r[0] -ceq 'packages' -and $r.Count -ge 3) {
            if ($r[1] -eq '') { continue }
            $p = "p`t$($r[1])"
            if (-not $lab.ContainsKey($p)) { $lab[$p] = $r[1]; $ord.Add($p) }
            if ($r.Count -eq 4) { $f["$p`t$($r[2])"] = $r[3] }
            $has = $true; continue
        }
        if ($r[0] -ceq 'dependencies' -and $r.Count -ge 4) {
            $l = "node_modules/$($r[1])"; $i = 2
            while ($i + 2 -lt $r.Count - 1 -and $r[$i] -ceq 'dependencies') { $l += "/node_modules/$($r[$i + 1])"; $i += 2 }
            $p = "v`t$l"
            if (-not $lab.ContainsKey($p)) { $lab[$p] = $l; $ord.Add($p) }
            if ($i -eq $r.Count - 2) { $f["$p`t$($r[$i])"] = $r[-1] }
        }
    }
    foreach ($p in $ord) {
        $v1 = $p.StartsWith('v')
        if ($has -eq $v1) { continue }                         # a lock with "packages": only those count
        $g = { param($k) $x = "$p`t$k"; if ($f.ContainsKey($x)) { [string]$f[$x] } else { '' } }
        if ((& $g 'link') -ceq 'true') { return "package-lock.json: $($lab[$p]): link" }
        if ((& $g $(if ($v1) { 'bundled' } else { 'inBundle' })) -ceq 'true') { continue }
        $rs = & $g 'resolved'
        if (-not (Npm-TarballOk $rs $reg)) { return "package-lock.json: $($lab[$p]): resolved $(if ($rs -eq '') { '（沒有）' } else { Npm-Unq $rs })" }
        if ((& $g 'integrity') -cnotmatch '^"sha[0-9]+-') { return "package-lock.json: $($lab[$p]): 沒有 integrity" }
    }
    ''
}
function Same-Bytes([string]$a, [string]$b) {
    if (-not (Test-Path -LiteralPath $a -PathType Leaf) -or -not (Test-Path -LiteralPath $b -PathType Leaf)) { return $false }
    $x = [IO.File]::ReadAllBytes($a); $y = [IO.File]::ReadAllBytes($b)
    if ($x.Length -ne $y.Length) { return $false }
    for ($i = 0; $i -lt $x.Length; $i++) { if ($x[$i] -ne $y[$i]) { return $false } }
    $true
}
function Deps-Fresh([string]$d, [string]$s) { # the store has this skill's npm packages, for this package.json (and lock)
    $src = Join-Path $s '.kit-src'
    if (-not (Test-Path -LiteralPath (Join-Path $s 'node_modules') -PathType Container)) { return $false }
    if (-not (Same-Bytes (Join-Path $d 'package.json') (Join-Path $src 'package.json'))) { return $false }
    $lock = Join-Path $d 'package-lock.json'
    if (Test-Path -LiteralPath $lock -PathType Leaf) { Same-Bytes $lock (Join-Path $src 'package-lock.json') }
    else { -not (Test-Path -LiteralPath (Join-Path $src 'package-lock.json')) }
}
function Venv-Python([string]$venv) { if ($OnWindows) { Join-Path (Join-Path $venv 'Scripts') 'python.exe' } else { Join-Path (Join-Path $venv 'bin') 'python' } }
function PyDeps-Fresh([string]$d, [string]$s) {
    (Test-Path -LiteralPath (Venv-Python (Join-Path $s 'venv')) -PathType Leaf) -and (Same-Bytes (Join-Path $d 'requirements.txt') (Join-Path (Join-Path $s '.kit-src') 'requirements.txt'))
}
function Pkgs-Cmd([string]$d) { # npm ci with a lock (the exact versions), else npm install
    $sub = if (Test-Path -LiteralPath (Join-Path $d 'package-lock.json') -PathType Leaf) { 'ci' } else { 'install' }
    [string[]]@('npm', $sub, '--ignore-scripts', '--omit=dev', '--no-audit', '--no-fund')
}
function Npm-Path { # on Windows npm.cmd (npm.ps1 may be blocked by the execution policy)
    $c = if ($OnWindows) { Get-Command 'npm.cmd' -CommandType Application -ErrorAction SilentlyContinue } else { Get-Command 'npm' -CommandType Application -ErrorAction SilentlyContinue }
    if ($c) { @($c)[0].Source } else { $null }
}
function Py-Path { # python3 (on Windows python.exe, not the Microsoft Store stub; on a Mac not the install stub)
    if (-not $OnWindows) { return (Prog-Path 'python3') }
    foreach ($c in @(Get-Command 'python.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) { if ($c.Source -notmatch 'WindowsApps') { return $c.Source } }
    $null
}
function Drop-DepsLink([string]$dst) { # take the links out of a skill copy first: removing the copy never goes into kit's store
    foreach ($x in 'node_modules', '.venv') {
        $l = Join-Path $dst $x
        $i = Get-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
        if ($i -and $i.LinkType) { [IO.Directory]::Delete($l) }
    }
}
function Link-One([string]$l, [string]$target) {
    $i = Get-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
    if ($i) { if (-not $i.LinkType) { return }; [IO.Directory]::Delete($l) }        # the skill brings its own
    $type = if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }
    try { New-Item -ItemType $type -Path $l -Target $target -ErrorAction Stop | Out-Null } catch { Warn "沒辦法連上套件 ${l}：$($_.Exception.Message)" }
}
function Link-Deps([string]$n, [string]$dst) { # the packages kit installed for skill N show in its copy DST
    $s = Deps-Store $n
    if ((Test-Path -LiteralPath (Join-Path $dst 'package.json') -PathType Leaf) -and (Deps-Fresh $dst $s)) { Link-One (Join-Path $dst 'node_modules') (Join-Path $s 'node_modules') }
    $s = PyDeps-Store $n
    if ((Test-Path -LiteralPath (Join-Path $dst 'requirements.txt') -PathType Leaf) -and (PyDeps-Fresh $dst $s)) { Link-One (Join-Path $dst '.venv') (Join-Path $s 'venv') }
}
function Py-Hint($skills) { # the line for the instructions block, when kit has a venv for one of these skills
    foreach ($n in @($skills)) {
        if (-not $n -or -not (Test-Path -LiteralPath (Join-Path (PyDeps-Store $n) 'venv') -PathType Container)) { continue }
        $p = Find-Item 'skill' $n; if (-not $p) { continue }
        $d = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath (Join-Path $d 'requirements.txt') -PathType Leaf) -or -not (PyDeps-Fresh $d (PyDeps-Store $n))) { continue }
        return '- skill 資料夾裡有 `.venv`（kit 裝的 Python 套件）時，執行那個 skill 的 Python 程式要用它自己的 python：`<skill 資料夾>/.venv/bin/python`（Windows：`<skill 資料夾>\.venv\Scripts\python.exe`），不要另外 pip install。' + "`n"
    }
    ''
}
function Packages-Json([string]$d, [string]$n) { # ', "packages": [...]' when the skill has packages to install
    $items = @()
    if (Pkgs-Need $d) {
        $s = Deps-Store $n
        $fresh = Deps-Fresh $d $s; $ok = if ($fresh) { 'true' } else { 'false' }
        $had = if (Test-Path -LiteralPath (Join-Path $s 'node_modules') -PathType Container) { 'true' } else { 'false' }
        $c = if (Npm-Path) { (Pkgs-Cmd $d) -join ' ' } else { '' }
        $bad = if ($fresh) { '' } else { Npm-Bad $d }               # (installed: it was looked at then)
        $items += '{"kind": "npm", "ok": ' + $ok + ', "had": ' + $had + ', "install": ' + (Json-S $c) + ', "bad": ' + (Json-S $bad) + '}'
    }
    if (PyPkgs-Need $d) {
        $s = PyDeps-Store $n
        $ok = if (PyDeps-Fresh $d $s) { 'true' } else { 'false' }
        $had = if (Test-Path -LiteralPath (Join-Path $s 'venv') -PathType Container) { 'true' } else { 'false' }
        $vp = if ($OnWindows) { 'venv\Scripts\python.exe' } else { 'venv/bin/python' }
        $pn = if ($OnWindows) { 'python' } else { 'python3' }
        $c = if (Py-Path) { "$pn -m venv venv; $vp $($PipArgs -join ' ')" } else { '' }
        $items += '{"kind": "pip", "ok": ' + $ok + ', "had": ' + $had + ', "install": ' + (Json-S $c) + ', "bad": ' + (Json-S (Py-ReqsBad (Join-Path $d 'requirements.txt'))) + '}'
    }
    if ($items.Count -eq 0) { return '' }
    ', "packages": [' + ($items -join ', ') + ']'
}
function Remove-Tree([string]$p) { # a folder and what is in it; links (junctions) in it are taken out first, never followed
    # (PowerShell 5.1's Remove-Item -Recurse goes into a junction and empties what it points at)
    if (-not (Test-Path -LiteralPath $p)) { return }
    $i = Get-Item -LiteralPath $p -Force
    if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { if ($i.PSIsContainer) { [IO.Directory]::Delete($p) } else { [IO.File]::Delete($p) }; return }
    $stack = New-Object System.Collections.Stack; $stack.Push($i.FullName)
    while ($stack.Count -gt 0) {
        foreach ($e in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -Directory -ErrorAction SilentlyContinue)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($e.FullName) } else { $stack.Push($e.FullName) }
        }
    }
    Remove-Item -LiteralPath $p -Recurse -Force
}
function Remove-Store([string]$p) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }   # kit's own: no links in it
function Install-Npm([string]$d, [string]$s) {
    $bad = Npm-Bad $d
    if ($bad) { Die "kit 不裝這些 npm 套件（只能裝 npm registry 上的版本，不能是 git、網址、檔案或連結）：$bad" }
    $npm = Npm-Path; if (-not $npm) { Die '要先有 Node.js（npm）：Kit 清單上按 Node.js 的「安裝」，或打 kit install-tool node' }
    $argv = Pkgs-Cmd $d
    Say "kit：在 $s 執行 $($argv -join ' ')（不跑套件自己的安裝程式）"
    if ($env:KIT_DRY_RUN) { return }
    # built in a folder of its own next to the store (gone again when npm fails or kit is stopped), then swapped in
    $new = "$s.new." + [IO.Path]::GetRandomFileName().Replace('.', '')
    $done = $false
    try {
        Ensure-Dir (Join-Path $new '.kit-src')
        $files = @('package.json', 'package-lock.json') | Where-Object { Test-Path -LiteralPath (Join-Path $d $_) -PathType Leaf }
        foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $d $f) -Destination (Join-Path $new $f) }
        $a = @($argv[1..($argv.Count - 1)])
        Push-Location -LiteralPath $new
        try { & $npm @a; $rc = $LASTEXITCODE } finally { Pop-Location }
        if ($rc -ne 0) { Die '裝套件失敗（上面是 npm 說的原因）' }
        foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $d $f) -Destination (Join-Path (Join-Path $new '.kit-src') $f) }
        Remove-Store $s
        Move-Item -LiteralPath $new -Destination $s
        $done = $true
    } finally {
        # .NET calls only (no command, function or loop): a Ctrl-C that comes while this runs stops PowerShell at the next one
        # (a terminal's Ctrl-C goes to npm too, and npm ending can bring kit here first). It never follows a link.
        if (-not $done) { try { if ([IO.Directory]::Exists($new)) { [IO.Directory]::Delete($new, $true) } } catch { } }
    }
}
function Pip-Back([string]$s) { # a pip install that did not finish: the venv kit had before goes back in its place
    Remove-Store $s
    if (Test-Path -LiteralPath "$s.old") { Move-Item -LiteralPath "$s.old" -Destination $s }
}
function Install-Pip([string]$d, [string]$s) {
    $bad = Py-ReqsBad (Join-Path $d 'requirements.txt')
    if ($bad) { Die "requirements.txt 有 kit 不接受的寫法（只能寫套件名和版本）：第 $bad" }
    $py = Py-Path; if (-not $py) { Die '要先有 Python：Kit 清單上按 Python 的「安裝」，或打 kit install-tool python' }
    Say "kit：在 $s 執行 python -m venv venv，再用它的 python $($PipArgs -join ' ')（只裝現成的 wheel，不跑套件的安裝程式）"
    if ($env:KIT_DRY_RUN) { return }
    # a venv remembers its own path (its launchers start with it): built where it stays, the old one kept until it works;
    # failing or stopped (Ctrl-C), the old one goes back. An .old left over: that install never finished.
    $old = "$s.old"
    if (Test-Path -LiteralPath $old) { Pip-Back $s }
    if (Test-Path -LiteralPath $s) { Move-Item -LiteralPath $s -Destination $old }
    $done = $false
    try {
        Ensure-Dir (Join-Path $s '.kit-src')
        Copy-Item -LiteralPath (Join-Path $d 'requirements.txt') -Destination (Join-Path $s 'requirements.txt')
        Push-Location -LiteralPath $s
        try {
            & $py -m venv venv; $rc = $LASTEXITCODE
            if ($rc -eq 0) { $vpy = Venv-Python (Join-Path $s 'venv'); & $vpy @PipArgs; $rc2 = $LASTEXITCODE } else { $rc2 = 1 }
        } finally { Pop-Location }
        if ($rc -ne 0) { Die '沒辦法建立 Python 的 venv（上面是原因）' }
        if ($rc2 -ne 0) { Die '裝套件失敗（上面是 pip 說的原因；只能裝有現成 wheel 的套件）' }
        Copy-Item -LiteralPath (Join-Path $d 'requirements.txt') -Destination (Join-Path (Join-Path $s '.kit-src') 'requirements.txt')
        $done = $true
    } finally {
        if ($done) { Remove-Store $old }
        else { # .NET calls only, as in Install-Npm: a Ctrl-C that comes while this runs must not leave the old venv aside
            try { if ([IO.Directory]::Exists($s)) { [IO.Directory]::Delete($s, $true) } } catch { }
            try { if ([IO.Directory]::Exists($old)) { [IO.Directory]::Move($old, $s) } } catch { }
        }
    }
}
function Link-Copies([string]$n) { # every copy of skill N kit put (the account, Codex and omp, each folder's own) gets the links
    if ($null -ne (State-Get 'skill' $n)) { Link-Deps $n (Join-Path (Join-Path $ClaudeDir 'skills') $n) }
    if ($null -ne (State-Get 'skill.agents' $n)) { Link-Deps $n (Join-Path $AgentsSkills $n) }
    foreach ($d in @(Dirs-Registered)) {
        if ($null -ne (State-Get (Dir-Kind $d 'skill') $n)) { Link-Deps $n (Join-Path (Join-Path (Join-Path $d '.claude') 'skills') $n) }
        if ($null -ne (State-Get (Dir-Kind $d 'skill.agents') $n)) { Link-Deps $n (Join-Path (Join-Path (Join-Path $d '.agents') 'skills') $n) }
    }
}
function Cmd-InstallDeps($rest) { # kit install-deps <skill> [npm|pip] : the skill's own packages, in kit's folders, no package scripts
    # (it holds kit's lock the whole time: one install at a time, and no sync in between)
    $use = '用法：kit install-deps <skill 名字> [npm|pip]'
    $rest = @($rest | Where-Object { $null -ne $_ })
    if ($rest.Count -eq 2 -and $rest[0] -eq 'mcp' -and $rest[1] -ne 'npm' -and $rest[1] -ne 'pip') { Mcp-Install ([string]$rest[1]); return }
    if ($rest.Count -ge 2 -and $rest[0] -eq 'skill') { $rest = @($rest[1..($rest.Count - 1)]) }
    $n = ''; $only = ''
    foreach ($a in @($rest)) {
        $a = [string]$a
        if ($a -eq 'npm' -or $a -eq 'pip') { if ($only -or -not $n) { Die $use }; $only = $a }
        elseif (-not $a -or $a.StartsWith('-') -or $n) { Die $use }
        else { $n = $a }
    }
    if (-not $n) { Die $use }
    $p = Find-Item 'skill' $n; if (-not $p) { Die "找不到 skill ${n}（打 kit list 看有哪些）" }
    $d = Split-Path -Parent $p; $did = $false
    if ($only -ne 'pip' -and (Pkgs-Need $d)) {
        $did = $true
        if (Deps-Fresh $d (Deps-Store $n)) { Say "kit：$n 的 npm 套件已經裝好了" }
        else { Install-Npm $d (Deps-Store $n); if (-not $env:KIT_DRY_RUN) { Say "kit：$n 的 npm 套件裝好了" } }
    }
    if ($only -ne 'npm' -and (PyPkgs-Need $d)) {
        $did = $true
        if (PyDeps-Fresh $d (PyDeps-Store $n)) { Say "kit：$n 的 Python 套件已經裝好了" }
        else { Install-Pip $d (PyDeps-Store $n); if (-not $env:KIT_DRY_RUN) { Say "kit：$n 的 Python 套件裝好了" } }
    }
    if (-not $did) { Say "kit：$n 不用另外裝套件"; return }
    if ($env:KIT_DRY_RUN) { return }
    # every copy kit put gets the links, and the account's instructions the python line
    if (-not (Test-Path -LiteralPath $Machine)) { return }
    Link-Copies $n
    Apply-Rules (Wanted)
}

# ---------- how full an agent's context is (kit context; kit statusline keeps Claude's) ----------
# The same as unix/kit. On Windows a process's folder and terminal can't be read: the panel passes --dir.
$script:CtxDir = Join-Path $KitConf 'ctx'
function Num-Of([string]$k, [string]$t) { $m = [regex]::Match($t, '"' + [regex]::Escape($k) + '"\s*:\s*([0-9]+)(\.[0-9]+)?'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
function Str-Of([string]$k, [string]$t) { $m = [regex]::Match($t, '"' + [regex]::Escape($k) + '"\s*:\s*"([^"]*)"'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
function After-Key([string]$k, [string]$t) { # the text after the last "KEY":
    $m = [regex]::Match($t, '"' + [regex]::Escape($k) + '"\s*:\s*', [Text.RegularExpressions.RegexOptions]::RightToLeft)
    if ($m.Success) { $t.Substring($m.Index + $m.Length) } else { $t }
}
function Sum-Of($t, [string[]]$keys) { $n = [long]0; foreach ($k in $keys) { $v = Num-Of $k $t; if ($v) { $n += [long]$v } }; $n }
function Setting-Window([string]$m) { # the window Claude Code is told to use for a model (autoCompactWindow: modelSettings.<model>,
    # else the top-level one), as its own /context shows it; '' when not set
    $sf = Join-Path $ClaudeDir 'settings.json'
    if (-not (Test-Path -LiteralPath $sf -PathType Leaf)) { return '' }
    $b = $m -creplace '\[1m\]$', ''; $w = ''
    try { $w = "$(Json-Get $sf "modelSettings.$b.autoCompactWindow")".Replace('"', '').Replace(' ', '') } catch { }
    if (-not $w) { try { $w = "$(Json-Get $sf 'autoCompactWindow')".Replace('"', '').Replace(' ', '') } catch { } }
    if ($w -cmatch '^[0-9]+\z') { $w } else { '' }
}
function Model-Window([string]$m) { # the context window Claude Code uses for a model: a setting (autoCompactWindow), else the model's own
    $w = Setting-Window $m
    if ($w) { return $w }
    if ($m -match '\[1m\]$|opus-5|opus-4-7|opus-4-8|sonnet-5|fable|mythos|haiku-5') { return '1000000' }
    if ($m -match '^(claude-|anthropic/)') { return '200000' }
    ''
}
function Proc-Args([int]$p) { # a process's command line ('' if gone)
    if ($OnWindows) { $c = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue; if ($c) { return [string]$c.CommandLine }; return '' }
    "$(& ps -o args= -p $p 2>$null)".Trim()
}
function Proc-Cwd([int]$p) {
    if ($OnWindows) { return '' }
    if (Test-Path -LiteralPath "/proc/$p") { return "$(& readlink "/proc/$p/cwd" 2>$null)" }
    if (Get-Command lsof -ErrorAction SilentlyContinue) { foreach ($l in @(& lsof -a -p $p -d cwd -Fn 2>$null)) { if ($l.StartsWith('n')) { return $l.Substring(1) } } }
    ''
}
function Claude-Pid { # the Claude process above this one (Claude runs the status line through a shell): one look at every process
    $up = @{}; $cl = @{}
    if ($OnWindows) {
        foreach ($c in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CommandLine -ErrorAction SilentlyContinue)) { $up[[int]$c.ProcessId] = [int]$c.ParentProcessId; $cl[[int]$c.ProcessId] = [string]$c.CommandLine }
    } else {
        foreach ($l in @(& ps -A -o pid= -o ppid= -o args= 2>$null)) {
            $w = "$l".Trim() -split '\s+', 3
            if ($w.Count -ge 2 -and $w[0] -match '^[0-9]+$' -and $w[1] -match '^[0-9]+$') { $up[[int]$w[0]] = [int]$w[1]; $cl[[int]$w[0]] = $(if ($w.Count -gt 2) { $w[2] } else { '' }) }
        }
    }
    if (-not $up.ContainsKey($PID)) { return $null }
    $p = $up[$PID]
    for ($n = 0; $n -lt 8 -and $p -gt 1 -and $up.ContainsKey($p); $n++) {
        $w = @(@($cl[$p].Trim() -split '\s+')[0..1] | Where-Object { $null -ne $_ } | ForEach-Object { ($_.Trim('"') -split '[\\/]')[-1] })
        if ($w.Count -gt 0 -and $w[0] -match '^claude(\.exe)?$' -or ($w.Count -gt 1 -and $w[1] -match '^(claude|claude\.js|cli\.js)$')) { return $p }
        $p = $up[$p]
    }
    $null
}
function Ctx-Json([string]$tool, [string]$u, [string]$w, [string]$src, [string]$m, [string]$own = '') { # OWN: the tool's own way of counting
    $pct = 'null'
    if ($u -and $w -and [long]$w -gt 0) { $pct = Ctx-Pct $u $w }
    if ($own) { $pct = $own }
    if ($pct -ne 'null' -and [long]$pct -gt 100) { $pct = '100' }      # an estimate past the window: full
    '{"tool": ' + (Json-S $tool) + ', "used": ' + $(if ($u) { $u } else { 'null' }) + ', "window": ' + $(if ($w) { $w } else { 'null' }) + ', "pct": ' + $pct + ', "source": ' + (Json-S $src) + ', "model": ' + (Json-S $m) + '}'
}
function Ctx-Pct([string]$u, [string]$w) { [string][long][Math]::Floor(([double][long]$u * 100 + [Math]::Floor([long]$w / 2)) / [long]$w) }   # (u * 100 + w / 2) / w in whole numbers
function Cmd-Statusline { # what Claude's statusLine runs: keep the numbers for kit context, print a short status line
    # (the window set in settings.json, autoCompactWindow, only when settings.json has one)
    $j = [Console]::In.ReadToEnd()
    $w = Num-Of 'context_window_size' $j
    $pm = [regex]::Match($j, '"used_percentage"\s*:\s*([0-9]+(\.[0-9]+)?)'); $pct = if ($pm.Success) { [string][long][Math]::Floor([double]::Parse($pm.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) + 0.5) } else { '' }
    $u = ''
    if ($j -match '"current_usage"\s*:\s*\{') { $u = [string](Sum-Of (After-Key 'current_usage' $j) @('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')) }
    $sid = Str-Of 'session_id' $j; $model = Str-Of 'id' (After-Key 'model' $j); $name = Str-Of 'display_name' $j
    $tp = Str-Of 'transcript_path' $j; $cwd = Str-Of 'project_dir' $j; if (-not $cwd) { $cwd = Str-Of 'cwd' $j }
    $cp = Claude-Pid
    if ($cp) {
        try {
            Ensure-Dir $CtxDir
            # the paths as Claude wrote them (already JSON text)
            $line = '{"pid": ' + $cp + ', "session": ' + (Json-S $sid) + ', "used": ' + $(if ($u) { $u } else { 'null' }) + ', "window": ' + $(if ($w) { $w } else { 'null' }) + ', "pct": ' + $(if ($pct) { $pct } else { 'null' }) + ', "model": ' + (Json-S $model) + ', "transcript": "' + $tp + '", "cwd": "' + $cwd + "`"}`n"
            $tmp = Join-Path $CtxDir ".claude-$cp.$PID"; [IO.File]::WriteAllText($tmp, $line, (New-Object Text.UTF8Encoding $false))
            Move-Item -LiteralPath $tmp -Destination (Join-Path $CtxDir "claude-$cp.json") -Force
        } catch { }
    }
    $sf = Join-Path $ClaudeDir 'settings.json'; $st = ''
    if (Test-Path -LiteralPath $sf -PathType Leaf) { try { $st = Read-Text $sf } catch { } }
    if ($st.Contains('autoCompactWindow')) { $sw = Setting-Window $model; if ($sw -and $sw -cne $w -and $u) { $w = $sw; $pct = Ctx-Pct $u $w } }
    if (-not $pct -and $u -and $w -and [long]$w -gt 0) { $pct = Ctx-Pct $u $w }
    $nm = if ($name) { $name } else { 'Claude' }
    $uk = if ($u) { [long]$u } else { 0 }
    if ($pct -and $w) { [Console]::Out.Write("$nm · context $pct%（$([long][Math]::Floor($uk / 1000))k / $([long][Math]::Floor([long]$w / 1000))k）`n") } else { [Console]::Out.Write("$nm`n") }
}
# A log can be hundreds of MB: kit reads its last 8 MB (all of it only when those have nothing to go by), line by line
# from a seek, never the whole file into memory.
$script:CtxTail = [long]8388608; if ("$env:KIT_CTX_TAIL" -match '^[0-9]+$') { $script:CtxTail = [long]$env:KIT_CTX_TAIL }
function Ctx-Open([string]$f, [long]$n) { # @(reader, cut): at the first whole line of the last N bytes of F (0: all of it); $null if unreadable
    try {
        $fs = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $cut = ($n -gt 0 -and $fs.Length -gt $n)
        if ($cut) { [void]$fs.Seek(-$n, [IO.SeekOrigin]::End) }
        $r = New-Object IO.StreamReader($fs, $Utf8)
        if ($cut) { [void]$r.ReadLine() }                         # (cut off in the middle)
        , @($r, $cut)
    } catch { $null }
}
function Newest-Files([string]$dir, [string]$filter) { # files called FILTER under DIR changed in the last 7 days, newest first (40 at most)
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $since = (Get-Date).AddDays(-7)
    @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $filter -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 40 | ForEach-Object { $_.FullName })
}
function Claude-Scan([string]$f, [long]$n) { # the last reply with its usage (not one Claude Code made itself: "<synthetic>", usage 0) and the last compaction
    $o = Ctx-Open $f $n; $a = ''; $an = 0; $c = ''; $cn = 0; $i = 0
    if ($o) {
        try {
            while ($null -ne ($l = $o[0].ReadLine())) {
                $i++
                if ($l.Contains('"type":"assistant"') -and $l.Contains('"usage"') -and -not $l.Contains('"model":"<synthetic>"')) { $a = $l; $an = $i }
                if ($l.Contains('"compact_boundary"')) { $c = $l; $cn = $i }
            }
        } finally { $o[0].Dispose() }
    }
    $which = if ($cn -gt $an) { 'cut' } elseif ($an) { 'reply' } elseif ($o -and $o[1]) { 'more' } else { '' }
    @{ which = $which; a = $a; c = $c }
}
function Claude-Ctx([string]$cpid, [string]$cwd) {
    $f = Claude-Record $cpid
    if ($f) {
        # the window: what settings.json tells Claude Code (autoCompactWindow, as its own /context shows), else Claude's
        $j = Read-Text $f; $m = Str-Of 'model' $j; $w = Setting-Window $m; if (-not $w) { $w = Num-Of 'window' $j }
        return Ctx-Json 'claude' (Num-Of 'used' $j) $w 'statusline' $m
    }
    if (-not $cwd) { return Ctx-Json 'claude' '' '' '' '' }
    $d = Join-Path (Join-Path $ClaudeDir 'projects') ($cwd -replace '[^A-Za-z0-9]', '-')
    $t = @(if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1 })
    if ($t.Count -eq 0) { return Ctx-Json 'claude' '' '' '' '' }
    $s = Claude-Scan $t[0].FullName $CtxTail; if ($s.which -eq 'more') { $s = Claude-Scan $t[0].FullName 0 }
    $m = Str-Of 'model' $s.a; $w = Model-Window $m
    if ($s.which -eq 'cut') { return Ctx-Json 'claude' (Num-Of 'postTokens' $s.c) $w 'transcript' $m }
    if (-not $s.a) { return Ctx-Json 'claude' '' '' 'transcript' '' }
    Ctx-Json 'claude' ([string](Sum-Of (After-Key 'usage' $s.a) @('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'))) $w 'transcript' $m
}
function Codex-Pct([long]$u, [long]$w) { # Codex's own "% context left" turned into % used (12000 tokens are its baseline)
    $b = 12000; if ($w -le $b) { return '100' }
    $e = $w - $b; $used = [Math]::Max([long]0, $u - $b); $rem = [Math]::Max([long]0, $e - $used)
    [string](100 - [long][Math]::Floor(($rem * 100 + [Math]::Floor($e / 2)) / $e))
}
function Codex-Last([string]$f, [long]$n) { # its last token_count and turn_context
    $o = Ctx-Open $f $n; $t = ''; $c = ''
    if ($o) {
        try {
            while ($null -ne ($l = $o[0].ReadLine())) {
                if ($l.Contains('"token_count"') -and $l.Contains('"last_token_usage"')) { $t = $l }
                if ($l.Contains('"turn_context"')) { $c = $l }
            }
        } finally { $o[0].Dispose() }
    }
    @{ which = $(if ((-not $t -or -not $c) -and $o -and $o[1]) { 'more' } else { 'ok' }); t = $t; c = $c }
}
function Codex-Ctx([string]$cwd) { # the newest rollout started in that folder
    $f = Codex-Rollout $cwd
    if (-not $f) { return Ctx-Json 'codex' '' '' '' '' }
    $s = Codex-Last $f $CtxTail; if ($s.which -eq 'more') { $s = Codex-Last $f 0 }
    $m = Str-Of 'model' $s.c
    if (-not $s.t) { return Ctx-Json 'codex' '' '' 'rollout' $m }
    $u = Num-Of 'total_tokens' (After-Key 'last_token_usage' $s.t); $w = Num-Of 'model_context_window' $s.t
    Ctx-Json 'codex' $u $w 'rollout' $m $(if ($u -and $w) { Codex-Pct ([long]$u) ([long]$w) } else { '' })
}
function Omp-Window([string]$m) {
    $db = Join-Path $OmpDir 'models.db'; $w = ''
    $prov = ($m -split '/', 2)[0]; $id = if ($m.Contains('/')) { ($m -split '/', 2)[1] } else { $m }
    if ((Test-Path -LiteralPath $db) -and (Get-Command sqlite3 -ErrorAction SilentlyContinue) -and ($m -notmatch "'")) {
        $q = "select json_extract(m.value,'`$.contextWindow') from model_cache, json_each(models) m where (provider_id = '$prov' or provider_id like '${prov}:%') and json_extract(m.value,'`$.id') = '$id' limit 1"
        $w = "$(& sqlite3 -readonly "file:$($db.Replace('\', '/'))?mode=ro" $q 2>$null)".Trim()
    }
    if ($w -match '^[0-9]+$') { $w } else { Model-Window $id }
}
$script:TextRx = [regex]'"text":"(?:[^"\\]|\\.)*"'
function Omp-Scan([string]$f, [long]$n) {
    # the last finished reply, the last compaction, the last model change; and like omp's own footer, what came after
    # that reply (tool results, your next message): their text at about 4 bytes a token, each image about 1600 tokens
    # (only the message itself: what omp keeps for its screen, "details", is not sent to the model)
    $o = Ctx-Open $f $n; $a = ''; $an = 0; $c = ''; $cn = 0; $m = ''; $tb = [long]0; $im = [long]0; $i = 0
    if ($o) {
        try {
            while ($null -ne ($l = $o[0].ReadLine())) {
                $i++
                if ($l.Contains('"role":"assistant"') -and -not $l.Contains('"stopReason":"aborted"') -and -not $l.Contains('"stopReason":"error"')) { $a = $l; $an = $i; $tb = [long]0; $im = [long]0; continue }
                if ($l.Contains('"type":"compaction"') -or $l.Contains('"type":"reset_boundary"')) { $c = $l; $cn = $i }
                if ($l.Contains('"type":"model_change"')) { $m = $l }
                if ($an -and $l.Contains('"type":"message"')) {
                    $s = $l; $k = $s.IndexOf(',"details":', [StringComparison]::Ordinal); if ($k -ge 0) { $s = $s.Substring(0, $k) }
                    $x = 0; while (($x = $s.IndexOf('"type":"image"', $x, [StringComparison]::Ordinal)) -ge 0) { $im++; $x += 14 }
                    foreach ($t in $TextRx.Matches($s)) { $tb += $Utf8.GetByteCount($t.Value) - 9 }
                }
            }
        } finally { $o[0].Dispose() }
    }
    $which = if ($cn -gt $an) { 'cut' } elseif ($an) { 'reply' } elseif ($o -and $o[1]) { 'more' } else { '' }
    @{ which = $which; a = $a; c = $c; m = $m; tb = $tb; im = $im }
}
function Omp-Ctx([string]$opid, [string]$cwd) {
    $f = Omp-Session $opid $cwd
    if (-not $f) { return Ctx-Json 'omp' '' '' '' '' }
    $s = Omp-Scan $f $CtxTail; if ($s.which -eq 'more') { $s = Omp-Scan $f 0 }
    $m = Str-Of 'model' $s.m
    if ($s.a -and -not $m) { $m = (Str-Of 'provider' $s.a) + '/' + (Str-Of 'model' $s.a) }
    $w = if ($m) { Omp-Window $m } else { '' }
    if ($s.which -eq 'cut') { return Ctx-Json 'omp' (Num-Of 'tokensAfter' $s.c) $w 'session' $m }
    if (-not $s.a) { return Ctx-Json 'omp' '' $w 'session' $m }
    $u = Num-Of 'promptTokens' (After-Key 'contextSnapshot' $s.a)
    if (-not $u) { $u = [string](Sum-Of (After-Key 'usage' $s.a) @('input', 'cacheRead', 'cacheWrite')) }
    $rm = Num-Of 'historyRewriteTokensRemoved' $s.a
    if ($rm) { $u = [string][Math]::Max([long]0, [long]$u - [long]$rm) }
    $u = [string]([long]$u + [long][Math]::Floor($s.tb / 4) + $s.im * 1600)
    Ctx-Json 'omp' $u $w 'session' $m
}
function Omp-Session([string]$opid, [string]$cwd) { # the session its terminal points at, else the newest of that folder ('' if none)
    $f = ''
    if (-not $OnWindows -and $opid) {
        $tty = "$(& ps -o tty= -p $opid 2>$null)".Trim() -replace '^/dev/', '' -replace '/', '-'
        if ($tty -and $tty -notmatch '^\?+$') { $bc = Join-Path (Join-Path $OmpDir 'terminal-sessions') $tty; if (Test-Path -LiteralPath $bc) { $f = "$(@(Get-Content -LiteralPath $bc -TotalCount 2 -Encoding UTF8)[1])" } }
    }
    if (-not $f -or -not (Test-Path -LiteralPath $f)) {
        $f = ''
        if ($cwd) {
            $want = '"cwd":' + (Json-S $cwd)
            foreach ($x in Newest-Files (Join-Path $OmpDir 'sessions') '*.jsonl') {
                if (@(Get-Content -LiteralPath $x -TotalCount 3 -Encoding UTF8 | Where-Object { $_.Contains('"type":"session"') -and $_.Contains($want) }).Count -gt 0) { $f = $x; break }
            }
        }
    }
    $f
}
function Agent-Guess([string]$cpid, [string]$tool, [string]$dir) { # @(tool, folder): TOOL, else guessed from the process
    # (claude|codex|omp); DIR, else the process's folder (for kit context and kit files)
    if (-not $tool) {
        $pa = Proc-Args ([int]$cpid)
        if ($pa) { $w = @($pa.Trim() -split '\s+'); $s2 = ($w[0] + ':' + $(if ($w.Count -gt 1) { $w[1] } else { '' }))
            $b = ($w[0].Trim('"') -split '[\\/]')[-1]
            if ($b -like 'claude*' -or $s2 -match ':.*claude') { $tool = 'claude' } elseif ($b -like 'codex*' -or $s2 -match ':.*codex') { $tool = 'codex' } elseif ($b -like 'omp*' -or $s2 -match ':.*omp') { $tool = 'omp' } }
    }
    if ($tool -ceq 'claude-code') { $tool = 'claude' } elseif ($tool -ceq 'pi') { $tool = 'omp' }
    if (-not $dir) { $dir = Proc-Cwd ([int]$cpid) }
    , @($tool, $dir)
}
function Cmd-Context($rest) { # kit context --pid PID [--tool claude|codex|omp] [--dir DIR] [--detail [--fresh]] : how full that agent's context is (JSON)
    $use = '用法：kit context --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--detail [--fresh]]'
    $rest = @($rest); $cpid = ''; $tool = ''; $dir = ''; $detail = $false; $fresh = $false
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $a = [string]$rest[$i]
        if ($a -ceq '--detail') { $detail = $true; continue }
        if ($a -ceq '--fresh') { $fresh = $true; continue }
        if ($a -cne '--pid' -and $a -cne '--tool' -and $a -cne '--dir') { Die $use }
        if ($i + 1 -ge $rest.Count) { Die $use }
        $v = [string]$rest[++$i]
        if ($a -ceq '--pid') { $cpid = $v } elseif ($a -ceq '--tool') { $tool = $v } else { $dir = $v }
    }
    if ($cpid -cnotmatch '^[0-9]+\z') { Die $use }
    $g = Agent-Guess $cpid $tool $dir; $tool = $g[0]; $dir = $g[1]
    # the kept numbers (and details) of processes that are gone
    if (Test-Path -LiteralPath $CtxDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $CtxDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -clike 'claude-*.json' -or $_.Name -clike 'detail-*.json' })) {
            $p = $f.Name.Substring($f.Name.IndexOf('-') + 1); $p = $p.Substring(0, $p.Length - 5)
            if ($p -cne $cpid -and $p -cmatch '^[0-9]{1,9}\z' -and -not (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($detail) { Ctx-Detail $cpid $tool $dir $fresh; return }
    $out = switch ($tool) { 'claude' { Claude-Ctx $cpid $dir } 'codex' { Codex-Ctx $dir } 'omp' { Omp-Ctx $cpid $dir } default { Ctx-Json '' '' '' '' '' } }
    [Console]::Out.Write($out + "`n")
}

# ---------- kit context --detail: where the tokens go ----------
# The same JSON line as unix/kit (its comments there say what is in it and where each part comes from). Sizes are
# counted the way awk counts them there (LC_ALL=C): UTF-8 bytes of the text as it is in the file, still JSON-escaped;
# the numbers are worked out in the same order, so the answer is the same to the token.
# On Windows Claude Code gets its hooks-off setting as a file ($KIT_CONF/ctx/probe-settings.json): cmd.exe would
# mangle the quotes of a JSON argument.
$script:CtxDetailTail = [long]33554432; if ("$env:KIT_CTX_DETAIL_TAIL" -match '^[0-9]+$') { $script:CtxDetailTail = [long]$env:KIT_CTX_DETAIL_TAIL }
$script:CtxProbeInit = '{"type":"control_request","request_id":"i1","request":{"subtype":"initialize"}}'
$script:CtxProbeAsk = '{"type":"control_request","request_id":"c1","request":{"subtype":"get_context_usage"}}'
$script:Ord = [StringComparison]::Ordinal
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Sep = [string][IO.Path]::DirectorySeparatorChar
$script:StrvRx = New-Object 'System.Collections.Generic.Dictionary[string,regex]'
$script:CtlRx = [regex]'[\x01-\x1f]'
$script:EscRx = [regex]'\\[nrtbf]'
$script:DataRx = [regex]'"(data|image_url)":"[^"]*"'
$script:TxtRx = [regex]'"text":"[^"\\]*(?:\\.[^"\\]*)*"'
$script:NumRx = [regex]'^[ \t\n]*[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?'
$script:StrNumRx = [regex]'^[ \t\n]*[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?[ \t\n]*\z'
$script:TypeRx = [regex]'"type":"[a-z_]+"'
$script:NsRx = [regex]'\{"type":"[a-z_]+","name":"'
$script:RootRx = [regex]'- `r[0-9]+` = `[^`]*`'
$script:ItemRx = [regex]'\\n- '
$script:FileRx = [regex]'\(file: [^)]*\)'
$script:ClaudePartRx = [regex]'\{"type":"(text|thinking|redacted_thinking|tool_use|server_tool_use)"'
$script:ToolIdRx = [regex]'\{"tool_use_id":"'
$script:OmpPartRx = [regex]'\{"type":"(text|thinking|toolCall|redactedThinking)"'
$script:McpTomlRx = [regex]'^[ \t\r\n\f\v]*\[mcp_servers\.([^\].]*)\][ \t\r\n\f\v]*\z'
$script:ClaudeSkipAt = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($x in 'skill_listing instructions deferred_tools_delta deferred_tools_record mcp_instructions_delta agent_listing_delta prompt_snapshot thinking_drop credential_org'.Split(' ')) { [void]$ClaudeSkipAt.Add($x) }
$script:CtxNm = New-Object 'System.Collections.Generic.Dictionary[string,string]'
foreach ($x in @(@('system_prompt', '系統提示'), @('system_tools', '系統工具'), @('system_tools_deferred', '系統工具（延後載入）'),
        @('mcp_tools', 'MCP 工具'), @('mcp_tools_deferred', 'MCP 工具（延後載入）'), @('mcp_instructions', 'MCP 伺服器說明'),
        @('custom_agents', '自訂 agents'), @('memory_files', '記憶檔'), @('skills', 'Skills'), @('messages', '對話訊息'),
        @('slash_commands', '斜線指令'), @('other', '其他／自上次更新以來'), @('autocompact_buffer', '自動壓縮保留區'),
        @('free_space', '可用空間'), @('instructions', '指示檔'), @('compaction', '壓縮後的摘要'),
        @('memory', '記憶檔'), @('mcp', 'MCP（依伺服器）'), @('tools', '工具（依類別）'), @('agents', '自訂 agents'),
        @('commands', '斜線指令'), @('tool_results', '工具（呼叫＋結果，依工具）'), @('attachments', '附加內容（依種類）'),
        @('msgs', '對話內容（依種類）'))) { $CtxNm[$x[0]] = $x[1] }
function New-Dict([string]$t = 'double') { New-Object "System.Collections.Generic.Dictionary[string,$t]" }
function New-List([string]$t = 'string') { , (New-Object "System.Collections.Generic.List[$t]") }
function Dict-Get($d, [string]$k, $def = 0.0) { $v = $null; if ($d.TryGetValue($k, [ref]$v)) { $v } else { $def } }
function Dict-Add($d, [string]$k, [double]$x) { $v = 0.0; [void]$d.TryGetValue($k, [ref]$v); $d[$k] = $v + $x }
function Dict-Keys($a, $b) { # the keys of A, then those of B that A does not have
    $o = New-List; foreach ($k in $a.Keys) { $o.Add($k) }; foreach ($k in $b.Keys) { if (-not $a.ContainsKey($k)) { $o.Add($k) } }; , $o
}
function Unix-Now { [long][Math]::Floor(([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds) }
function Ctx-Strv([string]$s, [string]$k) { # the text of "K":"..." in S (still JSON-escaped)
    $rx = $null
    if (-not $StrvRx.TryGetValue($k, [ref]$rx)) { $rx = New-Object regex ('"' + [regex]::Escape($k) + '":"([^"\\]*(?:\\.[^"\\]*)*)"'); $StrvRx[$k] = $rx }
    $m = $rx.Match($s); if ($m.Success) { $m.Groups[1].Value } else { '' }
}
function Ctx-Unesc([string]$s) { # JSON escapes undone (a control character: a space)
    $s = $s.Replace('\\', [string][char]1).Replace('\"', '"').Replace('\/', '/')
    $CtlRx.Replace($EscRx.Replace($s, ' ').Replace([string][char]1, '\'), ' ')
}
function Ctx-Unjs([string]$s) { $s.Replace('\\', '\').Replace('\"', '"').Replace('\/', '/') }   # a JSON string's text as it is
function Ctx-Rnd([double]$x) { [Math]::Truncate($x + 0.5) }
function Ctx-Num([double]$x) { # a number the way awk prints it
    if ($x -eq [Math]::Truncate($x) -and [Math]::Abs($x) -lt 1e15) { return ([long]$x).ToString($Inv) }
    $x.ToString('G6', $Inv).Replace('E', 'e')
}
function Ctx-Val([string]$s) { # a text as awk takes it for a number
    $m = $NumRx.Match($s); if (-not $m.Success) { return [double]0 }
    [double]::Parse($m.Value.Trim(), [Globalization.NumberStyles]::Float, $Inv)
}
function Ctx-Imgs([string]$s) { # how many images (like unix/kit: "image" ones first, then "input_image" ones after the last)
    $n = 0; $p = 0
    while ($true) {
        $i = $s.IndexOf('"type":"image"', $p, $Ord)
        if ($i -lt 0) { $i = $s.IndexOf('"type":"input_image"', $p, $Ord) }
        if ($i -lt 0) { return $n }
        $n++; $p = $i + 12
    }
}
function Ctx-Wt([string]$s) { # a piece's tokens: its bytes / 4 (not an image's data), and 1600 an image
    $d = 0
    if ($s.Contains('"data":"') -or $s.Contains('"image_url":"')) { foreach ($m in $DataRx.Matches($s)) { $d += $Utf8.GetByteCount($m.Value) } }
    ($Utf8.GetByteCount($s) - $d) / 4 + (Ctx-Imgs $s) * 1600
}
function Ctx-Short([string]$p) { # a path with ~ for the home folder
    $h = $UserHome
    if ($h -and $p.StartsWith($h, $Ord) -and ($p.Length -eq $h.Length -or $p[$h.Length] -eq [char]'/' -or $p[$h.Length] -eq [char]'\')) { return '~' + $p.Substring($h.Length) }
    $p
}
function Ctx-Head([string]$s, [int]$n) { # the whole characters in the first N bytes of S
    if ($s.Length -gt $n) { $s = $s.Substring(0, $n) }
    while (($b = $Utf8.GetByteCount($s)) -gt $n) { $s = $s.Substring(0, $s.Length - [Math]::Max(1, [Math]::Floor(($b - $n) / 3))) }
    $s
}
function Ctx-Head80([string]$s) { $b = $Utf8.GetBytes($s); [Convert]::ToBase64String($b, 0, [Math]::Min(80, $b.Length)) }   # its first 80 bytes, to compare
function Ctx-Parts([string]$s, $rx) { # S cut right before each match of RX (what comes before the first one dropped)
    $ms = $rx.Matches($s); $o = New-List
    for ($i = 0; $i -lt $ms.Count; $i++) { $e = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $s.Length }; $o.Add($s.Substring($ms[$i].Index, $e - $ms[$i].Index)) }
    , $o
}
function Ctx-Size([string]$f) { # the size of a file (through a link), -1 when it is not one that can be read
    try { $fs = [IO.File]::Open($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)); try { return [long]$fs.Length } finally { $fs.Dispose() } } catch { return [long]-1 }
}
function Ctx-Join([string]$a, [string]$n) { if ($OnWindows -and ($a.EndsWith('\', $Ord) -or $a.EndsWith('/', $Ord))) { return $a + $n }; $a + $Sep + $n }
function Ctx-SamePath([string]$a, [string]$b) {
    if ($OnWindows) { return [string]::Equals($a.Replace('/', '\').TrimEnd('\'), $b.Replace('/', '\').TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }
    $a -ceq $b
}
function Ctx-Under([string]$p, [string]$dir) { # P is somewhere under DIR
    if (-not $p) { return $false }
    if ($OnWindows) { return $p.Replace('/', '\').StartsWith($dir.Replace('/', '\').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }
    $p.StartsWith($dir + '/', $Ord)
}
function Ctx-Parent([string]$a) { # like dirname
    if ($OnWindows) { try { return [string][IO.Path]::GetDirectoryName($a) } catch { return '' } }
    $s = $a.TrimEnd('/'); if (-not $s) { return '/' }
    $i = $s.LastIndexOf('/'); if ($i -lt 0) { return '.' }
    $s = $s.Substring(0, $i).TrimEnd('/'); if ($s) { $s } else { '/' }
}
function Ctx-Up([string]$d) { # DIR and the folders above it up to its git root (or only DIR when it is in none), root first
    $list = New-List; $a = $d
    while ($true) {
        $list.Insert(0, $a)
        if (Test-Path -LiteralPath (Ctx-Join $a '.git')) { return , $list.ToArray() }
        if ($a -ceq '/' -or (Ctx-SamePath $a $UserHome)) { break }
        $up = Ctx-Parent $a
        if (-not $up -or $up -ceq $a) { break }
        $a = $up
    }
    , @($d)
}
function Ctx-Files([string]$note, $files, $out) { # "path TAB bytes TAB note" for each file that is there and not empty
    foreach ($f in $files) { $n = Ctx-Size $f; if ($n -gt 0) { $out.Add("$f`t$n`t$note") } }
}
function Ctx-Stream([string]$f) { # @(reader, first line or $null): a log for a detail look: all of it, or its first line and the
    # whole lines in its last KIT_CTX_DETAIL_TAIL bytes
    try { $fs = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) } catch { return $null }
    try {
        if ($fs.Length -le $CtxDetailTail) { return , @((New-Object IO.StreamReader($fs, $Utf8)), $null) }
        $r = New-Object IO.StreamReader($fs, $Utf8, $true, 65536, $true); $first = $r.ReadLine(); $r.Dispose()
        [void]$fs.Seek(-$CtxDetailTail, [IO.SeekOrigin]::End)
        $r = New-Object IO.StreamReader($fs, $Utf8); [void]$r.ReadLine()                # (cut off in the middle)
        , @($r, $first)
    } catch { $fs.Dispose(); $null }
}

# the rows (a TAB between fields): H key value | C id name tokens kind est | G id name est | I group name tokens note path parent
function Ctx-Q([string]$s) { '"' + $CtlRx.Replace($s.Replace('\', '\\').Replace('"', '\"'), '') + '"' }
function Ctx-B([string]$v) { if ($v -ceq '1') { 'true' } else { 'false' } }
function Ctx-Nul([string]$v) { if ($v -ceq '') { 'null' } else { $v } }
function Ctx-Name([string]$id, [string]$x) {
    if ($x.StartsWith('=', $Ord)) { return $x.Substring(1) }
    $v = $null; if ($CtxNm.TryGetValue($id, [ref]$v)) { return $v }
    if ($x -cne '') { $x } else { $id }
}
function Ctx-Less([string]$a, [string]$b) { # a < b the way awk compares two fields: as numbers when both are, else by bytes
    if ($StrNumRx.IsMatch($a) -and $StrNumRx.IsMatch($b)) { return (Ctx-Val $a) -lt (Ctx-Val $b) }
    $x = $Utf8.GetBytes($a); $y = $Utf8.GetBytes($b); $n = [Math]::Min($x.Length, $y.Length)
    for ($i = 0; $i -lt $n; $i++) { if ($x[$i] -ne $y[$i]) { return $x[$i] -lt $y[$i] } }
    $x.Length -lt $y.Length
}
function Ctx-Before($A, [int]$x, [int]$y) { # item X before item Y: more tokens first (none last), then by name, then as listed
    $ta = $A.itk[$x]; $tc = $A.itk[$y]
    if ($ta -ceq '' -and $tc -cne '') { return $false }
    if ($tc -ceq '' -and $ta -cne '') { return $true }
    if ($ta -cne '') { $na = Ctx-Val $ta; $nc = Ctx-Val $tc; if ($na -ne $nc) { return $na -gt $nc } }
    Ctx-Less $A.inm[$x] $A.inm[$y]
}
function Ctx-Items($A, [string]$g, [string]$par) { # the items of group G under PAR, as JSON
    $list = New-List 'int'
    for ($i = 0; $i -lt $A.inm.Count; $i++) {
        if ($A.ig[$i] -cne $g -or $A.ipar[$i] -cne $par) { continue }
        $k = $list.Count; $list.Add($i)
        while ($k -gt 0 -and (Ctx-Before $A $i $list[$k - 1])) { $list[$k] = $list[$k - 1]; $k-- }
        $list[$k] = $i
    }
    $o = New-List
    foreach ($i in $list) {
        $t = '{"name": ' + (Ctx-Q $A.inm[$i]) + ', "tokens": ' + (Ctx-Nul $A.itk[$i]) + ', "note": ' + (Ctx-Q $A.inote[$i]) + ', "path": ' + (Ctx-Q $A.ipath[$i])
        if ($par -ceq '' -and $A.inm[$i] -cne '') { $kids = Ctx-Items $A $g $A.inm[$i]; if ($kids -cne '') { $t += ', "items": [' + $kids + ']' } }
        $o.Add($t + '}')
        if ($par -ceq '' -and $A.itk[$i] -cne '') { Dict-Add $A.gsum $g (Ctx-Val $A.itk[$i]); [void]$A.gknown.Add($g) }
    }
    $o -join ', '
}
function Ctx-Assemble($rows, [string]$now) { # the rows -> the JSON line
    $h = New-Dict 'string'; $cats = New-List; $gid = New-List; $gnm = New-List; $ges = New-List
    $A = @{ ig = (New-List); inm = (New-List); itk = (New-List); inote = (New-List); ipath = (New-List); ipar = (New-List)
        gsum = (New-Dict); gknown = (New-Object 'System.Collections.Generic.HashSet[string]') }
    foreach ($r in $rows) {
        $f = [string[]]($r.Split("`t") + @('', '', '', '', '', '', ''))
        if ($f[0] -ceq 'H') { $h[$f[1]] = $f[2] }
        elseif ($f[0] -ceq 'C') {
            if (($f[3] -ceq '' -or (Ctx-Val $f[3]) -eq 0) -and $f[4] -cne 'free') { continue }
            $cats.Add('{"id": ' + (Ctx-Q $f[1]) + ', "name": ' + (Ctx-Q (Ctx-Name $f[1] $f[2])) + ', "tokens": ' + (Ctx-Num (Ctx-Val $f[3])) + ', "kind": ' + (Ctx-Q $f[4]) + ', "est": ' + (Ctx-B $f[5]) + '}')
        }
        elseif ($f[0] -ceq 'G') { $gid.Add($f[1]); $gnm.Add((Ctx-Name $f[1] $f[2])); $ges.Add($f[3]) }
        elseif ($f[0] -ceq 'I') { $A.ig.Add($f[1]); $A.inm.Add($f[2]); $A.itk.Add($f[3]); $A.inote.Add($f[4]); $A.ipath.Add($f[5]); $A.ipar.Add($f[6]) }
    }
    $u = Dict-Get $h 'used' ''; $w = Dict-Get $h 'window' ''; $p = Dict-Get $h 'pct' ''
    if ($p -ceq '' -and $u -cne '' -and (Ctx-Val $w) -gt 0) { $wv = Ctx-Val $w; $p = Ctx-Num ([Math]::Truncate(((Ctx-Val $u) * 100 + [Math]::Truncate($wv / 2)) / $wv)) }
    if ($p -cne '' -and (Ctx-Val $p) -gt 100) { $p = '100' }
    $e = Dict-Get $h 'error' ''
    $o = '{"tool": ' + (Ctx-Q (Dict-Get $h 'tool' '')) + ', "used": ' + (Ctx-Nul $u) + ', "window": ' + (Ctx-Nul $w) + ', "pct": ' + (Ctx-Nul $p) + ', "source": ' + (Ctx-Q (Dict-Get $h 'source' '')) + ', "model": ' + (Ctx-Q (Dict-Get $h 'model' ''))
    $o += ', "at": ' + $now + ', "exact": ' + (Ctx-B (Dict-Get $h 'exact' '')) + ', "session": ' + (Ctx-Q (Dict-Get $h 'session' '')) + ', "compact_at": ' + (Ctx-Nul (Dict-Get $h 'compact_at' ''))
    $o += ', "commands": {"compact": ' + (Ctx-Q (Dict-Get $h 'compact' '')) + ', "with_text": ' + (Ctx-B (Dict-Get $h 'with_text' '')) + ', "clear": ' + (Ctx-Q (Dict-Get $h 'clear' '')) + '}'
    $o += ', "note": ' + (Ctx-Q (Dict-Get $h 'note' '')) + ', "error": ' + $(if ($e -ceq '') { 'null' } else { Ctx-Q $e }) + ', "categories": [' + ($cats -join ', ') + '], "groups": ['
    $gs = New-List
    for ($i = 0; $i -lt $gid.Count; $i++) {
        $t = Ctx-Items $A $gid[$i] ''; if ($t -ceq '') { continue }
        $gs.Add('{"id": ' + (Ctx-Q $gid[$i]) + ', "name": ' + (Ctx-Q $gnm[$i]) + ', "tokens": ' + $(if ($A.gknown.Contains($gid[$i])) { Ctx-Num $A.gsum[$gid[$i]] } else { 'null' }) + ', "est": ' + (Ctx-B $ges[$i]) + ', "items": [' + $t + ']}')
    }
    $o + ($gs -join ', ') + ']}'
}
function Row-H($rows, [string]$k) { foreach ($r in $rows) { if ($r.StartsWith("H`t$k`t", $Ord)) { return $r.Substring($k.Length + 3) } }; '' }
function Rows-Add($R, $rows) { foreach ($x in $rows) { if (-not $x.StartsWith("H`t", $Ord)) { $R.Add($x) } } }   # all but the H rows

# ---------- Claude ----------
$script:ClaudeRec = $null
function Claude-Record([string]$cpid) { # the file the status line keeps for that Claude ('' if none); on Windows also one of a
    # claude process up to 3 levels under it (the pane's process may be a shell or cmd.exe that started Claude)
    if (-not $cpid) { return '' }
    $f = Join-Path $CtxDir "claude-$cpid.json"
    if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
    if (-not $OnWindows) { return '' }
    if ($null -ne $script:ClaudeRec) { return $script:ClaudeRec }
    $script:ClaudeRec = ''
    if (@(Get-ChildItem -LiteralPath $CtxDir -Filter 'claude-*.json' -File -ErrorAction SilentlyContinue).Count -eq 0) { return '' }
    $kids = @{}
    foreach ($c in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)) {
        $pp = [int]$c.ParentProcessId; if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-List 'int' }; $kids[$pp].Add([int]$c.ProcessId)
    }
    $level = @([int]$cpid)
    for ($d = 0; $d -lt 3; $d++) {
        $next = @()
        foreach ($p in $level) {
            if (-not $kids.ContainsKey($p)) { continue }
            foreach ($k in $kids[$p]) {
                if ($k -eq $p) { continue }
                $f = Join-Path $CtxDir "claude-$k.json"; if (Test-Path -LiteralPath $f -PathType Leaf) { $script:ClaudeRec = $f; return $f }
                $next += $k
            }
        }
        $level = $next
    }
    ''
}
function Claude-Session([string]$cpid, [string]$dir) { # @(id, folder, transcript) of the Claude Code in CPID (the id checked), else $null
    # what the status line kept; else ~/.claude/sessions/<pid>.json (older Claude Code); else the daemon's roster
    # (only pid / replPid / sessionId / cwd are read: it holds tokens too); else the newest transcript of its folder
    # changed since it started
    $sid = ''; $cwd = ''; $tp = ''
    $f = Claude-Record $cpid
    if ($f) { $j = Read-Text $f; $sid = Str-Of 'session' $j; $cwd = Ctx-Unjs (Str-Of 'cwd' $j); $tp = Ctx-Unjs (Str-Of 'transcript' $j) }
    $f = Join-Path (Join-Path $ClaudeDir 'sessions') "$cpid.json"
    if (-not $sid -and (Test-Path -LiteralPath $f -PathType Leaf)) { $j = Read-Text $f; $sid = Str-Of 'sessionId' $j; $cwd = Ctx-Unjs (Str-Of 'cwd' $j) }
    $f = Join-Path (Join-Path $ClaudeDir 'daemon') 'roster.json'
    if (-not $sid -and (Test-Path -LiteralPath $f -PathType Leaf)) {
        $sid = ''; $cwd = ''; $w = @{}; $order = New-List
        foreach ($l in @(Json-LeavesOf $f)) {
            if ($null -eq $l -or $l.Count -ne 4 -or $l[0] -cne 'workers' -or @('pid', 'replPid', 'sessionId', 'cwd') -cnotcontains $l[2]) { continue }
            $v = $l[3]; if ($v.StartsWith('"', $Ord)) { $v = $v.Substring(1) }; if ($v.EndsWith('"', $Ord)) { $v = $v.Substring(0, $v.Length - 1) }
            if (-not $w.ContainsKey($l[1])) { $w[$l[1]] = New-Dict 'string'; $order.Add($l[1]) }
            $w[$l[1]][$l[2]] = $v
        }
        foreach ($x in $order) {
            if ((Dict-Get $w[$x] 'pid' '') -ceq $cpid -or (Dict-Get $w[$x] 'replPid' '') -ceq $cpid) { $sid = Dict-Get $w[$x] 'sessionId' ''; $cwd = Ctx-Unjs (Dict-Get $w[$x] 'cwd' ''); break }
        }
    }
    if (-not $cwd) { $cwd = $dir }
    if (-not $sid -and $cwd) {
        $d = Join-Path (Join-Path $ClaudeDir 'projects') ($cwd -creplace '[^A-Za-z0-9]', '-')
        $start = $null; try { $start = (Get-Process -Id ([int]$cpid) -ErrorAction Stop).StartTime } catch { }
        if ($start -and (Test-Path -LiteralPath $d -PathType Container)) {
            $now = Get-Date; $mins = [Math]::Floor(($now - $start).TotalSeconds / 60) + 2
            $t = @(Get-ChildItem -LiteralPath $d -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { [Math]::Ceiling(($now - $_.LastWriteTime).TotalMinutes) -lt $mins } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($t.Count -gt 0) { $sid = $t[0].BaseName; $tp = $t[0].FullName }
        }
    }
    if ($sid -cnotmatch '^[A-Za-z0-9_-]+\z') { return $null }
    , @($sid, $cwd, $tp)
}
function Claude-Where([string]$cpid, [string]$dir) { # @(id, folder, transcript) (transcript: only one under ~/.claude/projects
    # that is there, else ''), else $null when there is no session
    $s = Claude-Session $cpid $dir; if (-not $s) { return $null }
    $sid = $s[0]; $cwd = $s[1]; $tp = $s[2]
    if (-not $cwd) { $cwd = $dir }
    $pd = Join-Path $ClaudeDir 'projects'
    if (-not (Ctx-Under $tp $pd) -or -not $tp.EndsWith('.jsonl', $Ord) -or -not (Test-Path -LiteralPath $tp -PathType Leaf)) { $tp = '' }
    if (-not $tp) { $tp = Join-Path (Join-Path $pd ($cwd -creplace '[^A-Za-z0-9]', '-')) "$sid.jsonl" }
    if (-not (Test-Path -LiteralPath $tp -PathType Leaf)) { $tp = '' }
    , @($sid, $cwd, $tp)
}
function Ctx-Arg([string]$a) { # one argument on a command line (Windows rules; .NET splits it the same way on mac/Linux)
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    '"' + ([regex]::Replace($a, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}
function Ctx-Kill($p) { # the process and what it started
    try {
        if ($p.HasExited) { return }
        if ($OnWindows) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null; return }
        if ($p.GetType().GetMethod('Kill', [Type[]]@([bool]))) { $p.Kill($true) } else { $p.Kill() }
    } catch { }
}
function Claude-Bin { # how to start Claude Code: @(program, its arguments before claude's, claude), else $null
    $c = @(Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)
    if ($c.Count -eq 0) { $c = @(Get-Command claude -CommandType ExternalScript -ErrorAction SilentlyContinue) }
    $p = if ($c.Count -gt 0) { [string]$c[0].Path } else { '' }
    if (-not $p) { $x = Join-Path (Join-Path (Join-Path $UserHome '.local') 'bin') $(if ($OnWindows) { 'claude.exe' } else { 'claude' }); if (Test-Path -LiteralPath $x -PathType Leaf) { $p = $x } }
    if (-not $p) { return $null }
    $e = [IO.Path]::GetExtension($p).ToLowerInvariant()
    if ($e -eq '.cmd' -or $e -eq '.bat') { return , @($(if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }), 'cmd', $p) }
    if ($e -eq '.ps1') { return , @((Get-Process -Id $PID).Path, '-NoProfile -ExecutionPolicy Bypass -File', $p) }
    , @($p, '', $p)
}
function Claude-Probe([string]$sid, [string]$cwd) { # Claude Code's own get_context_usage answer for that session (one line), else ''
    $b = Claude-Bin; if (-not $b) { return '' }
    if (-not $cwd -or -not [IO.Directory]::Exists($cwd)) { return '' }
    $t = 30; if ("$env:KIT_CTX_PROBE_TIMEOUT" -match '^[0-9]+$') { $t = [int]$env:KIT_CTX_PROBE_TIMEOUT }; if ($t -le 0) { $t = 86400 }
    # every hook off (a SessionStart hook must not run), no transcript written; only the c1 line is kept (the
    # initialize answer, which names the account, is never stored)
    $set = '{"disableAllHooks":true}'
    if ($OnWindows) { $sf = Join-Path $CtxDir 'probe-settings.json'; try { Ensure-Dir $CtxDir; [IO.File]::WriteAllText($sf, $set + "`n", $Utf8) } catch { return '' }; $set = $sf }
    $a = '-p --input-format stream-json --output-format stream-json --verbose --resume ' + $sid + ' --no-session-persistence --settings ' + (Ctx-Arg $set)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $b[0]
    $psi.Arguments = if ($b[1] -eq '') { $a } elseif ($b[1] -eq 'cmd') { '/d /s /c "' + (Ctx-Arg $b[2]) + ' ' + $a + '"' } else { $b[1] + ' ' + (Ctx-Arg $b[2]) + ' ' + $a }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $cwd
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
    $end = [DateTime]::UtcNow.AddSeconds($t); $line = ''; $p = $null
    try {
        $p = [Diagnostics.Process]::Start($psi)
        [void]$p.StandardError.ReadToEndAsync()                                   # read, never shown
        # straight to the pipe: Windows PowerShell's writer may put a BOM in front
        try { $in = $Utf8.GetBytes($CtxProbeInit + "`n" + $CtxProbeAsk + "`n"); $p.StandardInput.BaseStream.Write($in, 0, $in.Length); $p.StandardInput.BaseStream.Flush() } catch { }
        try { $p.StandardInput.BaseStream.Close() } catch { }
        while ($true) {
            $left = ($end - [DateTime]::UtcNow).TotalMilliseconds; if ($left -le 0) { break }
            $r = $p.StandardOutput.ReadLineAsync()
            if (-not $r.Wait([int][Math]::Min($left, 2147483647))) { break }
            if ($null -eq $r.Result) { break }
            if ($r.Result.Contains('"request_id":"c1"')) { $line = $r.Result; break }
        }
        if ($line) {                                                               # let it end by itself (within the time)
            [void]$p.StandardOutput.ReadToEndAsync()
            $left = ($end - [DateTime]::UtcNow).TotalMilliseconds; if ($left -gt 0) { [void]$p.WaitForExit([int][Math]::Min($left, 2147483647)) }
        }
    } catch { }
    finally { if ($p) { Ctx-Kill $p; try { $p.Dispose() } catch { } } }
    $line
}
function Claude-ProbeRows([string]$line, $R) { # what Claude Code said (the c1 line) -> rows, and H probe_total / probe_max /
    # probe_model / msgs / buffer / threshold (or H probe_error)
    $lv = New-List 'object'
    try { Json-Leaves (Json-Parse $line) @() $lv } catch { $lv.Clear() }
    $t = New-Dict 'string'; $v = New-Dict 'string'; $n = New-Dict; $err = ''
    foreach ($l in $lv) {
        $nf = $l.Count
        if ($nf -eq 3 -and $l[0] -ceq 'response' -and $l[1] -ceq 'error') { $err = Ctx-V $l[2] }
        if ($nf -lt 2 -or $l[0] -cne 'response' -or $l[1] -cne 'response') { continue }
        $k = if ($nf -ge 3) { $l[2] } else { '' }; $x = Ctx-V $l[$nf - 1]
        if ($nf -eq 4) { $t[$k] = $x; continue }
        if ($nf -eq 6 -and ($k -ceq 'categories' -or $k -ceq 'memoryFiles' -or $k -ceq 'mcpTools' -or $k -ceq 'agents')) { Ctx-Top $n $k $l[3]; $v["$k`t$($l[3])`t$($l[4])"] = $x; continue }
        if ($nf -eq 5 -and $k -ceq 'slashCommands') { $v["sc`t$($l[3])"] = $x; continue }
        if ($nf -eq 7 -and $k -ceq 'skills' -and $l[3] -ceq 'skillFrontmatter') { Ctx-Top $n 'sk' $l[4]; $v["sk`t$($l[4])`t$($l[5])"] = $x; continue }
    }
    $tot = Dict-Get $t 'totalTokens' ''
    if ($err -cne '' -or $tot -ceq '') { $R.Add("H`tprobe_error`t" + $(if ($err -cne '') { $err } else { 'Claude Code 沒有給 context 的細項' })); return }
    $R.Add("H`tprobe_total`t$tot"); $R.Add("H`tprobe_max`t" + (Dict-Get $t 'maxTokens' '')); $R.Add("H`tprobe_model`t" + (Dict-Get $t 'model' ''))
    if ((Dict-Get $t 'isAutoCompactEnabled' '') -ceq 'true') { $R.Add("H`tthreshold`t" + (Dict-Get $t 'autoCompactThreshold' '')) }
    for ($i = 1; $i -le (Dict-Get $n 'categories'); $i++) {
        $id = Dict-Get $v "categories`t$i`tid" ''; $tk = Dict-Get $v "categories`t$i`ttokens" ''
        $kind = Dict-Get $v "categories`t$i`tkind" ''; if ($kind -ceq '') { $kind = if ((Dict-Get $v "categories`t$i`tisDeferred" '') -ceq 'true') { 'deferred' } else { 'used' } }
        if ($kind -ceq 'free') { continue }
        if ($id -ceq 'messages') { $R.Add("H`tmsgs`t$tk") }
        if ($kind -ceq 'buffer') { $R.Add("H`tbuffer`t$tk") } else { $R.Add("C`t$id`t" + (Dict-Get $v "categories`t$i`tname" '') + "`t$tk`t$kind`t0") }
    }
    $R.Add("G`tmemory`t`t0")
    for ($i = 1; $i -le (Dict-Get $n 'memoryFiles'); $i++) {
        $p = Dict-Get $v "memoryFiles`t$i`tpath" ''
        $R.Add("I`tmemory`t" + (Ctx-Short $p) + "`t" + (Dict-Get $v "memoryFiles`t$i`ttokens" '') + "`t" + (Dict-Get $v "memoryFiles`t$i`ttype" '') + "`t$p`t")
    }
    $R.Add("G`tskills`t`t0")
    for ($i = 1; $i -le (Dict-Get $n 'sk'); $i++) { $R.Add("I`tskills`t" + (Dict-Get $v "sk`t$i`tname" '') + "`t" + (Dict-Get $v "sk`t$i`ttokens" '') + "`t" + (Dict-Get $v "sk`t$i`tsource" '') + "`t" + (Dict-Get $v "sk`t$i`tpath" '') + "`t") }
    $R.Add("G`tmcp`t`t0")
    $nt = Dict-Get $n 'mcpTools'; $so = New-List; $st = New-Dict; $sn = New-Dict
    for ($i = 1; $i -le $nt; $i++) {
        $s = Dict-Get $v "mcpTools`t$i`tserverName" ''
        if (-not $st.ContainsKey($s)) { $so.Add($s) }
        Dict-Add $st $s (Ctx-Val (Dict-Get $v "mcpTools`t$i`ttokens" '')); Dict-Add $sn $s 1
    }
    foreach ($s in $so) { $R.Add("I`tmcp`t$s`t" + (Ctx-Num $st[$s]) + "`t" + (Ctx-Num $sn[$s]) + " 個工具`t`t") }
    for ($i = 1; $i -le $nt; $i++) {
        $R.Add("I`tmcp`t" + (Dict-Get $v "mcpTools`t$i`tname" '') + "`t" + (Dict-Get $v "mcpTools`t$i`ttokens" '') + "`t" + $(if ((Dict-Get $v "mcpTools`t$i`tisLoaded" '') -ceq 'true') { '已載入' } else { '延後載入' }) + "`t`t" + (Dict-Get $v "mcpTools`t$i`tserverName" ''))
    }
    $R.Add("G`tagents`t`t0")
    for ($i = 1; $i -le (Dict-Get $n 'agents'); $i++) {
        $an = Dict-Get $v "agents`t$i`tagentType" ''; if ($an -ceq '') { $an = Dict-Get $v "agents`t$i`tname" '' }
        $R.Add("I`tagents`t$an`t" + (Dict-Get $v "agents`t$i`ttokens" '') + "`t" + (Dict-Get $v "agents`t$i`tsource" '') + "`t`t")
    }
    if ((Ctx-Val (Dict-Get $v "sc`ttokens" '')) -gt 0) { $R.Add("G`tcommands`t`t0"); $R.Add("I`tcommands`t" + (Dict-Get $v "sc`tincludedCommands" '') + " 個指令`t" + (Dict-Get $v "sc`ttokens" '') + "`t`t`t") }
}
function Ctx-V([string]$s) { if ($s.StartsWith('"', $Ord)) { return Ctx-Unesc $s.Substring(1, $s.Length - 2) }; if ($s -ceq 'null') { '' } else { $s } }   # a leaf's value
function Ctx-Top($n, [string]$k, [string]$i) { $x = Ctx-Val $i; if ($x -gt (Dict-Get $n $k)) { $n[$k] = $x } }   # the highest item number (json counts from 1)
function Claude-Content([string]$s) { $i = $s.IndexOf('"content":', $Ord); if ($i -ge 0) { $s = $s.Substring($i) }; $j = $s.IndexOf('},"uuid":"', $Ord); if ($j -ge 0) { $s = $s.Substring(0, $j + 1) }; $s }
function Claude-MsgScan([string]$f) { # what was said since the last compaction (the transcript), by kind and by tool
    # (thinking from earlier turns is not counted: the API drops it; attachments Claude Code counts elsewhere neither)
    $a = @{ user = 0.0; meta = 0.0; reply = 0.0; summ = 0.0; tc = (New-Dict); tr = (New-Dict); tn = (New-Dict); at = (New-Dict) }
    $idn = New-Dict 'string'
    $st = Ctx-Stream $f; if (-not $st) { return $a }
    $r = $st[0]; $first = $st[1]
    try {
        while ($true) {
            if ($null -ne $first) { $l = $first; $first = $null } else { $l = $r.ReadLine(); if ($null -eq $l) { break } }
            if ($l.Contains('"isSidechain":true')) { continue }
            if ($l.Contains('"type":"system"') -and $l.Contains('"compact_boundary"')) {
                $a.user = 0.0; $a.meta = 0.0; $a.reply = 0.0; $a.summ = 0.0; $a.tc.Clear(); $a.tr.Clear(); $a.tn.Clear(); $a.at.Clear(); continue
            }
            if ($l.Contains('"type":"attachment"')) {
                $i = $l.IndexOf('"rendered":[', $Ord); if ($i -lt 0) { continue }
                $j = $l.IndexOf('"attachment":{', $Ord); $k = Ctx-Strv $(if ($j -ge 0) { $l.Substring($j) } else { $l }) 'type'
                if ($k -ceq '' -or $ClaudeSkipAt.Contains($k)) { continue }
                $s = $l.Substring($i); $j = $s.IndexOf(',"renderedRole"', $Ord); if ($j -ge 0) { $s = $s.Substring(0, $j + 1) }
                Dict-Add $a.at $k (Ctx-Wt $s); continue
            }
            if ($l.Contains('"type":"assistant"')) {
                $s = Claude-Content $l; $j = $s.IndexOf('"stop_reason"', $Ord); if ($j -ge 0) { $s = $s.Substring(0, $j + 1) }
                foreach ($p in (Ctx-Parts $s $ClaudePartRx)) {
                    if ($p.StartsWith('{"type":"text"', $Ord)) { $a.reply += $Utf8.GetByteCount((Ctx-Strv $p 'text')) / 4 }
                    elseif ($p.StartsWith('{"type":"tool_use"', $Ord) -or $p.StartsWith('{"type":"server_tool_use"', $Ord)) {
                        $nm = Ctx-Unesc (Ctx-Strv $p 'name'); $idn[(Ctx-Strv $p 'id')] = $nm; Dict-Add $a.tc $nm (Ctx-Wt $p); Dict-Add $a.tn $nm 1
                    }
                }
                continue
            }
            if ($l.Contains('"type":"user"')) {
                $s = Claude-Content $l
                if ($l.Contains('"isCompactSummary":true')) { $a.summ += Ctx-Wt $s; continue }
                if ($s.Contains('{"tool_use_id":"')) {
                    foreach ($p in (Ctx-Parts $s $ToolIdRx)) {
                        $id = $p.Substring(16); $q = $id.IndexOf('"', $Ord); $id = if ($q -ge 0) { $id.Substring(0, $q) } else { '' }
                        Dict-Add $a.tr (Dict-Get $idn $id '?') (Ctx-Wt $p)
                    }
                    continue
                }
                if ($l.Contains('"isMeta":true')) { $a.meta += Ctx-Wt $s } else { $a.user += Ctx-Wt $s }
            }
        }
    } finally { $r.Dispose() }
    $a
}
function Claude-MsgRows($a, [string]$target, $R) { # the rows of what was said, scaled to TARGET -> its own total
    $tcs = 0.0; foreach ($x in $a.tc.Values) { $tcs += $x }; $trs = 0.0; foreach ($x in $a.tr.Values) { $trs += $x }; $ats = 0.0; foreach ($x in $a.at.Values) { $ats += $x }
    $all = $a.user + $a.meta + $a.reply + $a.summ + $tcs + $trs + $ats
    $f = if ($target -cne '' -and (Ctx-Val $target) -gt 0 -and $all -gt 0) { (Ctx-Val $target) / $all } else { 1 }
    $R.Add("G`tmsgs`t`t1")
    foreach ($x in @(@('你的訊息', $a.user), @('系統附加的提示', $a.meta), @('回覆', $a.reply), @('工具呼叫', $tcs), @('工具結果', $trs), @('附加內容', $ats))) { $R.Add("I`tmsgs`t$($x[0])`t" + (Ctx-Num (Ctx-Rnd ($x[1] * $f))) + "`t`t`t") }
    if ($a.summ -gt 0) { $R.Add("I`tmsgs`t壓縮後的摘要`t" + (Ctx-Num (Ctx-Rnd ($a.summ * $f))) + "`t`t`t") }
    $R.Add("G`ttool_results`t`t1")
    foreach ($k in (Dict-Keys $a.tc $a.tr)) { $R.Add("I`ttool_results`t$k`t" + (Ctx-Num (Ctx-Rnd (((Dict-Get $a.tc $k) + (Dict-Get $a.tr $k)) * $f))) + "`t" + (Ctx-Num (Dict-Get $a.tn $k)) + " 次`t`t") }
    $R.Add("G`tattachments`t`t1")
    foreach ($k in $a.at.Keys) { $R.Add("I`tattachments`t$k`t" + (Ctx-Num (Ctx-Rnd ($a.at[$k] * $f))) + "`t`t`t") }
    Ctx-Rnd $all
}
function Claude-Detail([string]$cpid, [string]$dir, $R) { # the rows for a Claude Code
    $live = Claude-Ctx $cpid $dir; $lu = Num-Of 'used' $live; $lw = Num-Of 'window' $live; $lm = Str-Of 'model' $live
    foreach ($x in @("H`ttool`tclaude", "H`tcompact`t/compact", "H`twith_text`t1", "H`tclear`t/clear")) { $R.Add($x) }
    $sid = ''; $cwd = ''; $tp = ''
    $s = Claude-Where $cpid $dir; if ($s) { $sid = $s[0]; $cwd = $s[1]; $tp = $s[2] }
    if (-not $cwd) { $cwd = $dir }
    $R.Add("H`tsession`t$sid")
    $why = ''; $pr = New-List
    if (-not $sid) { $why = '找不到這個 Claude 的 session' }
    elseif ("$env:KIT_CTX_PROBE" -ceq '0') { $why = '沒有問 Claude Code（KIT_CTX_PROBE=0）' }
    else {
        $probe = Claude-Probe $sid $cwd
        if (-not $probe) { $why = 'Claude Code 沒有回答（太舊、沒裝在 PATH 上，或超過 ' + $(if ($env:KIT_CTX_PROBE_TIMEOUT) { $env:KIT_CTX_PROBE_TIMEOUT } else { '30' }) + ' 秒）' }
        else { Claude-ProbeRows $probe $pr; $why = Row-H $pr 'probe_error' }
    }
    $acc = if ($tp) { Claude-MsgScan $tp } else { $null }
    if ($why) {
        # Claude Code's own split is not there: the live total, and what was said estimated from the transcript
        foreach ($x in @("H`terror`t$why", ("H`tsource`t" + (Str-Of 'source' $live)), "H`tmodel`t$lm", "H`texact`t0")) { $R.Add($x) }
        $msgs = [double]0; if ($acc) { $msgs = Claude-MsgRows $acc '' (New-List) }
        if ($lu -and $msgs -gt [double]$lu) { $msgs = [double]$lu }
        if ($acc) { [void](Claude-MsgRows $acc (Ctx-Num $msgs) $R) }
        $R.Add("H`tused`t$lu"); $R.Add("H`twindow`t$lw")
        if ($lu) {
            $R.Add("C`tsystem_prompt`t=系統提示、工具、記憶檔、Skills（估算）`t" + (Ctx-Num ([double]$lu - $msgs)) + "`tused`t1"); $R.Add("C`tmessages`t`t" + (Ctx-Num $msgs) + "`tused`t1")
            if ($lw -and [long]$lw -gt [long]$lu) { $R.Add("C`tfree_space`t`t$([long]$lw - [long]$lu)`tfree`t0") }
        }
        $R.Add("H`tnote`t細項是從對話紀錄估的（大小 ÷ 4），只看得出對話裡各種內容大概佔多少。")
        return
    }
    $tot = Row-H $pr 'probe_total'; $max = Row-H $pr 'probe_max'; $mdl = Row-H $pr 'probe_model'; $msgs = Row-H $pr 'msgs'; $buf = Row-H $pr 'buffer'; $thr = Row-H $pr 'threshold'
    if (-not $mdl) { $mdl = $lm }
    $w = Setting-Window $mdl; if (-not $w) { $w = $max }; if (-not $w) { $w = $lw }
    # the live number (status line / transcript) is what the agent really has; a fresh process may not see all of it
    # (MCP servers it did not start, what came since): the difference is its own row
    $used = $tot; $other = [long]0
    if ($lu -and $tot -cmatch '^[0-9]+\z' -and [long]$lu -gt [long]$tot) { $used = $lu; $other = [long]$lu - [long]$tot }
    foreach ($x in @("H`tsource`tget_context_usage", "H`tmodel`t$mdl", "H`texact`t1", "H`tused`t$used", "H`twindow`t$w")) { $R.Add($x) }
    if ($thr) { $R.Add("H`tcompact_at`t$thr") }
    Rows-Add $R $pr
    if ($other -gt 0) { $R.Add("C`tother`t`t$other`tused`t0") }
    if ($buf) { $R.Add("C`tautocompact_buffer`t`t$buf`tbuffer`t0") }
    $free = (Ctx-Int $w) - (Ctx-Int $used) - (Ctx-Int $buf); if ($free -lt 0) { $free = 0 }
    $R.Add("C`tfree_space`t`t$free`tfree`t0")
    if ($acc) { [void](Claude-MsgRows $acc $(if ($msgs) { $msgs } else { '0' }) $R) }
    $R.Add("H`tnote`t分類是 Claude Code 自己算的；「對話內容」「工具」「附加內容」的細項是從對話紀錄估的（大小 ÷ 4，一張圖約 1600），照比例對到 Claude 算的總數。")
}
function Ctx-Int([string]$s) { if ($s -cmatch '^-?[0-9]+\z') { [long]$s } else { [long]0 } }

# ---------- Codex ----------
function Codex-Rollout([string]$dir) { # the newest rollout started in that folder ('' if none)
    if (-not $dir -or -not (Test-Path -LiteralPath (Join-Path $CodexDir 'sessions') -PathType Container)) { return '' }
    $want = '"cwd":' + (Json-S $dir)
    foreach ($f in Newest-Files (Join-Path $CodexDir 'sessions') 'rollout-*.jsonl') {
        if ("$(Get-Content -LiteralPath $f -TotalCount 1 -Encoding UTF8)".Contains($want)) { return $f }
    }
    ''
}
function Codex-InstrFiles([string]$dir) { # the AGENTS.md files Codex reads for DIR: its own (~/.codex), then each folder from the git root down
    $o = New-List
    $x = Ctx-Join $CodexDir 'AGENTS.override.md'; if ((Ctx-Size $x) -gt 0) { Ctx-Files 'Codex 帳號' @($x) $o } else { Ctx-Files 'Codex 帳號' @(Ctx-Join $CodexDir 'AGENTS.md') $o }
    if ($dir) {
        foreach ($d in (Ctx-Up $dir)) {
            if (-not $d) { continue }
            $x = Ctx-Join $d 'AGENTS.override.md'; if ((Ctx-Size $x) -gt 0) { Ctx-Files '資料夾' @($x) $o } else { Ctx-Files '資料夾' @(Ctx-Join $d 'AGENTS.md') $o }
        }
    }
    , $o
}
function Codex-Reset($S) { foreach ($k in 'sysd', 'instr', 'skills', 'mcpl', 'user', 'reply', 'other', 'comp') { $S[$k] = 0.0 }; $S.tc.Clear(); $S.tr.Clear(); $S.tn.Clear(); $S.sk.Clear(); $S.dl.Clear() }
function Codex-Tools($T, [string]$s) { # the tools Codex lists (the last list counts), by namespace
    $T.nsw.Clear(); $T.nso.Clear(); $T.tw.Clear(); $T.tlo.Clear(); $T.ns = ''
    $i = $s.IndexOf('"tools":[', $Ord); if ($i -ge 0) { $s = $s.Substring($i) }
    foreach ($p in (Ctx-Parts $s $NsRx)) {
        $ty = Ctx-Strv $p 'type'; $nm = Ctx-Unesc (Ctx-Strv $p 'name'); $w = $Utf8.GetByteCount($p) / 4
        if ($ty -ceq 'namespace') { $T.ns = $nm; if (-not $T.nsw.ContainsKey($nm)) { $T.nso.Add($nm) }; Dict-Add $T.nsw $nm $w }
        elseif ($T.ns -cne '') {
            $key = $T.ns + "`t" + $nm
            if (-not $T.tw.ContainsKey($key)) { if (-not $T.tlo.ContainsKey($T.ns)) { $T.tlo[$T.ns] = New-List }; $T.tlo[$T.ns].Add($nm) }
            Dict-Add $T.tw $key $w
        }
        else { if (-not $T.nsw.ContainsKey($nm)) { $T.nso.Add($nm) }; Dict-Add $T.nsw $nm $w }
    }
}
function Codex-Skills($S, $root, [string]$v) { # the skills Codex lists, with the folder each is in
    foreach ($m in $RootRx.Matches($v)) { $e = $m.Value.Substring(3, $m.Length - 4); $root[$e.Substring(0, $e.IndexOf('`', $Ord))] = $e.Substring($e.IndexOf('= `', $Ord) + 3) }
    $i = $v.IndexOf('### Available skills', $Ord); if ($i -lt 0) { return }
    $parts = $ItemRx.Split($v.Substring($i))
    for ($j = 1; $j -lt $parts.Count; $j++) {
        $e = $parts[$j]; $k = $e.IndexOf('\n</skills_instructions>', $Ord); if ($k -ge 0) { $e = $e.Substring(0, $k) }
        $q = $e.IndexOf(': ', $Ord); $nm = if ($q -ge 0) { $e.Substring(0, $q) } else { '' }
        $rel = ''; $m = $FileRx.Match($e); if ($m.Success) { $rel = $m.Value.Substring(7, $m.Length - 8) }
        $q = $rel.IndexOf('/', $Ord); $k = if ($q -ge 0) { $rel.Substring(0, $q) } else { '' }
        $in = $root.ContainsKey($k); if ($in) { $rel = $root[$k] + $rel.Substring($q) }
        $S.sk.Add(@((Ctx-Unesc $nm), ($Utf8.GetByteCount($e) / 4), (Ctx-Unesc $rel), $(if ($in) { Ctx-Short (Ctx-Unesc $root[$k]) } else { '' })))
    }
}
function Codex-List($S, [string]$v) { # the deferred tools Codex lists (only their names and what they are)
    $parts = $ItemRx.Split($v)
    for ($j = 1; $j -lt $parts.Count; $j++) { $e = $parts[$j]; $q = $e.IndexOf(':', $Ord); $S.dl.Add(@((Ctx-Unesc $(if ($q -ge 0) { $e.Substring(0, $q) } else { '' })), ($Utf8.GetByteCount($e) / 4))) }
}
function Codex-Scan([string]$f, [string]$total, [string]$window, $files, $mcp, $R) { # the rollout -> rows
    $S = @{ tc = (New-Dict); tr = (New-Dict); tn = (New-Dict); sk = (New-List 'object'); dl = (New-List 'object') }; Codex-Reset $S
    $T = @{ nsw = (New-Dict); nso = (New-List); tw = (New-Dict); tlo = (New-Dict 'object'); ns = '' }
    $base = 0.0; $bstart = ''; $dup = $false; $cn = New-Dict 'string'; $root = New-Dict 'string'
    $conf = New-List; foreach ($x in $mcp) { if ($x -cne '' -and -not $conf.Contains($x)) { $conf.Add($x) } }
    $st = Ctx-Stream $f
    if ($st) {
        $rd = $st[0]; $first = $st[1]
        try {
            while ($true) {
                if ($null -ne $first) { $l = $first; $first = $null } else { $l = $rd.ReadLine(); if ($null -eq $l) { break } }
                $tt = ''; $m = $TypeRx.Match($l); if ($m.Success) { $tt = $m.Value.Substring(8, $m.Length - 9) }
                $pt = ''; $i = $l.IndexOf('"payload":{"type":"', $Ord); if ($i -ge 0) { $pt = $l.Substring($i + 19); $q = $pt.IndexOf('"', $Ord); $pt = if ($q -ge 0) { $pt.Substring(0, $q) } else { '' } }
                if ($tt -ceq 'session_meta') {
                    $i = $l.IndexOf('"base_instructions":', $Ord)
                    if ($i -ge 0) {
                        $b = $l.Substring($i); $bt = if ($b.StartsWith('"base_instructions":{', $Ord)) { Ctx-Strv $b 'text' } else { Ctx-Strv $b 'base_instructions' }
                        $base = $Utf8.GetByteCount($bt) / 4; $bstart = if ($bt -ceq '') { '' } else { Ctx-Head80 $bt }
                    }
                    continue
                }
                if ($tt -ceq 'compacted') { Codex-Reset $S; $S.comp = $Utf8.GetByteCount($l) / 4; continue }
                if ($tt -cne 'response_item') { continue }
                if ($pt -ceq 'message') {
                    $role = Ctx-Strv $l 'role'
                    if ($role -ceq 'user') { $S.user += (Ctx-Imgs $l) * 1600 }
                    foreach ($m in $TxtRx.Matches($l)) {
                        $v = $m.Value.Substring(8, $m.Length - 9); $n = $Utf8.GetByteCount($v) / 4
                        if ($role -ceq 'developer') {
                            if ($bstart -cne '' -and (Ctx-Head80 $v) -ceq $bstart) { $S.sysd += $n; $dup = $true }
                            elseif ($v.StartsWith('<skills_instructions>', $Ord)) { $S.skills += $n; Codex-Skills $S $root $v }
                            elseif ($v.StartsWith('<tools>', $Ord)) { $S.mcpl += $n; Codex-List $S $v }
                            else { $S.sysd += $n }
                        } elseif ($role -ceq 'user') {
                            if ($v.StartsWith('# AGENTS.md instructions', $Ord) -or $v.StartsWith('<user_instructions>', $Ord)) { $S.instr += $n }
                            elseif ($v.StartsWith('<environment_context>', $Ord)) { $S.sysd += $n }
                            else { $S.user += $n }
                        } elseif ($role -ceq 'assistant') { $S.reply += $n }
                        else { $S.other += $n }
                    }
                    continue
                }
                if ($pt -ceq 'reasoning') { continue }
                if ($pt -ceq 'function_call' -or $pt -ceq 'custom_tool_call') {
                    $nm = Ctx-Unesc (Ctx-Strv $l 'name'); $cn[(Ctx-Strv $l 'call_id')] = $nm
                    Dict-Add $S.tc $nm ($Utf8.GetByteCount((Ctx-Strv $l $(if ($pt -ceq 'function_call') { 'arguments' } else { 'input' }))) / 4); Dict-Add $S.tn $nm 1; continue
                }
                if ($pt -ceq 'function_call_output' -or $pt -ceq 'custom_tool_call_output') {
                    $nm = Dict-Get $cn (Ctx-Strv $l 'call_id') '?'
                    $i = $l.IndexOf('"output":', $Ord); Dict-Add $S.tr $nm (Ctx-Wt $(if ($i -ge 0) { $l.Substring($i) } else { $l })); continue
                }
                if ($pt -ceq 'local_shell_call' -or $pt -ceq 'web_search_call' -or $pt -ceq 'tool_search_call') { $nm = $pt.Substring(0, $pt.Length - 5); Dict-Add $S.tc $nm ($Utf8.GetByteCount($l) / 4); Dict-Add $S.tn $nm 1; continue }
                if ($pt -ceq 'additional_tools') { Codex-Tools $T $l; continue }
                if ($pt -ceq 'compaction' -or $pt -ceq 'compaction_summary') { Codex-Reset $S; $S.comp = $Utf8.GetByteCount($l) / 4; continue }
                $S.other += $Utf8.GetByteCount($l) / 4
            }
        } finally { $rd.Dispose() }
    }
    $tcs = 0.0; foreach ($x in $S.tc.Values) { $tcs += $x }; $trs = 0.0; foreach ($x in $S.tr.Values) { $trs += $x }
    $stl = 0.0; $mcpt = 0.0; $nst = New-Dict; $ism = New-Dict 'bool'
    foreach ($ns in $T.nso) {
        $nw = Dict-Get $T.nsw $ns; $lst = Dict-Get $T.tlo $ns @()
        foreach ($nm in $lst) { $nw += $T.tw[$ns + "`t" + $nm] }
        $nst[$ns] = $nw; $ism[$ns] = ($ns.StartsWith('mcp__', $Ord) -or $conf.Contains($ns)); if ($ism[$ns]) { $mcpt += $nw } else { $stl += $nw }
    }
    $mcpt += $S.mcpl
    $raw = New-Dict
    $raw['system_prompt'] = $(if ($dup) { 0 } else { $base }) + $S.sysd; $raw['instructions'] = $S.instr; $raw['skills'] = $S.skills; $raw['system_tools'] = $stl
    $raw['mcp_tools'] = $mcpt; $raw['messages'] = $S.user + $S.reply + $tcs + $trs + $S.other; $raw['compaction'] = $S.comp
    $order = @('system_prompt', 'instructions', 'skills', 'system_tools', 'mcp_tools', 'messages', 'compaction')
    $all = 0.0; foreach ($k in $order) { $all += $raw[$k] }
    $tv = Ctx-Val $total; $has = ($total -cne '' -and $tv -gt 0 -and $all -gt 0)
    $f = if ($has) { $tv / $all } else { 1 }
    $big = ''; $sum = 0.0; $sc = New-Dict
    foreach ($k in $order) { $sc[$k] = Ctx-Rnd ($raw[$k] * $f); $sum += $sc[$k]; if ($big -ceq '' -or $sc[$k] -gt $sc[$big]) { $big = $k } }
    if ($has) { $sc[$big] += $tv - $sum }
    if ($total -ceq '') { $R.Add("H`tused`t" + (Ctx-Num (Ctx-Rnd $all))) }
    foreach ($k in $order) { $R.Add("C`t$k`t`t" + (Ctx-Num $sc[$k]) + "`tused`t1") }
    if ($window -cne '' -and (Ctx-Val $window) -gt 0) { $fr = (Ctx-Val $window) - $(if ($total -cne '' -and $tv -gt 0) { $tv } else { Ctx-Rnd $all }); $R.Add("C`tfree_space`t`t" + (Ctx-Num $(if ($fr -gt 0) { $fr } else { 0 })) + "`tfree`t0") }
    # the AGENTS.md files: their sizes, scaled to what the instructions came to
    $fs = 0.0; foreach ($x in $files) { $y = $x.Split("`t"); if ($y.Count -ge 3) { $fs += (Ctx-Val $y[1]) / 4 } }
    $R.Add("G`tinstructions`t`t1")
    foreach ($x in $files) {
        $y = $x.Split("`t"); if ($y.Count -lt 3) { continue }
        $tk = if ($S.instr -gt 0 -and $fs -gt 0) { Ctx-Num (Ctx-Rnd ((Ctx-Val $y[1]) / 4 * $sc['instructions'] / $fs)) } else { '' }
        $R.Add("I`tinstructions`t" + (Ctx-Short $y[0]) + "`t$tk`t" + $(if ($S.instr -gt 0) { $y[2] } else { '這次對話沒讀到' }) + "`t" + $y[0] + "`t")
    }
    $R.Add("G`tskills`t`t1")
    foreach ($e in $S.sk) { $R.Add("I`tskills`t" + $e[0] + "`t" + $(if ($S.skills -gt 0) { Ctx-Num (Ctx-Rnd ($e[1] * $sc['skills'] / $S.skills)) } else { '' }) + "`t" + $e[3] + "`t" + $e[2] + "`t") }
    $R.Add("G`ttools`t`t1"); $R.Add("G`tmcp`t`t1")
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($ns in $T.nso) {
        $g = if ($ism[$ns]) { 'mcp' } else { 'tools' }; $lst = @(Dict-Get $T.tlo $ns @())
        $R.Add("I`t$g`t$ns`t" + (Ctx-Num (Ctx-Rnd ($nst[$ns] * $f))) + "`t$($lst.Count) 個工具`t`t")
        foreach ($nm in $lst) { $R.Add("I`t$g`t$nm`t" + (Ctx-Num (Ctx-Rnd ($T.tw[$ns + "`t" + $nm] * $f))) + "`t`t`t$ns") }
        [void]$seen.Add($ns)
    }
    foreach ($e in $S.dl) { $R.Add("I`tmcp`t" + $e[0] + "`t" + (Ctx-Num (Ctx-Rnd ($e[1] * $f))) + "`t延後載入（只放名字和說明）`t`t"); [void]$seen.Add($e[0]) }
    foreach ($k in $conf) { if (-not $seen.Contains($k) -and -not $seen.Contains('mcp__' + $k)) { $R.Add("I`tmcp`t$k`t`t設定裡有，這次對話沒看到它的工具`t`t") } }
    $R.Add("G`tmsgs`t`t1")
    foreach ($x in @(@('你的訊息', $S.user), @('回覆', $S.reply), @('工具呼叫', $tcs), @('工具結果', $trs), @('其他', $S.other))) { $R.Add("I`tmsgs`t$($x[0])`t" + (Ctx-Num (Ctx-Rnd ($x[1] * $f))) + "`t`t`t") }
    $R.Add("G`ttool_results`t`t1")
    foreach ($k in (Dict-Keys $S.tc $S.tr)) { $R.Add("I`ttool_results`t$k`t" + (Ctx-Num (Ctx-Rnd (((Dict-Get $S.tc $k) + (Dict-Get $S.tr $k)) * $f))) + "`t" + (Ctx-Num (Dict-Get $S.tn $k)) + " 次`t`t") }
}
function Codex-Detail([string]$dir, $R) { # the rows for a Codex
    foreach ($x in @("H`ttool`tcodex", "H`tcompact`t/compact", "H`twith_text`t0", "H`tclear`t/new", "H`tsource`trollout", "H`texact`t0")) { $R.Add($x) }
    $f = Codex-Rollout $dir; if (-not $f) { $R.Add("H`terror`t找不到這個資料夾的 Codex 對話紀錄（~/.codex/sessions）"); return }
    $c = Codex-Ctx $dir; $u = Num-Of 'used' $c; $w = Num-Of 'window' $c
    foreach ($x in @(("H`tmodel`t" + (Str-Of 'model' $c)), "H`tused`t$u", "H`twindow`t$w", ("H`tpct`t" + (Num-Of 'pct' $c)))) { $R.Add($x) }
    if ((Ctx-Size $f) -gt $CtxDetailTail) { $R.Add("H`tbig`t1") }
    $mcp = New-List; $cf = Ctx-Join $CodexDir 'config.toml'
    if (Test-Path -LiteralPath $cf -PathType Leaf) { foreach ($l in (Read-Text $cf).Split("`n")) { $m = $McpTomlRx.Match($l); if ($m.Success) { $mcp.Add($m.Groups[1].Value.Replace('"', '')) } } }
    Codex-Scan $f $u $w (Codex-InstrFiles $dir) $mcp $R
    $R.Add("H`tnote`t總數是 Codex 自己記的（最後一次 token_count）；分到各類是從對話紀錄估的（大小 ÷ 4），照比例對到總數。Codex 自己顯示的 % 會先扣掉 12000（它的基本用量）。")
}

# ---------- omp ----------
function Omp-InstrFiles([string]$dir) { # the instruction files omp may read for DIR (omp reads several tools' ones; a guess from what is there)
    $o = New-List
    Ctx-Files 'omp 帳號' @(Ctx-Join $OmpDir 'AGENTS.md') $o
    Ctx-Files 'Claude 帳號' @(Ctx-Join $ClaudeDir 'CLAUDE.md') $o
    if ($dir) {
        foreach ($d in (Ctx-Up $dir)) {
            if (-not $d -or (Ctx-SamePath $d $UserHome)) { continue }
            Ctx-Files '資料夾' @((Ctx-Join $d 'AGENTS.md'), (Ctx-Join $d 'CLAUDE.md'), (Ctx-Join (Ctx-Join $d '.omp') 'AGENTS.md'), (Ctx-Join (Ctx-Join $d '.claude') 'CLAUDE.md')) $o
        }
    }
    , $o
}
function Omp-SkillFiles([string]$dir) { # "name TAB bytes TAB path TAB where" for the skills omp may list: their name and description
    # ("where" as unix/kit has it: the skill's folder name)
    $o = New-List; $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $ds = @((Ctx-Join $OmpDir 'skills'), $AgentsSkills, (Ctx-Join $ClaudeDir 'skills'))
    if ($dir) { $ds += @((Ctx-Join (Ctx-Join $dir '.omp') 'skills'), (Ctx-Join (Ctx-Join $dir '.agents') 'skills'), (Ctx-Join (Ctx-Join $dir '.claude') 'skills')) }
    foreach ($d in $ds) {
        if (-not [IO.Directory]::Exists($d)) { continue }
        $subs = [string[]]@(foreach ($x in [IO.Directory]::GetDirectories($d)) { $n = [IO.Path]::GetFileName($x); if (-not $n.StartsWith('.', $Ord)) { $n } })
        [Array]::Sort($subs, [StringComparer]::Ordinal)
        foreach ($n in $subs) {
            $f = Ctx-Join (Ctx-Join $d $n) 'SKILL.md'
            try { $text = [IO.File]::ReadAllText($f, $Utf8) } catch { continue }
            $nm = $n; $w = $n; $nn = ''; $de = ''; $c = 0
            foreach ($l in $text.Split("`n")) {
                if ($l -ceq '---') { $c++; if ($c -eq 2) { break }; continue }
                if ($c -eq 1 -and $l.StartsWith('name:', $Ord)) { $nn = $l -creplace '^name:[ \t]*', '' }
                if ($c -eq 1 -and $l.StartsWith('description:', $Ord)) { $de = $l -creplace '^description:[ \t]*', '' }
            }
            if ($nn -cne '') { $nm = $nn }
            if (-not $seen.Add($nm)) { continue }
            $o.Add("$nm`t$($Utf8.GetByteCount($nm) + $Utf8.GetByteCount($de) + 20)`t$f`t$(Ctx-Short $w)")
        }
    }
    , $o
}
function Omp-Num([string]$s, [string]$k) { $m = [regex]::Match($s, '"' + $k + '":([0-9]+)'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
function Omp-MsgText([string]$s) { $i = $s.IndexOf(',"details":', $Ord); if ($i -ge 0) { $s.Substring(0, $i) } else { $s } }   # what is sent (not "details")
function Omp-DetailScan([string]$f, [string]$total, [string]$window, $files, $skills, $mcp, $R) { # the session -> rows
    $ek = New-List; $en = New-List; $ew = New-List 'double'; $el = New-List 'long'
    $lid = New-Dict 'long'; $cl = [long]0; $keep = ''; $summ = 0.0; $rb = $false; $nmt = ''; $tst = ''; $nr = [long]0
    $st = Ctx-Stream $f
    if ($st) {
        $rd = $st[0]; $first = $st[1]
        try {
            while ($true) {
                if ($null -ne $first) { $l = $first; $first = $null } else { $l = $rd.ReadLine(); if ($null -eq $l) { break } }
                $nr++
                $id = Ctx-Strv (Ctx-Head $l 200) 'id'; if ($id -cne '') { $lid[$id] = $nr }
                if ($l.StartsWith('{"type":"compaction"', $Ord)) { $cl = $nr; $keep = Ctx-Strv $l 'firstKeptEntryId'; $summ = $Utf8.GetByteCount((Ctx-Strv $l 'summary')) / 4; $rb = $false; continue }
                if ($l.StartsWith('{"type":"reset_boundary"', $Ord)) { $cl = $nr; $keep = ''; $summ = 0.0; $rb = $true; continue }
                if ($l.StartsWith('{"type":"custom_message"', $Ord)) { $ek.Add('at'); $en.Add((Ctx-Strv $l 'customType')); $ew.Add((Ctx-Wt (Omp-MsgText $l))); $el.Add($nr); continue }
                if (-not $l.StartsWith('{"type":"message"', $Ord)) { continue }
                $role = Ctx-Strv $l 'role'; $s = Omp-MsgText $l
                if ($role -ceq 'assistant') {
                    if ($l.Contains('"stopReason":"aborted"') -or $l.Contains('"stopReason":"error"')) { continue }
                    $i = $l.IndexOf('"contextSnapshot":{', $Ord); if ($i -ge 0) { $cs = $l.Substring($i); $nmt = Omp-Num $cs 'nonMessageTokens'; $tst = Omp-Num $cs 'toolSchemaTokens' }
                    foreach ($p in (Ctx-Parts $s $OmpPartRx)) {
                        if ($p.StartsWith('{"type":"text"', $Ord)) { $ek.Add('reply'); $en.Add(''); $ew.Add($Utf8.GetByteCount((Ctx-Strv $p 'text')) / 4); $el.Add($nr) }
                        elseif ($p.StartsWith('{"type":"toolCall"', $Ord)) { $ek.Add('tc'); $en.Add((Ctx-Unesc (Ctx-Strv $p 'name'))); $ew.Add((Ctx-Wt $p)); $el.Add($nr) }
                    }
                } elseif ($role -ceq 'toolResult') { $nm = Ctx-Unesc (Ctx-Strv $l 'toolName'); if ($nm -ceq '') { $nm = '?' }; $ek.Add('tr'); $en.Add($nm); $ew.Add((Ctx-Wt $s)); $el.Add($nr) }
                elseif ($role -ceq 'user') { $ek.Add('user'); $en.Add(''); $ew.Add((Ctx-Wt $s)); $el.Add($nr) }
                else { $ek.Add('other'); $en.Add($role); $ew.Add((Ctx-Wt $s)); $el.Add($nr) }
            }
        } finally { $rd.Dispose() }
    }
    $start = [long]1
    if ($cl) { $start = $cl + 1; if ($keep -cne '' -and $lid.ContainsKey($keep) -and $lid[$keep] -lt $cl) { $start = $lid[$keep] } }
    $tc = New-Dict; $tr = New-Dict; $tn = New-Dict; $at = New-Dict; $raw = New-Dict; $tcs = 0.0; $trs = 0.0; $ats = 0.0
    for ($e = 0; $e -lt $ek.Count; $e++) {
        if ($el[$e] -lt $start -or $el[$e] -eq $cl) { continue }
        $k = $ek[$e]; $wv = $ew[$e]
        if ($k -ceq 'tc') { Dict-Add $tc $en[$e] $wv; Dict-Add $tn $en[$e] 1; $tcs += $wv }
        elseif ($k -ceq 'tr') { Dict-Add $tr $en[$e] $wv; $trs += $wv }
        elseif ($k -ceq 'at') { Dict-Add $at $en[$e] $wv; $ats += $wv }
        else { Dict-Add $raw $k $wv }
    }
    if ($cl -and -not $rb) { $raw['summ'] = $summ }
    $ru = Dict-Get $raw 'user'; $rr = Dict-Get $raw 'reply'; $ro = Dict-Get $raw 'other'; $rs = Dict-Get $raw 'summ'
    $all = $ru + $rr + $tcs + $trs + $ats + $ro + $rs
    $fsz = 0.0; foreach ($x in $files) { $y = $x.Split("`t"); if ($y.Count -ge 3) { $fsz += (Ctx-Val $y[1]) / 4 } }
    $ssz = 0.0; foreach ($x in $skills) { $y = $x.Split("`t"); if ($y.Count -ge 4) { $ssz += (Ctx-Val $y[1]) / 4 } }
    $tv = Ctx-Val $total
    if ($nmt -cne '' -and $total -cne '') {
        # the numbers omp keeps: what is not the conversation, and of that the tools
        $tools = Ctx-Val $tst; $rest = (Ctx-Val $nmt) - $tools; if ($rest -lt 0) { $rest = 0 }
        $fi = $fsz; $sk = $ssz; if ($fi + $sk -gt $rest) { if ($fi + $sk -gt 0) { $fi = Ctx-Rnd ($fsz * $rest / ($fsz + $ssz)); $sk = $rest - $fi } }
        $fi = Ctx-Rnd $fi; $sk = Ctx-Rnd $sk; $sp = $rest - $fi - $sk
        $mt = $tv - (Ctx-Val $nmt); if ($mt -lt 0) { $mt = 0 }
        $R.Add("C`tsystem_prompt`t`t" + (Ctx-Num $sp) + "`tused`t1"); $R.Add("C`tsystem_tools`t`t" + (Ctx-Num $tools) + "`tused`t0")
        $R.Add("C`tinstructions`t`t" + (Ctx-Num $fi) + "`tused`t1"); $R.Add("C`tskills`t`t" + (Ctx-Num $sk) + "`tused`t1")
    } else {
        $ar = Ctx-Rnd $all; $mt = if ($total -cne '') { $tv } else { $ar }; if ($mt -gt $ar) { $mt = $ar }
        $sp = $(if ($total -cne '') { $tv } else { $ar }) - $mt; $fi = 0; $sk = 0
        $R.Add("C`tsystem_prompt`t=系統提示、工具、指示檔、Skills（估算）`t" + (Ctx-Num $sp) + "`tused`t1")
    }
    $f = if ($all -gt 0) { $mt / $all } else { 1 }
    $cm = Ctx-Rnd ($rs * $f); $R.Add("C`tmessages`t`t" + (Ctx-Num ($mt - $cm)) + "`tused`t1"); $R.Add("C`tcompaction`t`t" + (Ctx-Num $cm) + "`tused`t1")
    if ($window -cne '' -and (Ctx-Val $window) -gt 0 -and $total -cne '') { $fr = (Ctx-Val $window) - $tv; $R.Add("C`tfree_space`t`t" + (Ctx-Num $(if ($fr -gt 0) { $fr } else { 0 })) + "`tfree`t0") }
    $R.Add("G`tinstructions`t`t1")
    foreach ($x in $files) { $y = $x.Split("`t"); if ($y.Count -ge 3) { $R.Add("I`tinstructions`t" + (Ctx-Short $y[0]) + "`t" + $(if ($fsz -gt 0 -and $fi -gt 0) { Ctx-Num (Ctx-Rnd ((Ctx-Val $y[1]) / 4 * $fi / $fsz)) } else { '' }) + "`t" + $y[2] + "`t" + $y[0] + "`t") } }
    $R.Add("G`tskills`t`t1")
    foreach ($x in $skills) { $y = $x.Split("`t"); if ($y.Count -ge 4) { $R.Add("I`tskills`t" + $y[0] + "`t" + $(if ($ssz -gt 0 -and $sk -gt 0) { Ctx-Num (Ctx-Rnd ((Ctx-Val $y[1]) / 4 * $sk / $ssz)) } else { '' }) + "`t" + $y[3] + "`t" + $y[2] + "`t") } }
    $R.Add("G`tmcp`t`t1")
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $mcp) { if ($x -cne '' -and $seen.Add($x)) { $R.Add("I`tmcp`t$x`t`t設定的 MCP（它的工具算在「系統工具」）`t`t") } }
    $R.Add("G`tmsgs`t`t1")
    foreach ($x in @(@('你的訊息', $ru), @('回覆', $rr), @('工具呼叫', $tcs), @('工具結果', $trs), @('附加內容', $ats), @('其他', $ro))) { $R.Add("I`tmsgs`t$($x[0])`t" + (Ctx-Num (Ctx-Rnd ($x[1] * $f))) + "`t`t`t") }
    if ($cm -gt 0) { $R.Add("I`tmsgs`t壓縮後的摘要`t" + (Ctx-Num $cm) + "`t`t`t") }
    $R.Add("G`ttool_results`t`t1")
    foreach ($k in (Dict-Keys $tc $tr)) { $R.Add("I`ttool_results`t$k`t" + (Ctx-Num (Ctx-Rnd (((Dict-Get $tc $k) + (Dict-Get $tr $k)) * $f))) + "`t" + (Ctx-Num (Dict-Get $tn $k)) + " 次`t`t") }
    $R.Add("G`tattachments`t`t1")
    foreach ($k in $at.Keys) { $R.Add("I`tattachments`t$k`t" + (Ctx-Num (Ctx-Rnd ($at[$k] * $f))) + "`t`t`t") }
}
function Omp-Detail([string]$opid, [string]$dir, $R) { # the rows for an omp
    foreach ($x in @("H`ttool`tomp", "H`tcompact`t/compact", "H`twith_text`t1", "H`tclear`t/new", "H`tsource`tsession", "H`texact`t0")) { $R.Add($x) }
    $f = Omp-Session $opid $dir; if (-not $f) { $R.Add("H`terror`t找不到這個 omp 的 session（~/.omp/agent/sessions）"); return }
    $c = Omp-Ctx $opid $dir
    foreach ($x in @(("H`tmodel`t" + (Str-Of 'model' $c)), ("H`tused`t" + (Num-Of 'used' $c)), ("H`twindow`t" + (Num-Of 'window' $c)))) { $R.Add($x) }
    $mcp = New-List; $mf = @(Ctx-Join $OmpDir 'mcp.json'); if ($dir) { $mf += @((Ctx-Join (Ctx-Join $dir '.omp') 'mcp.json'), (Ctx-Join $dir '.mcp.json')) }
    foreach ($x in $mf) { if (Test-Path -LiteralPath $x -PathType Leaf) { foreach ($k in @(Json-Keys $x @('mcpServers'))) { $mcp.Add($k) } } }
    Omp-DetailScan $f (Num-Of 'used' $c) (Num-Of 'window' $c) (Omp-InstrFiles $dir) (Omp-SkillFiles $dir) $mcp $R
    $R.Add("H`tnote`t總數和「系統工具」是 omp 自己記的（最後一次回覆的 context 快照）；其他分類和細項是從檔案和對話紀錄估的（大小 ÷ 4），照比例對到 omp 的數字。指示檔和 skills 是照現在的檔案估的。")
}

function Ctx-Rows([string]$cpid, [string]$tool, [string]$dir, $R) { # the rows for one agent
    if ($tool -ceq 'claude') { Claude-Detail $cpid $dir $R }
    elseif ($tool -ceq 'codex') { Codex-Detail $dir $R }
    elseif ($tool -ceq 'omp') { Omp-Detail $cpid $dir $R }
    else { $R.Add("H`terror`t不是 Claude Code、Codex 或 omp") }
}
function Ctx-Detail([string]$cpid, [string]$tool, [string]$dir, [bool]$fresh) { # the detail JSON, kept a minute
    $f = Join-Path $CtxDir "detail-$cpid.json"; $now = Unix-Now
    $ttl = if ($env:KIT_CTX_DETAIL_TTL) { $env:KIT_CTX_DETAIL_TTL } else { '60' }
    if (-not $fresh -and (Test-Path -LiteralPath $f -PathType Leaf)) {
        $j = ''; try { $j = (Read-Text $f).TrimEnd("`n") } catch { }
        $at = Num-Of 'at' $j
        if ($at -and $ttl -cmatch '^-?[0-9]+\z' -and $now - [long]$at -lt [long]$ttl -and $now - [long]$at -ge 0 -and (Str-Of 'tool' $j) -ceq $tool) { [Console]::Out.Write($j + "`n"); return }
    }
    $R = New-List
    Ctx-Rows $cpid $tool $dir $R
    $j = Ctx-Assemble $R ([string]$now)
    try { Ensure-Dir $CtxDir; $tmp = "$f.$PID"; [IO.File]::WriteAllText($tmp, $j + "`n", $Utf8); Move-Item -LiteralPath $tmp -Destination $f -Force } catch { }
    [Console]::Out.Write($j + "`n")
}

# ---------- kit files: the files an agent read or changed ----------
# The same JSON line as unix/kit (its comments there say what is taken from each tool's log). Only paths are taken from
# a log, and of what was said only the start of the person's messages (turns' "text", 30 characters at most). Each
# log: its last KIT_CTX_TAIL bytes (8 MB).
$script:FilesMax = 200
$script:TurnsMax = 30
$script:TurnFiles = 50
$script:FilesNoTurn = [string][char]1
$script:FilesTsNormRx = [regex]'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?\z'
$script:FilesLeadRx = [regex]'^(?:[ \t]|\\[nrtf])+'
$script:FilesSkipRx = [regex]'^(?:<command-name>|<command-message>|<local-command-stdout>|<local-command-caveat>|Caveat:|\[Request interrupted|<task-notification>|<bash-input>|<bash-stdout>|<bash-stderr>|<environment_context>|<user_instructions>)'
$script:FilesStrRx = [regex]'^"((?:[^"\\]|\\.)*)"'
function Files-Div([long]$a, [long]$b) { [long][Math]::Truncate($a / $b) }   # (as awk's int(a / b))
function Files-TsNorm([string]$x) { # a timestamp as YYYY-MM-DDTHH:MM:SSZ (UTC), else ''
    $m = $FilesTsNormRx.Match($x); if (-not $m.Success) { return '' }
    $z = $m.Groups[2].Value
    if (-not $z -or $z -ceq 'Z') { return $x.Substring(0, 19) + 'Z' }
    [long]$o = ([int]$z.Substring(1, 2) * 60 + [int]$z.Substring($z.Length - 2, 2)) * $(if ($z[0] -ceq [char]'-') { -1 } else { 1 })
    [long]$y = [int]$x.Substring(0, 4); [long]$mo = [int]$x.Substring(5, 2); [long]$d = [int]$x.Substring(8, 2)
    if ($mo -le 2) { $y-- }; $era = Files-Div $y 400; $yoe = $y - $era * 400   # (days from 1970-01-01: H. Hinnant)
    $doe = $yoe * 365 + (Files-Div $yoe 4) - (Files-Div $yoe 100) + (Files-Div (153 * $(if ($mo -gt 2) { $mo - 3 } else { $mo + 9 }) + 2) 5) + $d - 1
    $mi = ($era * 146097 + $doe - 719468) * 1440 + [int]$x.Substring(11, 2) * 60 + [int]$x.Substring(14, 2) - $o
    $dd = Files-Div $mi 1440; if ($dd * 1440 -gt $mi) { $dd-- }; $mi -= $dd * 1440
    $dd += 719468; $era = Files-Div $dd 146097; $doe = $dd - $era * 146097
    $yoe = Files-Div ($doe - (Files-Div $doe 1460) + (Files-Div $doe 36524) - (Files-Div $doe 146096)) 365
    $y = $yoe + $era * 400; $doe -= 365 * $yoe + (Files-Div $yoe 4) - (Files-Div $yoe 100); $mp = Files-Div (5 * $doe + 2) 153
    $d = $doe - (Files-Div (153 * $mp + 2) 5) + 1; $mo = if ($mp -lt 10) { $mp + 3 } else { $mp - 9 }; if ($mo -le 2) { $y++ }
    $y.ToString($Inv) + '-' + $mo.ToString('00', $Inv) + '-' + $d.ToString('00', $Inv) + 'T' + (Files-Div $mi 60).ToString('00', $Inv) + ':' + ($mi % 60).ToString('00', $Inv) + ':' + $x.Substring(17, 2) + 'Z'
}
function Files-Text([string]$s) { # the start of a message (S: JSON-escaped) for a turn, still escaped (as ttext in unix/kit);
    # FilesNoTurn: not a message the person sent
    while ($true) {
        $s = $FilesLeadRx.Replace($s, '', 1)
        if (-not $s.StartsWith('<system-reminder>', $Ord)) { break }
        $i = $s.IndexOf('</system-reminder>', $Ord); if ($i -lt 0) { return '' }
        $s = $s.Substring($i + 18)
    }
    if ($FilesSkipRx.IsMatch($s)) { return $FilesNoTurn }
    if ($s.StartsWith('<hc from=\"', $Ord) -and ($i = $s.IndexOf('\">', 11, $Ord)) -ge 0) {
        $s = 'hc ' + $s.Substring(11, $i - 11) + '：' + $s.Substring($i + 3).Replace('</hc>', '')
    }
    $o = New-Object Text.StringBuilder; $n = 0; $sp = $false; $cut = $false; $L = $s.Length; $i = 0
    while ($i -lt $L) {
        $c = [string]$s[$i]; $w = $false; $st = $true
        if ($c -ceq '\') {
            $e = if ($i + 1 -lt $L) { [string]$s[$i + 1] } else { '' }
            if ($e -ceq 'u') {
                $h = $s.Substring($i + 2, [Math]::Min(4, $L - $i - 2)).ToLowerInvariant()
                if ($h -cnotmatch '^[0-9a-f]{4}\z') { $i += 2; continue }
                $i += 6
                if ($h -cmatch '^00[01]' -or $h -ceq '007f') { if ([string]::CompareOrdinal($h, '0009') -ge 0 -and [string]::CompareOrdinal($h, '000d') -le 0) { $w = $true } else { continue } }
                else { $c = '\u' + $h; if ($h -cmatch '^d[c-f]') { $st = $false } }   # (a low surrogate: the same character)
            } elseif ($e -ceq 'n' -or $e -ceq 'r' -or $e -ceq 't' -or $e -ceq 'f') { $w = $true; $i += 2 }
            elseif ($e -ceq 'b') { $i += 2; continue }
            elseif ($e -ceq '"' -or $e -ceq '\') { $c = '\' + $e; $i += 2 }
            else { $c = $e; $i += 2 }
        } else {
            $i++; $v = [int][char]$c
            if ($v -eq 32 -or ($v -ge 9 -and $v -le 13)) { $w = $true }
            elseif ($v -lt 32 -or $v -eq 127) { continue }
            elseif ($v -ge 0xDC00 -and $v -le 0xDFFF) { $st = $false }               # (a low surrogate: the same character)
        }
        if ($w) { $sp = $true; continue }
        if ($st) {
            if ($sp -and $n -gt 0) { if ($n -eq 30) { $cut = $true; break }; [void]$o.Append(' '); $n++ }
            $sp = $false
            if ($n -eq 30) { $cut = $true; break }
            $n++
        }
        [void]$o.Append($c)
    }
    $r = $o.ToString()
    if ($cut) { if ($r.EndsWith(' ', $Ord)) { $r = $r.Substring(0, $r.Length - 1) }; $r += '…' }
    $r
}
function Files-FirstText([string]$s) { # the first text item in S (an array of content items) that has words, JSON-escaped
    while (($i = $s.IndexOf('{"type":"text","text":"', $Ord)) -ge 0) {
        $s = $s.Substring($i + 15); $x = Ctx-Strv $s 'text'; if ((Files-Text $x) -cne '') { return $x }
    }
    ''
}
function Files-FirstTs([string]$l) { $m = $FilesTsRx.Match($l); if ($m.Success) { $m.Value.Substring(13, $m.Length - 14) } else { '' } }
function Files-MsgText([string]$s) { # the message (S: from its content on): a string, or the first text in an array of items
    if ($s.StartsWith('"', $Ord)) { $m = $FilesStrRx.Match($s); if ($m.Success) { return $m.Groups[1].Value }; return '' }
    Files-FirstText $s
}
$script:FilesZero = '00000000000000000'
$script:FilesTsRx = [regex]'"timestamp":"[^"]*"'
$script:FilesChangeRx = [regex]'"(?:[^"\\]|\\.)*":\{(?:"type":)?"(add|update|delete)"'
$script:FilesKindRx = [regex]'"path":"((?:[^"\\]|\\.)*)","kind":\{"type":"(add|update|delete)"'
$script:FilesMoveRx = [regex]'"move_path":"((?:[^"\\]|\\.)*)"'
$script:FilesPatchRx = [regex]'\*\*\* (Add File|Update File|Delete File|Move to): '
$script:FilesHashRx = [regex]'(?:^|\\n)\[([^\]]+)#[0-9A-Za-z]+\]\\n'
$script:FilesUriRx = [regex]'^[A-Za-z][A-Za-z0-9+.-]+://'
function Files-Ptxt([string]$s, [int]$lv) { # the path after "*** Add File: " up to the end of its line (LV: 2 when the patch is a string in a string)
    $o = New-Object Text.StringBuilder; $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -eq [char]'"') { break }
        if ($c -eq [char]'\') {
            if ($lv -eq 1 -and $i + 1 -lt $s.Length -and $s[$i + 1] -eq [char]'\') { [void]$o.Append('\'); $i += 2; continue }
            if ($lv -eq 1 -and $i + 1 -lt $s.Length -and $s[$i + 1] -eq [char]'/') { [void]$o.Append('/'); $i += 2; continue }
            if ($lv -eq 2 -and $i + 3 -lt $s.Length -and $s.Substring($i, 4) -ceq '\\\\') { [void]$o.Append('\'); $i += 4; continue }
            break
        }
        [void]$o.Append($c); $i++
    }
    $o.ToString().TrimEnd([char]' ', [char]"`t")
}
function Files-Scan([string]$tool, [string]$f, [int]$fi, [bool]$main, $Keys, $Vals) { # the rows of one log: a sort key (time, file, n) in
    # KEYS, in VALS @(tag, path, turn) (turn: the main log's turn number, - for a sub-agent's) or a turn's start @('turn', '', n, at, text)
    $o = Ctx-Open $f $CtxTail; if (-not $o) { return }
    $t = ''; $r = 0; $tn = 0; $last = ''; $touched = $false
    try {
        while ($null -ne ($l = $o[0].ReadLine())) {
            $add = New-Object 'System.Collections.Generic.List[object]'; $traw = $null; $tat = ''
            if ($tool -ceq 'claude') {
                if ($l.StartsWith('{"type":"api-request', $Ord)) { continue }
                $k = -1; if ($main -and $l.Contains('"type":"user"')) { $k = $l.IndexOf('"message":{"role":"user","content":', $Ord) }
                if ($k -ge 0 -and -not $l.Contains('"isMeta":true') -and -not $l.Contains('"isCompactSummary":true')) {
                    $ms = $FilesTsRx.Matches($l)
                    $x = ''; if ($ms.Count -gt 0) { $x = $ms[$ms.Count - 1].Value; $x = $x.Substring(13, $x.Length - 14) }
                    if ($x) { $t = (($x -creplace '[^0-9]', '') + $FilesZero).Substring(0, 17) } elseif (-not $t) { $t = $FilesZero }
                    $s = $l.Substring($k + 35)
                    if ($s.StartsWith('[', $Ord) -and $s.Contains('"type":"tool_result"')) { continue }
                    $traw = Files-MsgText $s; $tat = $x
                } elseif (-not $l.Contains('"type":"assistant"') -or -not $l.Contains('"type":"tool_use"')) { continue }
            }
            if ($tool -ceq 'claude' -and $null -eq $traw) {
                $ms = $FilesTsRx.Matches($l)
                $x = ''; if ($ms.Count -gt 0) { $x = $ms[$ms.Count - 1].Value; $x = $x.Substring(13, $x.Length - 14) }
                if ($x) { $t = (($x -creplace '[^0-9]', '') + $FilesZero).Substring(0, 17) } elseif (-not $t) { $t = $FilesZero }
                $s = $l; $i = $s.IndexOf('"type":"tool_use"', $Ord)
                while ($i -ge 0) {
                    $s = $s.Substring($i + 17); $i = $s.IndexOf('"type":"tool_use"', $Ord)
                    $seg = if ($i -ge 0) { $s.Substring(0, $i) } else { $s }
                    $n = Ctx-Strv $seg 'name'; $g = ''
                    if ($n -ceq 'Read') { $g = 'read' } elseif ($n -ceq 'Write') { $g = 'write' } elseif ($n -ceq 'Edit' -or $n -ceq 'MultiEdit' -or $n -ceq 'NotebookEdit') { $g = 'edit' }
                    if (-not $g) { continue }
                    $p = Ctx-Strv $seg 'file_path'; if (-not $p) { $p = Ctx-Strv $seg 'notebook_path' }
                    if ($p) { $add.Add(@($g, (Ctx-Unesc $p))) }
                }
            } elseif ($tool -ceq 'codex') {
                $t = $FilesZero
                $i = $l.IndexOf('"changes":', $Ord); $u = -1; $j = -1
                if ($l.Contains('"type":"event_msg"')) { $u = $l.IndexOf('"payload":{"type":"user_message"', $Ord) }
                if ($u -lt 0 -and $l.Contains('"type":"item_completed"')) { $j = $l.IndexOf('"item":{"type":"UserMessage"', $Ord) }
                if ($u -ge 0) {
                    $s = $l.Substring($u + 10); $k = Ctx-Strv $s 'kind'; if ($k -and $k -cne 'plain') { continue }
                    $traw = Ctx-Strv $s 'message'; $tat = Files-FirstTs $l
                } elseif ($j -ge 0) {
                    $s = $l.Substring($j); $k = $s.IndexOf('"content":[', $Ord); if ($k -lt 0) { continue }
                    $traw = Files-FirstText $s.Substring($k + 11); $tat = Files-FirstTs $l
                } elseif (($l.Contains('"type":"FileChange"') -or $l.Contains('"type":"patch_apply_')) -and $i -ge 0) {
                    $s = $l.Substring($i + 10)
                    foreach ($m in $FilesChangeRx.Matches($s)) {
                        $v = $m.Value; $add.Add(@($(if ($m.Groups[1].Value -ceq 'add') { 'write' } else { 'edit' }), (Ctx-Unesc $v.Substring(1, $v.IndexOf('":{', $Ord) - 1))))
                    }
                    foreach ($m in $FilesKindRx.Matches($s)) { $add.Add(@($(if ($m.Groups[2].Value -ceq 'add') { 'write' } else { 'edit' }), (Ctx-Unesc $m.Groups[1].Value))) }
                    foreach ($m in $FilesMoveRx.Matches($s)) { $add.Add(@('edit', (Ctx-Unesc $m.Groups[1].Value))) }
                } elseif ($l.Contains('"type":"custom_tool_call"') -or $l.Contains('"type":"function_call"')) {
                    $pos = 0
                    foreach ($m in $FilesPatchRx.Matches($l)) {
                        $b = [Math]::Max($pos, $m.Index - 3); $lv = if ($l.Substring($b, $m.Index - $b) -ceq '\\n') { 2 } else { 1 }
                        $pos = $m.Index + $m.Length
                        $add.Add(@($(if ($m.Groups[1].Value -ceq 'Add File') { 'write' } else { 'edit' }), (Files-Ptxt $l.Substring($pos) $lv)))
                    }
                }
            } elseif ($tool -ceq 'omp') {
                $t = $FilesZero; $k = -1
                if ($l.Contains('"type":"message"')) { $k = $l.IndexOf('"message":{"role":"user","content":', $Ord) }
                if ($k -ge 0) { $traw = Files-MsgText $l.Substring($k + 35); $tat = Files-FirstTs $l }
                elseif (-not $l.Contains('"role":"assistant"') -or -not $l.Contains('{"type":"toolCall"')) { continue }
                $s = $l; $i = $s.IndexOf('{"type":"toolCall"', $Ord)
                while ($i -ge 0) {
                    $s = $s.Substring($i + 18); $i = $s.IndexOf('{"type":"toolCall"', $Ord)
                    $seg = if ($i -ge 0) { $s.Substring(0, $i) } else { $s }
                    $n = Ctx-Strv $seg 'name'; if ($n -cne 'read' -and $n -cne 'edit' -and $n -cne 'write') { continue }
                    $k = $seg.IndexOf('"arguments":{', $Ord); if ($k -lt 0) { continue }
                    $a = $seg.Substring($k + 12); $p = Ctx-Unesc (Ctx-Strv $a 'path')
                    if ($n -ceq 'read') { $p = $p -creplace ':[0-9][0-9,-]*\z', '' }
                    $add.Add(@($n, $p))
                    if ($n -cne 'edit') { continue }
                    $x = Ctx-Strv $a 'input'; $q = 0   # hashline edits: a [path#hash] line before each file
                    while (($m = $FilesHashRx.Match($x, $q)).Success) { $add.Add(@('edit', (Ctx-Unesc $m.Groups[1].Value))); $q = $m.Index + $m.Length - 2 }
                }
            }
            if ($null -ne $traw) {   # a turn starts (Codex: a version that writes both a user_message event and a UserMessage item: one turn)
                if ($tool -ceq 'codex' -and $traw -ceq $last -and -not $touched) { continue }
                $x = Files-Text $traw; if ($x -ceq '' -or $x -ceq $FilesNoTurn) { continue }
                $r++; $tn++; $Keys.Add($t + '000000' + $r.ToString('D10', $Inv)); $Vals.Add(@('turn', '', [string]$tn, (Files-TsNorm $tat), $x))
                $last = $traw; $touched = $false; continue
            }
            $tu = if ($main) { [string]$tn } else { '-' }
            foreach ($e in $add) {
                if (-not $e[1] -or ($tool -ceq 'omp' -and $FilesUriRx.IsMatch($e[1]))) { continue }
                $r++; $Keys.Add($t + $fi.ToString('D6', $Inv) + $r.ToString('D10', $Inv)); $Vals.Add(@($e[0], $e[1], $tu)); $touched = $true
            }
        }
    } finally { $o[0].Dispose() }
}
function Files-Rows([string]$tool, [string]$log) { # @(tag, path, turn) of every file the log (and, Claude, its sub-agents) shows, and the turns' starts, oldest first
    if (@('claude', 'codex', 'omp') -cnotcontains $tool -or -not $log -or -not (Test-Path -LiteralPath $log -PathType Leaf)) { return , @() }
    $fs = @($log); $mf = $log
    if ($tool -ceq 'claude') {   # the oldest file first (as ls -tr)
        $sd = Join-Path $log.Substring(0, $log.Length - 6) 'subagents'
        $mf = (Get-Item -LiteralPath $log).FullName
        $all = @(Get-Item -LiteralPath $log) + @(Get-ChildItem -LiteralPath $sd -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.EndsWith('.jsonl', $Ord) })
        $fs = @($all | Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Ascending = $true }, @{ Expression = { $_.FullName }; Descending = $true } | ForEach-Object { $_.FullName })
    }
    $K = New-List; $V = New-Object 'System.Collections.Generic.List[object]'; $fi = 0
    foreach ($f in $fs) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }; $fi++; Files-Scan $tool $f $fi ($f -ceq $mf) $K $V }
    $ka = $K.ToArray(); $ix = New-Object 'int[]' $ka.Length; for ($i = 0; $i -lt $ix.Length; $i++) { $ix[$i] = $i }
    [Array]::Sort($ka, $ix, [StringComparer]::Ordinal)   # (an index: PowerShell may hand Sort a copy of an object[])
    $out = New-Object 'System.Collections.Generic.List[object]'; foreach ($i in $ix) { $out.Add($V[$i]) }
    , $out
}
function Files-Git([string]$dir) { # what git status shows in the repo DIR is in (absolute; a rename: its new name)
    $out = New-List
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return , $out }
    $g = Prog-Path 'git'; if (-not $g) { return , $out }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $ol = $env:GIT_OPTIONAL_LOCKS; $env:GIT_OPTIONAL_LOCKS = '0'
    try {
        $top = "$(& $g -C $dir rev-parse --show-toplevel 2>$null)".Trim()
        if ($LASTEXITCODE -ne 0 -or -not $top) { return , $out }
        $z = (@(& $g -C $dir status --porcelain -z --ignore-submodules=all 2>$null) | ForEach-Object { "$_" }) -join "`n"
        if ($LASTEXITCODE -ne 0) { return , $out }
        $skip = $false
        foreach ($e in $z.Split([char]0)) {
            if ($skip) { $skip = $false; continue }
            if ($e.Length -le 3) { continue }
            if ($e.Substring(0, 2) -cmatch '[RC]') { $skip = $true }
            $out.Add($top + '/' + $e.Substring(3))
        }
    } finally { $ErrorActionPreference = $old; $env:GIT_OPTIONAL_LOCKS = $ol }
    , $out
}
function Files-Abs([string]$p, [string]$dir) { # absolute (a relative one under DIR; ~/ is the home folder); a drive letter (or \\server): with /
    if ($p.StartsWith('~/', $Ord) -and $UserHome) { $p = $UserHome + $p.Substring(1) }
    if (-not $p.StartsWith('/', $Ord) -and $p -cnotmatch '^[A-Za-z]:[\\/]' -and -not $p.StartsWith('\\', $Ord)) {
        if (-not $dir) { return '' }
        while ($p.StartsWith('./', $Ord)) { $p = $p.Substring(2) }
        $p = ($dir -creplace '[\\/]+\z', '') + '/' + $p
    }
    if ($p -cmatch '^[A-Za-z]:[\\/]' -or $p.StartsWith('\\', $Ord)) { $p = $p.Replace('\', '/') }
    while (($i = $p.IndexOf('/./', $Ord)) -ge 0) { $p = $p.Substring(0, $i + 1) + $p.Substring($i + 3) }
    $p
}
function Files-Pick($rows, $gits, [string]$dir) { # newest first, one per path (with a drive letter: compared ignoring case); then the git ones
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $out = New-Object 'System.Collections.Generic.List[object]'
    $all = New-Object 'System.Collections.Generic.List[object]'
    for ($i = $rows.Count - 1; $i -ge 0; $i--) { if ($rows[$i][0] -cne 'turn') { $all.Add($rows[$i]) } }
    foreach ($p in $gits) { $all.Add(@('git', $p)) }
    foreach ($e in $all) {
        $p = Files-Abs $e[1] $dir; if (-not $p) { continue }
        $k = if ($p -cmatch '^[A-Za-z]:/' -or $p.StartsWith('//', $Ord)) { $p.ToLowerInvariant() } else { $p }
        if ($seen.Add($k)) { $out.Add(@($e[0], $p)) }
    }
    , $out
}
function Files-Turns($rows, [string]$dir) { # the turns, newest first (n 0, the files before the first one seen, last): @(n, at, text, files
    # @(tag, path) newest first, one per path); a sub-agent's touch: in the turn that started last before it (the rows are in time order)
    $cur = 0; $top = 0; $at = @{}; $tx = @{}; $tu = New-Object 'int[]' $rows.Count
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $e = $rows[$i]
        if ($e[0] -ceq 'turn') { $cur = [int]$e[2]; if ($cur -gt $top) { $top = $cur }; $at[$cur] = $e[3]; $tx[$cur] = $e[4]; continue }
        $tu[$i] = if ($e[2] -ceq '-') { $cur } else { [int]$e[2] }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal); $lists = @{}
    for ($i = $rows.Count - 1; $i -ge 0; $i--) {
        $e = $rows[$i]; if ($e[0] -ceq 'turn') { continue }
        $p = Files-Abs $e[1] $dir; if (-not $p) { continue }
        $k = if ($p -cmatch '^[A-Za-z]:/' -or $p.StartsWith('//', $Ord)) { $p.ToLowerInvariant() } else { $p }
        if (-not $seen.Add([string]$tu[$i] + "`t" + $k)) { continue }
        if (-not $lists.ContainsKey($tu[$i])) { $lists[$tu[$i]] = New-Object 'System.Collections.Generic.List[object]' }
        $lists[$tu[$i]].Add(@($e[0], $p))
    }
    $out = New-Object 'System.Collections.Generic.List[object]'
    for ($u = $top; $u -ge 0; $u--) {
        if (-not $lists.ContainsKey($u)) { continue }
        $a = ''; $x = ''; if ($u -gt 0) { $a = $at[$u]; $x = $tx[$u] }
        $out.Add(@($u, $a, $x, $lists[$u]))
    }
    , $out
}
function Cmd-Files($rest) { # kit files --pid PID [--tool claude|codex|omp] [--dir DIR] [--git] [--json] : the files that agent read or changed
    $use = '用法：kit files --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--git] [--json]'
    $rest = @($rest); $cpid = ''; $tool = ''; $dir = ''; $git = $false; $json = $false
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $a = [string]$rest[$i]
        if ($a -ceq '--git') { $git = $true; continue }
        if ($a -ceq '--json') { $json = $true; continue }
        if ($a -cne '--pid' -and $a -cne '--tool' -and $a -cne '--dir') { Die-C usage $use }
        if ($i + 1 -ge $rest.Count) { Die-C usage $use }
        $v = [string]$rest[++$i]
        if ($a -ceq '--pid') { $cpid = $v } elseif ($a -ceq '--tool') { $tool = $v } else { $dir = $v }
    }
    if ($cpid -cnotmatch '^[0-9]+\z') { Die-C usage $use }
    $g = Agent-Guess $cpid $tool $dir; $tool = [string]$g[0]; $dir = [string]$g[1]
    $log = ''; $note = ''
    if ($tool -ceq 'claude') { $s = Claude-Where $cpid $dir; if ($s) { $log = $s[2] }; if (-not $log) { $note = '找不到這個 Claude 的對話紀錄（~/.claude/projects）' } }
    elseif ($tool -ceq 'codex') { $log = Codex-Rollout $dir; if (-not $log) { $note = '找不到這個資料夾的 Codex 對話紀錄（~/.codex/sessions）' } }
    elseif ($tool -ceq 'omp') { $log = Omp-Session $cpid $dir; if (-not $log) { $note = '找不到這個 omp 的 session（~/.omp/agent/sessions）' } }
    elseif (-not $tool) { $note = '看不出是哪種 agent（用 --tool claude|codex|omp 指定）' }
    else { $note = "不認得這種 agent：${tool}（只認得 claude、codex、omp）" }
    $gits = if ($git) { Files-Git $dir } else { @() }
    $items = New-List; $human = New-List; $n = 0; $rows = Files-Rows $tool $log
    foreach ($e in (Files-Pick $rows $gits $dir)) {
        $tag = $e[0]; $p = $e[1]
        if ([IO.File]::Exists($p)) { $ex = 'true' } elseif ($tag -ceq 'read' -or $tag -ceq 'git') { continue } else { $ex = 'false' }
        $n++; if ($n -gt $FilesMax) { break }
        $items.Add('{"path": ' + (Json-S $p) + ', "tag": "' + $tag + '", "exists": ' + $ex + '}')
        $human.Add("$p  $tag" + $(if ($ex -ceq 'false') { '（已經不在）' } else { '' }))
    }
    $turns = New-List
    foreach ($u in (Files-Turns $rows $dir)) {
        if ($turns.Count -ge $TurnsMax) { break }
        $fl = New-List
        foreach ($e in $u[3]) {
            if ($fl.Count -ge $TurnFiles) { break }
            $tag = $e[0]; $p = $e[1]
            if ([IO.File]::Exists($p)) { $ex = 'true' } elseif ($tag -ceq 'read') { continue } else { $ex = 'false' }
            $fl.Add('{"path": ' + (Json-S $p) + ', "tag": "' + $tag + '", "exists": ' + $ex + '}')
        }
        if ($fl.Count -gt 0) { $turns.Add('{"n": ' + $u[0] + ', "at": "' + $u[1] + '", "text": "' + $u[2] + '", "files": [' + ($fl -join ', ') + ']}') }
    }
    if ($json) {
        $j = '{"tool": ' + (Json-S $tool) + ', "log": ' + (Json-S $log) + ', "dir": ' + (Json-S $dir) + ', "files": [' + ($items -join ', ') + '], "turns": [' + ($turns -join ', ') + ']'
        if ($note) { $j += ', "note": ' + (Json-S $note) }
        Out-Json ($j + '}')
    } else {
        if ($note) { Warn $note }
        if ($human.Count -gt 0) { foreach ($h in $human) { Say $h } } else { Warn '沒有看到讀過或改過的檔案' }
    }
}

# ---------- commands ----------
function Need-Init { if (-not (Test-Path -LiteralPath $Machine)) { Die-C not_init '還沒設定：先打  kit init <網址或資料夾>' } }
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
        if (Has-Creds $s) { Die "網址裡有帳號或 token（$(Url-Safe $s)）：不要把密碼放進網址，先用 git clone 登入一次（Git 的認證管理會記住），再用不含帳號的網址" }
        if (Is-Url $s) { $s }
        elseif (Test-Path -LiteralPath $s -PathType Container) { Canon-Dir $s }
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
            if (Test-Path -LiteralPath $p -PathType Container) { Canon-Dir $p } else { $p }
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
    Apply-Dirs                                                # first: a folder that is gone leaves the list Codex's trust comes from
    Apply-All
    $new = @(foreach ($i in Available) { if ($null -eq (State-Get 'seen' $i)) { $i } })
    if ($new.Count -gt 0) { Say "kit：新： $($new -join ' ')  （要用就 kit add <種類> <名字>）" }
    Seen-All
    Version-Nag
}
# Is this Claude saving its transcript? (the same as unix/kit) A Claude Code started from inside another Claude's
# shell inherits CLAUDE_CODE_CHILD_SESSION=1 and then writes no transcript (no /resume);
# CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 makes it save again. Claude gives its hooks CHILD_SESSION=1 too, so this
# reads the environment of the claude process (the nearest parent named claude), not kit's own.
# Windows: the parent and the environment come from that process's PEB (ntdll NtQueryInformationProcess and
# ReadProcessMemory, declared at run time, so no Add-Type and no compiler); 64-bit PowerShell only, anything that
# cannot be read means no warning. Claude hands CHILD_SESSION to its children without setting it on itself, so the
# PEB (the process's current environment) still shows what it was started with.
# Codex and omp only skip their session log when told to (codex exec --ephemeral, omp --no-session): nothing to check.
$script:NtApi = $null
function Nt-Api {
    if ($script:NtApi) { return $script:NtApi }
    $ab = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object Reflection.AssemblyName 'KitNt'), 'Run')
    $tb = $ab.DefineDynamicModule('KitNt').DefineType('KitNt', 'Public, Class')
    foreach ($d in @(@('ntdll.dll', 'NtQueryInformationProcess', [int], @([IntPtr], [int], [byte[]], [int], [IntPtr])),
            @('kernel32.dll', 'OpenProcess', [IntPtr], @([int], [bool], [int])),
            @('kernel32.dll', 'ReadProcessMemory', [bool], @([IntPtr], [IntPtr], [byte[]], [IntPtr], [IntPtr])),
            @('kernel32.dll', 'CloseHandle', [bool], @([IntPtr])))) {
        $m = $tb.DefinePInvokeMethod($d[1], $d[0], 'Public, Static, PinvokeImpl', 'Standard', $d[2], [Type[]]$d[3], 'Winapi', 'Unicode')
        $m.SetImplementationFlags('PreserveSig')
    }
    $script:NtApi = $tb.CreateType(); $script:NtApi
}
function Win-Mem($api, [IntPtr]$h, [long]$addr, [long]$n) { # $n bytes at $addr in process $h, or $null
    $b = New-Object byte[] $n
    if ($api::ReadProcessMemory($h, [IntPtr]$addr, $b, [IntPtr]$n, [IntPtr]::Zero)) { , $b } else { $null }
}
function Win-Peb([int]$p, [bool]$wantEnv) { # the parent pid of process $p, or ($wantEnv) its environment lines; $null if unreadable
    if ([IntPtr]::Size -ne 8) { return $null }                       # the offsets below are the 64-bit ones
    $api = Nt-Api
    $h = $api::OpenProcess(0x1010, $false, $p)                       # PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
        $b = New-Object byte[] 48                                    # PROCESS_BASIC_INFORMATION
        if ($api::NtQueryInformationProcess($h, 0, $b, 48, [IntPtr]::Zero) -ne 0) { return $null }
        if (-not $wantEnv) { return [int][BitConverter]::ToInt64($b, 40) }      # InheritedFromUniqueProcessId
        $q = Win-Mem $api $h ([BitConverter]::ToInt64($b, 8) + 0x20) 8          # PEB.ProcessParameters
        if ($null -eq $q) { return $null }; $pp = [BitConverter]::ToInt64($q, 0)
        $q = Win-Mem $api $h ($pp + 0x80) 8                                      # .Environment
        if ($null -eq $q) { return $null }; $ea = [BitConverter]::ToInt64($q, 0)
        $q = Win-Mem $api $h ($pp + 0x3F0) 8                                     # .EnvironmentSize (bytes)
        if ($null -eq $q) { return $null }; $n = [BitConverter]::ToInt64($q, 0)
        if ($n -le 0 -or $n -gt 4MB) { return $null }
        $q = Win-Mem $api $h $ea $n; if ($null -eq $q) { return $null }
        $lines = New-Object Collections.Generic.List[string]
        foreach ($l in [Text.Encoding]::Unicode.GetString($q).Split([char]0)) { if (-not $l) { break }; $lines.Add($l) }
        $lines.ToArray()
    } finally { [void]$api::CloseHandle($h) }
}
function Proc-Parent([int]$p) { # 0 when there is none (or it is gone: a newer process with its pid is not its parent)
    if (-not $OnWindows) { $v = "$(& ps -o ppid= -p $p 2>$null)".Trim(); if ($v -match '^\d+$') { return [int]$v }; return 0 }
    $q = Win-Peb $p $false; if (-not $q) { return 0 }
    try { if ((Get-Process -Id $q -ErrorAction Stop).StartTime -gt (Get-Process -Id $p -ErrorAction Stop).StartTime) { return 0 } } catch { return 0 }
    $q
}
function Proc-Name([int]$p) {
    if ($OnWindows) { try { (Get-Process -Id $p -ErrorAction Stop).ProcessName } catch { '' } }
    else { $v = "$(& ps -o comm= -p $p 2>$null)".Trim(); $v.Substring($v.LastIndexOf('/') + 1) }
}
function Proc-Env([int]$p) { # the start environment of process $p, one VAR=value per line
    if ($OnWindows) { return Win-Peb $p $true }
    if (Test-Path -LiteralPath "/proc/$p/environ") { return ([IO.File]::ReadAllText("/proc/$p/environ")).Split([char]0) }
    $a = "$(& ps -ww -p $p -o command= 2>$null)"; $e = "$(& ps -E -ww -p $p -o command= 2>$null)"   # macOS: command line, then environment
    if ($a -and $e.StartsWith($a)) { $e = $e.Substring($a.Length) }
    $e.Split(' ')
}
function Transcript-Check { # print Claude's SessionStart JSON (a warning) when the claude above us saves no transcript
    if ($env:KIT_TRANSCRIPT_CHECK -eq '0') { return }
    try {
        $sf = Join-Path $ClaudeDir 'settings.json'
        if ((Test-Path -LiteralPath $sf) -and (Read-Text $sf).Contains('transcript-check')) { return }   # your own hook does it
        $p = $PID; $c = ''
        for ($i = 0; $i -lt 6; $i++) {
            $p = Proc-Parent $p; if ($p -le 1) { return }
            $c = Proc-Name $p; if ($c -eq 'claude') { break }
        }
        if ($c -ne 'claude') { return }
        $e = @(Proc-Env $p)
        if ($e -notcontains 'CLAUDE_CODE_CHILD_SESSION=1' -or $e -contains 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1') { return }
        $restart = if ($OnWindows) { "`$env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE='1'; claude" } else { 'env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude' }
        $msg = "⚠ 這個 session 沒有在存對話紀錄：關掉之後 /resume 找不回來。請先叫它寫交接檔，再用會存檔的方式重開（$restart）。"
        $ctx = 'WARNING: transcript saving is OFF for this session (the claude process was started with CLAUDE_CODE_CHILD_SESSION=1 and without CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1). If the user closes it, the conversation is lost and cannot be resumed. Tell the user this in your first reply (in Traditional Chinese), commit work often, and before the user closes it write a HANDOFF.md. Any Claude you launch yourself (in a new terminal or pane) must be started with: ' + $restart + ' ...'
        [Console]::Out.WriteLine('{"systemMessage":' + (Json-Str $msg) + ',"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":' + (Json-Str $ctx) + '}}')
    } catch { }
}
function Sync-Hook { # run by Claude at start: warn when it saves no transcript; sync in the background, at most every 10 minutes
    Transcript-Check
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
    $script:Locked = $true; $script:LockMine = $true
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
function Kit-Only([string]$f) { # FILE has nothing but kit's block (kit made it for a folder's own)
    $in = $false
    foreach ($l in (Read-Text $f) -split "`n") { $l = $l.TrimEnd("`r"); if ($l -eq $BeginMark) { $in = $true }; if (-not $in -and $l.Trim()) { return $false }; if ($l -eq $EndMark) { $in = $false } }
    $true
}
function Here-Rows([string]$dir) { # what an agent started in DIR gets that kit does not manage: @(scope, kind, name, path, tools)
    # (the folder's own that kit put there, kit add --dir, are not listed: the panel shows them as kit's)
    $rows = New-Object System.Collections.Generic.List[object]
    $cd = Join-Path $ClaudeDir 'CLAUDE.md'
    $root = Dir-Root $dir; $mine = @(Dir-Items $root)
    $a = $dir
    while ($a) {
        foreach ($f in @((Join-Path $a 'CLAUDE.md'), (Join-Path $a 'CLAUDE.local.md'), (Join-Path (Join-Path $a '.claude') 'CLAUDE.md'))) {
            if ((Test-Path -LiteralPath $f -PathType Leaf) -and $f -ne $cd -and -not (Kit-Only $f)) { $rows.Add(@('dir', 'rule', (Here-Short $dir $f), $f, 'claude')) }
        }
        $dc = Join-Path $a '.claude'
        if ($dc -ne $ClaudeDir) {
            $rd = Join-Path $dc 'rules'
            if (Test-Path -LiteralPath $rd -PathType Container) {
                foreach ($n in Sorted-Names (Get-ChildItem -LiteralPath $rd -File -Filter '*.md')) { $f = Join-Path $rd $n; $rows.Add(@('dir', 'rule', (Here-Short $dir $f), $f, 'claude')) }
            }
            $sd = Join-Path $dc 'skills'
            if (Test-Path -LiteralPath $sd -PathType Container) {
                foreach ($n in Sorted-Names (Get-ChildItem -LiteralPath $sd -Directory)) {
                    if ($a -eq $root -and $mine -contains "skill:$n") { continue }
                    $f = Join-Path (Join-Path $sd $n) 'SKILL.md'; if (Test-Path -LiteralPath $f -PathType Leaf) { $rows.Add(@('dir', 'skill', $n, $f, 'claude')) }
                }
            }
        }
        $f = Join-Path $a 'AGENTS.md'
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and -not (Kit-Only $f)) { $rows.Add(@('dir', 'rule', (Here-Short $dir $f), $f, 'codex omp')) }
        $up = Split-Path -Parent $a
        if (-not $up -or $up -eq $a) { break }
        $a = $up
    }
    $f = Join-Path $dir '.mcp.json'
    if (Test-Path -LiteralPath $f -PathType Leaf) { foreach ($n in Json-Keys $f @('mcpServers')) { if ($dir -eq $root -and $mine -contains "mcp:$n") { continue }; $rows.Add(@('dir', 'mcp', $n, $f, 'claude')) } }
    if (Test-Path -LiteralPath $ClaudeJson -PathType Leaf) {
        $pks = @($dir); if ($dir.Contains('\')) { $pks += $dir.Replace('\', '/') }
        $seenMcp = @{}
        foreach ($pk in $pks) {
            foreach ($n in Json-Keys $ClaudeJson @('projects', $pk, 'mcpServers')) { if (-not $seenMcp.ContainsKey($n)) { $seenMcp[$n] = 1; $rows.Add(@('dir', 'mcp', $n, $ClaudeJson, 'claude')) } }
        }
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
function Pid-Tree([string]$top) { # TOP and every process under it
    $p = @{}
    if ($OnWindows) { foreach ($x in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $p["$($x.ProcessId)"] = "$($x.ParentProcessId)" } }
    else { foreach ($l in @(& ps -A -o pid= -o ppid= 2>$null)) { $f = @("$l".Trim() -split '\s+'); if ($f.Count -ge 2 -and $f[0] -match '^[0-9]+$') { $p[$f[0]] = $f[1] } } }
    $out = New-Object System.Collections.Generic.List[string]; $out.Add($top)
    foreach ($x in $p.Keys) {
        $y = $x; $i = 0
        while ($i -lt 64 -and $y -ne $top -and $p.ContainsKey($y)) { $y = $p[$y]; $i++ }
        if ($y -eq $top -and $x -ne $top) { $out.Add($x) }
    }
    $out.ToArray()
}
function Run-Agent([string]$top) { # the agent that kit run started at or under TOP (kit run leaves a marker), if any
    $d = Join-Path $KitConf 'run'
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { return '' }
    $tree = @(Pid-Tree $top)
    $names = [string[]]@(Get-ChildItem -LiteralPath $d -File | ForEach-Object { $_.Name } | Where-Object { $_ -match '^[0-9]+$' })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $found = ''
    foreach ($p in $names) {
        $f = Join-Path $d $p; $alive = $false
        try { $alive = [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) } catch { }
        if (-not $alive) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; continue }   # that kit run has ended
        if (-not $found -and $tree -contains $p) { $found = $f }
    }
    if ($found) { return @((Read-Text $found) -split "`n")[0].TrimEnd("`r") }
    ''
}
function Agent-Json([string]$n) { # {"name", "source", "rules", "skills", "mcp"} of a kit agent
    $f = Find-Item 'agent' $n; $src = ''; $fm = @()
    if ($f) { $src = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $f)); try { $fm = Yaml-Lines $f -Frontmatter } catch { $fm = @() } }
    "{`"name`": $(Json-S $n), `"source`": $(Json-S $src), `"rules`": $(Json-Arr (YGet-From $fm 'rules')), `"skills`": $(Json-Arr (YGet-From $fm 'skills')), `"mcp`": $(Json-Arr (YGet-From $fm 'mcp'))}"
}
function Here-Json([string]$dir, [string]$hpid) { # the "here" part of kit list --json --dir
    $user = ''; $agent = ''
    if ($hpid) { $user = Other-User $hpid; $agent = Run-Agent $hpid }
    $out = ",`n  `"here`": {`"dir`": $(Json-S $dir), `"user`": $(if ($user) { Json-S $user } else { 'null' }), `"agent`": $(if ($agent) { Agent-Json $agent } else { 'null' })"
    if ($user) { return $out + ', "items": []}' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $out + ", `"error`": $(Json-S '找不到這個資料夾'), `"items`": []}" }
    $froot = Dir-Root $dir
    $out += ", `"folder`": {`"dir`": $(Json-S $froot), `"why`": $(Json-S (Dir-WhyNot $froot)), `"items`": $(Json-Arr @(Dir-Items $froot))}"
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
function Push-Mode([string]$dir) { $m = @(YGet (Join-Path $dir 'kit.yaml') 'push'); if ($m.Count -gt 0 -and $m[0]) { [string]$m[0] } else { 'pr' } }   # pr (the default) or direct
function Cmd-ListJson([string]$hereDir = '', [string]$herePid = '') { # what kit list shows, as JSON for programs (a screen like a kit panel); unix/kit prints the same
    $want = Wanted; $req = Kit-Items 'required'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`n  `"kit`": $(Json-S $KitVersion),`n  `"sources`": [")
    $first = $true; $chg = @{}
    foreach ($s in @(M-Sources)) {
        if (-not $s) { continue }
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        $d = Src-Dir $s; $sf = @(Send-Files $d); $chg[$d] = $sf      # what kit push would send from it
        [void]$sb.Append("`n    {`"name`": $(Json-S (Src-Name $s)), `"source`": $(Json-S (Url-Safe $s)), `"dir`": $(Json-S $d), `"push`": $(Json-S (Push-Mode $d)), `"changed`": $(Json-Arr $sf)}")
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
        # changed: kit push would send it (a skill: any file in its folder)
        $sf = @($chg[$dir]); $changed = 'false'
        if ($k -eq 'skill') { if (@($sf | Where-Object { $_.StartsWith("skills/$n/", [StringComparison]::Ordinal) }).Count -gt 0) { $changed = 'true' } }
        else { $rel = @{ rule = "rules/$n.md"; mcp = "mcp/$n.yaml"; agent = "agents/$n.md" }[$k]; if ($sf -ccontains $rel) { $changed = 'true' } }
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        $nj = if ($k -eq 'skill') { ', "needs": ' + (Needs-Json (Split-Path -Parent $p) $dir) + (Packages-Json (Split-Path -Parent $p) $n) } elseif ($k -eq 'mcp') { Mcp-ListJson $p $n } else { '' }
        [void]$sb.Append("`n    {`"kind`": $(Json-S $k), `"name`": $(Json-S $n), `"status`": $(Json-S $status), `"new`": $new, `"changed`": $changed, `"source`": $(Json-S (Split-Path -Leaf $dir)), `"description`": $(Json-S (Item-Desc $k $p)), `"path`": $(Json-S $p)$nj}")
    }
    [void]$sb.Append("`n  ],`n  `"kit_version_wanted`": $(Json-S (Wanted-Version))")
    if ($hereDir) { [void]$sb.Append((Here-Json $hereDir $herePid)) }
    [void]$sb.Append("`n}")
    Out-Json $sb.ToString()
}
function Cmd-List($rest) {
    $rest = @($rest | Where-Object { $null -ne $_ })
    if ($rest.Count -ge 1 -and $rest[0] -eq '--json') {
        $hd = ''; $hp = ''
        for ($i = 1; $i -lt $rest.Count; $i++) {
            switch -CaseSensitive ($rest[$i]) {
                '--dir' { if ($i + 1 -ge $rest.Count) { Die-C usage '--dir 後面要接資料夾' }; $i++; $hd = $rest[$i]; if (Test-Path -LiteralPath $hd -PathType Container) { $hd = Real-Dir $hd } }
                '--pid' { if ($i + 1 -ge $rest.Count -or $rest[$i + 1] -notmatch '^[0-9]+$') { Die-C usage '--pid 後面要接數字' }; $i++; $hp = $rest[$i] }
                default { Die-C usage '用法：kit list --json [--dir 資料夾] [--pid 程式編號]' }
            }
        }
        Need-Init; Cmd-ListJson $hd $hp; return
    }
    if ($rest.Count -gt 0) { Die-C usage '用法：kit list [--json [--dir 資料夾] [--pid 程式編號]]' }
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
    # an MCP in use whose package is downloaded at each start (kit can install it once)
    foreach ($n in (Of-Kind $want 'mcp')) {
        $p = Find-Item 'mcp' $n; if (-not $p) { continue }
        $pk = Mcp-Pkg (Mcp-Info $p)
        if (-not $pk -or (Mcp-Installed $n $pk)) { continue }
        if ($pk[2] -and -not $pk[6]) { Say "   mcp:$n 每次啟動時下載 $($pk[1])（先裝好：kit install-deps mcp ${n}）" }
        else { Say "   mcp:$n 每次啟動時下載 $(if ($pk[1]) { $pk[1] } else { '它的套件' })" }
    }
    Say ''
    Say '* 在用   R 團隊必備   N 新的   agent 用  kit run <名字>  開'
    Say "寫到：$(Targets)"
    Version-Nag
}
function Cmd-AddRm([string]$verb, $rest) {
    $rest = @($rest); $dir = ''
    if ($rest.Count -gt 0 -and $rest[0] -eq '--dir') {
        if ($rest.Count -lt 2) { Die '--dir 後面要接資料夾' }
        $dir = $rest[1]; $rest = @(if ($rest.Count -gt 2) { $rest[2..($rest.Count - 1)] })
    }
    if ($rest.Count -ne 2) { Die "用法：kit $verb [--dir 資料夾] rule|skill|mcp <名字>" }
    Need-Init
    $k = $rest[0]; $n = $rest[1]; $i = "${k}:$n"
    if (@('rule', 'skill', 'mcp') -notcontains $k) { Die '種類只能是 rule、skill、mcp' }
    if ($dir) { Dir-AddRm $verb $dir $k $n; return }
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
    $name = $rest[0]; $extra = @(if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] })   # @(if ...): an empty else would be $null
    $tool = 'claude'
    if ($extra.Count -gt 0 -and $extra[0] -eq '--tool') {
        if ($extra.Count -lt 2) { Die '--tool 後面要接 claude、codex 或 omp' }
        $tool = $extra[1]; $extra = @(if ($extra.Count -gt 2) { $extra[2..($extra.Count - 1)] })
    }
    if (@('claude', 'codex', 'omp') -notcontains $tool) { Die '--tool 只能是 claude、codex 或 omp' }
    $f = Find-Item 'agent' $name; if (-not $f) { Die "找不到 agent ${name}（打 kit list 看有哪些）" }
    if (Take-Lock -Soft) { $script:Quiet = $true; try { Cmd-Sync } catch { } finally { $script:Quiet = $false; Release-Lock } }   # busy (another kit is syncing): start as it is

    # the agent's folder, gone when kit ends (also on Ctrl-C); a dry run keeps it to look at, without kit's links in it.
    # Folders of runs that were killed (their kit is gone) go now, their links (junctions) taken out first.
    foreach ($o in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'kit-run.*' -ErrorAction SilentlyContinue)) {
        $pf = Join-Path $o.FullName '.kit-pid'
        if (-not (Test-Path -LiteralPath $pf -PathType Leaf)) { continue }
        $op = "$(Read-Text $pf)".Trim()
        if ($op -match '^[0-9]+$' -and -not (Get-Process -Id ([int]$op) -ErrorAction SilentlyContinue)) { try { Remove-Tree $o.FullName } catch { } }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('kit-run.' + [IO.Path]::GetRandomFileName())
    $skdir = if ($tool -eq 'claude') { Join-Path $tmp '.claude/skills' } else { Join-Path $tmp 'skills' }
    $mark = Join-Path (Join-Path $KitConf 'run') "$PID"
    $dry = [bool]$env:KIT_DRY_RUN
    Ensure-Dir $skdir
    if (-not $dry) { Write-Text (Join-Path $tmp '.kit-pid') "$PID`n" }
    try {
        $fm = $null
        try { $fm = Yaml-Lines $f -Frontmatter } catch { Die "bad header in $f" }
        $skills = @()
        foreach ($n in YGet-From $fm 'skills') {
            $p = Find-Item 'skill' $n; if (-not $p) { Warn "skill $n not found"; continue }
            Copy-Item -LiteralPath (Split-Path -Parent $p) -Destination (Join-Path $skdir $n) -Recurse
            if (-not $dry) { Link-Deps $n (Join-Path $skdir $n) }
            $skills += $n
        }
        $sb = New-Object System.Text.StringBuilder
        foreach ($n in YGet-From $fm 'rules') {
            $p = Find-Item 'rule' $n; if (-not $p) { Warn "rule $n not found"; continue }
            [void]$sb.Append((Read-Text $p)).Append("`n")
        }
        [void]$sb.Append((Py-Hint (YGet-From $fm 'skills')))
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
                    $fl = Codex-Mcp-Fields $p $n ${function:Arg-TomlStr} ${function:Arg-TomlKey} '=' ','
                    if ($null -eq $fl) { continue }
                    $parts = @(); $envs = @()
                    foreach ($x in $fl) { if ($x[0].StartsWith('env.')) { $envs += (Arg-TomlKey $x[0].Substring(4)) + '=' + $x[1] } else { $parts += $x[0] + '=' + $x[1] } }
                    $v = '{' + ($parts -join ',')
                    if ($envs.Count -gt 0) { $v += ',env={' + ($envs -join ',') + '}' }
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
        if ($dry) { Say $tool; foreach ($x in $a) { Say $x }; Say "tmp=$tmp"; return }
        # the same quoting rules on PowerShell 5.1 and 7 (Arg-TomlStr is written for them)
        $PSNativeCommandArgumentPassing = 'Legacy'
        # a marker (this process -> agent name), so a program showing the pane can tell which agent runs in it
        try { Ensure-Dir (Join-Path $KitConf 'run'); Write-Text $mark "$name`n" } catch { }
        & $tool @($a.ToArray())
        $rc = $LASTEXITCODE
    } finally {
        # (on PowerShell 5.1 Remove-Item -Recurse would go into the junctions to kit's packages: they come out first)
        if (-not $dry) {
            try { Remove-Tree $tmp } catch { }
            Remove-Item -LiteralPath $mark -Force -ErrorAction SilentlyContinue
        }
    }
    exit $rc
}
function Cmd-Uninstall($rest) {
    $self = (@($rest) -contains '--self')
    $left = $false
    foreach ($d in @(Dirs-Registered)) {                      # the folders' own: kit's files out, .agentkit gone
        if (Test-Path -LiteralPath $d -PathType Container) {
            $f = Join-Path $d $DirFile; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
            $script:Quiet = $true; Apply-Dir $d; $script:Quiet = $false
        }
        Dirs-Set $d 'rm'
    }
    foreach ($f in @((Join-Path $ClaudeDir 'CLAUDE.md'), (Join-Path $CodexDir 'AGENTS.md'), (Join-Path $OmpDir 'AGENTS.md'))) { if (-not (Replace-Block $f $BeginMark $EndMark '')) { $left = $true } }
    if (-not (Replace-Block (Join-Path $CodexDir 'config.toml') $TomlBegin $TomlEnd '')) { $left = $true }
    if (-not (Replace-TopBlock (Join-Path $CodexDir 'config.toml') $TopBegin $TopEnd '')) { $left = $true }
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
        if ($f[0] -eq 'statusline' -and (Flat-Json (Json-Get (Join-Path $ClaudeDir 'settings.json') 'statusLine')) -eq (Flat-Json $f[2])) { $ops.Add(@('del', 'statusLine')) }
    }
    if ($ops.Count -gt 0) { Json-Edit (Join-Path $ClaudeDir 'settings.json') $ops.ToArray(); Prune-Deny }
    if ($left) { Die '有的檔案 kit 沒辦法改（看上面），其他的已經拿掉；修好後再打一次  kit uninstall' }
    foreach ($f in @($State, $Machine)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    foreach ($x in 'deps', 'pydeps', 'mcp-deps', 'ctx') { $deps = Join-Path $KitConf $x; if (Test-Path -LiteralPath $deps) { Remove-Item -LiteralPath $deps -Recurse -Force } }
    Say 'kit：已移除 kit 放進 Claude、Codex、omp 的東西（你自己的檔案沒動）'
    Say "     來源的 clone 還留在 $KitSrc"
    if ($self) {
        $dir = if ((Split-Path -Leaf $KitLib) -eq 'lib') { Split-Path -Parent $KitLib } else { $KitLib }
        if ($OnWindows) {
            # the raw value (%VAR% kept), written back as REG_EXPAND_SZ
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            if ($key) {
                $p = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($p) { $key.SetValue('Path', ((@($p.Split(';') | Where-Object { $_ -and $_.TrimEnd('\') -ne $dir.TrimEnd('\') })) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
                $key.Close()
                # tell Windows the variables changed (new terminals see it)
                [Environment]::SetEnvironmentVariable('AGENTKIT_PATH_REFRESH', '1', 'User'); [Environment]::SetEnvironmentVariable('AGENTKIT_PATH_REFRESH', $null, 'User')
            }
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
        if (-not (Test-Path -LiteralPath $to -PathType Container)) { Die-C no_source "找不到 --to ${to}（要是來源名字或資料夾）" }
        return (Canon-Dir $to)
    }
    if (Test-Path -LiteralPath 'kit.yaml' -PathType Leaf) { return (Canon-Dir (Get-Location).ProviderPath) }
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
$script:McpSkeleton = @'
# 一個 MCP server。兩種寫法選一種，另一種刪掉。
# 密碼、token 不要寫在這裡：寫成 ${變數名}，值放在每台電腦自己的環境變數。
# 別人給的設定（JSON、claude mcp add …）：存成檔案，用  kit new mcp --config 檔案  帶進來比較快。

# 1. 在這台電腦跑一個程式：
command: （啟動 MCP server 的程式，例如 npx 或 uvx）
args: []
# env:
#   API_TOKEN: ${API_TOKEN}

# 2. 連到一個網址（把上面的 command、args、env 刪掉，打開下面幾行）：
# type: http          # 或 sse
# url: https://mcp.example.com/mcp
# headers:
#   Authorization: Bearer ${API_TOKEN}
'@ -replace "`r", ''
function Skeleton([string]$kind, [string]$name) {
    switch ($kind) {
        'rule' { "# $name`n`n（在這裡寫規則，一條一行。）`n" }
        'skill' { "---`nname: $name`ndescription: （什麼時候用這個 skill，一句話）`n---`n`n（在這裡寫步驟。）`n" }
        'mcp' { $McpSkeleton + "`n" }
        'agent' { "---`nname: $name`ndescription: （這個 agent 做什麼）`nrules: []`nskills: []`nmcp: []`n# tools:`n#   only: [Read, Grep, Glob]`n#   deny: []`n---`n（在這裡寫 agent 的角色和做法。）`n" }
    }
}
function Parse-ItemArgs($rest) {
    $o = @{ Kind = ''; Name = ''; From = ''; To = ''; Force = $false; Config = ''; Look = $false }
    $rest = @($rest)
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $a = [string]$rest[$i]
        switch -CaseSensitive ($a) {
            '--from' { if ($i + 1 -ge $rest.Count) { Die '--from 後面要接資料夾' }; $i++; $o.From = [string]$rest[$i] }
            '--to' { if ($i + 1 -ge $rest.Count) { Die '--to 後面要接來源' }; $i++; $o.To = [string]$rest[$i] }
            '--force' { $o.Force = $true }
            '--config' { if ($i + 1 -ge $rest.Count) { Die-C usage '--config 後面要接檔案（或 - 從標準輸入讀）' }; $i++; $o.Config = [string]$rest[$i] }
            '--look' { $o.Look = $true }
            default {
                if (-not $o.Name -and -not $o.Kind -and ($Kinds -ccontains $a)) { $o.Kind = $a }
                elseif (-not $o.Name) { $o.Name = $a }
                else { Die-C usage "多了一個參數：$a" }
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
    if ($o.Config) {
        if ($o.Kind -ne 'mcp' -or $o.From) { Die-C usage '用法：kit new mcp [名字] --config 檔案|- [--to 來源] [--look]' }
        Mcp-NewConfig $o; return
    }
    if ($o.Look) { Die-C usage '--look 要和 --config 一起用：kit new mcp [名字] --config 檔案 --look' }
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
        $old = State-Get 'from' "${kind}:$($o.Name)@$dir"; if (-not $old) { $old = State-From-Old "${kind}:$($o.Name)" $dir }; $now = Item-Hash $kind $dst
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
                foreach ($k in 'rule', 'skill', 'mcp') {      # the keys: rules, skills, mcp
                    $key = if ($k -eq 'mcp') { 'mcp' } else { "${k}s" }
                    foreach ($r in @(YGet-From $fm $key)) { if ($r -and -not $where.Contains("${k}:$r")) { Problem "${rel}: 找不到 ${k}:$r" } }
                }
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
            switch -CaseSensitive (Mcp-Type $f) {
                'stdio' { if ($cmd.Count -eq 0 -or -not $cmd[0]) { Problem "${rel}: 少了 command" } }
                { $_ -eq 'http' -or $_ -eq 'sse' } {
                    $u = @(YGet $f 'url'); if ($u.Count -eq 0 -or -not $u[0]) { Problem "${rel}: 少了 url" }
                    if ($cmd.Count -gt 0 -and $cmd[0]) { Problem "${rel}: 有 type: http 或 sse（網址的 MCP）就不要 command" }
                }
                default { Problem "${rel}: type 只能是 stdio、http 或 sse" }
            }
            # a secret written in the source (the value is never printed): it goes in an environment variable
            foreach ($x in @(Mcp-Lines (Mcp-Info $f) 'X')) { $q = $x.Split("`t"); Problem "${rel}: $($q[0]) 看起來是密碼或 token，不能寫在來源裡：改成 `${$($q[1])}，值放在每台電腦自己的環境變數" }
            $mh = @(YGet $kitYaml 'allowed_hosts') + @(YGet $kitYaml 'content_hosts')
            if (Test-Path -LiteralPath $Machine) { foreach ($sd in Src-Dirs) { $mh += @(YGet (Join-Path $sd 'kit.yaml') 'allowed_hosts') + @(YGet (Join-Path $sd 'kit.yaml') 'content_hosts') } }
            $mh = @($mh | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
            foreach ($v in @($cmd) + @(YGet $f 'args')) {
                if ($v -match '^(git\+|github:|git@)') { Problem "${rel}: MCP 只能從公司允許的套件來源裝，不能用 $v 這種寫法" }
                elseif ($v.Contains('://')) {   # a package index etc.: only a host the sources list (allowed_hosts or content_hosts)
                    $h = (($v.Substring($v.IndexOf('://') + 3) -replace '^[^@/]*@', '') -replace '[:/?#].*$', '').ToLowerInvariant()
                    if ($mh -notcontains $h) { Problem "${rel}: MCP 只能從公司允許的套件來源裝：$h 不在 allowed_hosts 或 content_hosts" }
                }
            }
        }
        if (Test-Path -LiteralPath $kitYaml -PathType Leaf) {
            if (@('pr', 'direct') -cnotcontains (Push-Mode $d)) { Problem 'kit.yaml: push 只能是 pr 或 direct' }
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
        $hosts = @(Uniq @($hosts | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }))
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
                    if ($doms -notcontains $dom.ToLowerInvariant() -and $doms -notcontains $dom) { Problem "commit $($parts[0]): 作者 email 不是公司網域" }
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
        else { $dirs += (Canon-Dir $a) }
    }
    if ($dirs.Count -eq 0) {
        if ((Test-Path -LiteralPath 'kit.yaml' -PathType Leaf) -or $script:CheckCi) { $dirs = @(Canon-Dir (Get-Location).ProviderPath) }
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
function Export-Skip([string]$rel) { # files that stay out of the export (README goes along: it is the manual; the scan below still checks it)
    if ("/$rel".Contains('/.github/')) { return $true }
    $b = ($rel -split '/')[-1]
    ($b -match '^(CHANGELOG|LICENSE|LICENCE)') -or $b -eq 'private-words.txt'
}
function Install-Md { # INSTALL.md of the export (no URLs; the same text as unix/kit writes)
    $t = @'
# 安裝 kit

先把公司的 agentkit repo clone 下來（網址問管理這個 repo 的人），再照你的系統做。
第一次用（特別是 Windows）：照 docs/company.md 從頭做一次，從安裝到第一次送出修改都有。

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

每個指令的用法看 README.md，各版改了什麼看 docs/changes.md。
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
        if ($x -eq '--version') { if ($i + 1 -ge $a.Count -or -not $a[$i + 1]) { Die '--version 後面要接版本，例：0.2.0+gitea.1' }; $i++; $ver = [string]$a[$i] }
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
$script:ItemRe = '^(rules/[^/]+\.md|skills/[^/]+/.+|mcp/[^/]+\.yaml|agents/[^/]+\.md|third_party\.lock)$'   # the files kit push sends
function Send-Files([string]$dir) { # what kit push would send from DIR: the changed item files, and kit.yaml when all that
    # changed in it is collect_sources (kit collect --allow added an author); nothing else
    $all = @(Changed-Files $dir)
    $files = @($all | Where-Object { $_ -cmatch $ItemRe })
    if ($files.Count -eq 0) { return }
    $files
    if (($all -ccontains 'kit.yaml') -and (Collect-OnlyYaml $dir)) { 'kit.yaml' }
}
function Changed-Files([string]$dir) { # changed files in DIR, exactly as named (a rename: the new and the old name)
    $raw = "$(@(Git-Q -C $dir status --porcelain -z --untracked-files=all) -join "`n")"
    $old = $false
    foreach ($e in $raw.Split([char]0)) {
        if ($old) { $old = $false; if ($e) { $e }; continue }
        if ($e.Length -lt 4) { continue }
        if ($e[0] -eq 'R') { $old = $true }
        $e.Substring(3)
    }
}
function Git-AddCommit([string]$dir, [string]$msg, $files) { # commit exactly these files (names taken literally, not as patterns)
    $env:GIT_LITERAL_PATHSPECS = '1'
    try {
        [void](Git-Q -C $dir add -A '--' @files); if ($LASTEXITCODE -ne 0) { return $false }
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $o = @(& git -C $dir commit -q -m $msg '--' @files 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $old }
        if ($LASTEXITCODE -eq 0) { return $true }
        # git (or a commit hook) said no: say what it said, and put the files back as they were (nothing staged)
        foreach ($l in @($o | Select-Object -First 40)) { Warn "  $l" }
        if ($o.Count -gt 40) { Warn "  …（還有 $($o.Count - 40) 行）" }
        [void](Git-Q -C $dir reset -q '--' @files)
        $false
    } finally { Remove-Item env:GIT_LITERAL_PATHSPECS -ErrorAction SilentlyContinue }
}
function Collect-OnlyYaml([string]$dir) { # kit.yaml differs from the last commit only in collect_sources (kit collect --allow)
    $head = @(Git-Q -C $dir show HEAD:kit.yaml)
    if ($LASTEXITCODE -ne 0) { return $false }
    $strip = {
        param($lines)
        $s = $false
        foreach ($l in $lines) {
            if ($l -match '^collect_sources:') { $s = $true; continue }
            if ($s -and $l -match '^\s*(-\s|#|$)') { continue }
            $s = $false; $l.TrimEnd("`r")
        }
    }
    $now = (Read-Text (Join-Path $dir 'kit.yaml')) -split "`r?`n"
    if ($now.Count -gt 0 -and $now[-1] -eq '') { $now = $now[0..($now.Count - 2)] }
    ((& $strip $head) -join "`n") -ceq ((& $strip $now) -join "`n")
}
function Author-Check([string]$dir) { # with author_domains in kit.yaml, the commit's author and committer must use one
    $doms = @(YGet (Join-Path $dir 'kit.yaml') 'author_domains' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    if ($doms.Count -eq 0) { return }
    $ids = @(Git-Q -C $dir var GIT_AUTHOR_IDENT) + @(Git-Q -C $dir var GIT_COMMITTER_IDENT)
    $emails = @(foreach ($i in $ids) { if ("$i" -match '<([^>]*)>') { $Matches[1] } })
    if ($emails.Count -eq 0) { Die-C no_git_identity 'git 還不知道你的名字和信箱，什麼都沒送。請打  git config --global user.name "你的名字"  和  git config --global user.email 你的公司信箱' }
    foreach ($e in $emails) {
        if ($doms -notcontains $e.Substring($e.LastIndexOf('@') + 1).ToLowerInvariant()) { Die-C author_not_allowed "git 的作者信箱 $e 不是公司網域（要是 $($doms -join ' ')），什麼都沒送。請打  git config user.email 你的公司信箱（也看看 GIT_AUTHOR_EMAIL、GIT_COMMITTER_EMAIL）" }
    }
}
function Rev-Count([string]$dir, [string]$range) { $n = "$(@(Git-Q -C $dir rev-list --count $range) -join '')"; if ($LASTEXITCODE -ne 0 -or $n -notmatch '^[0-9]+$') { return '1' }; $n }
function Push-Direct($dir, $leaf, $files, $msg, $dry) { # kit.yaml says push: direct: commit on this branch, push to every remote
    $remotes = @(Git-Q -C $dir remote | Where-Object { $_ })
    if ($remotes.Count -eq 0) { Die-C no_remote "$leaf 沒有 remote，不知道要送到哪" }
    $cur = "$(@(Git-Q -C $dir symbolic-ref --short -q HEAD) -join '')"
    if (-not $cur) { Die-C not_on_branch "$leaf 現在不在分支上，什麼都沒送" }
    foreach ($r in $remotes) { Check-PushUrls $dir $r }
    # only the new commit may go out: every remote has this branch already, with nothing unpushed here or new there
    foreach ($r in $remotes) {
        [void](Git-Safe -C $dir fetch -q --no-recurse-submodules $r "+refs/heads/${cur}:refs/remotes/$r/$cur")
        if ($LASTEXITCODE -ne 0) { Warn "沒辦法更新 $r/${cur}（沒網路？），用上次拿到的" }
        [void](Git-Q -C $dir rev-parse -q --verify "refs/remotes/$r/$cur")
        if ($LASTEXITCODE -ne 0) { Die-C out_of_sync "$r 上沒有 ${cur}，什麼都沒送（第一次請自己  git push $r ${cur}）" }
        $n = Rev-Count $dir "refs/remotes/$r/${cur}..HEAD"
        if ($n -ne '0') { Die-C out_of_sync "${cur} 有 ${n} 個 commit 還沒推到 ${r}，什麼都沒送（先自己  git push $r ${cur}）" }
        $n = Rev-Count $dir "HEAD..refs/remotes/$r/$cur"
        if ($n -ne '0') { Die-C out_of_sync "$r 的 ${cur} 有 ${n} 個你這裡沒有的 commit，什麼都沒送（先  git pull $r ${cur}）" }
    }
    Say "要送的檔案（$leaf）："
    foreach ($f in $files) { Say "  $f" }
    Say "kit.yaml 寫 push: direct：直接 commit 到 ${cur}，推到 $($remotes -join ' ')，不開 PR"
    Say "commit：$msg"
    $PJ.branch = $cur; $PJ.remotes = $remotes
    if ($dry) { Say '（--dry-run：沒有 commit，沒有送）'; if ($JsonOut) { Push-Json $false }; return }
    if (-not (Git-AddCommit $dir $msg $files)) { Die-C push_failed 'commit 失敗，什麼都沒送' }
    $fail = $false
    foreach ($r in $remotes) {
        $o = @(Git-Safe -C $dir push -q --no-recurse-submodules $r "HEAD:refs/heads/$cur")
        if ($LASTEXITCODE -eq 0) { Say "已推到 $r" } else { Warn "沒辦法推到 ${r}（落後了要先 git pull？沒網路？），git 說："; Git-Err $o; $fail = $true }
    }
    if ($fail) { Die-C push_failed "commit 已經在本機的 ${cur}，有的 remote 沒推成功（看上面）" }
    if ($JsonOut) { Push-Json $true }
}
function Json-OrNull([string]$s) { if ($s) { Json-S $s } else { 'null' } }
function Push-Json([bool]$sent) { # with --json, what kit push sends (or would), from $PJ, on stdout (unix/kit prints the same)
    $b = { param($v) if ($v) { 'true' } else { 'false' } }
    Out-Json ('{"source": ' + (Json-S (Split-Path -Leaf $PJ.dir)) + ', "dir": ' + (Json-S $PJ.dir) + ', "push": ' + (Json-S $PJ.mode) + ', "dry_run": ' + (& $b $PJ.dry) +
        ', "files": ' + (Json-Arr $PJ.files) + ', "skipped": ' + (Json-Arr $PJ.skipped) + ', "commit": ' + (Json-OrNull $PJ.commit) + ', "branch": ' + (Json-OrNull $PJ.branch) +
        ', "into": ' + (Json-OrNull $PJ.into) + ', "remotes": ' + (Json-Arr $PJ.remotes) + ', "sent": ' + (& $b $sent) + ', "pr_url": ' + (Json-OrNull $PJ.pr) +
        ', "compare_url": ' + (Json-OrNull $PJ.compare) + '}')
}
function Cmd-Push($rest) {
    $to = ''; $dry = $false; $r = @($rest | Where-Object { $_ })
    for ($i = 0; $i -lt $r.Count; $i++) {
        if ($r[$i] -ceq '--to') { if ($i + 1 -ge $r.Count) { Die-C usage '--to 後面要接來源' }; $i++; $to = $r[$i] }
        elseif ($r[$i] -ceq '--dry-run') { $dry = $true }
        elseif ($r[$i] -ceq '--json') { }          # (set before: stdout has only the JSON)
        else { Die-C usage '用法：kit push [--to 來源] [--dry-run] [--json]' }
    }
    $dir = Target-Dir $to
    $leaf = Split-Path -Leaf $dir
    $top = @(Git-Q -C $dir rev-parse --show-toplevel)
    $prefix = @(Git-Q -C $dir rev-parse --show-prefix | Where-Object { $_ })
    if ($top.Count -eq 0 -or $prefix.Count -gt 0) { Die-C not_git "$leaf 不是 git repo（要先 git clone 團隊來源）" }
    $script:PushDir = $dir
    # what --json prints (Push-Json)
    $script:PJ = @{ dir = $dir; mode = (Push-Mode $dir); dry = $dry; files = @(); skipped = @(); commit = ''; branch = ''; into = ''; remotes = @(); pr = ''; compare = '' }

    # what changed: only item files are sent
    $all = @(Changed-Files $dir)
    $files = @($all | Where-Object { $_ -cmatch $ItemRe })
    $other = @($all | Where-Object { $files -cnotcontains $_ })
    if ($files.Count -eq 0) {
        Say "沒有要送的（$leaf 裡沒有改過的 rule、skill、mcp、agent）"
        $PJ.skipped = $other; if ($JsonOut) { Push-Json $false }
        return
    }
    $items = @(Push-Items $dir $files)
    # kit.yaml goes too when all that changed in it is collect_sources (kit collect --allow added an author)
    if (($other -contains 'kit.yaml') -and (Collect-OnlyYaml $dir)) { $files += 'kit.yaml'; $other = @($other | Where-Object { $_ -ne 'kit.yaml' }) }
    if ($other.Count -gt 0) { Warn "這些不是 rule、skill、mcp、agent，不會送：$($other -join ' ')" }
    $PJ.files = $files; $PJ.skipped = $other

    # checks: any problem stops everything
    if (-not (Check-Dirs @($dir))) { Die-C check_failed 'kit check 有問題，什麼都沒送（改好再 kit push）' }
    Author-Check $dir
    $parts = @(foreach ($v in 'add', 'update', 'remove') { $l = @($items | Where-Object { $_[0] -eq $v } | ForEach-Object { $_[1] }); if ($l.Count -gt 0) { "$v $($l -join ', ')" } })
    $msg = "kit: $($parts -join '; ')"; $PJ.commit = $msg
    # kit.yaml push: pr (the default): a branch on origin + a PR; push: direct (your own source): commit here, push to every remote
    $mode = Push-Mode $dir
    if ($mode -ceq 'direct') { Push-Direct $dir $leaf $files $msg $dry; return }
    if ($mode -cne 'pr') { Die-C bad_push_mode "kit.yaml 的 push 只能是 pr 或 direct（現在是 ${mode}）" }
    $origin = "$(@(Git-Q -C $dir remote get-url origin) -join '')"
    if ($LASTEXITCODE -ne 0 -or -not $origin) { Die-C no_origin "$leaf 沒有 origin，不知道要開 PR 到哪，什麼都沒送（團隊來源要有 origin；自己的來源想直接推到它的 remote，在 kit.yaml 加一行  push: direct）" }
    Check-Host $origin; Check-PushUrls $dir 'origin'
    $ownerRepo = Url-Path $origin
    # the Gitea token goes only to the Gitea you named (KIT_GITEA_API), or to origin's host when this source's own
    # kit.yaml lists it in allowed_hosts; anywhere else kit prints the link and you open the PR yourself
    $api = ''; $web = ''; $tokenTo = $false
    if ($env:KIT_GITEA_API) { $api = $env:KIT_GITEA_API.TrimEnd('/'); Check-Host $api; $web = $api -replace '/api/v1$', ''; $tokenTo = $true }
    elseif (Is-Url $origin) {
        $web = "https://$(Url-Host $origin)"; $api = "$web/api/v1"
        $own = @(YGet (Join-Path $dir 'kit.yaml') 'allowed_hosts' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
        if ($own -contains (Url-Host $origin)) { $tokenTo = $true }
    }

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
    # where the PR goes: origin's default branch (as this clone knows it, else as origin says)
    $into = "$(@(Git-Q -C $dir symbolic-ref --short -q refs/remotes/origin/HEAD) -join '')" -replace '^origin/', ''
    if (-not $into) { foreach ($l in @(Git-Safe -C $dir ls-remote --symref origin HEAD)) { if ("$l" -match '^ref:\s+refs/heads/(\S+)\s+HEAD$') { $into = $Matches[1]; break } } }
    if (-not $into) { $into = 'main' }

    $compare = if ($web) { "$web/$ownerRepo/compare/$into...$b" } else { '' }
    Say "要送的檔案（$leaf）："
    foreach ($f in $files) { Say "  $f" }
    Say "分支：${b}（PR 到 ${into}）"
    Say "commit：$msg"
    $PJ.branch = $b; $PJ.into = $into; $PJ.remotes = @('origin'); $PJ.compare = $compare
    if ($dry) { Say '（--dry-run：沒有 commit，沒有送）'; if ($JsonOut) { Push-Json $false }; return }

    # the branch starts from origin's base, so unpushed local commits are never sent
    $orig = "$(@(Git-Q -C $dir symbolic-ref --short -q HEAD) -join '')"
    if (-not $orig) { $orig = "$(@(Git-Q -C $dir rev-parse HEAD) -join '')" }
    [void](Git-Safe -C $dir fetch -q --no-recurse-submodules origin "+refs/heads/${into}:refs/remotes/origin/$into")
    if ($LASTEXITCODE -ne 0) { Warn "沒辦法更新 origin/${into}（沒網路？）" }
    [void](Git-Q -C $dir rev-parse -q --verify "refs/remotes/origin/$into")
    if ($LASTEXITCODE -ne 0) { Die-C push_failed "找不到 origin 的 ${into} 分支（沒網路？還是 origin 的主分支不叫 ${into}？），什麼都沒送" }
    $start = "refs/remotes/origin/$into"
    [void](Git-Q -C $dir checkout -q --no-track -b $b $start)
    if ($LASTEXITCODE -ne 0) { Die-C push_failed "沒辦法開分支 ${b}（你改的檔案跟 origin/$into 有衝突？），什麼都沒送" }
    $ok = Git-AddCommit $dir $msg $files
    if (-not $ok) { [void](Git-Q -C $dir checkout -q $orig); [void](Git-Q -C $dir branch -q -D $b); Die-C push_failed 'commit 失敗，什麼都沒送' }
    [void](Git-Q -C $dir checkout -q $orig)
    if ($LASTEXITCODE -ne 0) { Warn "沒辦法切回 ${orig}，你現在在 $b" }
    $o = @(Git-Safe -C $dir push -q --no-recurse-submodules origin "refs/heads/${b}:refs/heads/$b")
    if ($LASTEXITCODE -ne 0) { Warn "沒辦法 push 分支 ${b}，git 說："; Git-Err $o; Die-C push_failed "commit 留在本機的 ${b}（沒網路？沒權限？）" }
    Say "已送出分支 ${b}。改的檔案已從這裡移到那個分支，PR 合併後打 git pull 就會回來；想先看可以  git checkout $b"

    # pull request
    $tok = ''; $tf = Join-Path $KitConf 'gitea-token'
    if ($env:KIT_GITEA_TOKEN) { $tok = $env:KIT_GITEA_TOKEN }
    elseif (Test-Path -LiteralPath $tf -PathType Leaf) {
        if (-not $script:OnWindows) { $m = "$(& ls -l $tf)"; if ($m.Length -lt 10 -or $m.Substring(4, 6) -ne '------') { Warn "$tf 的權限太開放了，請打  chmod 600 $tf" } }
        $tok = (Read-Text $tf) -replace '\s', ''
    }
    if ($tok -and $api -and -not $tokenTo) {
        Say "kit.yaml 的 allowed_hosts 沒有列 $(Url-Host $origin)，kit 不把 Gitea token 送過去；PR 請自己開（或設 KIT_GITEA_API）"
    } elseif ($tok -and $api) {
        $body = "由 kit push 送出：`n" + ((@($items | ForEach-Object { "- $($_[0]) $($_[1])" })) -join "`n")
        $json = '{"title":' + (Json-Str $msg) + ',"head":' + (Json-Str $b) + ',"base":' + (Json-Str $into) + ',"body":' + (Json-Str $body) + '}'
        $code = ''
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $resp = Invoke-RestMethod -Method Post -Uri "$api/repos/$ownerRepo/pulls" -Headers @{ Authorization = "token $tok" } `
                -ContentType 'application/json; charset=utf-8' -Body ($Utf8.GetBytes($json)) -TimeoutSec 30 -UseBasicParsing
            $pr = ''; if ($resp -and ($resp.PSObject.Properties.Name -contains 'html_url')) { $pr = [string]$resp.html_url }
            $PJ.pr = $pr
        } catch { try { $code = [string][int]$_.Exception.Response.StatusCode } catch { } }
        if ($PJ.pr) { Say "已開 PR：$($PJ.pr)" } else { Warn "沒辦法自動開 PR（Gitea 回 $(if ($code) { $code } else { '沒回應' })）" }
    } elseif (-not $tok) {
        Say "沒有 Gitea token（KIT_GITEA_TOKEN 或 ${tf}），PR 請自己開"
    }
    if (-not $PJ.pr) { if ($compare) { Say "開 PR：$compare" } else { Say "請到 Gitea 用分支 $b 開 PR" } }
    if ($JsonOut) { Push-Json $true }
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
    Die-C not_maintainer '只有維護者能用 collect／outdated（kit.yaml 的 maintainers）'
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
function Skill-Dirs([string]$repo) { # the folders that hold a SKILL.md, relative ("." = the top); not inside dot folders or node_modules
    $out = @()
    foreach ($e in @(Walk-Tree $repo)) {
        if ($e.PSIsContainer -or $e.Name -cne 'SKILL.md') { continue }
        $rel = Rel-Path $repo $e.FullName
        if ("/$rel" -match '/(\.|node_modules/)') { continue }
        $d = $rel -replace '/?SKILL\.md$', ''
        $out += $(if ($d) { $d } else { '.' })
    }
    [string[]]$a = @($out); [Array]::Sort($a, [StringComparer]::Ordinal); $a
}
function Collect-License([string]$src, [string]$repo) { # the skill's own LICENSE, else the repo's ($null: none)
    foreach ($d in @($src, $repo)) {
        $l = @(Get-ChildItem -LiteralPath $d -File -Force | Where-Object { $_.Name -cmatch '^(LICENSE|LICENCE|COPYING)' } | Sort-Object Name | Select-Object -First 1 | ForEach-Object { $_.FullName })[0]
        if ($l) { return $l }
    }
    $null
}
function Collect-Scan([string]$src, [string]$outDir) { # what collect takes (text files, no links, no dot folders); copies into OUTDIR when given
    $scripts = @(); $skipped = 0
    foreach ($e in @(Walk-Tree $src)) {
        $rel = Rel-Path $src $e.FullName
        if ("/$rel" -match '/(\.|node_modules(/|$))') { continue }   # .github/, .claude-plugin/ ...: for other tools, not the skill
        if (Is-Link $e) { $skipped++; if ($outDir) { Warn "跳過捷徑 $rel" }; continue }
        if ($e.PSIsContainer) { continue }
        if ($e.Length -gt 0 -and (Is-Binary $e.FullName)) { $skipped++; if ($outDir) { Warn "跳過非文字檔 $rel" }; continue }
        if ($outDir) { $t = Join-Path $outDir $rel; Ensure-Dir (Split-Path -Parent $t); Copy-Item -LiteralPath $e.FullName -Destination $t }
        if ($rel -match '\.(sh|py|js|mjs|cjs|ts|ps1|rb|pl|bat|cmd)$') { $scripts += $rel }
    }
    [string[]]$s = @($scripts); [Array]::Sort($s, [StringComparer]::Ordinal)
    @{ scripts = ($s -join ' '); skipped = $skipped }
}
function Yaml-ListAdd([string]$f, [string]$k, [string]$v) { # VALUE goes into the list KEY ([a, b] on its line, or "- x" lines under it); no KEY: a new line KEY: [VALUE]
    $text = if (Test-Path -LiteralPath $f) { Read-Text $f } else { '' }
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]@($text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $at = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith("${k}:")) { $at = $i; break } }
    $bad = "看不懂 $f 的 ${k}，請自己把 $v 加進去"
    if ($at -lt 0) { $lines.Add("${k}: [$v]") }
    else {
        $rest = $lines[$at].Substring($k.Length + 1)
        if ($rest -match '^\s*\[') {
            $a = $lines[$at].IndexOf('['); $b = $lines[$at].IndexOf(']')
            if ($b -lt 0) { Die $bad }
            $inner = $lines[$at].Substring($a + 1, $b - $a - 1)
            $lines[$at] = $lines[$at].Substring(0, $a + 1) + $(if ($inner -match '^\s*$') { $v } else { "$inner, $v" }) + $lines[$at].Substring($b)
        } elseif ($rest -match '^\s*(#.*)?$') {
            $ind = '  '; $last = $at
            for ($i = $at + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^(\s*)-\s') { $ind = $Matches[1]; $last = $i }
                elseif ($lines[$i] -match '^\s*(#.*)?$') { continue }
                else { break }
            }
            $lines.Insert($last + 1, "$ind- $v")
        } else { Die $bad }
    }
    Write-Text $f (($lines -join $nl) + $nl)
    if (@(YGet $f $k) -notcontains $v) { Die "加進 $f 的 $k 沒成功，請自己把 $v 加進去" }
}
function Cmd-Collect($rest) {
    $arg = ''; $path = ''; $name = ''; $ref = ''; $to = ''; $force = $false; $allow = $false; $look = $false
    $r = @($rest | Where-Object { $_ })
    for ($i = 0; $i -lt $r.Count; $i++) {
        switch -CaseSensitive ($r[$i]) {
            '--path' { if ($i + 1 -ge $r.Count) { Die '--path 後面要接 repo 裡的資料夾' }; $i++; $path = $r[$i] }
            '--name' { if ($i + 1 -ge $r.Count) { Die '--name 後面要接名字' }; $i++; $name = $r[$i] }
            '--ref' { if ($i + 1 -ge $r.Count) { Die '--ref 後面要接分支或 tag' }; $i++; $ref = $r[$i] }
            '--to' { if ($i + 1 -ge $r.Count) { Die '--to 後面要接來源' }; $i++; $to = $r[$i] }
            '--force' { $force = $true }
            '--allow' { $allow = $true }
            '--look' { $look = $true }
            default { if ($r[$i].StartsWith('-')) { Die-C usage "不認得 $($r[$i])" }; if ($arg) { Die-C usage "多了一個參數：$($r[$i])" }; $arg = $r[$i] }
        }
    }
    if (-not $arg) { Die-C usage '用法：kit collect <原作者的 repo 網址> [--path repo 裡的資料夾] [--name 名字] [--ref 分支或 tag] [--allow]，或 kit collect <名字>（再收一次）' }
    $dir = Target-Dir $to
    Check-Maintainer $dir
    if (Is-Url $arg) { $url = $arg }
    else {
        $line = Lock-Get $dir $arg; if (-not $line) { Die "$(Split-Path -Leaf $dir) 的 third_party.lock 裡沒有 ${arg}（第一次收要給網址）" }
        $f = $line.Split("`t"); $name = $arg; $url = $f[1]
        if (-not $path) { $path = $f[2] }
        if (-not $ref -and $f[3] -ne '-') { $ref = $f[3] }
    }
    if ($path -eq '.') { $path = '' }
    # collect_sources: who may be collected from. --allow adds this author to it, only in your own source (push: direct);
    # a team source's list is the maintainers' to change. --look only looks: it says whether the author is on the list.
    $ok = Collect-Allowed $url $dir
    $real = "$(& git ls-remote --get-url $url 2>$null)".Trim()
    $moved = $real -and $real -ne $url
    if ($moved -and -not (Collect-Allowed $real $dir)) {
        if (-not $look) { Die-C not_allowed "git 設定把 $url 改到 ${real}，不在 collect_sources" }
        $ok = $false
    }
    $own = (Push-Mode $dir) -eq 'direct'
    # --look downloads only what kit collect could take: a host in allowed_hosts (the target source's own list, else
    # every source's), and an author on collect_sources or one your own source can add (--allow)
    $savePush = $script:PushDir; $script:PushDir = $dir; Check-Host $url; $script:PushDir = $savePush
    if (-not $ok -and $look) {
        if ($moved) { Die-C not_allowed "git 設定把 $url 改到 ${real}，不在 collect_sources，不下載" }
        if (-not $own) { Die-C not_allowed "$(Url-Id $url) 不在 collect_sources（$(Split-Path -Leaf $dir)/kit.yaml），不下載；這是團隊的來源，要請維護者把它加進 kit.yaml 的 collect_sources" }
    }
    $add = $false
    if (-not $ok -and -not $look) {
        if (-not $allow) {
            if ($own) { Die "$(Url-Id $url) 不在 collect_sources（$(Split-Path -Leaf $dir)/kit.yaml），不能收；確定要收就加 --allow，一起加進清單" }
            Die "$(Url-Id $url) 不在 collect_sources（$(Split-Path -Leaf $dir)/kit.yaml），不能收"
        }
        if (-not $own) { Die "--allow 只能用在你自己的來源（kit.yaml 寫 push: direct 的）；團隊來源請維護者把 $(Url-Id $url) 加進 kit.yaml 的 collect_sources" }
        if ($moved) { Die "git 設定把 $url 改到 ${real}：--allow 不幫這種網址加清單" }
        $add = $true
    }
    $path = $path.Replace('\', '/').Trim('/')
    if ("/$path/" -match '/\.\.?/') { Die '--path 不能有 .. 或 .' }

    $tmp = New-TempDir 'kit-collect.'
    try {
        $repo = Join-Path $tmp 'repo'
        if (-not $look) { Say "從 $(Url-Id $url) 下載$(if ($ref) { "（$ref）" })…" }
        $ga = @('clone', '-q', '--depth', '1', '--no-recurse-submodules'); if ($ref) { $ga += @('--branch', $ref) }
        $out = Git-Safe @($ga + @($url, $repo))
        if ($LASTEXITCODE -ne 0) { foreach ($l in @($out)) { Warn "  $l" }; Die-C download_failed "沒辦法下載 $url" }
        $sha = "$(& git -C $repo rev-parse HEAD)".Trim()
        $repo = Full-Path $repo
        # which folder: --path, else the top if it has a SKILL.md, else the only folder in the repo that has one
        $found = @(if ($path) { $path } elseif (Test-Path -LiteralPath (Join-Path $repo 'SKILL.md') -PathType Leaf) { '.' } else { Skill-Dirs $repo })
        if ($found.Count -eq 0) { Die-C no_skill "$(Url-Id $url) 裡找不到 SKILL.md" }
        if ($look) { # what kit would collect, as JSON (a screen program shows it before you collect)
            $sk = @()
            foreach ($d in $found) {
                $src = if ($d -eq '.') { $repo } else { Join-Path $repo $d }
                if (-not (Test-Path -LiteralPath (Join-Path $src 'SKILL.md') -PathType Leaf)) { Die-C no_skill "$(Url-Id $url)/$d 裡沒有 SKILL.md" }
                $fm = $null; try { $fm = Yaml-Lines (Join-Path $src 'SKILL.md') -Frontmatter } catch { $fm = @() }
                $n = $name; if (-not $n) { $n = "$(@(YGet-From $fm 'name')[0])" }
                if (-not $n) { $n = if ($d -eq '.') { Split-Path -Leaf (Url-Id $url) } else { Split-Path -Leaf $d } }
                $desc = "$(@(YGet-From $fm 'description')[0])"
                $lic = Collect-License $src $repo; $kind = if ($lic) { License-Kind $lic } else { '' }
                $sc = Collect-Scan $src $null
                $dst = Join-Path (Join-Path $dir 'skills') $n
                $ex = if (Test-Path -LiteralPath $dst) { if (Lock-Get $dir $n) { 'collected' } else { 'own' } } else { '' }
                $sk += ('{"path": ' + (Json-Str $d) + ', "name": ' + (Json-Str $n) + ', "valid": ' + $(if (Valid-Name $n) { 'true' } else { 'false' }) +
                    ', "description": ' + (Json-Str $desc) + ', "license": ' + (Json-Str $kind) + ', "scripts": ' + (Json-Str $sc.scripts) +
                    ', "skipped": ' + $sc.skipped + ', "exists": ' + (Json-Str $ex) + ', "dest": ' + (Json-Str ((Join-Path $dst 'SKILL.md').Replace('\', '/'))) + '}')
            }
            $canAllow = (-not $ok) -and $own -and -not $moved
            [Console]::Out.Write('{"source": ' + (Json-Str (Split-Path -Leaf $dir)) + ', "dir": ' + (Json-Str $dir.Replace('\', '/')) + ', "push": ' + (Json-Str (Push-Mode $dir)) +
                ', "url": ' + (Json-Str $url) + ', "id": ' + (Json-Str (Url-Id $url)) + ', "commit": ' + (Json-Str $sha) +
                ', "allowed": ' + $(if ($ok) { 'true' } else { 'false' }) + ', "can_allow": ' + $(if ($canAllow) { 'true' } else { 'false' }) +
                ', "skills": [' + "`n  " + ($sk -join ",`n  ") + "`n]}`n")
            return
        }
        if ($found.Count -gt 1) { Die ("$(Url-Id $url) 裡有好幾個 skill，用 --path 選一個：`n" + (($found | ForEach-Object { "  $_" }) -join "`n")) }
        $path = if ($found[0] -eq '.') { '' } else { $found[0] }
        $src = if ($path) { Join-Path $repo $path } else { $repo }
        if (Test-Path -LiteralPath $src -PathType Container) { $src = Full-Path $src }
        if (-not ($src + [IO.Path]::DirectorySeparatorChar).StartsWith($repo + [IO.Path]::DirectorySeparatorChar) -and $src -ne $repo) { Die '--path 要在 repo 裡面' }
        if (-not (Test-Path -LiteralPath (Join-Path $src 'SKILL.md') -PathType Leaf)) { Die "$(Url-Id $url)$(if ($path) { "/$path" }) 裡沒有 SKILL.md（用 --path 指出 skill 的資料夾）" }
        if (-not $name) { try { $name = @(YGet-From (Yaml-Lines (Join-Path $src 'SKILL.md') -Frontmatter) 'name')[0] } catch { $name = '' } }
        if (-not $name) { $name = if ($path) { Split-Path -Leaf $src } else { Split-Path -Leaf (Url-Id $url) } }
        if (-not (Valid-Name $name)) { Die "名字 $name 不行（只能小寫英文、數字和 -），用 --name 給一個" }
        $dst = Join-Path (Join-Path $dir 'skills') $name
        if ((Test-Path -LiteralPath $dst) -and -not (Lock-Get $dir $name) -and -not $force) { Die "$(Split-Path -Leaf $dir) 已經有 skill:${name}，而且不是 collect 收的（要整份換掉加 --force，或用 --name 換名字）" }
        $lic = Collect-License $src $repo
        if (-not $lic) { Die "$(Url-Id $url) 沒有 LICENSE，不知道能不能用，不收" }
        $kind = License-Kind $lic
        $outDir = Join-Path $tmp 'out'; Ensure-Dir $outDir
        $sc = Collect-Scan $src $outDir
        $licName = Split-Path -Leaf $lic
        if (-not (Test-Path -LiteralPath (Join-Path $outDir $licName))) { Copy-Item -LiteralPath $lic -Destination (Join-Path $outDir $licName) }
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Ensure-Dir (Join-Path $dir 'skills')
        Copy-Item -LiteralPath $outDir -Destination $dst -Recurse
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $p2 = if ($path) { $path } else { '.' }; $r2 = if ($ref) { $ref } else { '-' }
    Lock-Set $dir ((@($name, $url, $p2, $r2, $sha, $kind, (Get-Date -Format 'yyyy-MM-dd'))) -join "`t")
    if ($add) { Yaml-ListAdd (Join-Path $dir 'kit.yaml') 'collect_sources' (Url-Id $url); Say "已把 $(Url-Id $url) 加進 $(Split-Path -Leaf $dir)/kit.yaml 的 collect_sources" }
    Say "已收 skill:$name ← $(Url-Id $url)$(if ($path) { "/$path" }) @ $($sha.Substring(0, 12))（授權 $kind）"
    if ($kind -eq 'unknown') { Warn "認不出授權種類，請自己看 skills/$name/$licName" }
    if ($kind -eq 'GPL') { Warn 'GPL 類授權：改了再發布要公開原始碼，請確認可以用' }
    if ($sc.scripts) { Warn "這個 skill 有會執行的檔案，送出前請看過： $($sc.scripts)" }
    $script:Quiet2 = $true
    if (-not (Check-Dirs @($dir) $false)) { Warn 'kit check 有問題，送出前請先打  kit check  看看' }
    if ($own) { Say "下一步：用 git diff 看收進來的檔案；沒問題就  kit push  送出，要用它就  kit add skill $name" }
    else { Say '下一步：kit diff 看不到第三方的差異，請用 git diff 看；沒問題就  kit push  開 PR' }
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

# ---------- agents: the definitions (agents/<name>.md), for programs that show agents ----------
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
    foreach ($l in $lines) { $l = $l.TrimEnd("`r"); if ($c -ge 2) { $out += $l }; if ($l -eq '---') { $c++ } }
    ($out -join "`n").TrimEnd("`n")
}
function Cmd-Agents($rest) {
    $rest = @($rest | Where-Object { $null -ne $_ })
    if ($rest.Count -ne 1 -or $rest[0] -ne '--json') { Die-C usage '用法：kit agents --json' }
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
    Out-Json $sb.ToString()
}
function Fm-SetList([string]$f, [string]$key, [string]$val) { # KEY: [val] in the frontmatter (block lists replaced, added if missing)
    # a block list: the indented lines after KEY go, up to the next key or ---; blank and comment lines
    # in between stay only when the block goes on after them. Line ends (LF or CRLF) are kept.
    $text = Read-Text $f; $nl = $text.EndsWith("`n")
    $lines = $text -split "`n"; if ($nl) { $lines = $lines[0..($lines.Count - 2)] }
    $eol = if ($lines.Count -gt 0 -and $lines[0].EndsWith("`r")) { "`r" } else { '' }
    $out = New-Object System.Collections.Generic.List[string]
    $held = New-Object System.Collections.Generic.List[string]
    $infm = $false; $skip = $false; $done = $false; $i = 0
    foreach ($raw in $lines) {
        $i++; $l = $raw.TrimEnd("`r")
        if ($i -eq 1 -and $l -eq '---') { $infm = $true; $out.Add($raw); continue }
        if ($infm -and $skip) {
            if ($l -match '^[ \t]*(#.*)?$') { $held.Add($raw); continue }
            if ($l -match '^[ \t]') { $held.Clear(); continue }
            $skip = $false; $out.AddRange($held); $held.Clear()
        }
        if ($infm -and $l -eq '---') { if (-not $done) { $out.Add("${key}: [$val]$eol") }; $done = $true; $infm = $false; $out.Add($raw); continue }
        if ($infm -and $l.StartsWith("${key}:")) { $out.Add("${key}: [$val]$eol"); $done = $true; if ($l.Substring($key.Length + 1) -match '^[ \t]*(#.*)?$') { $skip = $true }; continue }
        $out.Add($raw)
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
    $fm = $null; try { $fm = Yaml-Lines $f -Frontmatter } catch { Die "$f 開頭的 --- 區塊讀不懂，沒改（打 kit check 看哪裡錯）" }
    $cur = @(YGet-From $fm $key | Where-Object { $_ })
    if ($verb -eq 'add') {
        if (-not (Find-Item $k $item)) { Die "找不到 ${k}:${item}（kit 的來源裡沒有）" }
        if ($cur -contains $item) { Say "agent $n 已經有 ${k}:${item}"; return }
        $new = @($cur + $item)
    } else {
        if ($cur -notcontains $item) { Say "agent $n 本來就沒有 ${k}:${item}"; return }
        $new = @($cur | Where-Object { $_ -ne $item })
    }
    Fm-SetList $f $key ($new -join ', ')
    $d = Split-Path -Parent (Split-Path -Parent $f)
    Say "agent ${n}：$(if ($verb -eq 'add') { '加上' } else { '拿掉' }) ${k}:${item}（改了 ${f}，還沒送出：打  kit push --to $(Split-Path -Leaf $d)）"
    $sep = [IO.Path]::DirectorySeparatorChar
    if (($d + $sep).StartsWith($KitSrc.TrimEnd('/', '\') + $sep) -or ($d + $sep).StartsWith((Canon-Dir $KitSrc).TrimEnd('/', '\') + $sep)) { Warn "這個檔案在 kit 自己同步用的資料夾（${KitSrc}）裡：沒送出前，kit sync 可能沒辦法更新它；最好在你自己 clone 的來源改" }
    if (@(YGet $Machine 'approvals' | Where-Object { $_ }).Count -gt 0) { Warn '這台只用簽過的版本（approvals）：改的要送出、合併、再簽過，這台才會用到' }
}

function Usage {
    Say @'
kit - 管理 AI 寫程式工具的 rule、skill、MCP 和 agent

  kit init <網址|資料夾> [更多...]   第一次：設定來源，加上預設的東西
  kit list [--json]                 有哪些、你在用哪些、哪些是新的（--json 給程式讀）
     --json --dir 資料夾 [--pid 程式編號]
                                    再列出在那個資料夾開的 agent 另外會讀到的（不是 kit 管的）
  kit agents --json                 每個 agent 用了哪些 rule、skill、MCP（JSON，給畫面程式用）
  kit agent <名字> add|rm rule|skill|mcp <東西>   改 agent 用的東西（改來源裡的檔案，再用 kit push 送出）
  kit add rule|skill|mcp <名字>     開始用（整個帳號：每個資料夾、每個 agent 都有）
  kit rm  rule|skill|mcp <名字>     不用了（之後 sync 也不會加回來）
  kit add --dir <資料夾> rule|skill|mcp <名字>
                                    只加到這個資料夾：在這裡（含子資料夾）開的 agent 才有
  kit rm  --dir <資料夾> rule|skill|mcp <名字>
  kit tools                         skill 會用到的程式（node、python…）：這台有沒有、怎麼裝
  kit install-tool <程式名> [--min 版本]
                                    用 kit 的裝法裝，太舊就升級（畫面程式的「安裝」按鈕也是用這個）
  kit install-deps <skill> [npm|pip] 裝 skill 自己的套件（在 kit 的資料夾，不跑套件的安裝程式）
  kit install-deps mcp <名字>       裝 MCP 的套件（固定的版本），之後不用每次啟動時下載
  kit context --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--detail [--fresh]]
                                  那個 agent 的 context 用了多少（JSON；--detail：用在哪些地方）
  kit files --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--git] [--json]
                                  那個 agent 讀過、改過的檔案，新的在前（--json 給程式讀；--git：再加上 git 有變動的）
  kit run <agent> [--tool codex|omp] [參數]   開一個做好的 agent（預設用 Claude）
  kit sync [--force]                現在更新（kit run 會自動做）

寫內容的人用（只吃本機資料夾，不連網）：
  kit new rule|skill|mcp|agent <名字> [--from 本機資料夾] [--to 來源]
  kit new mcp [名字] --config 檔案|- [--to 來源] [--look]
                                    從貼上的 MCP 設定建立（JSON、claude mcp add、codex mcp add、config.toml）；
                                    密碼和 token 換成 ${變數}，套件固定版本（只有這個會連網：查最新版本）；--look 只看不寫（JSON）
  kit diff   [種類] <名字> --from 本機資料夾   比較
  kit update [種類] <名字> --from 本機資料夾   更新；別人改過會停下來（--force 硬蓋）
  kit check [--ci] [資料夾...]      檢查格式、引用、名字重複、網址、不該公開的字

維護者用（只收 kit.yaml 的 collect_sources 列的原作者）：
  kit collect <原作者 repo 網址> [--path 資料夾] [--name 名字] [--ref 分支] [--allow]   收別人的 skill（保留 LICENSE）
                                    （沒給 --path：repo 裡只有一個 SKILL.md 就用它；--allow：自己的來源一起加進 collect_sources）
  kit collect <名字>                再收一次＝整份換成原作者的新版
  kit collect <原作者 repo 網址> --look [--path 資料夾] [--ref 分支] [--to 來源]
                                    只下載來看、什麼都不寫：找到的 skill、授權、會執行的檔案（JSON，給程式讀）
  kit outdated                      看收過的 skill 原作者有沒有新版
  kit export-self <資料夾> [--version <版本>]   匯出 kit 的原始碼（給公司的 git server）
  kit ci-template [檔案]            Gitea Actions 範本（PR 自動跑 kit check --ci），例：
                                      kit ci-template .gitea/workflows/kit-check.yaml
  kit push [--to 來源] [--dry-run] [--json]
                                    檢查後送出改的東西：開 PR（預設），或 kit.yaml 寫 push: direct 就直接推
                                    （--json：送了／會送什麼、錯誤，都印成 JSON 給程式讀）

  kit self-update                   更新 kit 本身
  kit uninstall [--self]            拿掉 kit 加的東西（--self 連 kit 也移除）
  kit --version
  kit api                           給程式讀的介面版本（major.minor，例如 1.2）：給畫面程式確認看得懂 kit 的輸出。
                                    不相容的改變 major 加一；新增欄位或指令 minor 加一（清單看 README 的「給程式讀的介面」）
'@
}

# ---------- main ----------
$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
$rest = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }
# programs read JSON: list/agents/push/files --json and collect/new --look print only JSON on stdout (errors too)
if ((@('list', 'ls', 'agents', 'push', 'files') -ccontains $cmd -and @($rest) -ccontains '--json') -or (@('collect', 'new') -ccontains $cmd -and @($rest) -ccontains '--look')) { $script:JsonOut = $true }
try {
    # the commands that change state.tsv, the tools' files or a source: one kit at a time (sync --hook / --bg take it themselves)
    if (@('init', 'sync', 'add', 'rm', 'remove', 'uninstall', 'push', 'agent', 'install-deps') -contains $cmd -and -not (@($rest) -contains '--hook' -or @($rest) -contains '--bg')) { [void](Take-Lock) }
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
        'tools' { Cmd-Tools $rest }
        'install-tool' { Cmd-InstallTool $rest }
        'install-deps' { Cmd-InstallDeps $rest }
        'context' { Cmd-Context $rest }
        'files' { Cmd-Files $rest }
        'statusline' { Cmd-Statusline }
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
        'api' { Say $KitApi }     # the version of what programs read (README: 給程式讀的介面)
        { $_ -in '--version', 'version' } { Say "kit $KitVersion" }
        { $_ -in '', '-h', '--help', 'help' } { Usage }
        '__json-get' { $v = Json-Get $rest[0] $rest[1]; if ($null -eq $v) { exit 1 }; Say $v }   # for tests
        '__dir-hash' { Say (Dir-Hash @($rest)[0]) }                                                  # for tests
        default { Die "沒有這個指令：${cmd}（打 kit help）" }
    }
} catch {
    if ($env:KIT_DEBUG) { Warn $_.ScriptStackTrace }
    Die $_.Exception.Message
} finally { if (-not ($cmd -eq 'sync' -and @($rest) -contains '--bg')) { Release-Lock } }
exit 0
