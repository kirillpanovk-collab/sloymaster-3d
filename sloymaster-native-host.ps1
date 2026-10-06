param(
    [Parameter(Mandatory = $true)][string]$SessionFile,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$ApplicationFile
)

$ErrorActionPreference = 'Stop'
$MaximumModelBytes = 200MB
$MaximumIdleSeconds = 14400

function Write-HttpResponse {
    param($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body, [hashtable]$ExtraHeaders = @{})
    $reason = switch ($Status) { 200 {'OK'} 400 {'Bad Request'} 401 {'Unauthorized'} 404 {'Not Found'} 413 {'Payload Too Large'} 500 {'Internal Server Error'} default {'Error'} }
    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`n"
    foreach ($entry in $ExtraHeaders.GetEnumerator()) { $header += "$($entry.Key): $($entry.Value)`r`n" }
    $header += "`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Write-JsonResponse {
    param($Stream, [int]$Status, $Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 16 -Compress
    Write-HttpResponse -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-HttpRequest {
    param($Stream)
    $headerBuffer = New-Object 'System.Collections.Generic.List[byte]'
    $matched = 0
    while ($headerBuffer.Count -lt 32768 -and $matched -lt 4) {
        $next = $Stream.ReadByte()
        if ($next -lt 0) { throw 'Соединение завершено до получения HTTP-заголовков.' }
        $headerBuffer.Add([byte]$next)
        if (($matched -eq 0 -or $matched -eq 2) -and $next -eq 13) { $matched++ }
        elseif (($matched -eq 1 -or $matched -eq 3) -and $next -eq 10) { $matched++ }
        else { $matched = if ($next -eq 13) { 1 } else { 0 } }
    }
    if ($matched -ne 4) { throw 'Заголовки запроса слишком велики или завершены неверно.' }
    $raw = [Text.Encoding]::ASCII.GetString($headerBuffer.ToArray())
    $lines = $raw -split "`r`n"
    $requestParts = $lines[0] -split ' ', 3
    if ($requestParts.Count -lt 2) { throw 'Неизвестный HTTP-запрос.' }
    $headers = @{}
    foreach ($line in $lines | Select-Object -Skip 1) {
        if (-not $line) { continue }
        $colon = $line.IndexOf(':')
        if ($colon -gt 0) { $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim() }
    }
    $length = 0L
    if ($headers.ContainsKey('content-length') -and -not [long]::TryParse($headers['content-length'], [ref]$length)) { throw 'Некорректная длина тела запроса.' }
    return [pscustomobject]@{ Method = $requestParts[0].ToUpperInvariant(); Target = $requestParts[1]; Headers = $headers; Length = $length }
}

function Read-RequestBodyToFile {
    param($Stream, [long]$Length, [string]$Path)
    if ($Length -lt 84 -or $Length -gt $MaximumModelBytes) { throw 'Размер подготовленной модели должен быть от 84 байт до 200 МБ.' }
    $file = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $buffer = New-Object byte[] 65536
        $remaining = $Length
        while ($remaining -gt 0) {
            $read = $Stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
            if ($read -le 0) { throw 'Передача модели прервалась.' }
            $file.Write($buffer, 0, $read)
            $remaining -= $read
        }
    } finally { $file.Dispose() }
}

function Get-ProfileRoot {
    param([string]$MachineProfilePath)
    $directory = Get-Item -LiteralPath (Split-Path -Parent $MachineProfilePath) -ErrorAction Stop
    if ($directory.Name -ieq 'printer' -and $null -ne $directory.Parent) { return $directory.Parent.FullName }
    while ($null -ne $directory -and $directory.Name -ine 'machine') { $directory = $directory.Parent }
    if ($null -eq $directory -or $null -eq $directory.Parent) { return $null }
    return $directory.Parent.FullName
}

function Get-PresetName {
    param([string]$Path)
    try {
        if ([IO.Path]::GetExtension($Path) -ieq '.json') {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @('name', 'preset_name', 'filament_settings_id', 'print_settings_id')) {
                $property = $json.PSObject.Properties[$key]
                if ($null -ne $property -and $property.Value) { return [string]$property.Value }
            }
        } else {
            $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $match = [regex]::Match($content, '(?im)^\s*(?:filament_settings_id|print_settings_id|printer_settings_id|name)\s*=\s*([^\r\n]+)')
            if ($match.Success) { return $match.Groups[1].Value.Trim().Trim('"') }
        }
    } catch { }
    return [IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-CategoryDirectories {
    param($Profile, $Slicer, [string]$Category)
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $root = Get-ProfileRoot -MachineProfilePath ([string]$Profile.path)
    if ($root) {
        $categoryFolder = if ($Slicer.adapter -eq 'prusa' -and $Category -eq 'process') { 'print' } else { $Category }
        $candidate = Join-Path $root $categoryFolder
        if (Test-Path -LiteralPath $candidate -PathType Container) { $directories.Add($candidate) }
    }
    $appDir = Split-Path -Parent ([string]$Slicer.path)
    for ($depth = 0; $depth -lt 4 -and $appDir; $depth++) {
        $candidate = Join-Path $appDir "resources\profiles"
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            foreach ($vendor in (Get-ChildItem -LiteralPath $candidate -Directory -ErrorAction SilentlyContinue)) {
                $sub = Join-Path $vendor.FullName $Category
                if (Test-Path -LiteralPath $sub -PathType Container) { $directories.Add($sub) }
            }
            break
        }
        $parent = Split-Path -Parent $appDir
        if ($parent -eq $appDir) { break }
        $appDir = $parent
    }
    return @($directories | Select-Object -Unique)
}

function Find-PresetPath {
    param($Profile, $Slicer, [string]$Category, [string]$DesiredName, [string]$MaterialKey = '')
    $dirs = @(Get-CategoryDirectories -Profile $Profile -Slicer $Slicer -Category $Category)
    if (-not $dirs.Count) { return $null }
    $extensions = if ($Slicer.adapter -eq 'prusa') { @('*.ini', '*.json') } else { @('*.json') }
    $files = New-Object 'System.Collections.Generic.List[string]'
    foreach ($dir in $dirs) {
        foreach ($extension in $extensions) {
            foreach ($item in (Get-ChildItem -LiteralPath $dir -Filter $extension -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1000)) { $files.Add($item.FullName) }
        }
    }
    if ($DesiredName) {
        $exact = $files | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_) -ieq $DesiredName -or (Get-PresetName -Path $_) -ieq $DesiredName } | Select-Object -First 1
        if ($exact) { return $exact }
    }
    if ($Category -ne 'filament' -or -not $MaterialKey) { return $null }
    $materialPattern = switch ($MaterialKey) {
        'pla' { '(?i)generic\s+pla(?!\s*(?:\+|plus|pro))' }
        'plaPlus' { '(?i)generic\s+pla(?:\s*\+|\s*(?:plus|pro))' }
        'petg' { '(?i)generic\s+petg' }
        'abs' { '(?i)generic\s+abs' }
        'asa' { '(?i)generic\s+asa' }
        'tpu' { '(?i)generic\s+tpu|generic\s+tpe' }
        'pa' { '(?i)generic\s+pa(?!\s*[-+]?\s*(?:cf|gf|ht))|generic\s+nylon(?!\s*[-+]?\s*(?:cf|gf|ht))' }
        'pc' { '(?i)generic\s+pc(?!\s*[-+]?\s*(?:cf|gf|ht))|generic\s+polycarbonate(?!\s*[-+]?\s*(?:cf|gf|ht))' }
        'pp' { '(?i)generic\s+pp' }
        'hips' { '(?i)generic\s+hips' }
        'pva' { '(?i)generic\s+pva|generic\s+bvoh' }
        'pvb' { '(?i)generic\s+pvb' }
        'cpe' { '(?i)generic\s+cpe' }
        default { '' }
    }
    if (-not $materialPattern) { return $null }
    $candidates = foreach ($path in $files) {
        $name = Get-PresetName -Path $path
        if ($name -match $materialPattern) { [pscustomobject]@{ Path = $path; User = ($path -match '[\\/]user[\\/]'); Name = $name } }
    }
    return ($candidates | Sort-Object @{ Expression = { if ($_.User) { 0 } else { 1 } } }, Name | Select-Object -First 1).Path
}

function ConvertTo-Number {
    param($Value, [double]$Minimum, [double]$Maximum, [string]$Name, [switch]$Optional)
    if ($null -eq $Value -or "$Value" -eq '') { if ($Optional) { return $null }; throw "Не задано значение «$Name»." }
    $number = 0.0
    if (-not [double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt $Minimum -or $number -gt $Maximum) { throw "Значение «$Name» выходит за допустимые пределы." }
    return $number.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
}

function Quote-WindowsArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-SlicerProject {
    param($Slicer, $Profile, $Settings, [string]$ModelPath, [string]$ProjectPath, [string]$LogPath)
    $adapter = [string]$Slicer.adapter
    if ($adapter -notin @('orca', 'bambu', 'prusa')) { throw 'Автоматическая передача настроек для этого слайсера не поддерживается.' }
    if (-not (Test-Path -LiteralPath ([string]$Profile.path) -PathType Leaf)) { throw 'Файл выбранного профиля принтера больше не найден.' }
    $machineJson = $null
    if ([IO.Path]::GetExtension([string]$Profile.path) -ieq '.json') { try { $machineJson = Get-Content -LiteralPath $Profile.path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $extruders = if ($Profile.extruders -as [int]) { [int]$Profile.extruders } else { 1 }
    if ($extruders -gt 1) { throw 'Автоподготовка для профиля с несколькими соплами остановлена. Выберите односопловый профиль: приложение пока не назначает материалы по экструдерам.' }
    $processName = [string]$Profile.defaultPrintProfile
    if (-not $processName -and $null -ne $machineJson) { $processName = [string]$machineJson.default_print_profile }
    $processPath = Find-PresetPath -Profile $Profile -Slicer $Slicer -Category 'process' -DesiredName $processName
    if (-not $processPath) { throw 'Не найден сохранённый профиль качества печати для выбранного принтера. Выберите принтер в слайсере и сохраните его профиль качества, затем повторите.' }
    $materialPath = Find-PresetPath -Profile $Profile -Slicer $Slicer -Category 'filament' -DesiredName '' -MaterialKey ([string]$Settings.material)
    if (-not $materialPath -and $Settings.material -notin @('highTemp', 'other')) { throw "В $($Slicer.name) не найден подходящий профиль семейства материала «$($Settings.material)». Выберите или установите Generic-профиль для этой катушки." }

    $number = {
        param($Value, $Min, $Max, $Name, $Optional)
        if ($Optional -and ($null -eq $Value -or "$Value" -eq '')) { return $null }
        return ConvertTo-Number -Value $Value -Minimum $Min -Maximum $Max -Name $Name -Optional:$Optional
    }
    $layer = & $number $Settings.layerHeight 0.04 1.2 'высота слоя' $false
    $firstLayer = & $number $Settings.firstLayerHeight 0.04 1.5 'высота первого слоя' $false
    $walls = [int](& $number $Settings.walls 2 12 'число стенок' $false)
    $infill = [int](& $number $Settings.infill 0 100 'заполнение' $false)
    $speed = & $number $Settings.speed 1 1000 'скорость' $true
    $nozzleTemp = & $number $Settings.nozzleTemp 100 500 'температура сопла' $true
    $bedTemp = & $number $Settings.bedTemp 20 200 'температура стола' $true
    $brim = & $number $Settings.brim 0 30 'кайма' $false
    $pattern = [string]$Settings.pattern
    if ($pattern -notin @('gyroid', 'grid', 'cubic', 'adaptivecubic')) { throw 'Неизвестный шаблон заполнения.' }
    $support = [string]$Settings.support
    if ($support -notin @('none', 'tree', 'normal')) { throw 'Неизвестный режим поддержек.' }
    $materialNames = @{ pla='PLA'; plaPlus='PLA'; petg='PETG'; abs='ABS'; asa='ASA'; tpu='TPU'; pa='PA'; pc='PC'; pp='PP'; hips='HIPS'; pva='PVA'; pvb='PVB'; cpe='CPE'; highTemp=''; other='' }
    if (-not $materialNames.ContainsKey([string]$Settings.material)) { throw 'Неизвестное семейство материала.' }

    $jobDir = Split-Path -Parent $ModelPath
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    if ($adapter -in @('orca', 'bambu')) {
        $settingsFiles = @()
        if ($processPath -and $adapter -eq 'orca') { $settingsFiles += $processPath }
        $settingsFiles += [string]$Profile.path
        if ($processPath -and $adapter -eq 'bambu') { $settingsFiles += $processPath }
        $arguments.Add('--load-settings=' + ($settingsFiles -join ';'))
        if ($materialPath) { $arguments.Add('--load-filaments=' + $materialPath) }
        $arguments.Add('--layer-height=' + $layer)
        $arguments.Add('--initial-layer-print-height=' + $firstLayer)
        $arguments.Add('--wall-loops=' + $walls)
        $arguments.Add('--top-shell-layers=5');$arguments.Add('--bottom-shell-layers=4')
        $arguments.Add('--sparse-infill-density=' + $infill + '%')
        $arguments.Add('--sparse-infill-pattern=' + $pattern)
        $arguments.Add('--enable-support=' + $(if ($support -eq 'none') { '0' } else { '1' }))
        if ($support -ne 'none') { $arguments.Add('--support-type=' + $(if ($support -eq 'tree') { 'tree(auto)' } else { 'normal(auto)' }));$arguments.Add('--support-threshold-angle=45') }
        $arguments.Add('--brim-type=' + $(if ($brim -gt 0) { 'outer_only' } else { 'no_brim' }))
        $arguments.Add('--brim-width=' + (ConvertTo-Number $brim 0 30 'кайма'))
        if ($nozzleTemp) { $arguments.Add('--nozzle-temperature=' + $nozzleTemp);$arguments.Add('--nozzle-temperature-initial-layer=' + $nozzleTemp) }
        if ($bedTemp) { $arguments.Add('--bed-temperature=' + $bedTemp);$arguments.Add('--bed-temperature-initial-layer=' + $bedTemp) }
        if ($materialNames[[string]$Settings.material]) { $arguments.Add('--filament-type=' + $materialNames[[string]$Settings.material]) }
        if ($speed) {$arguments.Add('--outer-wall-speed=' + [Math]::Max(8,[Math]::Round([double]$speed*.55)));$arguments.Add('--inner-wall-speed=' + $speed);$arguments.Add('--sparse-infill-speed=' + $speed);$arguments.Add('--top-surface-speed=' + [Math]::Max(8,[Math]::Round([double]$speed*.7)));$arguments.Add('--initial-layer-speed=20')}
        $arguments.Add('--arrange=1');$arguments.Add('--ensure-on-bed')
    } else {
        $arguments.Add('--load');$arguments.Add([string]$Profile.path)
        if ($processPath) {$arguments.Add('--load');$arguments.Add($processPath)}
        if ($materialPath) {$arguments.Add('--load');$arguments.Add($materialPath)}
        $arguments.Add('--layer-height=' + $layer);$arguments.Add('--first-layer-height=' + $firstLayer)
        $arguments.Add('--perimeters=' + $walls);$arguments.Add('--top-solid-layers=5');$arguments.Add('--bottom-solid-layers=4')
        $prusaPattern = if ($pattern -eq 'adaptivecubic') { 'cubic' } else { $pattern }
        $arguments.Add('--fill-density=' + $infill + '%');$arguments.Add('--fill-pattern=' + $prusaPattern)
        $arguments.Add('--support-material=' + $(if ($support -eq 'none') { '0' } else { '1' }))
        if ($support -eq 'tree') { $arguments.Add('--support-material-style=organic') }
        $arguments.Add('--brim-width=' + (ConvertTo-Number $brim 0 30 'кайма'))
        if ($nozzleTemp) {$arguments.Add('--temperature=' + $nozzleTemp)}
        if ($bedTemp) {$arguments.Add('--bed-temperature=' + $bedTemp)}
        if ($speed) {$arguments.Add('--max-print-speed=' + $speed);$arguments.Add('--first-layer-speed=20')}
    }
    $arguments.Add('--export-3mf=' + $ProjectPath)
    $arguments.Add($ModelPath)
    $cliPath = [string]$Slicer.path
    $guiPath = [string]$Slicer.path
    if ($adapter -eq 'prusa') {
        $dir = Split-Path -Parent $guiPath
        $console = Join-Path $dir 'prusa-slicer-console.exe'
        if (Test-Path -LiteralPath $console -PathType Leaf) { $cliPath = $console }
    }
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) { throw 'Исполняемый файл слайсера не найден.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $cliPath
    $start.Arguments = (($arguments | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' ')
    $start.UseShellExecute = $false;$start.CreateNoWindow = $true;$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true;$start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync();$stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(180000)) { try { $process.Kill() } catch { };throw 'Слайсер не подготовил проект за три минуты. Проверьте его версию и профиль принтера.' }
    $process.WaitForExit();$stdout = $stdoutTask.Result;$stderr = $stderrTask.Result
    @($stdout,$stderr) -join "`r`n" | Set-Content -LiteralPath $LogPath -Encoding UTF8
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
        $details = (@($stderr,$stdout) -join "`n" -replace '[\r\n]+',' ').Trim()
        if ($details.Length -gt 420) { $details = $details.Substring(0,420) }
        throw "Слайсер не смог сохранить проект. $details"
    }
    Start-Process -FilePath $guiPath -ArgumentList (Quote-WindowsArgument $ProjectPath) | Out-Null
}

try {
    $session = Get-Content -LiteralPath $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $session.token -or -not $session.metadata) { throw 'Файл сеанса локального помощника неполный.' }
    if ($session.applicationFile -and (Test-Path -LiteralPath ([string]$session.applicationFile) -PathType Leaf)) { $ApplicationFile = [string]$session.applicationFile }
    if (-not (Test-Path -LiteralPath $ApplicationFile -PathType Leaf)) { throw 'Файл приложения не найден.' }
    $token = [string]$session.token
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start(20)
    $lastActivity = [DateTime]::UtcNow
    while (([DateTime]::UtcNow - $lastActivity).TotalSeconds -lt $MaximumIdleSeconds) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100;continue }
        $client = $null
        try {
            $client = $listener.AcceptTcpClient();$client.ReceiveTimeout=30000;$client.SendTimeout=30000
            $stream = $client.GetStream();$request=Read-HttpRequest -Stream $stream;$lastActivity=[DateTime]::UtcNow
            $uri = [Uri]::new("http://127.0.0.1:$Port$($request.Target)")
            if ($request.Method -eq 'GET' -and $uri.AbsolutePath -eq '/api/health') {
                $requestedToken=[Uri]::UnescapeDataString(([regex]::Match($uri.Query,'(?:\?|&)token=([^&]+)').Groups[1].Value))
                if (-not [String]::Equals($requestedToken,$token,[StringComparison]::Ordinal)) { Write-JsonResponse $stream 401 @{ok=$false};continue }
                Write-JsonResponse $stream 200 @{ok=$true};continue
            }
            if ($request.Method -eq 'GET' -and $uri.AbsolutePath -eq '/') {
                $requestedToken=[Uri]::UnescapeDataString(([regex]::Match($uri.Query,'(?:\?|&)token=([^&]+)').Groups[1].Value))
                if (-not [String]::Equals($requestedToken,$token,[StringComparison]::Ordinal)) { Write-HttpResponse $stream 401 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Unauthorized'));continue }
                $body=[IO.File]::ReadAllBytes($ApplicationFile)
                $headers=@{'Content-Security-Policy'="default-src 'self' data: blob:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' https://raw.githubusercontent.com https://script.google.com https://script.googleusercontent.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"}
                Write-HttpResponse $stream 200 'text/html; charset=utf-8' $body $headers;continue
            }
            if ($request.Method -eq 'GET' -and $uri.AbsolutePath -in @('/sloymaster-icon.svg','/sloymaster-icon.ico')) {
                $asset=Join-Path (Split-Path -Parent $ApplicationFile) $uri.AbsolutePath.TrimStart('/')
                if (Test-Path -LiteralPath $asset -PathType Leaf) {$type=if ($asset.EndsWith('.svg')) {'image/svg+xml'} else {'image/x-icon'};Write-HttpResponse $stream 200 $type ([IO.File]::ReadAllBytes($asset));continue}
            }
            if (-not $request.Headers.ContainsKey('x-sloymaster-token') -or -not [String]::Equals($request.Headers['x-sloymaster-token'],$token,[StringComparison]::Ordinal)) { Write-JsonResponse $stream 401 @{ok=$false;message='Не прошла проверка локального сеанса.'};continue }
            if ($request.Method -eq 'POST' -and $uri.AbsolutePath -eq '/api/refresh') {
                $freshSession = Get-Content -LiteralPath $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not [String]::Equals([string]$freshSession.token,$token,[StringComparison]::Ordinal) -or -not $freshSession.metadata) { Write-JsonResponse $stream 401 @{ok=$false;message='Невозможно обновить локальный сеанс.'};continue }
                if ($freshSession.applicationFile -and (Test-Path -LiteralPath ([string]$freshSession.applicationFile) -PathType Leaf)) { $ApplicationFile = [string]$freshSession.applicationFile }
                $session = $freshSession
                Write-JsonResponse $stream 200 @{ok=$true};continue
            }
            if ($request.Method -eq 'GET' -and $uri.AbsolutePath -eq '/api/info') { Write-JsonResponse $stream 200 $session.metadata;continue }
            if ($request.Method -ne 'POST' -or $uri.AbsolutePath -ne '/api/open-slicer') { Write-JsonResponse $stream 404 @{ok=$false;message='Локальный адрес не найден.'};continue }
            if (-not $request.Headers.ContainsKey('x-sm-slicer-index') -or -not $request.Headers.ContainsKey('x-sm-profile-index') -or -not $request.Headers.ContainsKey('x-sm-settings')) { Write-JsonResponse $stream 400 @{ok=$false;message='Не выбраны программа, профиль или параметры.'};continue }
            $slicerIndex=0;$profileIndex=0
            if (-not [int]::TryParse($request.Headers['x-sm-slicer-index'],[ref]$slicerIndex) -or -not [int]::TryParse($request.Headers['x-sm-profile-index'],[ref]$profileIndex)) { Write-JsonResponse $stream 400 @{ok=$false;message='Индекс программы или профиля некорректен.'};continue }
            $slicers=@($session.metadata.slicers);$profiles=@($session.metadata.profiles)
            if ($slicerIndex -lt 0 -or $slicerIndex -ge $slicers.Count -or $profileIndex -lt 0 -or $profileIndex -ge $profiles.Count) { Write-JsonResponse $stream 400 @{ok=$false;message='Выбранная программа или профиль отсутствуют в локальном списке.'};continue }
            $slicer=$slicers[$slicerIndex];$profile=$profiles[$profileIndex]
            if ($slicer.adapter -notin @('orca','bambu','prusa') -or $profile.slicer -ne $slicer.name -or -not $slicer.path -or [IO.Path]::GetExtension([string]$slicer.path) -ine '.exe') { Write-JsonResponse $stream 400 @{ok=$false;message='Выбранные программа и профиль не подходят для передачи настроек.'};continue }
            $settingsText=([string]$request.Headers['x-sm-settings']).Replace('-','+').Replace('_','/')
            $settingsText += '=' * ((4-($settingsText.Length % 4)) % 4)
            try { $settings=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($settingsText)) | ConvertFrom-Json) } catch { Write-JsonResponse $stream 400 @{ok=$false;message='Не удалось прочитать параметры проекта.'};continue }
            $jobRoot=Join-Path $env:LOCALAPPDATA 'SloyMaster3D\PreparedProjects'
            $jobDir=Join-Path $jobRoot ([Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
            $modelPath=Join-Path $jobDir 'oriented-model.stl';$projectPath=Join-Path $jobDir 'Prepared-project.3mf';$logPath=Join-Path $jobDir 'slicer.log'
            try {
                Read-RequestBodyToFile -Stream $stream -Length $request.Length -Path $modelPath
                Invoke-SlicerProject -Slicer $slicer -Profile $profile -Settings $settings -ModelPath $modelPath -ProjectPath $projectPath -LogPath $logPath
                Write-JsonResponse $stream 200 @{ok=$true;project='Prepared-project.3mf';directory=$jobDir}
            } catch { Write-JsonResponse $stream 400 @{ok=$false;message=$_.Exception.Message} }
            continue
        } catch {
            if ($null -ne $client -and $client.Connected) { try { Write-JsonResponse $client.GetStream() 400 @{ok=$false;message=$_.Exception.Message} } catch { } }
        } finally { if ($null -ne $client) { $client.Close() } }
    }
} catch {
    try { if ($listener) { $listener.Stop() } } catch { }
} finally {
    try { if ($listener) { $listener.Stop() } } catch { }
    try { Remove-Item -LiteralPath $SessionFile -Force -ErrorAction SilentlyContinue } catch { }
}
