[CmdletBinding()]
param(
    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [string]$InstallDir,
    [switch]$NoPath,
    [switch]$Force,
    [switch]$PreserveData,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$AppName = 'HddScrub'

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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-PathEntry {
    param(
        [string]$PathToAdd,
        [ValidateSet('User', 'Machine')]
        [string]$Target
    )

    $environmentTarget = if ($Target -eq 'Machine') {
        [EnvironmentVariableTarget]::Machine
    } else {
        [EnvironmentVariableTarget]::User
    }

    $currentPath = [Environment]::GetEnvironmentVariable('Path', $environmentTarget)
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $entries = @($currentPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $alreadyPresent = $false
    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -ieq $PathToAdd.TrimEnd('\')) {
            $alreadyPresent = $true
            break
        }
    }

    if ($alreadyPresent) {
        Write-Ok ('PATH ja contem {0}' -f $PathToAdd)
        return
    }

    $newPath = if ([string]::IsNullOrWhiteSpace($currentPath)) {
        $PathToAdd
    } else {
        $currentPath.TrimEnd(';') + ';' + $PathToAdd
    }

    [Environment]::SetEnvironmentVariable('Path', $newPath, $environmentTarget)
    $env:Path = $env:Path.TrimEnd(';') + ';' + $PathToAdd
    Write-Ok ('PATH atualizado no escopo {0}' -f $Target)
}

function Copy-IfExists {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Source) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    }
}

function Read-ExistingInstallChoice {
    while ($true) {
        Write-Host ''
        Write-Host 'Uma instalacao existente foi encontrada.'
        Write-Host '[R] Reinstalar/atualizar mantendo manifests, reports e logs'
        Write-Host '[L] Instalacao limpa, apagando app e dados locais'
        Write-Host '[C] Cancelar instalacao'
        $answer = Read-Host 'Escolha [R/L/C]'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Warn 'Opcao invalida. Informe R, L ou C.'
            continue
        }

        switch -Regex ($answer.Trim()) {
            '^[rR]$' { return 'PreserveData' }
            '^[lL]$' { return 'Clean' }
            '^[cC]$' { return 'Cancel' }
            default { Write-Warn 'Opcao invalida. Informe R, L ou C.' }
        }
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Este instalador e exclusivo para Windows.'
}

if ($Scope -eq 'Machine' -and -not (Test-IsAdministrator)) {
    throw 'Instalacao Machine exige PowerShell como Administrador.'
}

if ($Clean -and $PreserveData) {
    throw 'Use apenas -Clean ou -PreserveData.'
}

if (-not $InstallDir) {
    if ($Scope -eq 'Machine') {
        $InstallDir = Join-Path $env:ProgramData $AppName
    } else {
        $InstallDir = Join-Path $env:LOCALAPPDATA $AppName
    }
}

$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$BinDir = Join-Path $InstallDir 'bin'
$DataDirs = @(
    (Join-Path $InstallDir 'manifests'),
    (Join-Path $InstallDir 'reports'),
    (Join-Path $InstallDir 'logs')
)

Write-Host ''
Write-Host '============================================================'
Write-Host 'HddScrub Installer'
Write-Host '============================================================'
Write-Host ('Scope      : {0}' -f $Scope)
Write-Host ('InstallDir : {0}' -f $InstallDir)
Write-Host ''

$installExists = Test-Path -LiteralPath $InstallDir
$installMode = 'New'

if ($installExists) {
    Write-Warn 'Diretorio de instalacao ja existe.'
    if ($Clean) {
        $installMode = 'Clean'
    } elseif ($PreserveData -or $Force) {
        $installMode = 'PreserveData'
    } else {
        $installMode = Read-ExistingInstallChoice
    }

    if ($installMode -eq 'Cancel') {
        Write-Warn 'Instalacao cancelada. Nada foi alterado.'
        exit 30
    }

    if ($installMode -eq 'Clean') {
        Write-Warn 'Voce escolheu instalacao limpa.'
        Write-Warn 'Isto apagara tambem manifests, reports e logs existentes.'
        Write-Host ('Diretorio alvo: {0}' -f $InstallDir)
        $answer = Read-Host 'Confirma apagar a instalacao existente e todos os dados locais? [S/N]'
        if ($answer -notmatch '^[sSyY]$') {
            Write-Warn 'Instalacao limpa cancelada. Nada foi alterado.'
            exit 30
        }

        Write-Step 'Removendo instalacao existente.'
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        $installExists = $false
    } else {
        Write-Ok 'Reinstalacao selecionada: dados existentes serao preservados.'
    }
}

Write-Step 'Criando diretorios.'
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
foreach ($dir in $DataDirs) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

Write-Step 'Copiando arquivos do app.'
$files = @(
    'hdd-integrity-check.ps1',
    'README.md',
    'AGENTS.md',
    'VERSION',
    '.gitignore',
    'NOTICE.md',
    'LICENSE',
    'install-local.ps1',
    'install.ps1',
    'uninstall.ps1'
)

foreach ($file in $files) {
    Copy-IfExists -Source (Join-Path $ProjectRoot $file) -Destination (Join-Path $InstallDir $file)
}

foreach ($dirName in @('bin', 'docs', 'tools', 'assets')) {
    $sourceDir = Join-Path $ProjectRoot $dirName
    if (Test-Path -LiteralPath $sourceDir) {
        Copy-Item -LiteralPath $sourceDir -Destination $InstallDir -Recurse -Force
    }
}

foreach ($dirName in @('manifests', 'reports', 'logs')) {
    $keep = Join-Path (Join-Path $ProjectRoot $dirName) '.gitkeep'
    if (Test-Path -LiteralPath $keep) {
        Copy-Item -LiteralPath $keep -Destination (Join-Path (Join-Path $InstallDir $dirName) '.gitkeep') -Force
    }
}

Write-Step 'Validando smartctl bundled.'
$smartctl = Join-Path $InstallDir 'tools\smartctl.exe'
if (Test-Path -LiteralPath $smartctl) {
    $smartVersion = & $smartctl --version 2>$null | Select-Object -First 1
    Write-Ok ([string]$smartVersion)
} else {
    Write-Warn 'tools\smartctl.exe nao encontrado. SMART exigira instalacao externa.'
}

if (-not $NoPath) {
    Write-Step 'Configurando PATH.'
    Add-PathEntry -PathToAdd $BinDir -Target $Scope
} else {
    Write-Warn 'PATH nao foi alterado por causa de -NoPath.'
}

Write-Step 'Validando wrapper.'
$wrapper = Join-Path $BinDir 'hddscrub.cmd'
if (-not (Test-Path -LiteralPath $wrapper)) {
    throw ('Wrapper nao encontrado: {0}' -f $wrapper)
}

& $wrapper --version

Write-Host ''
Write-Host '============================================================'
Write-Host 'INSTALACAO CONCLUIDA'
Write-Host '============================================================'
Write-Host ('Instalado em : {0}' -f $InstallDir)
Write-Host ('Dados em     : {0}' -f $InstallDir)
Write-Host ('Modo         : {0}' -f $installMode)
Write-Host ('Comando      : hddscrub')
Write-Host ''
Write-Host 'Abra um novo terminal e execute:'
Write-Host ''
Write-Host '  hddscrub'
Write-Host ''
Write-Host 'Para diagnostico:'
Write-Host ''
Write-Host '  hddscrub doctor'
Write-Host '============================================================'
