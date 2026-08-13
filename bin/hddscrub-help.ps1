[CmdletBinding()]
param(
    [string]$Topic,
    [string]$Version = 'unknown'
)

$ErrorActionPreference = 'Stop'

function Write-GeneralHelp {
    param([string]$Version)

    Write-Host ('hddscrub {0}' -f $Version)
    Write-Host 'HDD/SSD cold backup scrub and integrity checker for Windows.'
    Write-Host ''
    Write-Host 'USAGE'
    Write-Host '  hddscrub'
    Write-Host '  hddscrub <command> [options]'
    Write-Host '  hddscrub help [command]'
    Write-Host ''
    Write-Host 'COMMANDS'
    Write-Host '  data        Scrub preventivo completo dos dados.'
    Write-Host '              Filesystem scan + SHA-256. SMART e opcional.'
    Write-Host ''
    Write-Host '  scrub       Somente scrub SHA-256.'
    Write-Host '              Le todos os arquivos e cria/compara baseline.'
    Write-Host ''
    Write-Host '  fs          Somente filesystem scan nao destrutivo.'
    Write-Host '              Alias: filesystem'
    Write-Host ''
    Write-Host '  smart       Somente SMART.'
    Write-Host '              SMART inicial + Long/Extended Self-Test opcional.'
    Write-Host ''
    Write-Host '  full        Revisao completa.'
    Write-Host '              SMART, Long Test opcional, filesystem e SHA-256.'
    Write-Host ''
    Write-Host '  quick       Reconhecimento seguro.'
    Write-Host '              Identidade do disco + SMART inicial, sem etapas pesadas.'
    Write-Host ''
    Write-Host '  doctor      Valida instalacao, dependencias e caminhos.'
    Write-Host '  paths       Mostra caminhos da instalacao e dados.'
    Write-Host '  current     Mostra versao, PowerShell, elevacao e smartctl.'
    Write-Host '  version     Mostra versao. Alias: --version, -v'
    Write-Host '  uninstall   Remove a CLI. Pergunta se mantem ou apaga historico.'
    Write-Host '  help        Mostra esta ajuda.'
    Write-Host ''
    Write-Host 'OPTIONS'
    Write-Host '  --drive X, -d X       Unidade alvo. Exemplo: --drive E'
    Write-Host '  --drive=X             Forma alternativa para informar unidade.'
    Write-Host '  --skip-long-test      Pula SMART Long/Extended Self-Test.'
    Write-Host '  --allow-pd-smart      Permite fallback SMART por numero fisico do disco.'
    Write-Host '  --keep-data           Com uninstall, preserva dados apos confirmacao.'
    Write-Host '  --remove-data         Com uninstall, pede confirmacao extra e remove historico.'
    Write-Host '  -PreserveData         No instalador, reinstala mantendo historico.'
    Write-Host '  -Clean                No instalador, pede confirmacao e faz instalacao limpa.'
    Write-Host '  --help, -h            Mostra ajuda.'
    Write-Host '  --version, -v         Mostra versao.'
    Write-Host ''
    Write-Host 'EXAMPLES'
    Write-Host '  hddscrub'
    Write-Host '  hddscrub data --drive E'
    Write-Host '  hddscrub scrub -d X'
    Write-Host '  hddscrub fs --drive P'
    Write-Host '  hddscrub smart --drive E --skip-long-test'
    Write-Host '  hddscrub quick --drive X --allow-pd-smart'
    Write-Host '  hddscrub doctor'
    Write-Host '  hddscrub uninstall'
    Write-Host ''
    Write-Host 'SAFETY'
    Write-Host '  A CLI nunca escolhe disco automaticamente.'
    Write-Host '  Acoes de offline/desligamento continuam exigindo confirmacao.'
    Write-Host '  O scrub SHA-256 le arquivos, mas nao apaga, move ou corrige dados.'
    Write-Host ''
    Write-Host 'MORE'
    Write-Host '  hddscrub help data'
    Write-Host '  hddscrub help scrub'
    Write-Host '  hddscrub help smart'
    Write-Host '  hddscrub help uninstall'
}

function Write-CommandHelp {
    param([string]$Command)

    switch ($Command.ToLowerInvariant()) {
        'data' {
            Write-Host 'hddscrub data --drive X'
            Write-Host ''
            Write-Host 'Scrub preventivo completo dos dados.'
            Write-Host 'Executa filesystem scan nao destrutivo e leitura completa SHA-256.'
            Write-Host 'Antes dos dados, pergunta se voce quer executar SMART inicial.'
            Write-Host ''
            Write-Host 'Options: --drive X, -d X, --allow-pd-smart'
        }
        'scrub' {
            Write-Host 'hddscrub scrub --drive X'
            Write-Host ''
            Write-Host 'Somente scrub SHA-256.'
            Write-Host 'Le todos os arquivos e cria/compara baseline/historico.'
            Write-Host 'Pula SMART, Long Test e filesystem scan.'
            Write-Host ''
            Write-Host 'Options: --drive X, -d X'
        }
        'fs' { Write-CommandHelp -Command 'filesystem' }
        'filesystem' {
            Write-Host 'hddscrub fs --drive X'
            Write-Host ''
            Write-Host 'Somente filesystem scan nao destrutivo.'
            Write-Host 'Nao executa reparo automatico.'
            Write-Host ''
            Write-Host 'Options: --drive X, -d X'
        }
        'smart' {
            Write-Host 'hddscrub smart --drive X'
            Write-Host ''
            Write-Host 'Somente SMART.'
            Write-Host 'Executa SMART inicial e pergunta sobre Long/Extended Self-Test.'
            Write-Host ''
            Write-Host 'Options: --drive X, -d X, --skip-long-test, --allow-pd-smart'
        }
        'full' {
            Write-Host 'hddscrub full --drive X'
            Write-Host ''
            Write-Host 'Revisao completa.'
            Write-Host 'SMART inicial, Long Test opcional, filesystem scan e SHA-256.'
            Write-Host ''
            Write-Host 'Options: --drive X, -d X, --skip-long-test, --allow-pd-smart'
        }
        'quick' {
            Write-Host 'hddscrub quick --drive X'
            Write-Host ''
            Write-Host 'Reconhecimento seguro.'
            Write-Host 'Identifica unidade/disco/modelo/serial e executa apenas SMART inicial.'
            Write-Host 'Nao executa Long Test, filesystem scan ou SHA-256.'
            Write-Host ''
            Write-Host 'Options: --drive X, -d X, --allow-pd-smart'
        }
        'doctor' {
            Write-Host 'hddscrub doctor'
            Write-Host ''
            Write-Host 'Valida Windows, PowerShell, elevacao, script principal, smartctl e pastas.'
            Write-Host 'Nao executa verificacao em disco.'
        }
        'paths' {
            Write-Host 'hddscrub paths'
            Write-Host ''
            Write-Host 'Mostra app root, script principal, tools, manifests, reports e logs.'
        }
        'current' {
            Write-Host 'hddscrub current'
            Write-Host ''
            Write-Host 'Mostra versao, PowerShell, elevacao, smartctl e pasta da instalacao.'
        }
        'version' {
            Write-Host 'hddscrub --version'
            Write-Host 'hddscrub -v'
            Write-Host ''
            Write-Host 'Mostra a versao lida do arquivo VERSION e a versao do smartctl bundled.'
        }
        'uninstall' {
            Write-Host 'hddscrub uninstall [--keep-data|--remove-data]'
            Write-Host ''
            Write-Host 'Remove a CLI apos confirmacao.'
            Write-Host 'Sem flags, pergunta se deve manter ou apagar manifests, reports e logs.'
            Write-Host '--keep-data preserva dados apos confirmacao de desinstalacao.'
            Write-Host '--remove-data pede confirmacao extra antes de apagar o historico local.'
        }
        default {
            Write-Host ('Comando desconhecido para help: {0}' -f $Command) -ForegroundColor Yellow
            Write-Host 'Use: hddscrub help'
            exit 2
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Topic)) {
    Write-GeneralHelp -Version $Version
} else {
    Write-CommandHelp -Command $Topic
}
