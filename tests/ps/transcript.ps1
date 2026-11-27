. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# ---------- is Claude saving its transcript? (kit sync --hook under a fake claude started with a chosen environment) ----------
$FC = Join-Path $T 'fake-claude'; $TH = Join-Path $T 'tch'
[void](New-Item -ItemType Directory -Force -Path $FC, (Join-Path $TH '.claude'))
if ($OnWindows) { Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') (Join-Path $FC 'claude.exe') }
elseif ($IsMacOS) {   # ps -E shows no environment of Apple's own programs (bash, sh): a tiny one of our own
    W "$FC/c.c" "#include <stdlib.h>`nint main(int c, char **v) { return system(v[1]) == 0 ? 0 : 1; }`n"
    & xcode-select -p *> $null; if ($LASTEXITCODE -eq 0) { & cc -o "$FC/claude" "$FC/c.c" 2>$null }
} else { & ln -s (Get-Command bash).Source "$FC/claude" }
function TC([hashtable]$envs, [switch]$HookChild) { # kit sync --hook run by the fake claude started with $envs; output in $script:out
    $names = 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE', 'KIT_TRANSCRIPT_CHECK'
    $keep = @{}; foreach ($v in $names + 'HOME', 'USERPROFILE') { $keep[$v] = [Environment]::GetEnvironmentVariable($v) }
    foreach ($v in $names) { [Environment]::SetEnvironmentVariable($v, $null) }
    $env:HOME = $TH; $env:USERPROFILE = $TH; if ($OnWindows) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $TH 'AppData\Local')) }
    foreach ($k in $envs.Keys) { [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
    $o = Join-Path $T 'tc.out'; Remove-Item -LiteralPath $o -ErrorAction SilentlyContinue
    try {   # -HookChild: the hook's own environment has CHILD_SESSION=1 (Claude gives it to every hook)
        $kc = if ($HookChild) { "`"$Exe`" -NoProfile -ExecutionPolicy Bypass -Command `"`$env:CLAUDE_CODE_CHILD_SESSION='1'; & '$Kit' sync --hook`"" }
              else { "`"$Exe`" -NoProfile -ExecutionPolicy Bypass -File `"$Kit`" sync --hook" }
        if ($OnWindows) { Start-Process -FilePath (Join-Path $FC 'claude.exe') -ArgumentList "/d /c `"$kc > `"$o`"`"" -Wait -NoNewWindow }
        elseif ($IsMacOS) { & "$FC/claude" ($kc.Replace('$', '\$') + " > '$o'") }
        else { & "$FC/claude" -c ($kc.Replace('$', '\$') + " > '$o'; :") }
    } finally { foreach ($v in $keep.Keys) { [Environment]::SetEnvironmentVariable($v, $keep[$v]) } }
    $script:out = if (Test-Path -LiteralPath $o) { (ReadT $o).Trim() } else { '' }
}
if ((Test-Path (Join-Path $FC 'claude')) -or (Test-Path (Join-Path $FC 'claude.exe'))) {
    TC @{}; Check 'transcript: a normal claude: nothing said' { $out -eq '' }
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1' }; W "$T/tc.json" $out
    Check 'transcript: claude started with CHILD_SESSION=1: warned, as JSON for Claude' { (JGet "$T/tc.json" 'hookSpecificOutput.hookEventName') -eq '"SessionStart"' -and (JGet "$T/tc.json" 'systemMessage').Contains('/resume') }
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1'; CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = '1' }
    Check 'transcript: ... and FORCE_SESSION_PERSISTENCE=1 too: nothing said' { $out -eq '' }
    TC @{} -HookChild; Check "transcript: the hook's own CHILD_SESSION=1 (Claude gives it to every hook) is not looked at" { $out -eq '' }
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1'; KIT_TRANSCRIPT_CHECK = '0' }; Check 'transcript: KIT_TRANSCRIPT_CHECK=0: nothing said' { $out -eq '' }
    W "$TH/.claude/settings.json" '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/transcript-check.sh"}]}]}}'
    TC @{ CLAUDE_CODE_CHILD_SESSION = '1' }; Check 'transcript: your own transcript-check hook: kit says nothing (no second warning)' { $out -eq '' }
} else { [Console]::WriteLine('(transcript check: skipped, no C compiler on this Mac)') }

} finally { Done }
