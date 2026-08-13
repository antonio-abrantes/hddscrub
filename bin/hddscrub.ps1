[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

$Script:BinRoot = $PSScriptRoot
$Script:AppRoot = Split-Path -Parent $Script:BinRoot
$Script:MainScript = Join-Path $Script:AppRoot 'hdd-integrity-check.ps1'
$Script:UninstallScript = Join-Path $Script:AppRoot 'uninstall.ps1'
$Script:HelpScript = Join-Path $Script:BinRoot 'hddscrub-help.ps1'
$Script:VersionPath = Join-Path $Script:AppRoot 'VERSION'
$Script:ToolsRoot = Join-Path $Script:AppRoot 'tools'
$Script:SmartctlPath = Join-Path $Script:ToolsRoot 'smartctl.exe'
$Script:DriveDbPath = Join-Path $Script:ToolsRoot 'drivedb.h'

function Write-CliHeader {
    Write-Host 'hddscrub - HDD Backup Scrub CLI'
}

function Get-CliVersion {
    if (Test-Path -LiteralPath $Script:VersionPath) {
        $version = (Get-Content -LiteralPath $Script:VersionPath -TotalCount 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($version)) {
            return $version
        }
    }

    return 'unknown'
}

function Show-Help {
    param([string]$Topic)

    if (Test-Path -LiteralPath $Script:HelpScript) {
        if ([string]::IsNullOrWhiteSpace($Topic)) {
            & $Script:HelpScript -Version (Get-CliVersion)
        } else {
            & $Script:HelpScript -Topic $Topic -Version (Get-CliVersion)
        }
        return
    }

    Write-CliHeader
    Write-Host ''
    Write-Host 'Usage: hddscrub <command> [options]'
    Write-Host 'Commands: data, scrub, fs, smart, full, quick, doctor, paths, current, uninstall'
    Write-Host 'Options: --drive X, --help, --version'
}

function Get-OptionValue {
    param(
        [string[]]$Items,
        [string[]]$Names
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Names -contains $Items[$i]) {
            if (($i + 1) -ge $Items.Count) {
                throw ('Opcao {0} exige valor.' -f $Items[$i])
            }
            return $Items[$i + 1]
        }

        foreach ($name in $Names) {
            $prefix = $name + '='
            if ($Items[$i].StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $Items[$i].Substring($prefix.Length)
            }
        }
    }

    return $null
}

function Test-Flag {
    param(
        [string[]]$Items,
        [string[]]$Names
    )

    foreach ($item in $Items) {
        if ($Names -contains $item) {
            return $true
        }
    }
    return $false
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SmartctlVersion {
    if (-not (Test-Path -LiteralPath $Script:SmartctlPath)) {
        return 'not bundled'
    }

    try {
        $line = & $Script:SmartctlPath --version 2>$null | Select-Object -First 1
        return [string]$line
    } catch {
        return ('error: {0}' -f $_.Exception.Message)
    }
}

function Show-Version {
    Write-Host ('hddscrub {0}' -f (Get-CliVersion))
    Write-Host ('smartctl: {0}' -f (Invoke-SmartctlVersion))
}

function Show-Paths {
    Write-CliHeader
    Write-Host ''
    Write-Host ('App root     : {0}' -f $Script:AppRoot)
    Write-Host ('Main script  : {0}' -f $Script:MainScript)
    Write-Host ('Tools        : {0}' -f $Script:ToolsRoot)
    Write-Host ('smartctl.exe : {0}' -f $Script:SmartctlPath)
    Write-Host ('drivedb.h    : {0}' -f $Script:DriveDbPath)
    Write-Host ('manifests    : {0}' -f (Join-Path $Script:AppRoot 'manifests'))
    Write-Host ('reports      : {0}' -f (Join-Path $Script:AppRoot 'reports'))
    Write-Host ('logs         : {0}' -f (Join-Path $Script:AppRoot 'logs'))
}

function Show-Current {
    Write-CliHeader
    Write-Host ''
    Write-Host ('Version      : {0}' -f (Get-CliVersion))
    Write-Host ('PowerShell   : {0}' -f $PSVersionTable.PSVersion)
    Write-Host ('Elevated     : {0}' -f (Test-IsAdministrator))
    Write-Host ('smartctl     : {0}' -f (Invoke-SmartctlVersion))
    Write-Host ('App root     : {0}' -f $Script:AppRoot)
}

function Invoke-Doctor {
    Write-CliHeader
    Write-Host ''

    $checks = @(
        [pscustomobject]@{ Name = 'Windows'; Ok = $IsWindows -or $env:OS -eq 'Windows_NT'; Detail = $env:OS },
        [pscustomobject]@{ Name = 'PowerShell'; Ok = $PSVersionTable.PSVersion.Major -ge 5; Detail = [string]$PSVersionTable.PSVersion },
        [pscustomobject]@{ Name = 'Sessao elevada'; Ok = Test-IsAdministrator; Detail = 'necessaria para SMART/offline/filesystem' },
        [pscustomobject]@{ Name = 'Script principal'; Ok = Test-Path -LiteralPath $Script:MainScript; Detail = $Script:MainScript },
        [pscustomobject]@{ Name = 'smartctl.exe'; Ok = Test-Path -LiteralPath $Script:SmartctlPath; Detail = Invoke-SmartctlVersion },
        [pscustomobject]@{ Name = 'drivedb.h'; Ok = Test-Path -LiteralPath $Script:DriveDbPath; Detail = $Script:DriveDbPath },
        [pscustomobject]@{ Name = 'manifests'; Ok = Test-Path -LiteralPath (Join-Path $Script:AppRoot 'manifests'); Detail = Join-Path $Script:AppRoot 'manifests' },
        [pscustomobject]@{ Name = 'reports'; Ok = Test-Path -LiteralPath (Join-Path $Script:AppRoot 'reports'); Detail = Join-Path $Script:AppRoot 'reports' },
        [pscustomobject]@{ Name = 'logs'; Ok = Test-Path -LiteralPath (Join-Path $Script:AppRoot 'logs'); Detail = Join-Path $Script:AppRoot 'logs' }
    )

    foreach ($check in $checks) {
        if ($check.Ok) {
            Write-Host ('[OK]      {0}: {1}' -f $check.Name, $check.Detail) -ForegroundColor Green
        } else {
            Write-Host ('[WARNING] {0}: {1}' -f $check.Name, $check.Detail) -ForegroundColor Yellow
        }
    }
}

function Convert-ToMainScriptArgs {
    param([string[]]$Items)

    if ($Items.Count -eq 0) {
        return @()
    }

    $command = $Items[0].ToLowerInvariant()
    $rest = if ($Items.Count -gt 1) { @($Items[1..($Items.Count - 1)]) } else { @() }

    $mode = switch ($command) {
        'scrub' { 'ScrubOnly' }
        'data' { 'DataOnly' }
        'fs' { 'FilesystemOnly' }
        'filesystem' { 'FilesystemOnly' }
        'smart' { 'SmartOnly' }
        'full' { 'Full' }
        'quick' { 'Quick' }
        default { $null }
    }

    if (-not $mode) {
        return $Items
    }

    $mapped = @('-Mode', $mode)
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $item = $rest[$i]

        if ($item -in @('--drive', '-d', '/drive')) {
            if (($i + 1) -ge $rest.Count) {
                throw ('Opcao {0} exige valor.' -f $item)
            }
            $mapped += @('-DriveLetter', $rest[$i + 1])
            $i++
            continue
        }

        if ($item.StartsWith('--drive=', [StringComparison]::OrdinalIgnoreCase)) {
            $mapped += @('-DriveLetter', $item.Substring('--drive='.Length))
            continue
        }

        if ($item.StartsWith('/drive=', [StringComparison]::OrdinalIgnoreCase)) {
            $mapped += @('-DriveLetter', $item.Substring('/drive='.Length))
            continue
        }

        if ($item -eq '--allow-pd-smart') {
            $mapped += '-AllowPhysicalDiskSmartFallback'
            continue
        }

        if ($item -eq '--skip-long-test') {
            $mapped += '-SkipLongTest'
            continue
        }

        $mapped += $item
    }

    return $mapped
}

if (-not $Arguments -or $Arguments.Count -eq 0) {
    & $Script:MainScript
    exit $LASTEXITCODE
}

$first = $Arguments[0].ToLowerInvariant()
switch ($first) {
    '--help' { Show-Help; exit 0 }
    '-h' { Show-Help; exit 0 }
    '-?' { Show-Help; exit 0 }
    'help' {
        $topic = if ($Arguments.Count -gt 1) { $Arguments[1] } else { $null }
        Show-Help -Topic $topic
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        exit 0
    }
    '--version' { Show-Version; exit 0 }
    '-v' { Show-Version; exit 0 }
    'version' { Show-Version; exit 0 }
    'doctor' { Invoke-Doctor; exit 0 }
    'paths' { Show-Paths; exit 0 }
    'current' { Show-Current; exit 0 }
    'uninstall' {
        if (-not (Test-Path -LiteralPath $Script:UninstallScript)) {
            Write-Error ('uninstall.ps1 nao encontrado em {0}' -f $Script:UninstallScript)
            exit 1
        }
        $uninstallArgs = @()
        if (Test-Flag -Items $Arguments -Names @('--remove-data')) { $uninstallArgs += '-RemoveData' }
        if (Test-Flag -Items $Arguments -Names @('--keep-data')) { $uninstallArgs += '-KeepData' }
        & $Script:UninstallScript @uninstallArgs
        exit $LASTEXITCODE
    }
}

if (-not (Test-Path -LiteralPath $Script:MainScript)) {
    Write-Error ('Script principal nao encontrado: {0}' -f $Script:MainScript)
    exit 1
}

$mainArgs = Convert-ToMainScriptArgs -Items $Arguments
& $Script:MainScript @mainArgs
exit $LASTEXITCODE
