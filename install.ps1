[CmdletBinding()]
param(
    [string]$Repository = 'antonio-abrantes/hddscrub',
    [string]$Branch = 'main',
    [string]$ArchiveUrl,

    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [string]$InstallDir,
    [switch]$NoPath,
    [switch]$Force,
    [switch]$PreserveData,
    [switch]$Clean,
    [switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'
$Script:InstallScope = $Scope
$Script:InstallerExitCode = 1

function Write-Step {
    param([string]$Message)
    Write-Host ('[INFO] {0}' -f $Message) -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host ('[OK]   {0}' -f $Message) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host ('[WARN] {0}' -f $Message) -ForegroundColor Yellow
}

function Invoke-LocalInstaller {
    param([string]$InstallerPath)

    if ($InstallDir) {
        & $InstallerPath -Scope $Script:InstallScope -InstallDir $InstallDir -NoPath:$NoPath.IsPresent -Force:$Force.IsPresent -PreserveData:$PreserveData.IsPresent -Clean:$Clean.IsPresent
    } else {
        & $InstallerPath -Scope $Script:InstallScope -NoPath:$NoPath.IsPresent -Force:$Force.IsPresent -PreserveData:$PreserveData.IsPresent -Clean:$Clean.IsPresent
    }

    if ($null -ne $LASTEXITCODE) {
        $Script:InstallerExitCode = $LASTEXITCODE
    } elseif ($?) {
        $Script:InstallerExitCode = 0
    } else {
        $Script:InstallerExitCode = 1
    }
}

function Complete-Install {
    param([int]$Code)

    if ($Code -ne 0) {
        throw ('Instalador finalizou com codigo {0}.' -f $Code)
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Este instalador e exclusivo para Windows.'
}

$localInstaller = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'install-local.ps1' } else { $null }
$localMainScript = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'hdd-integrity-check.ps1' } else { $null }

if ($localInstaller -and $localMainScript -and
    (Test-Path -LiteralPath $localInstaller) -and
    (Test-Path -LiteralPath $localMainScript)) {
    Write-Step 'Instalacao local detectada.'
    Invoke-LocalInstaller -InstallerPath $localInstaller
    Complete-Install -Code $Script:InstallerExitCode
    return
}

if (-not $ArchiveUrl) {
    $ArchiveUrl = 'https://github.com/{0}/archive/refs/heads/{1}.zip' -f $Repository, $Branch
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hddscrub-install-{0}' -f ([guid]::NewGuid().ToString('N')))
$zipPath = Join-Path $tempRoot 'source.zip'
$extractRoot = Join-Path $tempRoot 'source'

Write-Host ''
Write-Host '============================================================'
Write-Host 'HddScrub Remote Installer'
Write-Host '============================================================'
Write-Host ('Repository : {0}' -f $Repository)
Write-Host ('Branch     : {0}' -f $Branch)
Write-Host ('Archive    : {0}' -f $ArchiveUrl)
Write-Host ''

try {
    Write-Step 'Baixando pacote do repositorio.'
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $webParams = @{
        Uri = $ArchiveUrl
        OutFile = $zipPath
        UseBasicParsing = $true
    }
    Invoke-WebRequest @webParams

    Write-Step 'Extraindo pacote.'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

    $installer = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter 'install-local.ps1' |
        Select-Object -First 1

    if (-not $installer) {
        throw 'install-local.ps1 nao foi encontrado no pacote baixado.'
    }

    $mainScript = Join-Path $installer.Directory.FullName 'hdd-integrity-check.ps1'
    if (-not (Test-Path -LiteralPath $mainScript)) {
        throw ('Pacote invalido: hdd-integrity-check.ps1 nao encontrado em {0}' -f $installer.Directory.FullName)
    }

    Write-Ok ('Pacote preparado em {0}' -f $installer.Directory.FullName)
    Invoke-LocalInstaller -InstallerPath $installer.FullName
} finally {
    if ($KeepDownload) {
        Write-Warn ('Download temporario preservado em {0}' -f $tempRoot)
    } elseif (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Complete-Install -Code $Script:InstallerExitCode
return
