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
$tl = Join-Path $lib 'tools'; if (Test-Path -LiteralPath $tl) { Remove-Item -LiteralPath $tl -Recurse -Force }   # how kit installs node, python, git
New-Item -ItemType Directory -Force -Path $tl | Out-Null
Copy-Item -Path (Join-Path $repo 'tools\*.yaml') -Destination $tl -Force
$old = Join-Path $lib 'herdr'   # what older kits kept here for a Herdr panel (kit's own copy; nothing in Herdr is touched)
if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $repo 'windows\kit.cmd') -Destination (Join-Path $dest 'kit.cmd') -Force
[IO.File]::WriteAllText((Join-Path $lib '.repo'), $repo, (New-Object Text.UTF8Encoding $false))   # where kit self-update pulls from

if ($onWindows) {
    # the raw value, so entries like %USERPROFILE%\bin stay as they are; written back as REG_EXPAND_SZ
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
    $p = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $parts = @($p.Split(';') | Where-Object { $_ })
    if (@($parts | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -eq $dest.TrimEnd('\') }).Count -eq 0) {
        $key.SetValue('Path', (($parts + $dest) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        # tell Windows the variables changed, so new terminals see the new PATH
        [Environment]::SetEnvironmentVariable('AGENTKIT_PATH_REFRESH', '1', 'User'); [Environment]::SetEnvironmentVariable('AGENTKIT_PATH_REFRESH', $null, 'User')
        Say "已把 $dest 加進你的 PATH，開新的終端機後生效"
    }
    $key.Close()
}
$v = ([IO.File]::ReadAllText((Join-Path $lib 'VERSION'))).Trim()
Say "kit $v 裝好了。下一步：kit init <團隊來源的網址>"
exit 0
