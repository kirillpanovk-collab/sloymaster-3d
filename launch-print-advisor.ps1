<#
Launch СлойМастер 3D, the local FDM print-preparation studio, in a standalone
Microsoft Edge app window with a token-protected loopback helper. The helper
provides a local snapshot of installed slicers, Windows printer queues, serial
devices, and saved profiles, and opens prepared projects in supported slicers.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Get-FirstPropertyValue {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and "$($property.Value)" -ne '') {
            return $property.Value
        }
    }
    return $null
}

function Get-NumberValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array]) { if ($Value.Count -gt 0) { $Value = $Value[0] } else { return $null } }
    $match = [regex]::Match("$Value", '-?\d+(?:[.,]\d+)?')
    if (-not $match.Success) { return $null }
    $numberText = $match.Value.Replace(',', '.')
    $parsed = 0.0
    if ([double]::TryParse($numberText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-JsonPropertyDeep {
    param($Object, [string[]]$Names, [int]$Depth = 0)
    if ($null -eq $Object -or $Depth -gt 8) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            if ($Object.Contains($name) -and $null -ne $Object[$name]) { return ,$Object[$name] }
        }
        foreach ($value in $Object.Values) {
            $found = Get-JsonPropertyDeep -Object $value -Names $Names -Depth ($Depth + 1)
            if ($null -ne $found) { return ,$found }
        }
    } elseif ($Object -is [System.Array]) {
        foreach ($value in $Object) {
            $found = Get-JsonPropertyDeep -Object $value -Names $Names -Depth ($Depth + 1)
            if ($null -ne $found) { return ,$found }
        }
    } else {
        foreach ($name in $Names) {
            $property = $Object.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) { return ,$property.Value }
        }
        foreach ($property in $Object.PSObject.Properties) {
            $found = Get-JsonPropertyDeep -Object $property.Value -Names $Names -Depth ($Depth + 1)
            if ($null -ne $found) { return ,$found }
        }
    }
    return $null
}

function Get-ProfileFromJson {
    param([string]$Path, [string]$Slicer)
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $name = Get-JsonPropertyDeep -Object $json -Names @('name', 'printer_settings_id', 'printer_model')
        $x = Get-NumberValue (Get-JsonPropertyDeep -Object $json -Names @('bed_width', 'machine_width', 'printable_width'))
        $y = Get-NumberValue (Get-JsonPropertyDeep -Object $json -Names @('bed_depth', 'machine_depth', 'printable_depth'))
        $z = Get-NumberValue (Get-JsonPropertyDeep -Object $json -Names @('printable_height', 'max_print_height', 'machine_height'))
        $nozzleRaw = Get-JsonPropertyDeep -Object $json -Names @('nozzle_diameter', 'machine_nozzle_size', 'nozzle_size')
        $nozzle = Get-NumberValue $nozzleRaw
        $extruders = 1
        if ($nozzleRaw -is [System.Array]) { $extruders = [Math]::Max(1, $nozzleRaw.Count) }
        elseif ("$nozzleRaw" -match ',|;') { $extruders = [Math]::Max(1, @("$nozzleRaw" -split '[,;]' | Where-Object { $_.Trim() }).Count) }
        $defaultPrintProfile = Get-JsonPropertyDeep -Object $json -Names @('default_print_profile', 'default_print_settings_id')
        $defaultFilamentProfile = Get-JsonPropertyDeep -Object $json -Names @('default_filament_profile', 'default_filament_settings_id')
        $maxNozzleTemp = Get-NumberValue (Get-JsonPropertyDeep -Object $json -Names @('max_nozzle_temperature', 'max_nozzle_temp', 'nozzle_max_temperature', 'max_hotend_temperature', 'max_hotend_temp', 'max_extruder_temp', 'extruder_max_temp'))
        $maxBedTemp = Get-NumberValue (Get-JsonPropertyDeep -Object $json -Names @('max_bed_temperature', 'max_bed_temp', 'bed_max_temp', 'heater_bed_max_temp'))
        $maxFlow = Get-NumberValue (Get-JsonPropertyDeep -Object $json -Names @('max_volumetric_flow', 'max_volumetric_flow_rate', 'max_volumetric_speed'))

        $area = Get-JsonPropertyDeep -Object $json -Names @('printable_area', 'bed_shape')
        if ($null -ne $area -and ($null -eq $x -or $null -eq $y)) {
            $xs = New-Object System.Collections.Generic.List[double]
            $ys = New-Object System.Collections.Generic.List[double]
            foreach ($point in @($area)) {
                if ($point -is [System.Array] -and $point.Count -ge 2) {
                    $px = Get-NumberValue $point[0]
                    $py = Get-NumberValue $point[1]
                    if ($null -ne $px -and $null -ne $py) { $xs.Add([double]$px); $ys.Add([double]$py) }
                } elseif ($point -is [string]) {
                    foreach ($pair in [regex]::Matches($point, '(-?\d+(?:[.,]\d+)?)\s*x\s*(-?\d+(?:[.,]\d+)?)')) {
                        $px = Get-NumberValue $pair.Groups[1].Value
                        $py = Get-NumberValue $pair.Groups[2].Value
                        if ($null -ne $px -and $null -ne $py) { $xs.Add([double]$px); $ys.Add([double]$py) }
                    }
                }
            }
            if ($xs.Count -gt 1) {
                if ($null -eq $x) { $x = [math]::Round(($xs | Measure-Object -Maximum).Maximum - ($xs | Measure-Object -Minimum).Minimum, 2) }
                if ($null -eq $y) { $y = [math]::Round(($ys | Measure-Object -Maximum).Maximum - ($ys | Measure-Object -Minimum).Minimum, 2) }
            }
        }

        if ($null -eq $name -or "$name" -match '^\s*$') { $name = [IO.Path]::GetFileNameWithoutExtension($Path) }
        if ($null -eq $x -and $null -eq $y -and $null -eq $z -and $null -eq $nozzle -and $null -eq $maxNozzleTemp -and $null -eq $maxBedTemp -and $null -eq $maxFlow) { return $null }
        $completeness = if ($null -ne $x -and $null -ne $y -and $null -ne $z -and $null -ne $nozzle) { 'specs-complete' } else { 'partial' }
        return [pscustomobject]@{ name = "$name"; slicer = $Slicer; path = [IO.Path]::GetFullPath($Path); defaultPrintProfile = [string]$defaultPrintProfile; defaultFilamentProfile = [string]$defaultFilamentProfile; extruders = $extruders; x = $x; y = $y; z = $z; nozzle = $nozzle; maxNozzleTemp = $maxNozzleTemp; maxBedTemp = $maxBedTemp; maxFlow = $maxFlow; active = $false; status = $completeness; source = "Сохранённый локальный профиль-кандидат: $([IO.Path]::GetFileName($Path))" }
    } catch { return $null }
}

function Get-ProfileFromIni {
    param([string]$Path, [string]$Slicer)
    try {
        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $nameMatch = [regex]::Match($content, '(?im)^\s*(?:printer_settings_id|printer_model|name)\s*=\s*([^\r\n]+)')
        $name = if ($nameMatch.Success) { $nameMatch.Groups[1].Value.Trim().Trim('"') } else { [IO.Path]::GetFileNameWithoutExtension($Path) }
        $xMatch = [regex]::Match($content, '(?im)^\s*(?:machine_width|bed_width)\s*=\s*([^\r\n]+)')
        $yMatch = [regex]::Match($content, '(?im)^\s*(?:machine_depth|bed_depth)\s*=\s*([^\r\n]+)')
        $zMatch = [regex]::Match($content, '(?im)^\s*(?:machine_height|max_print_height)\s*=\s*([^\r\n]+)')
        $nozzleMatch = [regex]::Match($content, '(?im)^\s*(?:machine_nozzle_size|nozzle_diameter|nozzle_size)\s*=\s*([^\r\n]+)')
        $maxNozzleTempMatch = [regex]::Match($content, '(?im)^\s*(?:max_nozzle_temperature|max_nozzle_temp|nozzle_max_temperature|max_hotend_temperature|max_hotend_temp|max_extruder_temp|extruder_max_temp)\s*=\s*([^\r\n]+)')
        $maxBedTempMatch = [regex]::Match($content, '(?im)^\s*(?:max_bed_temperature|max_bed_temp|bed_max_temp|heater_bed_max_temp)\s*=\s*([^\r\n]+)')
        $maxFlowMatch = [regex]::Match($content, '(?im)^\s*(?:max_volumetric_flow|max_volumetric_flow_rate|max_volumetric_speed)\s*=\s*([^\r\n]+)')
        $x = if ($xMatch.Success) { Get-NumberValue $xMatch.Groups[1].Value } else { $null }
        $y = if ($yMatch.Success) { Get-NumberValue $yMatch.Groups[1].Value } else { $null }
        $z = if ($zMatch.Success) { Get-NumberValue $zMatch.Groups[1].Value } else { $null }
        $nozzleRaw = if ($nozzleMatch.Success) { $nozzleMatch.Groups[1].Value } else { '' }
        $nozzle = if ($nozzleMatch.Success) { Get-NumberValue $nozzleRaw } else { $null }
        $extruders = if ($nozzleRaw) { [Math]::Max(1, @($nozzleRaw -split '[,;]' | Where-Object { $_.Trim() }).Count) } else { 1 }
        $printMatch = [regex]::Match($content, '(?im)^\s*(?:default_print_profile|print_settings_id)\s*=\s*([^\r\n]+)')
        $filamentMatch = [regex]::Match($content, '(?im)^\s*(?:default_filament_profile|filament_settings_id)\s*=\s*([^\r\n]+)')
        $defaultPrintProfile = if ($printMatch.Success) { $printMatch.Groups[1].Value.Trim().Trim('"') } else { '' }
        $defaultFilamentProfile = if ($filamentMatch.Success) { $filamentMatch.Groups[1].Value.Trim().Trim('"') } else { '' }
        $maxNozzleTemp = if ($maxNozzleTempMatch.Success) { Get-NumberValue $maxNozzleTempMatch.Groups[1].Value } else { $null }
        $maxBedTemp = if ($maxBedTempMatch.Success) { Get-NumberValue $maxBedTempMatch.Groups[1].Value } else { $null }
        $maxFlow = if ($maxFlowMatch.Success) { Get-NumberValue $maxFlowMatch.Groups[1].Value } else { $null }
        $bedMatch = [regex]::Match($content, '(?im)^\s*bed_shape\s*=\s*([^\r\n]+)')
        if ($bedMatch.Success -and ($null -eq $x -or $null -eq $y)) {
            $xs = New-Object System.Collections.Generic.List[double]
            $ys = New-Object System.Collections.Generic.List[double]
            foreach ($pair in [regex]::Matches($bedMatch.Groups[1].Value, '(-?\d+(?:[.,]\d+)?)\s*x\s*(-?\d+(?:[.,]\d+)?)')) {
                $px = Get-NumberValue $pair.Groups[1].Value
                $py = Get-NumberValue $pair.Groups[2].Value
                if ($null -ne $px -and $null -ne $py) { $xs.Add([double]$px); $ys.Add([double]$py) }
            }
            if ($xs.Count -gt 1) {
                if ($null -eq $x) { $x = [math]::Round(($xs | Measure-Object -Maximum).Maximum - ($xs | Measure-Object -Minimum).Minimum, 2) }
                if ($null -eq $y) { $y = [math]::Round(($ys | Measure-Object -Maximum).Maximum - ($ys | Measure-Object -Minimum).Minimum, 2) }
            }
        }
        if ($null -eq $x -and $null -eq $y -and $null -eq $z -and $null -eq $nozzle -and $null -eq $maxNozzleTemp -and $null -eq $maxBedTemp -and $null -eq $maxFlow) { return $null }
        $completeness = if ($null -ne $x -and $null -ne $y -and $null -ne $z -and $null -ne $nozzle) { 'specs-complete' } else { 'partial' }
        return [pscustomobject]@{ name = "$name"; slicer = $Slicer; path = [IO.Path]::GetFullPath($Path); defaultPrintProfile = $defaultPrintProfile; defaultFilamentProfile = $defaultFilamentProfile; extruders = $extruders; x = $x; y = $y; z = $z; nozzle = $nozzle; maxNozzleTemp = $maxNozzleTemp; maxBedTemp = $maxBedTemp; maxFlow = $maxFlow; active = $false; status = $completeness; source = "Сохранённый локальный профиль-кандидат: $([IO.Path]::GetFileName($Path))" }
    } catch { return $null }
}

function Get-SlicerProfiles {
    $profiles = New-Object System.Collections.Generic.List[object]
    $roaming = $env:APPDATA
    if (-not $roaming) { return @() }

    $roots = @(
        @{ name = 'OrcaSlicer'; path = (Join-Path $roaming 'OrcaSlicer') },
        @{ name = 'Bambu Studio'; path = (Join-Path $roaming 'BambuStudio') },
        @{ name = 'Creality Print'; path = (Join-Path $roaming 'Creality') },
        @{ name = 'ElegooSlicer'; path = (Join-Path $roaming 'ElegooSlicer') },
        @{ name = 'PrusaSlicer'; path = (Join-Path $roaming 'PrusaSlicer') },
        @{ name = 'SuperSlicer'; path = (Join-Path $roaming 'SuperSlicer') },
        @{ name = 'UltiMaker Cura'; path = (Join-Path $roaming 'cura') }
    )

    foreach ($entry in $roots) {
        if (-not (Test-Path -LiteralPath $entry.path)) { continue }
        $files = @()
        if ($entry.name -eq 'PrusaSlicer' -or $entry.name -eq 'SuperSlicer') {
            # Some Windows installs keep custom printer presets in a top-level folder.
            $directPrinter = Join-Path $entry.path 'printer'
            if (Test-Path -LiteralPath $directPrinter -PathType Container) {
                $files += Get-ChildItem -LiteralPath $directPrinter -Filter '*.ini' -File -ErrorAction SilentlyContinue | Select-Object -First 100
            }
        }
        # Only walk the app's explicitly named user directory, then inspect its
        # machine subfolders. Bundled "system" and factory catalogs are excluded.
        $userDirs = Get-ChildItem -LiteralPath $entry.path -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'user' } | Select-Object -First 20
        foreach ($userDir in $userDirs) {
            $machineDirs = @()
            $directMachine = Join-Path $userDir.FullName 'machine'
            if (Test-Path -LiteralPath $directMachine -PathType Container) { $machineDirs += Get-Item -LiteralPath $directMachine }
            foreach ($child in (Get-ChildItem -LiteralPath $userDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $childMachine = Join-Path $child.FullName 'machine'
                if (Test-Path -LiteralPath $childMachine -PathType Container) { $machineDirs += Get-Item -LiteralPath $childMachine }
            }
            foreach ($machineDir in $machineDirs) {
                $extensions = if ($entry.name -eq 'UltiMaker Cura') { @('*.cfg') } elseif ($entry.name -eq 'PrusaSlicer' -or $entry.name -eq 'SuperSlicer') { @('*.ini') } else { @('*.json') }
                foreach ($filter in $extensions) {
                    $files += Get-ChildItem -LiteralPath $machineDir.FullName -Filter $filter -File -ErrorAction SilentlyContinue | Select-Object -First 100
                }
            }
        }
        $files = @($files | Sort-Object FullName -Unique | Select-Object -First 100)
        foreach ($file in $files) {
            if ($file.Extension -ieq '.json') { $profile = Get-ProfileFromJson -Path $file.FullName -Slicer $entry.name }
            else { $profile = Get-ProfileFromIni -Path $file.FullName -Slicer $entry.name }
            if ($null -ne $profile) { $profiles.Add($profile) }
            if ($profiles.Count -ge 20) { break }
        }
        if ($profiles.Count -ge 20) { break }
    }
    return @($profiles | Sort-Object slicer, name, source -Unique | Select-Object -First 20)
}

function Get-SlicerAdapter {
    param([string]$Name, [string]$Path)
    $identity = "$Name $Path"
    if ($identity -match '(?i)orca') { return 'orca' }
    if ($identity -match '(?i)bambu') { return 'bambu' }
    if ($identity -match '(?i)prusa') { return 'prusa' }
    return ''
}

function Get-SlicerDisplayName {
    param([string]$Name, [string]$Path)
    switch (Get-SlicerAdapter -Name $Name -Path $Path) {
        'orca' { return 'OrcaSlicer' }
        'bambu' { return 'Bambu Studio' }
        'prusa' { return 'PrusaSlicer' }
        default { return $Name }
    }
}

function Resolve-SlicerExecutable {
    param([string]$Path, [string]$DisplayName)
    if (-not $Path) { return $null }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ([IO.Path]::GetExtension($Path) -ieq '.exe') { return [IO.Path]::GetFullPath($Path) }
        return $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $adapter = Get-SlicerAdapter -Name $DisplayName -Path $Path
    $expected = switch ($adapter) {
        'orca' { @('orca-slicer.exe') }
        'bambu' { @('bambu-studio.exe') }
        'prusa' { @('prusa-slicer.exe') }
        default { @('UltiMaker-Cura.exe','Cura.exe','superslicer.exe','CrealityPrint.exe','FlashPrint.exe','ideaMaker.exe','Simplify3D.exe','CHITUBOX.exe','ElegooSlicer.exe','LycheeSlicer.exe','VoxelMaker.exe','AnycubicSlicer.exe','QidiSlicer.exe','RaiseTouch.exe') }
    }
    $directories = @((Get-Item -LiteralPath $Path)) + @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue | Select-Object -First 12)
    foreach ($directory in $directories) {
        foreach ($exeName in $expected) {
            $candidate = Join-Path $directory.FullName $exeName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
        }
        if ($adapter -eq '') {
            $candidate = Get-ChildItem -LiteralPath $directory.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)(cura|slicer|bambu|creality|flashprint|ideamaker|chitubox|lychee|voxel|raise|simplify|anycubic|qidi)' } | Select-Object -First 1
            if ($candidate) { return [IO.Path]::GetFullPath($candidate.FullName) }
        }
    }
    return $null
}

function Get-InstalledSlicers {
    $found = New-Object System.Collections.Generic.List[object]
    $knownPattern = '(?i)(Ultimaker Cura|UltiMaker Cura|PrusaSlicer|SuperSlicer|OrcaSlicer|Bambu Studio|Creality Print|Anycubic|FlashPrint|ideaMaker|Simplify3D|CHITUBOX|Lychee Slicer|Elegoo Slicer|ElegooSlicer|VoxelMaker|QIDI Slicer|Raise3D)'
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        foreach ($app in (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ($app.DisplayName -notmatch $knownPattern) { continue }
            $rawPath = $app.InstallLocation
            if (-not $rawPath -and $app.DisplayIcon) { $rawPath = ($app.DisplayIcon -replace '^"?([^",]+\.exe).*$','$1') }
            $displayName = Get-SlicerDisplayName -Name ([string]$app.DisplayName) -Path ([string]$rawPath)
            $resolvedPath = Resolve-SlicerExecutable -Path ([string]$rawPath) -DisplayName $displayName
            if (-not $resolvedPath) { continue }
            $found.Add([pscustomobject]@{ name = $displayName; adapter = (Get-SlicerAdapter -Name $displayName -Path $resolvedPath); version = [string]$app.DisplayVersion; path = $resolvedPath })
        }
    }

    $exeNames = @('UltiMaker-Cura.exe','Cura.exe','prusa-slicer.exe','superslicer.exe','orca-slicer.exe','bambu-studio.exe','CrealityPrint.exe','FlashPrint.exe','ideaMaker.exe','Simplify3D.exe','CHITUBOX.exe','ElegooSlicer.exe','LycheeSlicer.exe','VoxelMaker.exe','AnycubicSlicer.exe','QidiSlicer.exe','RaiseTouch.exe')
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($root in $roots) {
        $installDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)(cura|prusa|super.?slicer|orca|bambu|creality|flashprint|ideamaker|chitubox|elegoo|simplify|anycubic|qidi|raise|lychee)' }
        foreach ($installDir in $installDirs) {
            $possibleDirs = @($installDir) + @(Get-ChildItem -LiteralPath $installDir.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 10)
            foreach ($dir in $possibleDirs) {
              foreach ($exeName in $exeNames) {
                $exe = Get-ChildItem -LiteralPath $dir.FullName -Filter $exeName -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) {
                $displayName = switch -Regex ($exe.Name) {
                    '(?i)Cura' { 'UltiMaker Cura'; break }
                    '(?i)prusa' { 'PrusaSlicer'; break }
                    '(?i)super' { 'SuperSlicer'; break }
                    '(?i)orca' { 'OrcaSlicer'; break }
                    '(?i)bambu' { 'Bambu Studio'; break }
                    '(?i)creality' { 'Creality Print'; break }
                    '(?i)elegoo' { 'ElegooSlicer'; break }
                    '(?i)anycubic' { 'AnycubicSlicer'; break }
                    '(?i)qidi' { 'QIDI Slicer'; break }
                    '(?i)raise' { 'Raise3D ideaMaker'; break }
                    default { [IO.Path]::GetFileNameWithoutExtension($exe.Name) }
                }
                    $displayName = Get-SlicerDisplayName -Name $displayName -Path $exe.FullName
                    $found.Add([pscustomobject]@{ name = $displayName; adapter = (Get-SlicerAdapter -Name $displayName -Path $exe.FullName); version = ''; path = [IO.Path]::GetFullPath($exe.FullName) })
                }
              }
            }
        }
    }
    return @($found | Where-Object { $_.path } | Sort-Object name, path -Unique | Select-Object -First 30)
}

function Get-WindowsPrinters {
    $items = New-Object System.Collections.Generic.List[object]
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
        foreach ($printer in (Get-Printer -ErrorAction SilentlyContinue)) {
            $identity = "$($printer.Name) $($printer.DriverName) $($printer.PortName)"
            $is3d = $identity -match '(?i)(3d|ender|creality|prusa|bambu|anycubic|elegoo|voron|artillery|qidi|flashforge|raise3d|ultimaker|makerbot|sovol|kingroon|flying bear)'
            $items.Add([pscustomobject]@{ name = [string]$printer.Name; driverName = [string]$printer.DriverName; portName = [string]$printer.PortName; is3d = [bool]$is3d })
        }
    }
    return @($items | Sort-Object name -Unique)
}

function Get-SerialCandidates {
    $items = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($device in (Get-CimInstance -ClassName Win32_SerialPort -ErrorAction SilentlyContinue)) {
            $items.Add([pscustomobject]@{ name = [string]$device.Name; deviceId = [string]$device.DeviceID })
        }
    } catch { }
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        foreach ($device in (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            $_.Class -eq 'Ports' -or $_.FriendlyName -match '(?i)(USB.*(serial|uart)|CH340|CP210|FTDI|3D printer|printer.*USB|COM\d+)'
        })) {
            $port = [regex]::Match([string]$device.FriendlyName, '(?i)\bCOM\d+\b').Value
            if (-not $port) { $port = [string]$device.InstanceId }
            $items.Add([pscustomobject]@{ name = [string]$device.FriendlyName; deviceId = $port })
        }
    }
    return @($items | Where-Object { $_.name -or $_.deviceId } | Sort-Object name, deviceId -Unique | Select-Object -First 100)
}

$htmlPath = Join-Path $PSScriptRoot 'stl-print-advisor.html'
if (-not (Test-Path -LiteralPath $htmlPath -PathType Leaf)) {
    throw "Application file not found: $htmlPath"
}

$payload = [ordered]@{
    printers = @(Get-WindowsPrinters)
    serialPorts = @(Get-SerialCandidates)
    slicers = @(Get-InstalledSlicers)
    profiles = @(Get-SlicerProfiles)
}
$json = $payload | ConvertTo-Json -Depth 12 -Compress

$nativeHostPath = Join-Path $PSScriptRoot 'sloymaster-native-host.ps1'
if (-not (Test-Path -LiteralPath $nativeHostPath -PathType Leaf)) { throw "Local Windows helper was not found: $nativeHostPath" }
$sessionRoot = Join-Path $env:LOCALAPPDATA 'SloyMaster3D\Sessions'
New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
$sessionPath = Join-Path $sessionRoot 'session-39417.json'
$port = 39417
$token = $null
$reuseHost = $false
$health = $null
if (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
    try {
        $previousSessionJson = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8
        $previousSession = $previousSessionJson | ConvertFrom-Json
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health?token=$([Uri]::EscapeDataString([string]$previousSession.token))" -TimeoutSec 1 -Method Get
        if ($health.ok -eq $true) {
            $token = [string]$previousSession.token
            $session = [ordered]@{ token = $token; metadata = $payload; applicationFile = [IO.Path]::GetFullPath($htmlPath) }
            $session | ConvertTo-Json -Depth 16 -Compress | Set-Content -LiteralPath $sessionPath -Encoding UTF8
            $refreshed = $null
            try { $refreshed = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/refresh" -TimeoutSec 2 -Method Post -Headers @{ 'X-SloyMaster-Token' = $token } } catch { }
            if ($refreshed -and $refreshed.ok -eq $true) { $reuseHost = $true }
            else { Set-Content -LiteralPath $sessionPath -Value $previousSessionJson -Encoding UTF8; throw 'Локальный помощник уже работает, но не может обновить сведения о профилях. Закройте окно приложения и повторите запуск.' }
        }
    } catch {
        if ($health -and $health.ok -eq $true -and -not $reuseHost) { throw 'Не удалось обновить сведения в уже работающем локальном помощнике. Повторите запуск позже.' }
    }
}
if (-not $reuseHost) {
    $random = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $token = ([BitConverter]::ToString($random) -replace '-', '').ToLowerInvariant()
    $session = [ordered]@{ token = $token; metadata = $payload; applicationFile = [IO.Path]::GetFullPath($htmlPath) }
    $session | ConvertTo-Json -Depth 16 -Compress | Set-Content -LiteralPath $sessionPath -Encoding UTF8
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source }
    Start-Process -FilePath $powershellPath -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $nativeHostPath + '"'),'-SessionFile',('"' + $sessionPath + '"'),'-Port',"$port",'-ApplicationFile',('"' + $htmlPath + '"')) | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try { $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health?token=$([Uri]::EscapeDataString($token))" -TimeoutSec 1 -Method Get; if ($health.ok -eq $true) { $ready = $true; break } } catch { }
        Start-Sleep -Milliseconds 200
    }
    if (-not $ready) { throw 'Не удалось запустить локальный помощник Windows на 127.0.0.1:39417.' }
}
$appUrl = "http://127.0.0.1:$port/?token=$([Uri]::EscapeDataString($token))"

$edgeCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
)
$edgePath = $null
$edgeCommand = Get-Command msedge.exe -ErrorAction SilentlyContinue
if ($edgeCommand) { $edgePath = $edgeCommand.Source }
if (-not $edgePath) { $edgePath = $edgeCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1 }
if (-not $edgePath) {
    throw 'Microsoft Edge was not found. Install Edge or add msedge.exe to PATH, then run this launcher again.'
}

Start-Process -FilePath $edgePath -ArgumentList @('--app=' + $appUrl, '--no-first-run') | Out-Null
