# Install kit for the current user only (no admin needed).
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1
# Files go to %LOCALAPPDATA%\Programs\agentkit; that folder is added to the
# user's PATH so "kit" works in cmd and PowerShell (new windows).
# This file must stay UTF-8 with BOM (Windows PowerShell 5.1 reads it as ANSI otherwise).
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { [Console]::Out.WriteLine($m) } }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path variable:IsWindows) -and $IsWindows)
$dest = if ($env:AGENTKIT_HOME) { $env:AGENTKIT_HOME }
        elseif ($onWindows) { Join-Path $env:LOCALAPPDATA 'Programs\agentkit' }
        else { Join-Path $env:HOME '.local/share/agentkit-ps' }
$lib = Join-Path $dest 'lib'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('install: 找不到 git，請先裝 Git for Windows'); exit 1
}

New-Item -ItemType Directory -Force -Path $lib | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'windows\kit.ps1') -Destination (Join-Path $lib 'kit.ps1') -Force
Copy-Item -LiteralPath (Join-Path $repo 'VERSION') -Destination (Join-Path $lib 'VERSION') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $lib 'templates') | Out-Null
Copy-Item -Path (Join-Path $repo 'templates\*') -Destination (Join-Path $lib 'templates') -Force
$hp = Join-Path $lib 'herdr'   # kit herdr-panel install copies the panel from here
if (Test-Path -LiteralPath $hp) { Remove-Item -LiteralPath $hp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $hp | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'herdr\kit-panel') -Destination $hp -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repo 'herdr\kit-pane') -Destination $hp -Recurse -Force
# the Herdr panel, if kit herdr-panel install put it there: new files, same settings (mod.json, config.json)
$uh = if ($onWindows -and $env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$hh = if ($env:HERDR_APP_HOME) { $env:HERDR_APP_HOME } elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'herdr-app' } else { Join-Path $uh '.config/herdr-app' }
$hm = Join-Path $hh 'mods/kit'
if (Test-Path -LiteralPath (Join-Path $hm '.kit-panel')) { Copy-Item -Path (Join-Path $repo 'herdr\kit-panel\*') -Destination $hm -Recurse -Force }
$hm = Join-Path $hh 'mods/kit-pane'
if (Test-Path -LiteralPath (Join-Path $hm '.kit-panel')) { Copy-Item -Path (Join-Path $repo 'herdr\kit-pane\*') -Destination $hm -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $repo 'windows\kit.cmd') -Destination (Join-Path $dest 'kit.cmd') -Force
[IO.File]::WriteAllText((Join-Path $lib '.repo'), $repo, (New-Object Text.UTF8Encoding $false))   # where kit self-update pulls from

if ($onWindows) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $p) { $p = '' }
    $parts = @($p.Split(';') | Where-Object { $_ })
    if (@($parts | Where-Object { $_.TrimEnd('\') -eq $dest.TrimEnd('\') }).Count -eq 0) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $dest) -join ';'), 'User')
        Say "已把 $dest 加進你的 PATH，開新的終端機後生效"
    }
}
$v = ([IO.File]::ReadAllText((Join-Path $lib 'VERSION'))).Trim()
Say "kit $v 裝好了。下一步：kit init <團隊來源的網址>"
exit 0
