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
    foreach ($raw in (Read-Text $path) -split "`n") {
        $no++
        $line = $raw.TrimEnd("`r")
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
function Allowed-Hosts { Uniq @(foreach ($d in Src-Dirs) { YGet (Join-Path $d 'kit.yaml') 'allowed_hosts' }) }

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
        if ((Test-Path -LiteralPath $dst) -and -not $old) { Warn "$dst 已經存在，不是 kit 放的，跳過"; continue }
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

function Cmd-Init($srcs) {
    if (@($srcs).Count -lt 1) { Die '用法：kit init <網址或資料夾> [更多來源...]' }
    $list = @(foreach ($s in $srcs) {
        if (Is-Url $s) { $s }
        elseif (Test-Path -LiteralPath $s -PathType Container) { (Resolve-Path -LiteralPath $s).ProviderPath }
        else { Die "找不到資料夾：$s" }
    })
    Write-Machine $list @() @()
    foreach ($s in M-Sources) { Fetch-Source $s }
    # sources may include more sources (for example the third-party repo)
    $more = @(foreach ($d in Src-Dirs) { YGet (Join-Path $d 'kit.yaml') 'include' })
    if ($more.Count -gt 0) {
        Write-Machine (Uniq ($list + $more)) @() @()
        foreach ($s in $more) { Fetch-Source $s }
    }
    Write-Machine (M-Sources) (Kit-Items 'recommended') @()
    Say "kit：設定好 $(@(M-Sources).Count) 個來源"
    Apply-All
    Seen-All
    Say 'kit：完成。打  kit list  看有哪些'
}
function Cmd-Sync {
    Need-Init
    foreach ($s in M-Sources) { Fetch-Source $s }
    Apply-All
    $new = @(foreach ($i in Available) { if ($null -eq (State-Get 'seen' $i)) { $i } })
    if ($new.Count -gt 0) { Say "kit：新： $($new -join ' ')  （要用就 kit add <種類> <名字>）" }
    Seen-All
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

function Cmd-List {
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
function Cmd-Run($rest) {
    $rest = @($rest)
    if ($rest.Count -lt 1) { Die '用法：kit run <agent> [claude 的參數...]' }
    Need-Init
    $name = $rest[0]; $extra = if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] } else { @() }
    $f = Find-Item 'agent' $name; if (-not $f) { Die "找不到 agent ${name}（打 kit list 看有哪些）" }
    $script:Quiet = $true; try { Cmd-Sync } catch { }; $script:Quiet = $false

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('kit-run.' + [IO.Path]::GetRandomFileName())
    Ensure-Dir (Join-Path $tmp '.claude/skills')
    $fm = $null
    try { $fm = Yaml-Lines $f -Frontmatter } catch { Die "bad header in $f" }
    foreach ($n in YGet-From $fm 'skills') {
        $p = Find-Item 'skill' $n; if (-not $p) { Warn "skill $n not found"; continue }
        Copy-Item -LiteralPath (Split-Path -Parent $p) -Destination (Join-Path $tmp ".claude/skills/$n") -Recurse
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in YGet-From $fm 'rules') {
        $p = Find-Item 'rule' $n; if (-not $p) { Warn "rule $n not found"; continue }
        [void]$sb.Append((Read-Text $p)).Append("`n")
    }
    $c = 0; foreach ($l in (Read-Text $f) -split "`n") { if ($c -ge 2) { [void]$sb.Append($l.TrimEnd("`r")).Append("`n") }; if ($l.TrimEnd("`r") -eq '---') { $c++ } }
    Write-Text (Join-Path $tmp 'prompt.md') $sb.ToString()
    $mcps = @(foreach ($n in YGet-From $fm 'mcp') {
        $p = Find-Item 'mcp' $n; if (-not $p) { Warn "mcp $n not found"; continue }
        $k = Mcp-Json $p; if ($k) { (Json-Str $n) + ':' + $k }
    })
    Write-Text (Join-Path $tmp 'mcp.json') ('{"mcpServers":{' + ($mcps -join ',') + "}}`n")

    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]]@('--add-dir', $tmp, '--append-system-prompt-file', (Join-Path $tmp 'prompt.md'), '--mcp-config', (Join-Path $tmp 'mcp.json')))
    $only = @(YGet-From $fm 'tools.only'); if ($only.Count -gt 0) { $a.Add('--tools'); $a.Add($only -join ',') }
    foreach ($d in YGet-From $fm 'tools.deny') { $a.Add('--disallowedTools'); $a.Add($d) }
    foreach ($x in $extra) { $a.Add($x) }
    if ($env:KIT_DRY_RUN) { Say 'claude'; foreach ($x in $a) { Say $x }; Say "tmp=$tmp"; return }
    & claude @($a.ToArray())
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
    [void](Git-Safe -C $repo pull --ff-only -q)
    if ($LASTEXITCODE -ne 0) { Die "沒辦法更新 ${repo}（沒網路，或 clone 裡有自己的改動？）" }
    $exe = (Get-Process -Id $PID).Path
    & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'windows/install.ps1') -Quiet
    if ($LASTEXITCODE -ne 0) { Die '重新安裝失敗' }
    Say "kit：已更新到 $((Read-Text (Join-Path $KitLib 'VERSION')).Trim())"
}
function Usage {
    Say @'
kit - 管理 AI 寫程式工具的 rule、skill、MCP 和 agent

  kit init <網址|資料夾> [更多...]   第一次：設定來源，加上預設的東西
  kit list                          有哪些、你在用哪些、哪些是新的
  kit add rule|skill|mcp <名字>     開始用
  kit rm  rule|skill|mcp <名字>     不用了（之後 sync 也不會加回來）
  kit run <agent> [claude 的參數]   開一個做好的 agent
  kit sync [--force]                現在更新（kit run 會自動做）
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
        { $_ -in 'list', 'ls' } { Cmd-List }
        'add' { Cmd-AddRm 'add' $rest }
        { $_ -in 'rm', 'remove' } { Cmd-AddRm 'rm' $rest }
        'run' { Cmd-Run $rest }
        'uninstall' { Cmd-Uninstall $rest }
        'self-update' { Cmd-SelfUpdate }
        { $_ -in '--version', 'version' } { Say "kit $KitVersion" }
        { $_ -in '', '-h', '--help', 'help' } { Usage }
        '__json-get' { $v = Json-Get $rest[0] $rest[1]; if ($null -eq $v) { exit 1 }; Say $v }   # for tests
        default { Die "沒有這個指令：${cmd}（打 kit help）" }
    }
} catch {
    Die $_.Exception.Message
}
exit 0
