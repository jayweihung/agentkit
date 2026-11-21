. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
function FileUrl([string]$p) { $p = $p.Replace('\', '/'); if ($p.StartsWith('/')) { "file://$p" } else { "file:///$p" } }
function G { & git @args 2>&1 | Out-Null }
# ---------- versions: kit list --json version, upstream, installed, held, loaded (kit api 1.14) ----------
$hSave = $H; Set-Home (Join-Path $T 'homev'); $VS = Join-Path $T 'versrc'
function VItem([string]$kind, [string]$name) { @($out -split "`n" | Where-Object { $_.Contains("{`"kind`": `"$kind`", `"name`": `"$name`",") })[0] }
function Blob8([string]$f) { "$(& git hash-object --no-filters -- $f)".Trim().Substring(0, 8) }
function VCommit([string]$when, [string]$msg) { $env:GIT_AUTHOR_DATE = $when; $env:GIT_COMMITTER_DATE = $when; G -C $VS add -A; G -C $VS -c user.name=t -c user.email=t@t commit -qm $msg; Remove-Item env:GIT_AUTHOR_DATE, env:GIT_COMMITTER_DATE }
W "$VS/rules/vr.md" "Be kind.`n"; W "$VS/skills/vs/sub/a.txt" "x`n"; W "$VS/skills/vs/SKILL.md" "---`nname: vs`ndescription: v`n---`nv1`n"
W "$VS/plugins/vp/.claude-plugin/plugin.json" "{`"name`": `"vp`", `"description`": `"p`"}`n"; W "$VS/plugins/vp/skills/x/SKILL.md" "---`nname: x`ndescription: x`n---`nx`n"
W "$VS/third_party.lock" ("# third_party.lock`nvs`tfile:///a/vs`tskills/vs`t-`t" + ('0' * 39) + "1`tMIT`t2026-11-15`t-`t2026-11-10`n")
G -C $VS init -q; VCommit '2026-11-01T10:00:00Z' 'first'
W "$VS/rules/vr.md" "Be kind, always.`n"; VCommit '2026-11-02T09:00:00Z' 'rule a'
$rid = Blob8 "$VS/rules/vr.md"
W "$T/vl" ("$((& git hash-object --no-filters -- "$VS/skills/vs/SKILL.md").Trim()) SKILL.md`n$((& git hash-object --no-filters -- "$VS/skills/vs/sub/a.txt").Trim()) sub/a.txt`n"); $sid = Blob8 "$T/vl"
W "$T/vl" ("$((& git hash-object --no-filters -- "$VS/plugins/vp/.claude-plugin/plugin.json").Trim()) .claude-plugin/plugin.json`n$((& git hash-object --no-filters -- "$VS/plugins/vp/skills/x/SKILL.md").Trim()) skills/x/SKILL.md`n"); $plid = Blob8 "$T/vl"
Kit init (FileUrl $VS); Kit add rule vr; Kit add skill vs
KitJ list --json; $vj1 = $out
$head = "$(& git -C $VS rev-parse HEAD)".Trim()
Check "version: a rule's id is its file's blob; the last commit that changed it, n = how many that day" { (VItem rule vr).Contains("`"version`": {`"id`": `"$rid`", `"date`": `"2026-11-02`", `"n`": 1, `"commit`": `"$head`", `"message`": `"rule a`", `"dirty`": false}, `"upstream`": null, `"installed`": {`"claude`": {`"id`": `"$rid`", `"at`": ") }
Check "version: a skill's id is the blob of its listing; upstream from third_party.lock; installed with a time" { $l = VItem skill vs; $l.Contains("`"version`": {`"id`": `"$sid`", `"date`": `"2026-11-01`", `"n`": 1,") -and $l.Contains("`"upstream`": {`"commit`": `"$(('0' * 39) + '1')`", `"date`": `"2026-11-10`", `"collected`": `"2026-11-15`"}") -and $l -cmatch "`"installed`": \{`"claude`": \{`"id`": `"$sid`", `"at`": [0-9]{10}\}, `"codex`": null, `"omp`": null\}, `"held`": null\}" }
Check "version: a plugin's id is the blob of its listing too; not installed" { (VItem plugin vp).Contains("`"version`": {`"id`": `"$plid`",") -and (VItem plugin vp).Contains('"installed": {"claude": null, "codex": null, "omp": null}, "held": null}') }
Check 'installed: state.tsv keeps the version and its time' { (ReadT "$H/.config/agentkit/state.tsv") -cmatch "(?m)^ver`tclaude:skill:vs`t$sid [0-9]+ " }
# the same content elsewhere (a folder, not git; with .DS_Store and Python caches): the same ids, no date or commit
$VC = Join-Path $T 'vcopy'; [void](New-Item -ItemType Directory -Force -Path $VC); foreach ($x in 'rules', 'skills', 'plugins') { Copy-Item -Recurse "$VS/$x" "$VC/$x" }
W "$VC/skills/vs/.DS_Store" "x"; W "$VC/skills/vs/sub/__pycache__/a.pyc" "c"
Set-Home (Join-Path $T 'homev2'); Kit init $VC; KitJ list --json
Check 'version: the same content not in git (with .DS_Store and caches): the same ids, no date or commit' { (VItem rule vr).Contains("`"version`": {`"id`": `"$rid`", `"date`": null, `"n`": null, `"commit`": null, `"message`": null, `"dirty`": false}") -and (VItem skill vs).Contains("`"id`": `"$sid`"") -and (VItem plugin vp).Contains("`"id`": `"$plid`"") }
Set-Home (Join-Path $T 'homev')
# a change not committed in the clone: dirty, the files' id; installed still the old one
$CLV = "$H/agentkit/versrc"; Add-Content -LiteralPath "$CLV/skills/vs/SKILL.md" 'more'
KitJ list --json
Check 'version: a change not committed: dirty, commit null, installed still the old one' { $l = VItem skill vs; $l.Contains('"commit": null, "message": "first", "dirty": true}') -and -not $l.Contains("`"version`": {`"id`": `"$sid`"") -and $l.Contains("`"installed`": {`"claude`": {`"id`": `"$sid`"") }
G -C $CLV checkout -q -- .
# the source changes: the latest is what kit sync fetched; then kit sync: the new id, a new time
W "$VS/rules/vr.md" "Be kind, really.`n"; VCommit '2026-11-03T10:00:00Z' 'rule c'; G -C $CLV fetch -q
$rid2 = Blob8 "$VS/rules/vr.md"
KitJ list --json
Check 'version: the latest is the remote branch kit sync fetched; installed is older' { (VItem rule vr).Contains("`"version`": {`"id`": `"$rid2`", `"date`": `"2026-11-03`"") -and (VItem rule vr).Contains("`"installed`": {`"claude`": {`"id`": `"$rid`"") }
Kit sync; KitJ list --json
Check 'installed: kit sync took the new one' { (VItem rule vr).Contains("`"installed`": {`"claude`": {`"id`": `"$rid2`"") }
$sa = @{ FilePath = $Exe; ArgumentList = @('-NoProfile', '-Command', 'Start-Sleep 600'); PassThru = $true }; if ($OnWindows) { $sa.WindowStyle = 'Hidden' }
$sp = Start-Process @sa
KitJ list --json --pid $sp.Id --tool claude; $l1 = VItem rule vr; $l2 = VItem plugin vp
KitJ list --json --pid $sp.Id; $l3 = VItem rule vr
Check 'loaded: an agent started after kit sync: new; not installed: null; one kit cannot tell (no --tool): unknown; no --pid: none' { $l1.EndsWith('"held": null, "loaded": "new"},') -and $l2.EndsWith('"held": null, "loaded": null}') -and $l3.EndsWith('"held": null, "loaded": "unknown"},') -and -not $vj1.Contains('"loaded"') }
Stop-Process -Id $sp.Id -Force -ErrorAction SilentlyContinue
if (-not $OnWindows) {
    KitJ list --json; $bash = (& /bin/sh -c "cd '$Repo' && HOME='$H' unix/kit list --json 2>/dev/null") -join "`n"
    Check 'version: unix/kit prints the same' { $bash -ceq $out }
}
Set-Home $hSave

} finally { Done }
