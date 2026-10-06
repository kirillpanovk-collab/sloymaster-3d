$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'Start-SloyMaster.cmd'
$icon = Join-Path $PSScriptRoot 'sloymaster-icon.ico'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Не найден Start-SloyMaster.cmd.' }

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$shortcutPath = Join-Path $desktop 'СлойМастер 3D.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $launcher
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'СлойМастер 3D — анализ и подготовка FDM-печати'
if (Test-Path -LiteralPath $icon -PathType Leaf) { $shortcut.IconLocation = "$icon,0" }
$shortcut.Save()
Write-Output "Создан ярлык: $shortcutPath"
