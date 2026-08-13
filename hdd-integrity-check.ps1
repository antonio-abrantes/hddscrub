[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DriveLetter,

    [switch]$SkipLongTest,
    [switch]$ChecksumOnly,
    [switch]$SmartOnly,
    [switch]$FilesystemOnly,

    [ValidateSet('Interactive', 'DataOnly', 'ScrubOnly', 'FilesystemOnly', 'Full', 'Quick', 'SmartOnly', 'ChecksumOnly')]
    [string]$Mode = 'Interactive',

    [switch]$AllowPhysicalDiskSmartFallback,

    [int]$LongTestPollSeconds = 60
)

$ErrorActionPreference = 'Stop'

$Script:HadNoParameters = ($PSBoundParameters.Count -eq 0)
$Script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Script:LogsRoot = Join-Path $Script:Root 'logs'
$Script:ReportsRoot = Join-Path $Script:Root 'reports'
$Script:DefaultManifestsRoot = Join-Path $Script:Root 'manifests'
$Script:RunStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$Script:LogPath = Join-Path $Script:LogsRoot ("run_{0}.log" -f $Script:RunStamp)
$Script:SmartctlPath = $null
$Script:ChecksumEnumerationErrors = 0

$ExitCodes = @{
    OK = 0
    Warning = 1
    SmartCritical = 2
    ChecksumMismatch = 3
    FilesystemWarning = 4
    InvalidSelection = 10
    UnsafeSystemDisk = 11
    SmartMappingFailure = 12
    DependencyMissing = 20
    UserCancelled = 30
    DiskDisappeared = 40
    OfflineFailed = 50
}

function New-ProjectDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-ProjectDirectories {
    New-ProjectDirectory -Path $Script:LogsRoot
    New-ProjectDirectory -Path $Script:ReportsRoot
    New-ProjectDirectory -Path $Script:DefaultManifestsRoot
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    $line = '{0} {1,-7} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $Script:LogPath -Value $line
}

function Write-Status {
    param(
        [ValidateSet('OK', 'WARNING', 'ERROR', 'INFO', 'SKIPPED')]
        [string]$Status,
        [string]$Message
    )

    $color = switch ($Status) {
        'OK' { 'Green' }
        'WARNING' { 'Yellow' }
        'ERROR' { 'Red' }
        'SKIPPED' { 'DarkYellow' }
        default { 'Cyan' }
    }

    Write-Host ('[{0}] {1}' -f $Status, $Message) -ForegroundColor $color
    if ($Status -eq 'ERROR') {
        Write-Log -Level 'ERROR' -Message $Message
    } elseif ($Status -eq 'WARNING') {
        Write-Log -Level 'WARNING' -Message $Message
    } else {
        Write-Log -Level 'INFO' -Message ('[{0}] {1}' -f $Status, $Message)
    }
}

function Write-Section {
    param([string]$Title)

    Write-Host ''
    Write-Host '============================================================'
    Write-Host $Title
    Write-Host '============================================================'
}

function Show-Banner {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'HDD BACKUP INTEGRITY CHECKER'
    Write-Host '============================================================'
    Write-Host 'Verificacao segura de HDDs de backup frio'
    Write-Host 'Nenhum disco sera escolhido automaticamente.'
    Write-Host ''
}

function Read-YesNo {
    param([string]$Prompt)

    while ($true) {
        $answer = Read-Host $Prompt
        if ($null -eq $answer) {
            continue
        }

        switch -Regex ($answer.Trim()) {
            '^[sSyY]$' { return $true }
            '^[nN]$' { return $false }
            default { Write-Host 'Responda S ou N.' -ForegroundColor Yellow }
        }
    }
}

function Normalize-DriveLetter {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmed = $Value.Trim().ToUpperInvariant()
    if ($trimmed -match '^([A-Z]):?$') {
        return ('{0}:' -f $Matches[1])
    }

    return $null
}

function Get-DriveLetterChar {
    param([string]$NormalizedDriveLetter)
    return $NormalizedDriveLetter.Substring(0, 1)
}

function Normalize-Serial {
    param([string]$Serial)

    if ([string]::IsNullOrWhiteSpace($Serial)) {
        return ''
    }

    return (($Serial.Trim()) -replace '\s+', '').ToUpperInvariant()
}

function Get-SafePathSegment {
    param([string]$Value)

    $clean = if ([string]::IsNullOrWhiteSpace($Value)) { 'UNKNOWN_SERIAL' } else { $Value.Trim() }
    return ($clean -replace '[\\/:*?"<>|]', '_')
}

function Format-Bytes {
    param([Nullable[Int64]]$Bytes)

    if ($null -eq $Bytes) {
        return 'Unknown'
    }

    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes
    $index = 0

    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }

    return ('{0:N2} {1}' -f $value, $units[$index])
}

function Format-Duration {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds)
    }

    return ('{0:00}:{1:00}' -f $Duration.Minutes, $Duration.Seconds)
}

function Get-ProjectRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $root = $Script:Root.TrimEnd('\') + '\'
    if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($root.Length)
    }

    return $Path
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-NotConflictingMode {
    $legacyModes = @($ChecksumOnly, $SmartOnly, $FilesystemOnly) | Where-Object { $_ }
    if ($legacyModes.Count -gt 1) {
        throw 'Use apenas um destes modos por vez: -ChecksumOnly, -SmartOnly ou -FilesystemOnly.'
    }

    if ($Mode -ne 'Interactive' -and ($ChecksumOnly -or $SmartOnly -or $FilesystemOnly)) {
        throw 'Use -Mode ou os parametros legados -ChecksumOnly/-SmartOnly/-FilesystemOnly, nao ambos.'
    }
}

function Select-RunMode {
    if ($ChecksumOnly) {
        return 'ScrubOnly'
    }

    if ($SmartOnly) {
        return 'SmartOnly'
    }

    if ($FilesystemOnly) {
        return 'FilesystemOnly'
    }

    if ($Mode -ne 'Interactive') {
        return $Mode
    }

    if (-not $Script:HadNoParameters) {
        return 'Full'
    }

    Write-Section -Title 'MODO DE VERIFICACAO'
    Write-Host '[1] Scrub preventivo completo dos dados'
    Write-Host '    Filesystem nao destrutivo + leitura completa dos arquivos + SHA-256/historico.'
    Write-Host '    Pergunta se voce quer executar SMART antes; se responder N, segue para os dados.'
    Write-Host ''
    Write-Host '[2] Somente scrub SHA-256'
    Write-Host '    Le todos os arquivos e compara/cria baseline. Pula SMART e filesystem.'
    Write-Host ''
    Write-Host '[3] Somente filesystem scan'
    Write-Host '    Scan NTFS nao destrutivo. Geralmente e bem mais rapido que SHA-256.'
    Write-Host ''
    Write-Host '[4] Revisao completa'
    Write-Host '    SMART inicial, Long Test opcional, filesystem scan e SHA-256/historico.'
    Write-Host ''
    Write-Host '[5] Reconhecimento SMART seguro'
    Write-Host '    Identifica unidade/disco/serial e executa apenas SMART inicial.'
    Write-Host ''
    Write-Host '[6] Somente SMART'
    Write-Host '    SMART inicial e Long Test opcional. Pula filesystem e SHA-256.'
    Write-Host ''
    Write-Host '[0] Sair'
    Write-Host '    Fecha sem selecionar disco e sem executar verificacoes.'
    Write-Host ''

    while ($true) {
        $selection = Read-Host 'Escolha o modo [0-6]'
        switch ($selection.Trim()) {
            '0' { return 'Exit' }
            { $_ -match '^(q|quit|exit|sair)$' } { return 'Exit' }
            '1' { return 'DataOnly' }
            '2' { return 'ScrubOnly' }
            '3' { return 'FilesystemOnly' }
            '4' { return 'Full' }
            '5' { return 'Quick' }
            '6' { return 'SmartOnly' }
            default { Write-Host 'Selecao invalida. Informe um numero de 0 a 6, ou Q para sair.' -ForegroundColor Yellow }
        }
    }
}

function Get-RunModeDescription {
    param([string]$EffectiveMode)

    switch ($EffectiveMode) {
        'DataOnly' { return 'Scrub preventivo dos dados: filesystem + leitura completa SHA-256/historico, SMART opcional.' }
        'ScrubOnly' { return 'Somente scrub SHA-256: leitura completa dos arquivos + baseline/comparacao.' }
        'FilesystemOnly' { return 'Somente filesystem scan: verificacao NTFS nao destrutiva.' }
        'Quick' { return 'Reconhecimento seguro: identidade + SMART inicial.' }
        'Full' { return 'Revisao completa: SMART, Long opcional, filesystem e SHA-256.' }
        'SmartOnly' { return 'Somente SMART: SMART inicial + Long opcional.' }
        'ChecksumOnly' { return 'Somente SHA-256: baseline/comparacao com historico.' }
        'Exit' { return 'Sair sem executar verificacoes.' }
        default { return $EffectiveMode }
    }
}

function New-SkippedStage {
    param(
        [string]$Stage,
        [string]$Reason,
        [string]$Classification = 'WARNING'
    )

    return [pscustomobject]@{
        status = 'SKIPPED'
        classification = $Classification
        stage = $Stage
        reason = $Reason
    }
}

function Confirm-SmartSafetyGate {
    param(
        [object]$SmartReport,
        [string]$EffectiveMode
    )

    if ($EffectiveMode -notin @('Full', 'SmartOnly')) {
        return $true
    }

    if ($null -eq $SmartReport) {
        return $false
    }

    Write-Section -Title 'PORTAO DE SEGURANCA'
    if ($SmartReport.classification -eq 'OK') {
        Write-Status -Status 'OK' -Message 'SMART inicial aprovado para prosseguir com as etapas selecionadas.'
        return $true
    }

    $alertText = if ($SmartReport.alerts -and $SmartReport.alerts.Count -gt 0) {
        $SmartReport.alerts -join '; '
    } else {
        'Sem detalhes adicionais.'
    }

    Write-Status -Status 'WARNING' -Message ('SMART inicial retornou {0}: {1}' -f $SmartReport.classification, $alertText)
    Write-Host 'As proximas etapas podem exigir leitura prolongada ou teste longo no HDD.'
    Write-Host 'Se este disco ja parece instavel, a opcao mais cautelosa e parar aqui e analisar o relatorio.'

    return (Read-YesNo -Prompt 'Deseja continuar mesmo assim com as etapas selecionadas? [S/N]')
}

function Find-Smartctl {
    $commands = @('smartctl.exe', 'smartctl')
    foreach ($commandName in $commands) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    $commonPaths = @(
        (Join-Path $Script:Root 'smartctl.exe'),
        (Join-Path $Script:Root 'tools\smartctl.exe'),
        "$env:ProgramFiles\smartmontools\bin\smartctl.exe",
        "${env:ProgramFiles(x86)}\smartmontools\bin\smartctl.exe"
    )

    foreach ($path in $commonPaths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    return $null
}

function Test-Dependencies {
    param(
        [string]$EffectiveMode,
        [switch]$SkipSmartctl
    )

    $required = @(
        'Get-Volume',
        'Get-Partition',
        'Get-Disk',
        'Set-Disk',
        'Get-CimInstance',
        'Get-FileHash',
        'Get-ChildItem',
        'Test-Path',
        'ConvertTo-Json',
        'ConvertFrom-Json'
    )

    $missing = @()
    foreach ($name in $required) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            $missing += $name
        }
    }

    if ($missing.Count -gt 0) {
        throw ('Dependencias ausentes: {0}' -f ($missing -join ', '))
    }

    if (-not $SkipSmartctl -and $EffectiveMode -notin @('ChecksumOnly', 'DataOnly', 'ScrubOnly', 'FilesystemOnly')) {
        $Script:SmartctlPath = Find-Smartctl
        if (-not $Script:SmartctlPath) {
            throw 'smartctl.exe nao foi encontrado. Instale smartmontools ou adicione smartctl.exe ao PATH.'
        }
    }
}

function Ensure-SmartctlAvailable {
    $Script:SmartctlPath = Find-Smartctl
    if (-not $Script:SmartctlPath) {
        throw 'smartctl.exe nao foi encontrado. Instale smartmontools ou adicione smartctl.exe ao PATH.'
    }
}

function Read-Config {
    $configPath = Join-Path $Script:Root 'config.json'
    $default = [ordered]@{
        include = @()
        exclude = @('$RECYCLE.BIN', 'System Volume Information', '.hdd-integrity/temp')
        alwaysLongTest = $false
        manifestRoot = $Script:DefaultManifestsRoot
        longTestPollSeconds = $LongTestPollSeconds
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        return [pscustomobject]$default
    }

    try {
        $loaded = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        if ($loaded.include) { $default.include = @($loaded.include) }
        if ($loaded.exclude) { $default.exclude = @($default.exclude + @($loaded.exclude)) }
        if ($null -ne $loaded.alwaysLongTest) { $default.alwaysLongTest = [bool]$loaded.alwaysLongTest }
        if ($loaded.manifestRoot) { $default.manifestRoot = [string]$loaded.manifestRoot }
        if ($loaded.longTestPollSeconds) { $default.longTestPollSeconds = [int]$loaded.longTestPollSeconds }
        Write-Status -Status 'OK' -Message ('Configuracao carregada: {0}' -f $configPath)
        return [pscustomobject]$default
    } catch {
        throw ('Falha ao ler config.json: {0}' -f $_.Exception.Message)
    }
}

function Get-PageFileDrives {
    $drives = @()
    try {
        $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)
        foreach ($pageFile in $pageFiles) {
            if ($pageFile.Name -match '^([A-Za-z]):\\') {
                $drives += ('{0}:' -f $Matches[1].ToUpperInvariant())
            }
        }
    } catch {
        Write-Log -Level 'WARNING' -Message ('Nao foi possivel consultar pagefile ativo: {0}' -f $_.Exception.Message)
    }

    return @($drives | Select-Object -Unique)
}

function Resolve-DriveToDisk {
    param([string]$NormalizedDriveLetter)

    $letter = Get-DriveLetterChar -NormalizedDriveLetter $NormalizedDriveLetter

    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    $partitions = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
    if ($partitions.Count -ne 1) {
        throw ('Nao foi possivel resolver {0} para uma unica particao.' -f $NormalizedDriveLetter)
    }

    $diskList = @($partitions[0] | Get-Disk -ErrorAction Stop)
    if ($diskList.Count -ne 1) {
        throw ('Nao foi possivel resolver {0} para um unico disco fisico.' -f $NormalizedDriveLetter)
    }

    $disk = $diskList[0]
    if ([string]::IsNullOrWhiteSpace([string]$disk.SerialNumber)) {
        throw ('O disco fisico de {0} nao informou SerialNumber. Abortando por seguranca.' -f $NormalizedDriveLetter)
    }

    return [pscustomobject]@{
        DriveLetter = $NormalizedDriveLetter
        DriveLetterChar = $letter
        Volume = $volume
        Partition = $partitions[0]
        Disk = $disk
        Serial = [string]$disk.SerialNumber
        NormalizedSerial = Normalize-Serial -Serial ([string]$disk.SerialNumber)
        Model = [string]$disk.FriendlyName
        UniqueId = [string]$disk.UniqueId
        DiskNumber = [int]$disk.Number
    }
}

function Test-PropertyTrue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $false
    }

    return [bool]$property.Value
}

function Assert-DriveIsSafe {
    param([object]$Context)

    if ($Context.DriveLetter -eq 'C:') {
        throw 'A unidade C: nunca pode ser selecionada.'
    }

    if (Test-PropertyTrue -Object $Context.Disk -Name 'IsBoot') {
        throw 'O disco selecionado contem particao de boot.'
    }

    if (Test-PropertyTrue -Object $Context.Disk -Name 'IsSystem') {
        throw 'O disco selecionado contem particao de sistema.'
    }

    if (Test-PropertyTrue -Object $Context.Partition -Name 'IsBoot') {
        throw 'A particao selecionada e de boot.'
    }

    if (Test-PropertyTrue -Object $Context.Partition -Name 'IsSystem') {
        throw 'A particao selecionada e de sistema.'
    }

    $pageFileDrives = @(Get-PageFileDrives)
    if ($pageFileDrives -contains $Context.DriveLetter) {
        throw ('A unidade {0} contem pagefile ativo.' -f $Context.DriveLetter)
    }
}

function Assert-DriveStillSame {
    param([object]$InitialContext)

    try {
        $current = Resolve-DriveToDisk -NormalizedDriveLetter $InitialContext.DriveLetter
    } catch {
        throw ('A unidade {0} desapareceu ou nao pode mais ser resolvida: {1}' -f $InitialContext.DriveLetter, $_.Exception.Message)
    }

    if ($current.NormalizedSerial -ne $InitialContext.NormalizedSerial) {
        throw ('Serial mudou durante a execucao. Inicial={0}; Atual={1}' -f $InitialContext.Serial, $current.Serial)
    }

    Assert-DriveIsSafe -Context $current
    return $current
}

function Get-EligibleVolumes {
    $rows = @()
    $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -ne 'CD-ROM' } | Sort-Object DriveLetter)
    foreach ($volume in $volumes) {
        $normalized = Normalize-DriveLetter -Value ([string]$volume.DriveLetter)
        if (-not $normalized -or $normalized -eq 'C:') {
            continue
        }

        try {
            $context = Resolve-DriveToDisk -NormalizedDriveLetter $normalized
            Assert-DriveIsSafe -Context $context
            $size = [Nullable[Int64]]$volume.Size
            $remaining = [Nullable[Int64]]$volume.SizeRemaining
            $used = if ($null -ne $size -and $null -ne $remaining) { $size - $remaining } else { $null }
            $rows += [pscustomobject]@{
                Index = $rows.Count + 1
                DriveLetter = $normalized
                Label = [string]$volume.FileSystemLabel
                FileSystem = [string]$volume.FileSystem
                Size = $size
                Used = $used
                Free = $remaining
                Context = $context
            }
        } catch {
            Write-Log -Level 'WARNING' -Message ('Unidade {0} ignorada na listagem: {1}' -f $normalized, $_.Exception.Message)
        }
    }

    return @($rows)
}

function Show-EligibleVolumes {
    param([object[]]$Rows)

    Write-Section -Title 'UNIDADES DISPONIVEIS'
    if ($Rows.Count -eq 0) {
        Write-Status -Status 'ERROR' -Message 'Nenhuma unidade elegivel foi encontrada.'
        return
    }

    foreach ($row in $Rows) {
        $label = if ([string]::IsNullOrWhiteSpace($row.Label)) { '(sem label)' } else { $row.Label }
        Write-Host ('[{0}] {1,-3} {2,-18} {3,-8} Tamanho {4,12} | Usado {5,12} | Livre {6,12}' -f `
            $row.Index,
            $row.DriveLetter,
            $label,
            $row.FileSystem,
            (Format-Bytes $row.Size),
            (Format-Bytes $row.Used),
            (Format-Bytes $row.Free))
    }
}

function Select-DriveContext {
    param([string]$PreselectedDriveLetter)

    $rows = @(Get-EligibleVolumes)
    Show-EligibleVolumes -Rows $rows

    if ($PreselectedDriveLetter) {
        $normalized = Normalize-DriveLetter -Value $PreselectedDriveLetter
        if (-not $normalized) {
            throw 'DriveLetter informado e invalido.'
        }

        $match = @($rows | Where-Object { $_.DriveLetter -eq $normalized })
        if ($match.Count -ne 1) {
            throw ('A unidade pre-selecionada {0} nao esta elegivel.' -f $normalized)
        }

        Write-Status -Status 'INFO' -Message ('Unidade pre-selecionada: {0}' -f $normalized)
        return $match[0].Context
    }

    if ($rows.Count -eq 0) {
        throw 'Nenhuma unidade elegivel para selecionar.'
    }

    while ($true) {
        $selection = Read-Host 'Selecione a unidade que deseja verificar (indice ou letra)'
        if ([string]::IsNullOrWhiteSpace($selection)) {
            continue
        }

        $trimmed = $selection.Trim()
        if ($trimmed -match '^\d+$') {
            $index = [int]$trimmed
            $match = @($rows | Where-Object { $_.Index -eq $index })
            if ($match.Count -eq 1) {
                return $match[0].Context
            }
        }

        $normalized = Normalize-DriveLetter -Value $trimmed
        if ($normalized) {
            $match = @($rows | Where-Object { $_.DriveLetter -eq $normalized })
            if ($match.Count -eq 1) {
                return $match[0].Context
            }
        }

        Write-Host 'Selecao invalida. Informe o indice da lista ou uma letra como E:.' -ForegroundColor Yellow
    }
}

function Show-DiskIdentity {
    param([object]$Context)

    $diskStatus = if ($Context.Disk.IsOffline) { 'Offline' } else { 'Online' }

    Write-Section -Title 'DISCO FISICO IDENTIFICADO'
    Write-Host ('Unidade : {0}' -f $Context.DriveLetter)
    Write-Host ('Disco   : {0}' -f $Context.DiskNumber)
    Write-Host ('Modelo  : {0}' -f $Context.Model)
    Write-Host ('Serial  : {0}' -f $Context.Serial)
    Write-Host ('Tamanho : {0}' -f (Format-Bytes $Context.Disk.Size))
    Write-Host ('Status  : {0}' -f $diskStatus)
    Write-Host ('BusType : {0}' -f $Context.Disk.BusType)
}

function Get-KnownManifestSerials {
    param([string]$ManifestRoot)

    if (-not (Test-Path -LiteralPath $ManifestRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $ManifestRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}

function Offer-KnownOfflineDisksOnline {
    param([string]$ManifestRoot)

    $knownSerialDirs = @(Get-KnownManifestSerials -ManifestRoot $ManifestRoot)
    if ($knownSerialDirs.Count -eq 0) {
        return
    }

    $knownNormalized = @{}
    foreach ($serial in $knownSerialDirs) {
        $knownNormalized[(Normalize-Serial -Serial $serial)] = $serial
    }

    $offlineDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.IsOffline })
    foreach ($disk in $offlineDisks) {
        $serial = [string]$disk.SerialNumber
        $normalized = Normalize-Serial -Serial $serial
        if (-not $knownNormalized.ContainsKey($normalized)) {
            continue
        }

        if (Test-PropertyTrue -Object $disk -Name 'IsBoot' -or Test-PropertyTrue -Object $disk -Name 'IsSystem') {
            continue
        }

        Write-Section -Title 'DISCO CONHECIDO OFFLINE'
        Write-Host ('Disco   : {0}' -f $disk.Number)
        Write-Host ('Modelo  : {0}' -f $disk.FriendlyName)
        Write-Host ('Serial  : {0}' -f $disk.SerialNumber)
        Write-Host ('Tamanho : {0}' -f (Format-Bytes $disk.Size))

        if (Read-YesNo -Prompt 'Deseja colocar este disco ONLINE para iniciar a verificacao? [S/N]') {
            Write-Log -Level 'INFO' -Message ('Usuario confirmou online do disco {0} serial {1}' -f $disk.Number, $disk.SerialNumber)
            Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
            Start-Sleep -Seconds 2
            $updated = Get-Disk -Number $disk.Number -ErrorAction Stop
            if ($updated.IsOffline) {
                throw ('Falha ao colocar disco {0} online.' -f $disk.Number)
            }
            Write-Status -Status 'OK' -Message ('Disco {0} esta online. Se a letra ainda nao aparecer, aguarde alguns segundos e execute novamente.' -f $disk.Number)
        } else {
            Write-Status -Status 'SKIPPED' -Message ('Disco {0} permaneceu offline.' -f $disk.Number)
        }
    }
}

function Invoke-Smartctl {
    param([string[]]$Arguments)

    $output = & $Script:SmartctlPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $raw = ($output | Out-String).Trim()
    $json = $null

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $json = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $json = $null
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw = $raw
        Json = $json
        Arguments = ($Arguments -join ' ')
    }
}

function Get-SmartScanCandidates {
    $scan = Invoke-Smartctl -Arguments @('--scan-open')
    if ([string]::IsNullOrWhiteSpace($scan.Raw)) {
        $scan = Invoke-Smartctl -Arguments @('--scan')
    }

    $candidates = @()
    foreach ($line in ($scan.Raw -split "`r?`n")) {
        $body = ($line -split '#', 2)[0].Trim()
        if ([string]::IsNullOrWhiteSpace($body)) {
            continue
        }

        $tokens = @($body -split '\s+')
        if ($tokens.Count -lt 1) {
            continue
        }

        $device = $tokens[0]
        $options = @()
        if ($tokens.Count -gt 1) {
            $options = @($tokens[1..($tokens.Count - 1)])
        }

        $candidates += [pscustomobject]@{
            Device = $device
            Options = $options
            ScanLine = $line
        }
    }

    return @($candidates)
}

function Get-SmartIdentifyForDevice {
    param(
        [string]$Device,
        [string[]]$Options
    )

    $args = @('-i', '-j') + @($Options) + @($Device)
    $info = Invoke-Smartctl -Arguments $args
    if ($null -eq $info.Json) {
        return $null
    }

    $smartSerial = [string]$info.Json.serial_number
    $smartModel = [string]$info.Json.model_name
    if ([string]::IsNullOrWhiteSpace($smartModel) -and $info.Json.device) {
        $smartModel = [string]$info.Json.device.model_name
    }

    return [pscustomobject]@{
        Device = $Device
        Options = @($Options)
        Serial = $smartSerial
        NormalizedSerial = Normalize-Serial -Serial $smartSerial
        Model = $smartModel
        Identify = $info.Json
        ExitCode = $info.ExitCode
        Raw = $info.Raw
    }
}

function Confirm-PhysicalDiskSmartFallback {
    param(
        [object]$Context,
        [object]$FallbackCandidate
    )

    Write-Section -Title 'SMART SEM SERIAL'
    Write-Status -Status 'WARNING' -Message 'O smartctl nao informou serial para este HDD, mas conseguiu ler SMART pelo numero fisico do disco.'
    Write-Host ''
    Write-Host 'Windows identificou:'
    Write-Host ('  Unidade : {0}' -f $Context.DriveLetter)
    Write-Host ('  Disco   : {0}' -f $Context.DiskNumber)
    Write-Host ('  Modelo  : {0}' -f $Context.Model)
    Write-Host ('  Serial  : {0}' -f $Context.Serial)
    Write-Host ''
    Write-Host 'smartctl identificou:'
    $fallbackSerialText = if ([string]::IsNullOrWhiteSpace($FallbackCandidate.Serial)) { '(ausente)' } else { $FallbackCandidate.Serial }
    Write-Host ('  Device  : {0}' -f $FallbackCandidate.Device)
    Write-Host ('  Modelo  : {0}' -f $FallbackCandidate.Model)
    Write-Host ('  Serial  : {0}' -f $fallbackSerialText)
    Write-Host ''
    Write-Host 'Este fallback usa o mapeamento Windows PhysicalDrive/Disco fisico:'
    Write-Host ('  Disk {0} -> {1}' -f $Context.DiskNumber, $FallbackCandidate.Device)
    Write-Host ''
    Write-Host 'Ele e menos forte que serial SMART, mas e adequado quando o smartctl nao expoe o serial e o numero fisico/modelo conferem.'

    if ($AllowPhysicalDiskSmartFallback) {
        Write-Status -Status 'WARNING' -Message 'Fallback por disco fisico permitido pelo parametro -AllowPhysicalDiskSmartFallback.'
        return $true
    }

    return (Read-YesNo -Prompt 'Deseja usar este mapeamento SMART por numero fisico do disco? [S/N]')
}

function Get-PhysicalDiskSmartFallback {
    param([object]$Context)

    $device = ('/dev/pd{0}' -f $Context.DiskNumber)
    $candidate = Get-SmartIdentifyForDevice -Device $device -Options @()
    if ($null -eq $candidate) {
        Write-Log -Level 'WARNING' -Message ('Fallback SMART {0} nao retornou JSON valido.' -f $device)
        return $null
    }

    Write-Log -Level 'INFO' -Message ('SMART physical fallback {0} model [{1}] serial [{2}]' -f $candidate.Device, $candidate.Model, $candidate.Serial)

    if ([string]::IsNullOrWhiteSpace($candidate.Model)) {
        return $null
    }

    if ([string]$candidate.Model -ne [string]$Context.Model) {
        Write-Log -Level 'WARNING' -Message ('Fallback SMART model mismatch. Windows [{0}], smartctl [{1}]' -f $Context.Model, $candidate.Model)
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($candidate.Serial) -and $candidate.NormalizedSerial -ne $Context.NormalizedSerial) {
        Write-Log -Level 'WARNING' -Message ('Fallback SMART serial mismatch. Windows [{0}], smartctl [{1}]' -f $Context.Serial, $candidate.Serial)
        return $null
    }

    if (-not (Confirm-PhysicalDiskSmartFallback -Context $Context -FallbackCandidate $candidate)) {
        throw 'Usuario recusou fallback SMART por numero fisico do disco.'
    }

    return [pscustomobject]@{
        Device = $candidate.Device
        Options = @()
        ScanLine = ('{0} # Windows PhysicalDrive/Disk {1} fallback' -f $candidate.Device, $Context.DiskNumber)
        Serial = $candidate.Serial
        Model = $candidate.Model
        Identify = $candidate.Identify
        MappingMethod = 'PhysicalDiskNumberFallback'
    }
}

function Match-SmartDevice {
    param([object]$Context)

    Write-Section -Title 'SMART DEVICE MAPPING'
    Write-Status -Status 'INFO' -Message 'Procurando dispositivo SMART por serial.'

    $candidates = @(Get-SmartScanCandidates)
    if ($candidates.Count -eq 0) {
        throw 'smartctl nao retornou candidatos.'
    }

    $smartMatches = @()
    $candidateSummaries = @()
    foreach ($candidate in $candidates) {
        $identify = Get-SmartIdentifyForDevice -Device $candidate.Device -Options @($candidate.Options)
        if ($null -eq $identify) {
            Write-Log -Level 'WARNING' -Message ('SMART candidato sem JSON valido: {0}' -f $candidate.ScanLine)
            continue
        }

        $candidateSummaries += [pscustomobject]@{
            device = $candidate.Device
            options = @($candidate.Options)
            model = $identify.Model
            serial = $identify.Serial
            normalizedSerial = $identify.NormalizedSerial
        }
        Write-Log -Level 'INFO' -Message ('SMART candidate {0} options [{1}] model [{2}] serial [{3}]' -f $candidate.Device, ($candidate.Options -join ' '), $identify.Model, $identify.Serial)

        if ($identify.NormalizedSerial -eq $Context.NormalizedSerial) {
            $smartMatches += [pscustomobject]@{
                Device = $candidate.Device
                Options = @($candidate.Options)
                ScanLine = $candidate.ScanLine
                Serial = $identify.Serial
                Model = $identify.Model
                Identify = $identify.Identify
                MappingMethod = 'Serial'
            }
        }
    }

    if ($smartMatches.Count -ne 1) {
        $withModel = @($candidateSummaries | Where-Object { [string]$_.model -eq [string]$Context.Model })
        if ($smartMatches.Count -eq 0 -and $withModel.Count -gt 0) {
            $fallback = Get-PhysicalDiskSmartFallback -Context $Context
            if ($fallback) {
                Write-Status -Status 'OK' -Message ('SMART associado por numero fisico: {0} (Disk {1})' -f $fallback.Device, $Context.DiskNumber)
                Write-Log -Level 'WARNING' -Message ('SMART device matched by physical disk fallback: {0}' -f $fallback.ScanLine)
                return $fallback
            }

            throw ('Nao foi possivel associar com seguranca {0} ao SMART por serial. O smartctl encontrou modelo compativel ({1}), mas nao informou serial. Verifique logs para candidatos.' -f $Context.DriveLetter, $Context.Model)
        }

        throw ('Nao foi possivel associar com seguranca {0} ao SMART por serial. Candidatos correspondentes: {1}. Verifique logs para detalhes.' -f $Context.DriveLetter, $smartMatches.Count)
    }

    $match = $smartMatches[0]
    Write-Status -Status 'OK' -Message ('SMART associado: {0} serial {1}' -f $match.Device, $match.Serial)
    Write-Log -Level 'INFO' -Message ('SMART device matched by serial: {0}' -f $match.ScanLine)
    return $match
}

function Get-RawSmartAttributeValue {
    param(
        [object]$SmartJson,
        [int[]]$Ids,
        [string[]]$Names
    )

    if ($null -eq $SmartJson -or $null -eq $SmartJson.ata_smart_attributes -or $null -eq $SmartJson.ata_smart_attributes.table) {
        return $null
    }

    foreach ($row in @($SmartJson.ata_smart_attributes.table)) {
        $rowName = [string]$row.name
        $rowId = [int]$row.id
        if (($Ids -contains $rowId) -or ($Names -contains $rowName)) {
            $raw = $row.raw.value
            if ($null -eq $raw) {
                $raw = $row.raw.string
            }

            $digits = ([string]$raw -replace '[^\d-]', ' ').Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($digits.Count -gt 0) {
                return [int64]$digits[0]
            }
        }
    }

    return $null
}

function Test-SmartSelfTestFailure {
    param([object]$SmartJson)

    if ($null -eq $SmartJson -or $null -eq $SmartJson.ata_smart_self_test_log -or $null -eq $SmartJson.ata_smart_self_test_log.standard) {
        return $false
    }

    foreach ($row in @($SmartJson.ata_smart_self_test_log.standard.table)) {
        $status = [string]$row.status.string
        if ($status -match 'Completed.*(read failure|write failure|servo|electrical|unknown failure|handling damage|interrupted.*host reset)') {
            return $true
        }
    }

    return $false
}

function Get-PreviousReport {
    param(
        [string]$ReportRoot,
        [string]$CurrentReportPath
    )

    if (-not (Test-Path -LiteralPath $ReportRoot)) {
        return $null
    }

    $previousFiles = @(Get-ChildItem -LiteralPath $ReportRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $CurrentReportPath } |
        Sort-Object LastWriteTimeUtc -Descending)

    if ($previousFiles.Count -eq 0) {
        return $null
    }

    try {
        return (Get-Content -Raw -LiteralPath $previousFiles[0].FullName | ConvertFrom-Json)
    } catch {
        Write-Log -Level 'WARNING' -Message ('Nao foi possivel ler relatorio anterior: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-SmartReport {
    param(
        [object]$SmartDevice,
        [object]$PreviousReport
    )

    $args = @('-a', '-j') + @($SmartDevice.Options) + @($SmartDevice.Device)
    $result = Invoke-Smartctl -Arguments $args
    if ($null -eq $result.Json) {
        throw ('smartctl nao retornou JSON valido para SMART completo. Saida: {0}' -f $result.Raw)
    }

    $smart = $result.Json
    $healthPassed = $null
    if ($smart.smart_status -and $null -ne $smart.smart_status.passed) {
        $healthPassed = [bool]$smart.smart_status.passed
    }

    $temperature = $null
    if ($smart.temperature -and $null -ne $smart.temperature.current) {
        $temperature = [int]$smart.temperature.current
    } elseif ($smart.nvme_smart_health_information_log -and $null -ne $smart.nvme_smart_health_information_log.temperature) {
        $temperature = [int]$smart.nvme_smart_health_information_log.temperature
    }

    $powerOnHours = $null
    if ($smart.power_on_time -and $null -ne $smart.power_on_time.hours) {
        $powerOnHours = [int64]$smart.power_on_time.hours
    } elseif ($smart.nvme_smart_health_information_log -and $null -ne $smart.nvme_smart_health_information_log.power_on_hours) {
        $powerOnHours = [int64]$smart.nvme_smart_health_information_log.power_on_hours
    }

    $powerCycles = $null
    if ($null -ne $smart.power_cycle_count) {
        $powerCycles = [int64]$smart.power_cycle_count
    } elseif ($smart.nvme_smart_health_information_log -and $null -ne $smart.nvme_smart_health_information_log.power_cycles) {
        $powerCycles = [int64]$smart.nvme_smart_health_information_log.power_cycles
    }

    $attributes = [ordered]@{
        reallocatedSectors = Get-RawSmartAttributeValue -SmartJson $smart -Ids @(5) -Names @('Reallocated_Sector_Ct', 'Reallocated_Event_Count')
        currentPendingSectors = Get-RawSmartAttributeValue -SmartJson $smart -Ids @(197) -Names @('Current_Pending_Sector')
        offlineUncorrectable = Get-RawSmartAttributeValue -SmartJson $smart -Ids @(198) -Names @('Offline_Uncorrectable')
        udmaCrcErrors = Get-RawSmartAttributeValue -SmartJson $smart -Ids @(199) -Names @('UDMA_CRC_Error_Count', 'CRC_Error_Count')
    }

    $alerts = @()
    $classification = 'OK'

    if ($null -eq $healthPassed) {
        $classification = 'UNKNOWN'
        $alerts += 'SMART overall-health desconhecido.'
    } elseif (-not $healthPassed) {
        $classification = 'CRITICAL'
        $alerts += 'SMART overall-health falhou.'
    }

    if ($null -ne $attributes.currentPendingSectors -and $attributes.currentPendingSectors -gt 0) {
        if ($classification -ne 'CRITICAL') { $classification = 'WARNING' }
        $alerts += ('Setores pendentes: {0}' -f $attributes.currentPendingSectors)
    }

    if ($null -ne $attributes.offlineUncorrectable -and $attributes.offlineUncorrectable -gt 0) {
        if ($classification -ne 'CRITICAL') { $classification = 'WARNING' }
        $alerts += ('Offline uncorrectable: {0}' -f $attributes.offlineUncorrectable)
    }

    if ($null -ne $PreviousReport -and $PreviousReport.smart -and $PreviousReport.smart.attributes) {
        $previousReallocated = $PreviousReport.smart.attributes.reallocatedSectors
        if ($null -ne $previousReallocated -and $null -ne $attributes.reallocatedSectors -and [int64]$attributes.reallocatedSectors -gt [int64]$previousReallocated) {
            if ($classification -ne 'CRITICAL') { $classification = 'WARNING' }
            $alerts += ('Setores realocados cresceram: anterior {0}, atual {1}' -f $previousReallocated, $attributes.reallocatedSectors)
        }
    }

    if (Test-SmartSelfTestFailure -SmartJson $smart) {
        $classification = 'CRITICAL'
        $alerts += 'Historico SMART contem falha em self-test.'
    }

    $summary = [ordered]@{
        classification = $classification
        healthPassed = $healthPassed
        temperatureC = $temperature
        powerOnHours = $powerOnHours
        powerCycleCount = $powerCycles
        firmware = [string]$smart.firmware_version
        attributes = $attributes
        alerts = @($alerts)
        rawSmartctlExitCode = $result.ExitCode
        raw = $smart
    }

    if ($classification -eq 'OK') {
        Write-Status -Status 'OK' -Message 'SMART inicial sem alertas relevantes.'
    } elseif ($classification -eq 'WARNING') {
        Write-Status -Status 'WARNING' -Message ('SMART com alertas: {0}' -f ($alerts -join '; '))
    } elseif ($classification -eq 'CRITICAL') {
        Write-Status -Status 'ERROR' -Message ('SMART critico: {0}' -f ($alerts -join '; '))
    } else {
        Write-Status -Status 'WARNING' -Message ('SMART desconhecido: {0}' -f ($alerts -join '; '))
    }

    return [pscustomobject]$summary
}

function Get-SmartSelfTestStatus {
    param([object]$SmartDevice)

    $report = Get-SmartReport -SmartDevice $SmartDevice -PreviousReport $null
    $raw = $report.raw
    $statusString = $null
    $remaining = $null

    if ($raw.ata_smart_data -and $raw.ata_smart_data.self_test -and $raw.ata_smart_data.self_test.status) {
        $statusString = [string]$raw.ata_smart_data.self_test.status.string
        if ($null -ne $raw.ata_smart_data.self_test.status.remaining_percent) {
            $remaining = [int]$raw.ata_smart_data.self_test.status.remaining_percent
        }
    }

    $inProgress = $false
    if ($statusString -match 'progress|remaining|Self-test routine in progress') {
        $inProgress = $true
    }
    if ($null -ne $remaining -and $remaining -gt 0) {
        $inProgress = $true
    }

    return [pscustomobject]@{
        InProgress = $inProgress
        Status = $statusString
        RemainingPercent = $remaining
        Report = $report
    }
}

function Get-LongTestEstimateMinutes {
    param([object]$SmartDevice)

    $args = @('-c', '-j') + @($SmartDevice.Options) + @($SmartDevice.Device)
    $capabilities = Invoke-Smartctl -Arguments $args
    if ($null -eq $capabilities.Json) {
        return $null
    }

    $json = $capabilities.Json
    if ($json.ata_smart_data -and $json.ata_smart_data.self_test -and $json.ata_smart_data.self_test.polling_minutes) {
        $polling = $json.ata_smart_data.self_test.polling_minutes
        if ($null -ne $polling.extended) {
            return [int]$polling.extended
        }
        if ($null -ne $polling.long) {
            return [int]$polling.long
        }
    }

    return $null
}

function Test-CancelKeyPressed {
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            return ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q')
        }
    } catch {
        return $false
    }

    return $false
}

function Invoke-SmartLongTest {
    param(
        [object]$SmartDevice,
        [int]$PollSeconds
    )

    Write-Section -Title 'SMART LONG / EXTENDED SELF-TEST'
    $estimate = Get-LongTestEstimateMinutes -SmartDevice $SmartDevice
    if ($estimate) {
        Write-Status -Status 'INFO' -Message ('Estimativa informada pelo HDD: aproximadamente {0} minutos.' -f $estimate)
    } else {
        Write-Status -Status 'INFO' -Message 'Estimativa de duracao nao informada pelo HDD.'
    }

    $startArgs = @('-t', 'long') + @($SmartDevice.Options) + @($SmartDevice.Device)
    $start = Invoke-Smartctl -Arguments $startArgs
    Write-Log -Level 'INFO' -Message ('Long self-test start output: {0}' -f $start.Raw)

    if ($start.ExitCode -ne 0 -and $start.Raw -match 'failed|unsupported|error|abort') {
        return [pscustomobject]@{
            status = 'FAILED_TO_START'
            classification = 'CRITICAL'
            estimateMinutes = $estimate
            startedAt = Get-Date
            finishedAt = Get-Date
            output = $start.Raw
        }
    }

    Write-Status -Status 'OK' -Message 'Long Self-Test iniciado. Pressione Q durante a espera para cancelar o teste.'
    $startedAt = Get-Date

    while ($true) {
        Start-Sleep -Seconds 5
        $status = Get-SmartSelfTestStatus -SmartDevice $SmartDevice
        $remainingText = if ($null -ne $status.RemainingPercent) { ('{0}% restante' -f $status.RemainingPercent) } else { 'progresso desconhecido' }
        $statusText = if ($status.Status) { $status.Status } else { 'status nao informado' }
        Write-Status -Status 'INFO' -Message ('Long Test: {0}; {1}' -f $statusText, $remainingText)

        if (-not $status.InProgress) {
            break
        }

        for ($i = 0; $i -lt $PollSeconds; $i++) {
            if (Test-CancelKeyPressed) {
                if (Read-YesNo -Prompt 'Cancelar o SMART Long Self-Test agora? [S/N]') {
                    $abortArgs = @('-X') + @($SmartDevice.Options) + @($SmartDevice.Device)
                    $abort = Invoke-Smartctl -Arguments $abortArgs
                    Write-Log -Level 'WARNING' -Message ('Usuario cancelou Long Self-Test. smartctl -X: {0}' -f $abort.Raw)
                    Write-Status -Status 'WARNING' -Message 'Long Self-Test cancelado pelo usuario.'
                    return [pscustomobject]@{
                        status = 'CANCELLED'
                        classification = 'INCOMPLETE'
                        estimateMinutes = $estimate
                        startedAt = $startedAt
                        finishedAt = Get-Date
                        output = $abort.Raw
                    }
                }
            }
            Start-Sleep -Seconds 1
        }
    }

    $finalStatus = Get-SmartSelfTestStatus -SmartDevice $SmartDevice
    $failed = Test-SmartSelfTestFailure -SmartJson $finalStatus.Report.raw
    $classification = if ($failed) { 'CRITICAL' } else { 'OK' }
    $label = if ($failed) { 'FAILED' } else { 'PASSED' }

    if ($failed) {
        Write-Status -Status 'ERROR' -Message 'Long Self-Test finalizou com falha registrada no historico SMART.'
    } else {
        Write-Status -Status 'OK' -Message 'Long Self-Test finalizou sem falha registrada.'
    }

    return [pscustomobject]@{
        status = $label
        classification = $classification
        estimateMinutes = $estimate
        startedAt = $startedAt
        finishedAt = Get-Date
        finalStatus = $finalStatus.Status
    }
}

function Invoke-ReadOnlyFilesystemCheck {
    param([object]$Context)

    Write-Section -Title 'FILESYSTEM'
    $fileSystem = [string]$Context.Volume.FileSystem

    if ($fileSystem -ne 'NTFS') {
        Write-Status -Status 'SKIPPED' -Message ('Filesystem {0} nao possui scan nao destrutivo implementado neste script.' -f $fileSystem)
        return [pscustomobject]@{
            status = 'SKIPPED'
            classification = 'WARNING'
            fileSystem = $fileSystem
            details = 'Filesystem nao suportado para scan somente leitura.'
        }
    }

    if (-not (Get-Command 'Repair-Volume' -ErrorAction SilentlyContinue)) {
        Write-Status -Status 'SKIPPED' -Message 'Repair-Volume nao esta disponivel neste PowerShell.'
        return [pscustomobject]@{
            status = 'SKIPPED'
            classification = 'WARNING'
            fileSystem = $fileSystem
            details = 'Repair-Volume indisponivel.'
        }
    }

    try {
        Write-Status -Status 'INFO' -Message ('Executando scan NTFS nao destrutivo em {0}' -f $Context.DriveLetter)
        $scanResult = Repair-Volume -DriveLetter $Context.DriveLetterChar -Scan -ErrorAction Stop
        $text = ($scanResult | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = 'Repair-Volume -Scan concluiu sem detalhes adicionais.'
        }

        if ($text -match 'NoErrorsFound|No errors|sem erros') {
            Write-Status -Status 'OK' -Message 'Filesystem sem inconsistencias reportadas.'
            $classification = 'OK'
            $status = 'OK'
        } elseif ($text -match 'ScanNeeded|SpotFixNeeded|Corruption|erro|error') {
            Write-Status -Status 'WARNING' -Message 'Foram encontradas possiveis inconsistencias. Nenhuma correcao automatica foi executada.'
            $classification = 'WARNING'
            $status = 'WARNING'
        } else {
            Write-Status -Status 'OK' -Message 'Scan de filesystem concluido.'
            $classification = 'OK'
            $status = 'OK'
        }

        return [pscustomobject]@{
            status = $status
            classification = $classification
            fileSystem = $fileSystem
            details = $text
        }
    } catch {
        Write-Status -Status 'WARNING' -Message ('Falha no scan de filesystem: {0}' -f $_.Exception.Message)
        return [pscustomobject]@{
            status = 'ERROR'
            classification = 'WARNING'
            fileSystem = $fileSystem
            details = $_.Exception.Message
        }
    }
}

function Test-RelativePathExcluded {
    param(
        [string]$RelativePath,
        [string[]]$Excludes
    )

    $path = ($RelativePath -replace '/', '\').TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    $leaf = Split-Path -Leaf $path
    foreach ($exclude in $Excludes) {
        if ([string]::IsNullOrWhiteSpace($exclude)) {
            continue
        }

        $pattern = ($exclude -replace '/', '\').Trim('\')
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }

        if ($pattern -like '*`**' -or $pattern -like '*?*') {
            if ($path -like $pattern -or $leaf -like $pattern) {
                return $true
            }
        } else {
            if ($path -ieq $pattern -or $leaf -ieq $pattern -or $path.StartsWith($pattern + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    return $false
}

function Get-RelativePath {
    param(
        [string]$RootPath,
        [string]$FullName
    )

    $root = $RootPath.TrimEnd('\') + '\'
    if ($FullName.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($root.Length)
    }

    return $FullName
}

function Get-ScopedFiles {
    param(
        [string]$RootPath,
        [object]$Config
    )

    $includeItems = @($Config.include)
    $startPaths = @()
    if ($includeItems.Count -eq 0) {
        $startPaths += $RootPath
    } else {
        foreach ($include in $includeItems) {
            if ([string]::IsNullOrWhiteSpace($include)) {
                continue
            }
            $startPaths += (Join-Path $RootPath $include)
        }
    }

    foreach ($start in $startPaths) {
        if (-not (Test-Path -LiteralPath $start)) {
            Write-Log -Level 'WARNING' -Message ('Include inexistente ignorado: {0}' -f $start)
            continue
        }

        $item = Get-Item -LiteralPath $start -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            $relativeFile = Get-RelativePath -RootPath $RootPath -FullName $item.FullName
            if (-not (Test-RelativePathExcluded -RelativePath $relativeFile -Excludes @($Config.exclude))) {
                Write-Output $item
            }
            continue
        }

        $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $stack.Push([System.IO.DirectoryInfo]$item)

        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            $relativeDir = Get-RelativePath -RootPath $RootPath -FullName $dir.FullName
            if (Test-RelativePathExcluded -RelativePath $relativeDir -Excludes @($Config.exclude)) {
                continue
            }

            try {
                foreach ($file in $dir.EnumerateFiles()) {
                    $relativeFile = Get-RelativePath -RootPath $RootPath -FullName $file.FullName
                    if (-not (Test-RelativePathExcluded -RelativePath $relativeFile -Excludes @($Config.exclude))) {
                        Write-Output $file
                    }
                }

                foreach ($childDir in $dir.EnumerateDirectories()) {
                    $relativeChild = Get-RelativePath -RootPath $RootPath -FullName $childDir.FullName
                    if (-not (Test-RelativePathExcluded -RelativePath $relativeChild -Excludes @($Config.exclude))) {
                        $stack.Push($childDir)
                    }
                }
            } catch {
                $Script:ChecksumEnumerationErrors++
                Write-Log -Level 'WARNING' -Message ('Erro ao enumerar {0}: {1}' -f $dir.FullName, $_.Exception.Message)
            }
        }
    }
}

function Get-FileInventoryStats {
    param(
        [string]$RootPath,
        [object]$Config
    )

    $count = 0
    [int64]$bytes = 0
    $startedAt = Get-Date
    $lastProgress = Get-Date
    $lastConsoleLine = Get-Date
    foreach ($file in Get-ScopedFiles -RootPath $RootPath -Config $Config) {
        if (Test-CancelKeyPressed) {
            if (Read-YesNo -Prompt 'Cancelar a estimativa de escopo agora? [S/N]') {
                Write-Progress -Activity 'Estimando escopo de arquivos' -Completed
                throw 'Usuario cancelou a estimativa de escopo.'
            }
        }

        $count++
        $bytes += [int64]$file.Length

        $now = Get-Date
        if (($now - $lastProgress).TotalSeconds -ge 2 -or ($count % 5000) -eq 0) {
            $writeConsole = (($now - $lastConsoleLine).TotalSeconds -ge 30)
            Write-InventoryProgress -Count $count -Bytes $bytes -CurrentPath $file.FullName -StartedAt $startedAt -ConsoleLine:$writeConsole
            $lastProgress = $now
            if ($writeConsole) {
                $lastConsoleLine = $now
            }
        }
    }

    Write-Progress -Activity 'Estimando escopo de arquivos' -Completed

    return [pscustomobject]@{
        count = $count
        bytes = $bytes
        enumerationErrors = $Script:ChecksumEnumerationErrors
    }
}

function Load-Manifest {
    param([string]$ManifestPath)

    $map = New-Object 'System.Collections.Generic.Dictionary[String,Object]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $map
    }

    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($ManifestPath)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.relativePath)) {
                $map[[string]$entry.relativePath] = $entry
            }
        } catch {
            Write-Log -Level 'WARNING' -Message ('Linha invalida no manifesto {0}:{1}: {2}' -f $ManifestPath, $lineNumber, $_.Exception.Message)
        }
    }

    return $map
}

function Write-InventoryProgress {
    param(
        [int64]$Count,
        [int64]$Bytes,
        [string]$CurrentPath,
        [datetime]$StartedAt,
        [switch]$ConsoleLine
    )

    $elapsed = (Get-Date) - $StartedAt
    $shortPath = if ([string]::IsNullOrWhiteSpace($CurrentPath)) { '' } else { Get-ProjectRelativePath -Path $CurrentPath }
    if ($shortPath.Length -gt 80) {
        $shortPath = '...' + $shortPath.Substring($shortPath.Length - 77)
    }

    $status = ('{0} arquivos | {1} encontrados | {2}' -f $Count, (Format-Bytes $Bytes), (Format-Duration $elapsed))
    if (-not [string]::IsNullOrWhiteSpace($shortPath)) {
        $status = '{0} | atual: {1}' -f $status, $shortPath
    }

    Write-Progress -Activity 'Estimando escopo de arquivos' -Status $status -PercentComplete -1

    if ($ConsoleLine) {
        Write-Status -Status 'INFO' -Message ('Estimativa: {0} arquivos, {1}, tempo {2}' -f $Count, (Format-Bytes $Bytes), (Format-Duration $elapsed))
    }
}

function Write-ChecksumProgress {
    param(
        [int64]$ProcessedFiles,
        [int64]$ProcessedBytes,
        [int64]$TotalBytes,
        [datetime]$StartedAt,
        [string]$CurrentRelativePath,
        [switch]$ConsoleLine
    )

    $elapsed = [Math]::Max(1, ((Get-Date) - $StartedAt).TotalSeconds)
    $rate = [int64]($ProcessedBytes / $elapsed)
    $percent = if ($TotalBytes -gt 0) { [Math]::Min(100, [Math]::Round(($ProcessedBytes / $TotalBytes) * 100, 2)) } else { 0 }
    $remainingSeconds = if ($rate -gt 0 -and $TotalBytes -gt $ProcessedBytes) { [int](($TotalBytes - $ProcessedBytes) / $rate) } else { 0 }
    $eta = if ($remainingSeconds -gt 0) { Format-Duration ([TimeSpan]::FromSeconds($remainingSeconds)) } else { 'calculando' }
    $shortPath = if ([string]::IsNullOrWhiteSpace($CurrentRelativePath)) { '' } else { $CurrentRelativePath }
    if ($shortPath.Length -gt 80) {
        $shortPath = '...' + $shortPath.Substring($shortPath.Length - 77)
    }

    $status = ("{0} arquivos | {1} de {2} | {3}% | {4}/s | restante {5}" -f $ProcessedFiles, (Format-Bytes $ProcessedBytes), (Format-Bytes $TotalBytes), $percent, (Format-Bytes $rate), $eta)
    if (-not [string]::IsNullOrWhiteSpace($shortPath)) {
        $status = '{0} | atual: {1}' -f $status, $shortPath
    }

    Write-Progress -Activity 'Scrub SHA-256' -Status $status -PercentComplete $percent

    if ($ConsoleLine) {
        Write-Status -Status 'INFO' -Message ("Scrub: {0} arquivos | {1}/{2} | {3}% | {4}/s | restante {5}" -f $ProcessedFiles, (Format-Bytes $ProcessedBytes), (Format-Bytes $TotalBytes), $percent, (Format-Bytes $rate), $eta)
    }
}

function New-ManifestEntry {
    param(
        [string]$RelativePath,
        [System.IO.FileInfo]$File,
        [string]$Hash
    )

    return [ordered]@{
        relativePath = $RelativePath
        size = [int64]$File.Length
        lastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
        sha256 = $Hash
    }
}

function New-ChecksumResult {
    param(
        [string]$Status,
        [string]$Classification,
        [string]$ManifestPath,
        [string]$DetailsPath,
        [object]$Stats,
        [int64]$Processed,
        [int64]$ProcessedBytes,
        [int64]$Ok,
        [int64]$Modified,
        [int64]$Missing,
        [int64]$New,
        [int64]$Errors,
        [datetime]$StartedAt,
        [string]$Message,
        [string]$PartialManifestPath
    )

    return [pscustomobject]@{
        status = $Status
        classification = $Classification
        manifestPath = $ManifestPath
        partialManifestPath = $PartialManifestPath
        detailsPath = if ($DetailsPath -and (Test-Path -LiteralPath $DetailsPath)) { $DetailsPath } else { $null }
        totalFiles = $Stats.count
        totalBytes = $Stats.bytes
        processedFiles = $Processed
        processedBytes = $ProcessedBytes
        ok = $Ok
        modified = $Modified
        missing = $Missing
        new = $New
        errors = $Errors
        enumerationErrors = $Script:ChecksumEnumerationErrors
        startedAt = $StartedAt
        finishedAt = Get-Date
        message = $Message
    }
}

function Invoke-ChecksumVerification {
    param(
        [object]$Context,
        [object]$Config,
        [string]$ManifestRoot,
        [string]$ReportRoot
    )

    Write-Section -Title 'SHA-256 / HISTORICO'
    $driveRoot = ('{0}\' -f $Context.DriveLetter)
    $manifestPath = Join-Path $ManifestRoot 'manifest.jsonl'
    $detailsPath = Join-Path $ReportRoot ("{0}_checksum-details.jsonl" -f $Script:RunStamp)
    New-ProjectDirectory -Path $ManifestRoot
    New-ProjectDirectory -Path $ReportRoot

    Write-Status -Status 'INFO' -Message 'Estimando escopo de arquivos.'
    Write-Host 'Pressione Q para cancelar a estimativa de forma limpa.' -ForegroundColor DarkGray
    $Script:ChecksumEnumerationErrors = 0
    $stats = Get-FileInventoryStats -RootPath $driveRoot -Config $Config
    Write-Status -Status 'INFO' -Message ('Escopo: {0} arquivos, {1}.' -f $stats.count, (Format-Bytes $stats.bytes))

    $baselineMode = -not (Test-Path -LiteralPath $manifestPath)
    if ($baselineMode) {
        Write-Host ''
        Write-Host 'Nenhum manifesto anterior foi encontrado.' -ForegroundColor Yellow
        Write-Host 'Esta execucao pode criar uma LINHA DE BASE de checksums.'
        Write-Host 'Ela nao comprova que os arquivos ja estavam integros antes de hoje.'
        if (-not (Read-YesNo -Prompt 'Deseja criar a baseline agora? [S/N]')) {
            Write-Status -Status 'SKIPPED' -Message 'Baseline nao criada por escolha do usuario.'
            return [pscustomobject]@{
                status = 'SKIPPED'
                classification = 'INCOMPLETE'
                manifestPath = $manifestPath
                detailsPath = $null
                totalFiles = $stats.count
                totalBytes = $stats.bytes
                ok = 0
                modified = 0
                missing = 0
                new = 0
                errors = 0
                enumerationErrors = $stats.enumerationErrors
            }
        }
    }

    $started = Get-Date
    $processed = 0
    [int64]$processedBytes = 0
    $ok = 0
    $modified = 0
    $new = 0
    $errors = 0
    $missing = 0
    $lastProgress = Get-Date
    $lastConsoleLine = Get-Date

    if ($baselineMode) {
        Write-Status -Status 'INFO' -Message 'Iniciando scrub SHA-256 para criar baseline.'
        Write-Host 'Pressione Q para cancelar o scrub de forma limpa.' -ForegroundColor DarkGray
        $tempManifestPath = Join-Path $ManifestRoot ("manifest_{0}.partial.jsonl" -f $Script:RunStamp)
        if (Test-Path -LiteralPath $tempManifestPath) {
            Remove-Item -LiteralPath $tempManifestPath -Force
        }

        foreach ($file in Get-ScopedFiles -RootPath $driveRoot -Config $Config) {
            if (Test-CancelKeyPressed) {
                if (Read-YesNo -Prompt 'Cancelar o scrub SHA-256 agora? [S/N]') {
                    Write-Progress -Activity 'SHA-256 / checksum' -Completed
                    Write-Status -Status 'WARNING' -Message 'Scrub SHA-256 cancelado pelo usuario. Nenhum arquivo do HDD foi alterado.'
                    return (New-ChecksumResult `
                        -Status 'CANCELLED' `
                        -Classification 'INCOMPLETE' `
                        -ManifestPath $manifestPath `
                        -DetailsPath $detailsPath `
                        -Stats $stats `
                        -Processed $processed `
                        -ProcessedBytes $processedBytes `
                        -Ok $ok `
                        -Modified $modified `
                        -Missing $missing `
                        -New $new `
                        -Errors $errors `
                        -StartedAt $started `
                        -Message 'Usuario cancelou o scrub SHA-256 durante criacao de baseline.' `
                        -PartialManifestPath $tempManifestPath)
                }
            }

            $processed++
            $relative = Get-RelativePath -RootPath $driveRoot -FullName $file.FullName
            try {
                $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $entry = New-ManifestEntry -RelativePath $relative -File $file -Hash $hash
                Add-Content -LiteralPath $tempManifestPath -Value ($entry | ConvertTo-Json -Compress -Depth 5)
                $ok++
                $processedBytes += [int64]$file.Length
            } catch {
                $errors++
                $detail = [ordered]@{ relativePath = $relative; status = 'ERROR'; message = $_.Exception.Message }
                Add-Content -LiteralPath $detailsPath -Value ($detail | ConvertTo-Json -Compress -Depth 5)
                Write-Log -Level 'WARNING' -Message ('Erro ao hashear {0}: {1}' -f $file.FullName, $_.Exception.Message)
            }

            $now = Get-Date
            if (($now - $lastProgress).TotalSeconds -ge 5 -or ($processed % 100) -eq 0) {
                $writeConsole = (($now - $lastConsoleLine).TotalSeconds -ge 30)
                Write-ChecksumProgress -ProcessedFiles $processed -ProcessedBytes $processedBytes -TotalBytes $stats.bytes -StartedAt $started -CurrentRelativePath $relative -ConsoleLine:$writeConsole
                $lastProgress = Get-Date
                if ($writeConsole) {
                    $lastConsoleLine = $now
                }
            }
        }

        Write-Progress -Activity 'SHA-256 / checksum' -Completed
        if ($errors -eq 0 -and $Script:ChecksumEnumerationErrors -eq 0) {
            Move-Item -LiteralPath $tempManifestPath -Destination $manifestPath -Force
            Write-Status -Status 'OK' -Message ('Baseline criada: {0}' -f $manifestPath)
            $classification = 'OK'
            $status = 'BASELINE_CREATED'
        } else {
            Write-Status -Status 'WARNING' -Message ('Baseline parcial mantida por haver erros: {0}' -f $tempManifestPath)
            $classification = 'INCOMPLETE'
            $status = 'BASELINE_PARTIAL'
        }
    } else {
        Write-Status -Status 'INFO' -Message ('Carregando manifesto: {0}' -f $manifestPath)
        $manifest = Load-Manifest -ManifestPath $manifestPath
        $seen = New-Object 'System.Collections.Generic.HashSet[String]' ([System.StringComparer]::OrdinalIgnoreCase)
        Write-Status -Status 'INFO' -Message 'Iniciando scrub SHA-256 e comparacao com manifesto.'
        Write-Host 'Pressione Q para cancelar o scrub de forma limpa.' -ForegroundColor DarkGray

        if (Test-Path -LiteralPath $detailsPath) {
            Remove-Item -LiteralPath $detailsPath -Force
        }

        foreach ($file in Get-ScopedFiles -RootPath $driveRoot -Config $Config) {
            if (Test-CancelKeyPressed) {
                if (Read-YesNo -Prompt 'Cancelar o scrub SHA-256 agora? [S/N]') {
                    Write-Progress -Activity 'SHA-256 / checksum' -Completed
                    Write-Status -Status 'WARNING' -Message 'Scrub SHA-256 cancelado pelo usuario. Nenhum arquivo do HDD foi alterado.'
                    return (New-ChecksumResult `
                        -Status 'CANCELLED' `
                        -Classification 'INCOMPLETE' `
                        -ManifestPath $manifestPath `
                        -DetailsPath $detailsPath `
                        -Stats $stats `
                        -Processed $processed `
                        -ProcessedBytes $processedBytes `
                        -Ok $ok `
                        -Modified $modified `
                        -Missing $missing `
                        -New $new `
                        -Errors $errors `
                        -StartedAt $started `
                        -Message 'Usuario cancelou o scrub SHA-256 durante comparacao com manifesto.' `
                        -PartialManifestPath $null)
                }
            }

            $processed++
            $relative = Get-RelativePath -RootPath $driveRoot -FullName $file.FullName
            try {
                $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $entry = $null
                if ($manifest.TryGetValue($relative, [ref]$entry)) {
                    [void]$seen.Add($relative)
                    if ([string]$entry.sha256 -eq $hash) {
                        $ok++
                    } else {
                        $modified++
                        $detail = [ordered]@{
                            relativePath = $relative
                            status = 'MODIFIED'
                            message = 'CHECKSUM MISMATCH'
                            oldSha256 = [string]$entry.sha256
                            newSha256 = $hash
                            oldSize = $entry.size
                            newSize = [int64]$file.Length
                            oldLastWriteTimeUtc = $entry.lastWriteTimeUtc
                            newLastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                        }
                        Add-Content -LiteralPath $detailsPath -Value ($detail | ConvertTo-Json -Compress -Depth 5)
                    }
                } else {
                    $new++
                    $detail = [ordered]@{
                        relativePath = $relative
                        status = 'NEW'
                        size = [int64]$file.Length
                        lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                        sha256 = $hash
                    }
                    Add-Content -LiteralPath $detailsPath -Value ($detail | ConvertTo-Json -Compress -Depth 5)
                }

                $processedBytes += [int64]$file.Length
            } catch {
                $errors++
                $detail = [ordered]@{ relativePath = $relative; status = 'ERROR'; message = $_.Exception.Message }
                Add-Content -LiteralPath $detailsPath -Value ($detail | ConvertTo-Json -Compress -Depth 5)
                Write-Log -Level 'WARNING' -Message ('Erro ao hashear {0}: {1}' -f $file.FullName, $_.Exception.Message)
            }

            $now = Get-Date
            if (($now - $lastProgress).TotalSeconds -ge 5 -or ($processed % 100) -eq 0) {
                $writeConsole = (($now - $lastConsoleLine).TotalSeconds -ge 30)
                Write-ChecksumProgress -ProcessedFiles $processed -ProcessedBytes $processedBytes -TotalBytes $stats.bytes -StartedAt $started -CurrentRelativePath $relative -ConsoleLine:$writeConsole
                $lastProgress = Get-Date
                if ($writeConsole) {
                    $lastConsoleLine = $now
                }
            }
        }

        foreach ($key in $manifest.Keys) {
            if (-not $seen.Contains($key)) {
                $missing++
                $detail = [ordered]@{
                    relativePath = $key
                    status = 'MISSING'
                    message = 'Arquivo presente no manifesto nao foi encontrado no HDD.'
                    oldSha256 = [string]$manifest[$key].sha256
                    oldSize = $manifest[$key].size
                    oldLastWriteTimeUtc = $manifest[$key].lastWriteTimeUtc
                }
                Add-Content -LiteralPath $detailsPath -Value ($detail | ConvertTo-Json -Compress -Depth 5)
            }
        }

        Write-Progress -Activity 'SHA-256 / checksum' -Completed

        if ($modified -gt 0 -or $errors -gt 0) {
            $classification = 'CRITICAL'
            $status = 'CHECKSUM_MISMATCH'
            Write-Status -Status 'ERROR' -Message ('Checksum mismatch/erro: modificados {0}, erros {1}.' -f $modified, $errors)
        } elseif ($missing -gt 0 -or $new -gt 0 -or $Script:ChecksumEnumerationErrors -gt 0) {
            $classification = 'WARNING'
            $status = 'WARNING'
            Write-Status -Status 'WARNING' -Message ('Checksum com diferencas: novos {0}, ausentes {1}, erros de enumeracao {2}.' -f $new, $missing, $Script:ChecksumEnumerationErrors)
        } else {
            $classification = 'OK'
            $status = 'OK'
            Write-Status -Status 'OK' -Message 'Todos os arquivos conferem com o manifesto.'
        }
    }

    return [pscustomobject]@{
        status = $status
        classification = $classification
        manifestPath = $manifestPath
        detailsPath = if (Test-Path -LiteralPath $detailsPath) { $detailsPath } else { $null }
        totalFiles = $stats.count
        totalBytes = $stats.bytes
        processedFiles = $processed
        processedBytes = $processedBytes
        ok = $ok
        modified = $modified
        missing = $missing
        new = $new
        errors = $errors
        enumerationErrors = $Script:ChecksumEnumerationErrors
        startedAt = $started
        finishedAt = Get-Date
    }
}

function Get-OverallResult {
    param([object]$Report)

    if ($Report.incomplete) {
        return 'INCOMPLETE'
    }

    $classifications = @()
    if ($Report.smart) { $classifications += [string]$Report.smart.classification }
    if ($Report.longTest) { $classifications += [string]$Report.longTest.classification }
    if ($Report.filesystem) { $classifications += [string]$Report.filesystem.classification }
    if ($Report.checksum) { $classifications += [string]$Report.checksum.classification }

    if ($classifications -contains 'INCOMPLETE') {
        return 'INCOMPLETE'
    }
    if ($classifications -contains 'CRITICAL') {
        return 'CRITICAL'
    }
    if ($classifications -contains 'WARNING' -or $classifications -contains 'UNKNOWN') {
        return 'WARNING'
    }

    return 'OK'
}

function Get-ExitCodeForReport {
    param([object]$Report)

    if ($Report.overall -eq 'INCOMPLETE') {
        return $ExitCodes.Warning
    }

    if ($Report.smart -and $Report.smart.classification -eq 'CRITICAL') {
        return $ExitCodes.SmartCritical
    }

    if ($Report.checksum -and ($Report.checksum.modified -gt 0 -or $Report.checksum.errors -gt 0)) {
        return $ExitCodes.ChecksumMismatch
    }

    if ($Report.filesystem -and $Report.filesystem.classification -eq 'WARNING') {
        return $ExitCodes.FilesystemWarning
    }

    if ($Report.overall -eq 'WARNING') {
        return $ExitCodes.Warning
    }

    return $ExitCodes.OK
}

function New-InitialReport {
    param(
        [object]$Context,
        [string]$ManifestRoot,
        [string]$ReportRoot
    )

    return [ordered]@{
        schemaVersion = 1
        startedAt = (Get-Date).ToString('o')
        finishedAt = $null
        hostname = $env:COMPUTERNAME
        drive = [ordered]@{
            letter = $Context.DriveLetter
            label = [string]$Context.Volume.FileSystemLabel
            fileSystem = [string]$Context.Volume.FileSystem
            size = $Context.Volume.Size
            sizeText = Format-Bytes $Context.Volume.Size
        }
        disk = [ordered]@{
            number = $Context.DiskNumber
            model = $Context.Model
            serial = $Context.Serial
            normalizedSerial = $Context.NormalizedSerial
            uniqueId = $Context.UniqueId
            busType = [string]$Context.Disk.BusType
            size = $Context.Disk.Size
            sizeText = Format-Bytes $Context.Disk.Size
            isOffline = [bool]$Context.Disk.IsOffline
        }
        paths = [ordered]@{
            manifestRoot = Get-ProjectRelativePath -Path $ManifestRoot
            reportRoot = Get-ProjectRelativePath -Path $ReportRoot
            logPath = Get-ProjectRelativePath -Path $Script:LogPath
        }
        smart = $null
        longTest = $null
        filesystem = $null
        checksum = $null
        overall = 'INCOMPLETE'
        incomplete = $false
        notes = @()
    }
}

function Write-Reports {
    param(
        [object]$Report,
        [string]$ReportRoot
    )

    $Report.finishedAt = (Get-Date).ToString('o')
    $Report.overall = Get-OverallResult -Report $Report

    New-ProjectDirectory -Path $ReportRoot
    $jsonPath = Join-Path $ReportRoot ("{0}.json" -f $Script:RunStamp)
    $txtPath = Join-Path $ReportRoot ("{0}.txt" -f $Script:RunStamp)
    $jsonRelativePath = Get-ProjectRelativePath -Path $jsonPath
    $txtRelativePath = Get-ProjectRelativePath -Path $txtPath
    $logRelativePath = Get-ProjectRelativePath -Path $Script:LogPath

    $Report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $smartStatus = if ($Report.smart) { $Report.smart.classification } else { 'SKIPPED' }
    $longStatus = if ($Report.longTest) { $Report.longTest.status } else { 'SKIPPED' }
    $fsStatus = if ($Report.filesystem) { $Report.filesystem.status } else { 'SKIPPED' }
    $checksumStatus = if ($Report.checksum) { $Report.checksum.status } else { 'SKIPPED' }
    $checksumVerified = if ($Report.checksum) { $Report.checksum.processedFiles } else { 0 }
    $checksumOk = if ($Report.checksum) { $Report.checksum.ok } else { 0 }
    $checksumMismatch = if ($Report.checksum) { $Report.checksum.modified } else { 0 }
    $checksumMissing = if ($Report.checksum) { $Report.checksum.missing } else { 0 }
    $checksumNew = if ($Report.checksum) { $Report.checksum.new } else { 0 }
    $checksumErrors = if ($Report.checksum) { $Report.checksum.errors } else { 0 }

    $txt = @"
============================================================
HDD BACKUP INTEGRITY CHECK
============================================================

Unidade:       $($Report.drive.letter)
Label:         $($Report.drive.label)
Modelo:        $($Report.disk.model)
Serial:        $($Report.disk.serial)
Disco:         $($Report.disk.number)
Capacidade:    $($Report.disk.sizeText)

SMART:         $smartStatus
Long Test:     $longStatus
Filesystem:    $fsStatus
Checksum:      $checksumStatus

Checksum:
  Verificados: $checksumVerified
  OK:          $checksumOk
  Mismatch:    $checksumMismatch
  Missing:     $checksumMissing
  Novos:       $checksumNew
  Erros:       $checksumErrors

Resultado geral: $($Report.overall)

Inicio:        $($Report.startedAt)
Fim:           $($Report.finishedAt)

Relatorio JSON: $jsonRelativePath
Log:            $logRelativePath
============================================================
"@

    Set-Content -LiteralPath $txtPath -Value $txt -Encoding UTF8
    Write-Status -Status 'OK' -Message ('Relatorio TXT: {0}' -f $txtRelativePath)
    Write-Status -Status 'OK' -Message ('Relatorio JSON: {0}' -f $jsonRelativePath)

    return [pscustomobject]@{
        JsonPath = $jsonPath
        TxtPath = $txtPath
        ReportRoot = $ReportRoot
        JsonRelativePath = $jsonRelativePath
        TxtRelativePath = $txtRelativePath
        ReportRootRelativePath = Get-ProjectRelativePath -Path $ReportRoot
    }
}

function Append-ScrubHistory {
    param(
        [object]$Report,
        [string]$ManifestRoot,
        [string]$JsonPath,
        [string]$TxtPath
    )

    if ($null -eq $Report.checksum -or $null -eq $Report.checksum.processedFiles) {
        return
    }

    New-ProjectDirectory -Path $ManifestRoot
    $historyPath = Join-Path $ManifestRoot 'scrub-history.jsonl'
    $entry = [ordered]@{
        runStamp = $Script:RunStamp
        finishedAt = $Report.finishedAt
        mode = $Report.mode
        overall = $Report.overall
        driveSerial = $Report.disk.serial
        driveModel = $Report.disk.model
        volumeLabel = $Report.drive.label
        scrubAction = 'full-file-read-with-sha256'
        totalFiles = $Report.checksum.totalFiles
        processedFiles = $Report.checksum.processedFiles
        processedBytes = $Report.checksum.processedBytes
        checksumStatus = $Report.checksum.status
        checksumOk = $Report.checksum.ok
        checksumModified = $Report.checksum.modified
        checksumMissing = $Report.checksum.missing
        checksumNew = $Report.checksum.new
        checksumErrors = $Report.checksum.errors
        reportJson = Get-ProjectRelativePath -Path $JsonPath
        reportTxt = Get-ProjectRelativePath -Path $TxtPath
    }

    Add-Content -LiteralPath $historyPath -Value ($entry | ConvertTo-Json -Compress -Depth 8)
    Write-Status -Status 'OK' -Message ('Historico de scrub: {0}' -f (Get-ProjectRelativePath -Path $historyPath))
}

function Show-ReportSummary {
    param([object]$Report)

    Write-Section -Title 'RESULTADO'
    $smartSummary = if ($Report.smart) { $Report.smart.classification } else { 'SKIPPED' }
    $longSummary = if ($Report.longTest) { $Report.longTest.status } else { 'SKIPPED' }
    $filesystemSummary = if ($Report.filesystem) { $Report.filesystem.status } else { 'SKIPPED' }
    $checksumSummary = if ($Report.checksum) { $Report.checksum.status } else { 'SKIPPED' }
    $status = switch ($Report.overall) {
        'OK' { 'OK' }
        'WARNING' { 'WARNING' }
        'CRITICAL' { 'ERROR' }
        default { 'WARNING' }
    }
    Write-Status -Status $status -Message ('Resultado geral: {0}' -f $Report.overall)
    Write-Host ('SMART      : {0}' -f $smartSummary)
    Write-Host ('Long Test  : {0}' -f $longSummary)
    Write-Host ('Filesystem : {0}' -f $filesystemSummary)
    Write-Host ('Checksum   : {0}' -f $checksumSummary)
}

function Open-PathSafely {
    param(
        [string]$Path,
        [switch]$WithNotepad
    )

    try {
        if ($WithNotepad) {
            Start-Process -FilePath 'notepad.exe' -ArgumentList @($Path) | Out-Null
        } else {
            Start-Process -FilePath 'explorer.exe' -ArgumentList @($Path) | Out-Null
        }
        return $true
    } catch {
        Write-Status -Status 'WARNING' -Message ('Nao foi possivel abrir {0}: {1}' -f $Path, $_.Exception.Message)
        return $false
    }
}

function Offer-OpenGeneratedArtifacts {
    param(
        [object]$Paths,
        [string]$LogPath
    )

    Write-Section -Title 'ARQUIVOS GERADOS'
    Write-Host ('Relatorio TXT : {0}' -f $Paths.TxtPath)
    Write-Host ('Relatorio JSON: {0}' -f $Paths.JsonPath)
    Write-Host ('Pasta         : {0}' -f $Paths.ReportRoot)
    Write-Host ('Log           : {0}' -f $LogPath)
    Write-Host ''
    Write-Host '[1] Abrir relatorio TXT no Notepad'
    Write-Host '[2] Abrir pasta do relatorio no Explorer'
    Write-Host '[3] Abrir pasta de logs no Explorer'
    Write-Host '[4] Nao abrir nada'
    Write-Host ''

    while ($true) {
        $selection = Read-Host 'Escolha [1-4, Enter para nao abrir]'
        if ([string]::IsNullOrWhiteSpace($selection)) {
            Write-Status -Status 'INFO' -Message 'Nenhum arquivo foi aberto.'
            return
        }

        switch ($selection.Trim()) {
            '1' {
                Open-PathSafely -Path $Paths.TxtPath -WithNotepad | Out-Null
                return
            }
            '2' {
                Open-PathSafely -Path $Paths.ReportRoot | Out-Null
                return
            }
            '3' {
                Open-PathSafely -Path $Script:LogsRoot | Out-Null
                return
            }
            '4' {
                Write-Status -Status 'INFO' -Message 'Nenhum arquivo foi aberto.'
                return
            }
            default {
                Write-Host 'Selecao invalida. Informe um numero de 1 a 4.' -ForegroundColor Yellow
            }
        }
    }
}

function Invoke-OfflinePreparation {
    param([object]$InitialContext)

    Write-Section -Title 'PREPARAR DESLIGAMENTO FISICO'
    if (-not (Read-YesNo -Prompt 'Deseja preparar o HDD para desligamento fisico agora? [S/N]')) {
        Write-Status -Status 'INFO' -Message 'O HDD permanecera ONLINE. Nenhuma alteracao foi feita no estado do disco.'
        return $true
    }

    Write-Host ''
    Write-Host 'Voce esta prestes a colocar OFFLINE:'
    Write-Host ''
    Write-Host ('Unidade : {0}' -f $InitialContext.DriveLetter)
    Write-Host ('Disco   : {0}' -f $InitialContext.DiskNumber)
    Write-Host ('Modelo  : {0}' -f $InitialContext.Model)
    Write-Host ('Serial  : {0}' -f $InitialContext.Serial)
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Confirma? [S/N]')) {
        Write-Status -Status 'INFO' -Message 'Operacao offline cancelada. O HDD permanece ONLINE.'
        return $true
    }

    Write-Status -Status 'INFO' -Message 'Revalidando DriveLetter -> Partition -> Disk -> Serial antes do offline.'
    $current = Assert-DriveStillSame -InitialContext $InitialContext
    Write-Log -Level 'INFO' -Message ('Serial revalidado antes do offline: {0}' -f $current.Serial)

    try {
        Write-Status -Status 'INFO' -Message ('Colocando disco fisico {0} offline.' -f $current.DiskNumber)
        Set-Disk -Number $current.DiskNumber -IsOffline $true -ErrorAction Stop
        Start-Sleep -Seconds 2
        $updated = Get-Disk -Number $current.DiskNumber -ErrorAction Stop
        if (-not $updated.IsOffline) {
            throw 'Windows nao confirmou IsOffline=True.'
        }

        Write-Section -Title 'DISCO OFFLINE COM SUCESSO'
        Write-Host ('HDD: {0}' -f $current.Model)
        Write-Host ('Serial: {0}' -f $current.Serial)
        Write-Host ''
        Write-Host 'O Windows nao esta mais usando este disco.'
        Write-Host ''
        Write-Host '>>> AGORA VOCE PODE DESLIGAR O HDD NO CONTROLADOR FISICO. <<<' -ForegroundColor Green
        Write-Host '============================================================'
        Write-Log -Level 'INFO' -Message ('Disco {0} confirmado offline.' -f $current.DiskNumber)
        return $true
    } catch {
        Write-Status -Status 'ERROR' -Message ('Falha ao colocar disco offline: {0}' -f $_.Exception.Message)
        Write-Host 'Nao desligue o HDD fisicamente ate confirmar manualmente que o Windows nao esta usando o disco.' -ForegroundColor Red
        return $false
    }
}

function Invoke-Main {
    Initialize-ProjectDirectories
    Show-Banner
    Write-Log -Level 'INFO' -Message 'Run started.'

    Assert-NotConflictingMode
    $effectiveMode = Select-RunMode
    Write-Status -Status 'INFO' -Message ('Modo selecionado: {0}' -f (Get-RunModeDescription -EffectiveMode $effectiveMode))

    if ($effectiveMode -eq 'Exit') {
        Write-Status -Status 'INFO' -Message 'Nenhuma verificacao foi executada.'
        exit $ExitCodes.OK
    }

    if (-not (Test-IsAdministrator)) {
        Write-Status -Status 'ERROR' -Message 'Execute este script em um PowerShell elevado como Administrador.'
        exit $ExitCodes.DependencyMissing
    }

    try {
        Test-Dependencies -EffectiveMode $effectiveMode -SkipSmartctl
        $config = Read-Config
        if ($config.longTestPollSeconds -and $config.longTestPollSeconds -gt 0) {
            $LongTestPollSeconds = [int]$config.longTestPollSeconds
        }
        New-ProjectDirectory -Path ([string]$config.manifestRoot)
        Offer-KnownOfflineDisksOnline -ManifestRoot ([string]$config.manifestRoot)
    } catch {
        Write-Status -Status 'ERROR' -Message $_.Exception.Message
        exit $ExitCodes.DependencyMissing
    }

    try {
        $context = Select-DriveContext -PreselectedDriveLetter $DriveLetter
        Assert-DriveIsSafe -Context $context
        Show-DiskIdentity -Context $context
        Write-Log -Level 'INFO' -Message ('Selected drive {0}; disk {1}; serial {2}' -f $context.DriveLetter, $context.DiskNumber, $context.Serial)

        if (-not (Read-YesNo -Prompt 'Confirma que deseja verificar este disco? [S/N]')) {
            Write-Status -Status 'WARNING' -Message 'Operacao cancelada pelo usuario.'
            exit $ExitCodes.UserCancelled
        }
    } catch {
        Write-Status -Status 'ERROR' -Message $_.Exception.Message
        exit $ExitCodes.InvalidSelection
    }

    $serialSegment = Get-SafePathSegment -Value $context.Serial
    $manifestRoot = Join-Path ([string]$config.manifestRoot) $serialSegment
    $reportRoot = Join-Path $Script:ReportsRoot $serialSegment
    $currentReportPath = Join-Path $reportRoot ("{0}.json" -f $Script:RunStamp)
    $report = New-InitialReport -Context $context -ManifestRoot $manifestRoot -ReportRoot $reportRoot
    $report.mode = $effectiveMode
    $exitCode = $ExitCodes.OK

    try {
        Test-Dependencies -EffectiveMode $effectiveMode
        $previousReport = Get-PreviousReport -ReportRoot $reportRoot -CurrentReportPath $currentReportPath

        if ($effectiveMode -in @('Full', 'Quick', 'SmartOnly')) {
            Ensure-SmartctlAvailable
            Assert-DriveStillSame -InitialContext $context | Out-Null
            $smartDevice = Match-SmartDevice -Context $context
            $report.smart = Get-SmartReport -SmartDevice $smartDevice -PreviousReport $previousReport

            if ($effectiveMode -eq 'Quick') {
                $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'Modo Reconhecimento seguro.' -Classification 'OK'
                $report.filesystem = New-SkippedStage -Stage 'Filesystem' -Reason 'Modo Reconhecimento seguro.' -Classification 'OK'
                $report.checksum = New-SkippedStage -Stage 'Checksum' -Reason 'Modo Reconhecimento seguro.' -Classification 'OK'
                Write-Status -Status 'SKIPPED' -Message 'Modo Reconhecimento seguro: etapas pesadas nao foram executadas.'
            } else {
                if (-not (Confirm-SmartSafetyGate -SmartReport $report.smart -EffectiveMode $effectiveMode)) {
                    $report.incomplete = $true
                    $report.notes += 'Usuario interrompeu no portao de seguranca apos SMART inicial.'
                    $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'Usuario interrompeu no portao de seguranca.' -Classification 'INCOMPLETE'
                    $report.filesystem = New-SkippedStage -Stage 'Filesystem' -Reason 'Usuario interrompeu no portao de seguranca.' -Classification 'INCOMPLETE'
                    $report.checksum = New-SkippedStage -Stage 'Checksum' -Reason 'Usuario interrompeu no portao de seguranca.' -Classification 'INCOMPLETE'
                } else {
                    $shouldRunLong = $false
                    if (-not $SkipLongTest) {
                        if ($config.alwaysLongTest) {
                            $shouldRunLong = $true
                        } else {
                            $shouldRunLong = Read-YesNo -Prompt 'Executar SMART Long/Extended Self-Test? [S/N]'
                        }
                    }

                    if ($shouldRunLong) {
                        Assert-DriveStillSame -InitialContext $context | Out-Null
                        $report.longTest = Invoke-SmartLongTest -SmartDevice $smartDevice -PollSeconds $LongTestPollSeconds
                    } else {
                        $report.longTest = [pscustomobject]@{
                            status = 'SKIPPED'
                            classification = 'WARNING'
                            reason = if ($SkipLongTest) { 'Parametro -SkipLongTest informado.' } else { 'Usuario optou por nao executar.' }
                        }
                        Write-Status -Status 'SKIPPED' -Message 'SMART Long/Extended Self-Test nao executado.'
                    }

                    if ($effectiveMode -eq 'Full') {
                        Assert-DriveStillSame -InitialContext $context | Out-Null
                        $report.filesystem = Invoke-ReadOnlyFilesystemCheck -Context $context

                        Assert-DriveStillSame -InitialContext $context | Out-Null
                        $report.checksum = Invoke-ChecksumVerification -Context $context -Config $config -ManifestRoot $manifestRoot -ReportRoot $reportRoot
                    } elseif ($effectiveMode -eq 'SmartOnly') {
                        $report.filesystem = New-SkippedStage -Stage 'Filesystem' -Reason 'Modo Somente SMART.' -Classification 'OK'
                        $report.checksum = New-SkippedStage -Stage 'Checksum' -Reason 'Modo Somente SMART.' -Classification 'OK'
                        Write-Status -Status 'SKIPPED' -Message 'Modo Somente SMART: filesystem e checksum pulados.'
                    }
                }
            }
        } elseif ($effectiveMode -eq 'DataOnly') {
            if (Read-YesNo -Prompt 'Deseja executar SMART inicial antes da checagem dos dados? [S/N]') {
                Ensure-SmartctlAvailable
                Assert-DriveStillSame -InitialContext $context | Out-Null
                $smartDevice = Match-SmartDevice -Context $context
                $report.smart = Get-SmartReport -SmartDevice $smartDevice -PreviousReport $previousReport

                if (-not (Confirm-SmartSafetyGate -SmartReport $report.smart -EffectiveMode 'Full')) {
                    $report.incomplete = $true
                    $report.notes += 'Usuario interrompeu no portao de seguranca apos SMART inicial.'
                    $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'Usuario interrompeu no portao de seguranca.' -Classification 'INCOMPLETE'
                    $report.filesystem = New-SkippedStage -Stage 'Filesystem' -Reason 'Usuario interrompeu no portao de seguranca.' -Classification 'INCOMPLETE'
                    $report.checksum = New-SkippedStage -Stage 'Checksum' -Reason 'Usuario interrompeu no portao de seguranca.' -Classification 'INCOMPLETE'
                } else {
                    $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'Modo Scrub preventivo dos dados: Long Test nao executado.' -Classification 'OK'
                    Assert-DriveStillSame -InitialContext $context | Out-Null
                    $report.filesystem = Invoke-ReadOnlyFilesystemCheck -Context $context

                    Assert-DriveStillSame -InitialContext $context | Out-Null
                    $report.checksum = Invoke-ChecksumVerification -Context $context -Config $config -ManifestRoot $manifestRoot -ReportRoot $reportRoot
                }
            } else {
                $report.smart = New-SkippedStage -Stage 'SMART' -Reason 'Usuario optou por pular SMART antes da checagem dos dados.' -Classification 'OK'
                $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'SMART pulado; Long Test nao aplicavel.' -Classification 'OK'
                Write-Status -Status 'SKIPPED' -Message 'SMART pulado por escolha do usuario. Seguindo para filesystem e SHA-256.'

                Assert-DriveStillSame -InitialContext $context | Out-Null
                $report.filesystem = Invoke-ReadOnlyFilesystemCheck -Context $context

                Assert-DriveStillSame -InitialContext $context | Out-Null
                $report.checksum = Invoke-ChecksumVerification -Context $context -Config $config -ManifestRoot $manifestRoot -ReportRoot $reportRoot
            }
        } elseif ($effectiveMode -eq 'ScrubOnly') {
            $report.smart = New-SkippedStage -Stage 'SMART' -Reason 'Modo Somente scrub SHA-256.' -Classification 'OK'
            $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'Modo Somente scrub SHA-256.' -Classification 'OK'
            $report.filesystem = New-SkippedStage -Stage 'Filesystem' -Reason 'Modo Somente scrub SHA-256.' -Classification 'OK'
            $report.notes += 'Modo Somente scrub SHA-256: SMART, Long Self-Test e filesystem scan foram pulados.'
            Write-Status -Status 'SKIPPED' -Message 'Modo Somente scrub SHA-256: SMART, Long Self-Test e filesystem scan pulados.'
            Assert-DriveStillSame -InitialContext $context | Out-Null
            $report.checksum = Invoke-ChecksumVerification -Context $context -Config $config -ManifestRoot $manifestRoot -ReportRoot $reportRoot
        } elseif ($effectiveMode -eq 'FilesystemOnly') {
            $report.smart = New-SkippedStage -Stage 'SMART' -Reason 'Modo Somente filesystem scan.' -Classification 'OK'
            $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'Modo Somente filesystem scan.' -Classification 'OK'
            $report.checksum = New-SkippedStage -Stage 'Checksum' -Reason 'Modo Somente filesystem scan.' -Classification 'OK'
            $report.notes += 'Modo Somente filesystem scan: SMART, Long Self-Test e SHA-256 foram pulados.'
            Write-Status -Status 'SKIPPED' -Message 'Modo Somente filesystem scan: SMART, Long Self-Test e SHA-256 pulados.'
            Assert-DriveStillSame -InitialContext $context | Out-Null
            $report.filesystem = Invoke-ReadOnlyFilesystemCheck -Context $context
        } else {
            $report.smart = New-SkippedStage -Stage 'SMART' -Reason 'Modo Somente SHA-256.' -Classification 'OK'
            $report.longTest = New-SkippedStage -Stage 'LongTest' -Reason 'Modo Somente SHA-256.' -Classification 'OK'
            $report.filesystem = New-SkippedStage -Stage 'Filesystem' -Reason 'Modo Somente SHA-256.' -Classification 'OK'
            $report.notes += 'Modo Somente SHA-256: SMART, Long Self-Test e filesystem scan foram pulados.'
            Write-Status -Status 'SKIPPED' -Message 'Modo Somente SHA-256: SMART, Long Self-Test e filesystem scan pulados.'
            Assert-DriveStillSame -InitialContext $context | Out-Null
            $report.checksum = Invoke-ChecksumVerification -Context $context -Config $config -ManifestRoot $manifestRoot -ReportRoot $reportRoot
        }
    } catch {
        $message = $_.Exception.Message
        Write-Status -Status 'ERROR' -Message $message
        $report.incomplete = $true
        $report.notes += ('Execucao incompleta: {0}' -f $message)

        if ($message -match 'SMART|smartctl|serial|associar') {
            $exitCode = $ExitCodes.SmartMappingFailure
        } elseif ($message -match 'desapareceu|mudou') {
            $exitCode = $ExitCodes.DiskDisappeared
        } else {
            $exitCode = $ExitCodes.Warning
        }
    }

    $paths = Write-Reports -Report $report -ReportRoot $reportRoot
    Append-ScrubHistory -Report $report -ManifestRoot $manifestRoot -JsonPath $paths.JsonPath -TxtPath $paths.TxtPath
    Show-ReportSummary -Report $report
    $computedExitCode = Get-ExitCodeForReport -Report $report
    if ($exitCode -eq $ExitCodes.OK) {
        $exitCode = $computedExitCode
    }

    Offer-OpenGeneratedArtifacts -Paths $paths -LogPath $Script:LogPath

    $offlineOk = Invoke-OfflinePreparation -InitialContext $context
    if (-not $offlineOk) {
        exit $ExitCodes.OfflineFailed
    }

    Write-Log -Level 'INFO' -Message ('Run finished with exit code {0}.' -f $exitCode)
    exit $exitCode
}

Invoke-Main
