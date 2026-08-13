# Especificacao Tecnica: Conversao para CLI Instalavel no Windows

## Objetivo

Converter o projeto atual em uma aplicacao CLI instalavel no Windows, mantendo o comportamento seguro do script existente e permitindo executar a ferramenta de qualquer terminal com um comando curto.

Nome proposto da CLI:

```text
hddscrub
```

Exemplos esperados apos instalacao:

```powershell
hddscrub
hddscrub scrub --drive X
hddscrub data --drive X
hddscrub fs --drive X
hddscrub smart --drive X
hddscrub full --drive X
```

O projeto deve continuar focado exclusivamente em Windows.

## Referencia de UX

Seguir o estilo do README/projeto `claude-code-switcher` do usuario:

- apresentacao curta e direta no inicio;
- install logo no topo;
- comando curto apos abrir um terminal novo;
- tabela de comandos;
- instalador local Windows;
- wrappers PowerShell;
- uninstall como comando;
- documentacao detalhada em `docs/`;
- creditos e licencas claros.

Adaptacao para este projeto:

- usar PowerShell, nao Bash;
- nao interceptar outros comandos;
- nao alterar ambiente global alem do PATH/atalho da propria CLI;
- nao reduzir seguranca do Windows sem consentimento;
- pedir elevacao somente quando necessario e explicando o motivo;
- manter a CLI como `hddscrub`.

## Premissas

- `hdd-integrity-check.ps1` continua sendo o motor funcional.
- A primeira conversao nao precisa reescrever a aplicacao em outra linguagem.
- O instalador cria wrappers em torno do PowerShell.
- A distribuicao pode incluir:

```text
tools\smartctl.exe
tools\drivedb.h
```

- Historicos, manifestos, logs e relatorios nao devem ficar dentro de `%ProgramFiles%` quando instalado como app.
- Execucoes com disco/SMART/offline ainda podem exigir terminal elevado.

## Status da Implementacao Atual

Implementado sem reescrever o motor principal:

- `bin\hddscrub.cmd`;
- `bin\hddscrub.ps1`;
- `install-local.ps1`;
- `install.ps1` como bootstrap local/remoto;
- `uninstall.ps1`;
- `VERSION`;
- `bin\hddscrub-help.ps1`;
- `NOTICE.md`;
- `LICENSE`;
- comandos `hddscrub`, `hddscrub help`, `hddscrub --version`, `hddscrub -v`, `hddscrub doctor`, `hddscrub paths`, `hddscrub current` e `hddscrub uninstall`;
- atalhos `scrub`, `data`, `fs`, `smart`, `full` e `quick`.

Decisao da primeira versao:

- `Scope User` instala em `%LOCALAPPDATA%\HddScrub`;
- `Scope Machine` instala em `%ProgramData%\HddScrub`;
- manifestos, relatorios e logs ficam na propria pasta instalada.

Motivo: o script principal atual ainda usa a propria pasta como base para `manifests`, `reports` e `logs`. Manter a instalacao em local gravavel permite implementar a CLI agora sem tocar no `hdd-integrity-check.ps1` enquanto ele esta em uso.

A separacao ideal entre app em `%ProgramFiles%` e dados em `%ProgramData%` continua recomendada para uma fase futura, depois de adicionar suporte formal a `HDDSCRUB_DATA_ROOT` no motor principal.

## Estrutura Recomendada

```text
hddscrub/
├── hdd-integrity-check.ps1
├── install-local.ps1
├── install.ps1
├── uninstall.ps1
├── VERSION
├── README.md
├── LICENSE
├── NOTICE.md
├── bin/
│   ├── hddscrub.cmd
│   ├── hddscrub.ps1
│   └── hddscrub-help.ps1
├── docs/
│   ├── HDD_BACKUP_INTEGRITY_SPEC.md
│   ├── CLI_INSTALLER_CONVERSION_SPEC.md
│   ├── installation-guide.md
│   ├── usage-guide.md
│   ├── safety-model.md
│   ├── smartmontools-notes.md
│   ├── uninstall.md
│   └── changelog.md
├── tools/
│   ├── smartctl.exe
│   ├── drivedb.h
│   └── README.md
├── manifests/
│   └── .gitkeep
├── reports/
│   └── .gitkeep
└── logs/
    └── .gitkeep
```

## Install no README

O README final deve ter uma secao semelhante a:

```markdown
## Install

### Windows (PowerShell 5 & 7)

```powershell
irm https://raw.githubusercontent.com/<owner>/<repo>/main/install.ps1 | iex
```

Open a new terminal, then:

```powershell
hddscrub
```

Done. Your scrub modes are available from anywhere.
```

Instalacao local:

```powershell
.\install-local.ps1
.\install.ps1
```

Opcoes:

```powershell
.\install-local.ps1 -Scope User
.\install-local.ps1 -Scope Machine
.\install-local.ps1 -InstallDir "D:\Tools\HddScrub"
.\install-local.ps1 -NoPath
.\install-local.ps1 -Force
.\install-local.ps1 -PreserveData
.\install-local.ps1 -Clean
```

## Locais de Instalacao

### Implementacao atual

Escopo `User`:

```text
%LOCALAPPDATA%\HddScrub\
```

Escopo `Machine`:

```text
%ProgramData%\HddScrub\
```

Em ambos, ficam dentro da pasta instalada:

```text
manifests\
reports\
logs\
```

Essa escolha preserva compatibilidade com o script principal atual e evita gravar historico em local protegido.

### Modelo ideal futuro

Depois que o motor principal aceitar um data root separado, usar a estrutura abaixo.

### Escopo User

App:

```text
%LOCALAPPDATA%\HddScrub\
```

Dados:

```text
%LOCALAPPDATA%\HddScrub\data\manifests\
%LOCALAPPDATA%\HddScrub\data\reports\
%LOCALAPPDATA%\HddScrub\data\logs\
```

Binarios no PATH:

```text
%LOCALAPPDATA%\HddScrub\bin\
```

Esse modo nao deve exigir Administrador para instalar.

### Escopo Machine

App:

```text
%ProgramFiles%\HddScrub\
```

Dados:

```text
%ProgramData%\HddScrub\manifests\
%ProgramData%\HddScrub\reports\
%ProgramData%\HddScrub\logs\
```

Binarios no PATH:

```text
%ProgramFiles%\HddScrub\bin\
```

Esse modo exige Administrador para instalar.

## Responsabilidades do Instalador

Arquivo principal:

```text
install-local.ps1
```

Responsabilidades:

1. Detectar Windows.
2. Detectar PowerShell 5.1+ e recomendar PowerShell 7 quando disponivel.
3. Aceitar `-Scope User` e `-Scope Machine`.
4. Para `Machine`, verificar Administrador antes de escrever em PATH de maquina. Em uma fase futura, tambem verificar antes de escrever em `%ProgramFiles%`.
5. Copiar arquivos do app para o diretorio de instalacao.
6. Copiar `tools\smartctl.exe` e `tools\drivedb.h`.
7. Criar diretorios de dados se nao existirem.
8. Criar `bin\hddscrub.cmd`.
9. Criar `bin\hddscrub.ps1`.
10. Adicionar `bin` ao PATH, exceto com `-NoPath`.
11. Opcionalmente registrar uma funcao leve no `$PROFILE` apenas para facilitar a sessao atual.
12. Nao alterar ExecutionPolicy global sem consentimento explicito.
13. Usar `-ExecutionPolicy Bypass` apenas no wrapper/comando executado.
14. Quando `InstallDir` ja existir, perguntar:
    - reinstalar/atualizar mantendo `manifests`, `reports` e `logs`;
    - fazer instalacao limpa apagando app e dados locais;
    - cancelar.
15. `-PreserveData` deve reinstalar mantendo historico.
16. `-Clean` deve pedir confirmacao antes de apagar app e dados locais.
17. `-Force` deve funcionar como reinstalacao preservando dados, para compatibilidade.
18. Validar:

```powershell
hddscrub --version
```

ou:

```powershell
& "<InstallDir>\bin\hddscrub.cmd" --version
```

19. Mostrar:

```text
Instalado em: ...
Dados em: ...
Comando: hddscrub
Abra um novo terminal se o PATH nao atualizar nesta sessao.
```

## Responsabilidades do Bootstrap Remoto

Arquivo:

```text
install.ps1
```

Responsabilidades:

1. Se executado dentro de uma pasta completa do projeto, chamar `install-local.ps1`.
2. Se executado via `irm ... | iex`, baixar um ZIP do repositorio.
3. Aceitar `-Repository`, `-Branch` e `-ArchiveUrl`.
4. Extrair o pacote em pasta temporaria.
5. Validar que `install-local.ps1` e `hdd-integrity-check.ps1` existem no pacote.
6. Chamar `install-local.ps1` com `-Scope`, `-InstallDir`, `-NoPath` e `-Force`.
7. Apagar a pasta temporaria ao final, exceto quando `-KeepDownload` for usado.

Exemplo publico:

```powershell
irm https://raw.githubusercontent.com/antonio-abrantes/hddscrub/main/install.ps1 | iex
```

Exemplo parametrizado:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/antonio-abrantes/hddscrub/main/install.ps1))) -Repository "antonio-abrantes/hddscrub" -Branch "main"
```

## Wrappers

### `bin\hddscrub.cmd`

Wrapper para `cmd.exe`, PowerShell e Windows Terminal:

```bat
@echo off
where pwsh.exe >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hddscrub.ps1" %*
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hddscrub.ps1" %*
)
```

### `bin\hddscrub.ps1`

Wrapper PowerShell:

```powershell
$AppRoot = Split-Path -Parent $PSScriptRoot
$Script = Join-Path $AppRoot 'hdd-integrity-check.ps1'
$env:HDDSCRUB_INSTALL_ROOT = $AppRoot
$env:HDDSCRUB_DATA_ROOT = '<data-root>'
& $Script @args
exit $LASTEXITCODE
```

Melhoria necessaria no wrapper: traduzir argumentos amigaveis para parametros atuais.

```text
--drive X        -> -DriveLetter X
--mode scrub     -> -Mode ScrubOnly
--mode data      -> -Mode DataOnly
--mode fs        -> -Mode FilesystemOnly
--mode smart     -> -Mode SmartOnly
--mode full      -> -Mode Full
--allow-pd-smart -> -AllowPhysicalDiskSmartFallback
```

## Comandos da CLI

Tabela esperada no README:

| Command | What it does |
| :--- | :--- |
| `hddscrub` | Abre menu interativo |
| `hddscrub scrub --drive X` | Executa somente scrub SHA-256 |
| `hddscrub data --drive X` | Executa scrub preventivo completo dos dados |
| `hddscrub fs --drive X` | Executa filesystem scan nao destrutivo |
| `hddscrub smart --drive X` | Executa somente SMART |
| `hddscrub full --drive X` | Executa revisao completa |
| `hddscrub quick --drive X` | Executa reconhecimento SMART seguro |
| `hddscrub current` | Mostra caminhos/configuracao ativa |
| `hddscrub paths` | Mostra instalacao, dados, tools e logs |
| `hddscrub doctor` | Valida ambiente e dependencias |
| `hddscrub uninstall` | Remove a CLI instalada |
| `hddscrub --help` | Mostra ajuda |
| `hddscrub --version` | Mostra versao do app e smartctl bundled |

Mapeamento:

```text
hddscrub                 -> menu interativo
hddscrub scrub --drive X -> -DriveLetter X -Mode ScrubOnly
hddscrub data --drive X  -> -DriveLetter X -Mode DataOnly
hddscrub fs --drive X    -> -DriveLetter X -Mode FilesystemOnly
hddscrub smart --drive X -> -DriveLetter X -Mode SmartOnly
hddscrub full --drive X  -> -DriveLetter X -Mode Full
hddscrub quick --drive X -> -DriveLetter X -Mode Quick
```

## `hddscrub doctor`

Deve verificar:

- Windows;
- PowerShell;
- se a sessao atual esta elevada;
- cmdlets Windows necessarios;
- `tools\smartctl.exe`;
- `tools\drivedb.h`;
- versao do `smartctl`;
- diretorios de dados;
- permissao de escrita em dados;
- PATH;
- versao instalada.

Saida esperada:

```text
[OK] Windows detectado
[OK] PowerShell 7.5
[OK] hddscrub no PATH
[OK] smartctl 7.5 bundled
[WARNING] Sessao nao esta elevada; SMART/offline podem falhar
```

## Dados e Portabilidade

Modo instalado nao deve gravar historico dentro da pasta do app quando ela estiver em `%ProgramFiles%`.

Usar:

```text
%LOCALAPPDATA%\HddScrub\data\
```

ou:

```text
%ProgramData%\HddScrub\
```

Melhoria futura no script principal:

- se `HDDSCRUB_DATA_ROOT` existir, usar esse caminho para `manifests`, `reports` e `logs`;
- se nao existir, manter comportamento portatil atual:

```text
.\manifests
.\reports
.\logs
```

## Permissoes e Elevacao

Instalar `User`:

- nao exige Administrador;
- altera PATH do usuario;
- copia app para `%LOCALAPPDATA%`.

Instalar `Machine`:

- exige Administrador;
- altera PATH de maquina;
- copia app para `%ProgramFiles%`;
- cria dados em `%ProgramData%`.

Executar:

- scrub SHA-256 pode funcionar sem Administrador se houver permissao de leitura;
- SMART, filesystem scan e offline/online devem recomendar ou exigir Administrador;
- se faltar elevacao, explicar:

```text
Esta operacao precisa de PowerShell como Administrador.
Abra um terminal elevado e execute novamente.
```

Nao elevar automaticamente sem o usuario entender.

## Uninstall

Arquivos:

```text
uninstall.ps1
```

Comandos:

```powershell
.\uninstall.ps1
.\uninstall.ps1 -Scope User
.\uninstall.ps1 -Scope Machine
.\uninstall.ps1 -KeepData
.\uninstall.ps1 -RemoveData
hddscrub uninstall
hddscrub uninstall --remove-data
```

Padrao:

```text
remove app/wrappers/PATH
mantem manifests/reports/logs
```

Se `--remove-data` ou `-RemoveData` for usado:

1. mostrar caminho completo dos dados;
2. pedir confirmacao explicita;
3. nunca apagar dados sem confirmacao.

## Atualizacao

Comando futuro:

```powershell
hddscrub update
```

Alternativa:

```powershell
.\install-local.ps1 -Force
.\install-local.ps1 -PreserveData
.\install-local.ps1 -Clean
```

Regras:

- `-Force` e `-PreserveData` preservam dados;
- `-Clean` pede confirmacao e apaga app/dados locais;
- reinstalacao interativa pergunta se mantem ou apaga dados;
- substituir/criar arquivos do app;
- nao apagar manifestos sem escolha explicita de instalacao limpa;
- atualizar wrappers;
- validar `smartctl.exe --version`.

## README Alvo Apos Conversao

Ordem recomendada:

1. Logo/nome curto.
2. Frase de valor:

```text
Prevent bit rot surprises in cold backup drives with one command.
```

3. Badges:

```text
PowerShell 5.1+
Windows
bundles smartmontools
license
```

4. Install.
5. Abrir novo terminal e rodar `hddscrub`.
6. Commands table.
7. Como funciona.
8. Dados/historico.
9. Segurança.
10. Documentation Index.
11. Créditos e licenças.

## Documentation Index Planejado

```text
docs/
├── CLI_INSTALLER_CONVERSION_SPEC.md
├── HDD_BACKUP_INTEGRITY_SPEC.md
├── installation-guide.md
├── usage-guide.md
├── safety-model.md
├── smartmontools-notes.md
├── uninstall.md
└── changelog.md
```

README deve conter uma secao:

```markdown
## Documentation Index

- Installation Guide
- Complete Usage Guide
- Safety Model
- smartmontools Notes
- Uninstall Guide
- Changelog
```

## Distribuicao do smartmontools

Arquivos bundled atualmente:

```text
tools\smartctl.exe
tools\drivedb.h
```

Origem:

```text
smartmontools
https://www.smartmontools.org/
https://sourceforge.net/projects/smartmontools/
```

Versao local observada:

```text
smartctl 7.5
```

Licenca:

```text
GPL-2.0-or-later
```

Obrigacoes recomendadas:

1. Manter creditos no README.
2. Criar `NOTICE.md`.
3. Incluir licenca GPL aplicavel ou link claro para ela.
4. Informar versao bundled.
5. Informar onde obter codigo-fonte correspondente.
6. Nao sugerir que smartmontools e autoria deste projeto.

## Arquivos de Credito e Licenca

Criar:

```text
NOTICE.md
licenses/
└── smartmontools-GPL-2.0-or-later.txt
```

Conteudo minimo do `NOTICE.md`:

```text
This project bundles smartctl.exe and drivedb.h from smartmontools.
smartmontools is Copyright (C) Bruce Allen, Christian Franke, Michael Cornwell and contributors.
smartmontools is licensed under GPL-2.0-or-later.
Homepage: https://www.smartmontools.org/
Source: https://sourceforge.net/projects/smartmontools/
```

## Release

Artefato recomendado:

```text
hddscrub-windows-x64-vX.Y.Z.zip
```

Conteudo:

```text
hddscrub/
├── install-local.ps1
├── install.ps1
├── uninstall.ps1
├── hdd-integrity-check.ps1
├── README.md
├── NOTICE.md
├── LICENSE
├── docs/
├── bin/
├── tools/
│   ├── smartctl.exe
│   ├── drivedb.h
│   └── README.md
├── manifests/.gitkeep
├── reports/.gitkeep
└── logs/.gitkeep
```

Nao incluir:

```text
logs/*.log
reports/<SERIAL>/*
manifests/<SERIAL>/*
config.json local
```

## Criterios de Aceitacao

- `install-local.ps1 -Scope User` instala sem Administrador.
- `install-local.ps1 -Scope Machine` exige Administrador.
- `hddscrub` funciona em novo terminal.
- `VERSION` e usado como fonte unica da versao da CLI.
- `hddscrub --version` mostra versao do app e do smartctl bundled.
- `hddscrub -v` mostra versao do app e do smartctl bundled.
- `hddscrub help` lista comandos, opcoes e exemplos.
- `hddscrub help smart` mostra ajuda especifica de comando.
- `hddscrub doctor` valida dependencias.
- `hddscrub scrub --drive X` chama `ScrubOnly`.
- `hddscrub data --drive X` chama `DataOnly`.
- `hddscrub fs --drive X` chama `FilesystemOnly`.
- `hddscrub full --drive X` chama `Full`.
- Reinstalacao preserva manifests/reports/logs quando `-Force` ou `-PreserveData` sao usados.
- Instalacao limpa exige escolha/confirmacao explicita.
- `hddscrub uninstall` pede confirmacao, pergunta se mantem ou apaga dados, e so entao remove.
- `hddscrub uninstall --keep-data` pede confirmacao e preserva manifests/reports/logs.
- `hddscrub uninstall --remove-data` pede confirmacao extra antes de apagar dados.
- Instalacao nao sobrescreve manifestos existentes.
- Release nao inclui logs, reports ou manifests pessoais.
- README e NOTICE creditam smartmontools.

## Ordem Recomendada de Implementacao

1. Criar `bin\hddscrub.ps1` e `bin\hddscrub.cmd`.
2. Adicionar parsing amigavel de comandos no wrapper.
3. Adicionar `--version`, `doctor`, `paths` e `current`.
4. Criar `install-local.ps1 -Scope User`.
5. Criar `uninstall.ps1 -Scope User`.
6. Adicionar `-Scope Machine`.
7. Separar data root instalado de data root portatil via `HDDSCRUB_DATA_ROOT`.
8. Criar `NOTICE.md` e pasta `licenses`.
9. Documentar release zip.
10. Testar em PowerShell 5.1 e 7.
11. Testar em terminal novo apos PATH.
