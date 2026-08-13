[CmdletBinding()]
param(
    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [string]$InstallDir,
    [switch]$KeepData,
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
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

function Remove-PathEntry {
    param(
        [string]$PathToRemove,
        [ValidateSet('User', 'Machine')]
        [string]$Target
    )

    $environmentTarget = if ($Target -eq 'Machine') {
        [EnvironmentVariableTarget]::Machine
    } else {
        [EnvironmentVariableTarget]::User
    }

    $currentPath = [Environment]::GetEnvironmentVariable('Path', $environmentTarget)
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        return
    }

    $entries = @($currentPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\') -ine $PathToRemove.TrimEnd('\')
    })

    try {
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), $environmentTarget)
        Write-Ok ('PATH atualizado no escopo {0}' -f $Target)
    } catch {
        Write-Warn ('Nao foi possivel atualizar o PATH no escopo {0}: {1}' -f $Target, $_.Exception.Message)
        Write-Warn ('Se necessario, remova manualmente este caminho do PATH: {0}' -f $PathToRemove)
    }
}

function Read-UninstallDataChoice {
    while ($true) {
        Write-Host ''
        Write-Host 'Dados locais encontrados/preservaveis: manifests, reports e logs.'
        Write-Host '[M] Manter dados e remover somente o app'
        Write-Host '[A] Apagar app e dados locais'
        Write-Host '[C] Cancelar desinstalacao'
        $answer = Read-Host 'Escolha [M/A/C]'
        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Warn 'Opcao invalida. Informe M, A ou C.'
            continue
        }

        switch -Regex ($answer.Trim()) {
            '^[mM]$' { return 'KeepData' }
            '^[aA]$' { return 'RemoveData' }
            '^[cC]$' { return 'Cancel' }
            default { Write-Warn 'Opcao invalida. Informe M, A ou C.' }
        }
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Este desinstalador e exclusivo para Windows.'
}

if ($Scope -eq 'Machine' -and -not (Test-IsAdministrator)) {
    throw 'Desinstalacao Machine exige PowerShell como Administrador.'
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

if ($KeepData -and $RemoveData) {
    throw 'Use apenas -KeepData ou -RemoveData.'
}

Write-Host ''
Write-Host '============================================================'
Write-Host 'HddScrub Uninstaller'
Write-Host '============================================================'
Write-Host ('Scope      : {0}' -f $Scope)
Write-Host ('InstallDir : {0}' -f $InstallDir)
Write-Host ''

if (-not (Test-Path -LiteralPath $InstallDir)) {
    Write-Warn 'Diretorio de instalacao nao encontrado.'
    exit 0
}

$dataDirs = @('manifests', 'reports', 'logs')
$answer = Read-Host 'Deseja desinstalar o HddScrub agora? [S/N]'
if ($answer -notmatch '^[sSyY]$') {
    Write-Warn 'Desinstalacao cancelada. Nada foi removido.'
    exit 30
}

if ($RemoveData) {
    Write-Warn 'Voce solicitou remover tambem manifests, reports e logs.'
    Write-Host ('Diretorio alvo: {0}' -f $InstallDir)
    $answer = Read-Host 'Confirma remover app e dados locais do HddScrub? [S/N]'
    if ($answer -notmatch '^[sSyY]$') {
        Write-Warn 'Remocao de dados cancelada. Nada foi removido.'
        exit 30
    }

    Write-Step 'Removendo PATH.'
    Remove-PathEntry -PathToRemove $BinDir -Target $Scope

    Write-Step 'Removendo app e dados.'
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Ok 'App e dados removidos.'
    exit 0
}

if (-not $KeepData) {
    $choice = Read-UninstallDataChoice
    if ($choice -eq 'Cancel') {
        Write-Warn 'Desinstalacao cancelada. Nada foi removido.'
        exit 30
    }

    if ($choice -eq 'RemoveData') {
        Write-Warn 'Voce escolheu apagar manifests, reports e logs.'
        Write-Host ('Diretorio alvo: {0}' -f $InstallDir)
        $confirmDataRemoval = Read-Host 'Confirma apagar app e dados locais do HddScrub? [S/N]'
        if ($confirmDataRemoval -notmatch '^[sSyY]$') {
            Write-Warn 'Remocao de dados cancelada. Nada foi removido.'
            exit 30
        }

        Write-Step 'Removendo PATH.'
        Remove-PathEntry -PathToRemove $BinDir -Target $Scope

        Write-Step 'Removendo app e dados.'
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Ok 'App e dados removidos.'
        exit 0
    }
}

Write-Step 'Removendo PATH.'
Remove-PathEntry -PathToRemove $BinDir -Target $Scope

Write-Step 'Removendo arquivos do app e preservando dados.'

$itemsToRemove = @(
    'hdd-integrity-check.ps1',
    'README.md',
    'AGENTS.md',
    'VERSION',
    '.gitignore',
    'NOTICE.md',
    'LICENSE',
    'install-local.ps1',
    'install.ps1',
    'uninstall.ps1',
    'bin',
    'docs',
    'tools',
    'assets'
)

foreach ($item in $itemsToRemove) {
    $path = Join-Path $InstallDir $item
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

foreach ($dirName in $dataDirs) {
    $path = Join-Path $InstallDir $dirName
    if (Test-Path -LiteralPath $path) {
        Write-Ok ('Dados preservados: {0}' -f $path)
    }
}

Write-Host ''
Write-Host '============================================================'
Write-Host 'DESINSTALACAO CONCLUIDA'
Write-Host '============================================================'
Write-Host 'Arquivos do app removidos.'
Write-Host 'Dados preservados por padrao.'
Write-Host ''
Write-Host 'Para remover dados no futuro, execute:'
Write-Host ''
Write-Host ('  .\uninstall.ps1 -Scope {0} -RemoveData' -f $Scope)
Write-Host '============================================================'
