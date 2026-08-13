<p align="center">
  <img src="assets/hddscrub-logo.svg" width="140" alt="HddScrub logo">
</p>

# HDD Backup Integrity Checker

Ferramenta em PowerShell para revisao periodica de HDDs usados como backup frio no Windows.

O objetivo e ajudar a reduzir o risco de perda silenciosa em arquivos armazenados em discos que ficam desligados a maior parte do tempo, usando uma rotina de scrub preventivo: ligar o HDD periodicamente, ler todos os arquivos, calcular SHA-256, comparar com o historico e registrar o resultado.

O script nao liga nem desliga eletricamente o HDD. O controle fisico continua sendo manual.

## Por que isto existe

Dados guardados por muito tempo podem sofrer degradacao silenciosa, geralmente chamada de bit rot ou apodrecimento de dados. Em HDDs mecanicos, isso pode aparecer como setores que ficam dificeis de ler, erros que so surgem quando um arquivo antigo e acessado novamente, corrupcao silenciosa nao percebida na hora, ou falhas causadas por envelhecimento do disco, magnetizacao enfraquecida, firmware/controladora, cabos, energia, temperatura, umidade ou simples desgaste.

Isso existe de verdade, mas nao deve ser entendido como "todo HDD desligado vai corromper rapidamente". Discos bem armazenados podem ficar anos sem problema. O ponto e que backup frio tem uma armadilha: se voce so descobre o erro quando precisa restaurar, talvez ja seja tarde.

O script ajuda criando uma rotina periodica de verificacao preventiva:

- le todos os arquivos, forcando o disco a acessar os dados armazenados;
- calcula SHA-256 para detectar mudancas silenciosas;
- compara com uma baseline salva fora do HDD;
- registra arquivos novos, ausentes, modificados ou com erro de leitura;
- opcionalmente consulta SMART como camada extra de saude do hardware;
- gera historico por serial do disco.

Ele nao impede fisicamente que um bit se degrade enquanto o disco esta guardado. A prevencao aqui e operacional: revisar periodicamente, detectar cedo e agir enquanto ainda ha tempo de copiar de outra fonte, substituir o disco ou refazer o backup.

## Frequencia recomendada

Para HDDs de backup frio, uma rotina razoavel e executar o scrub preventivo a cada **3 a 6 meses**.

Sugestao pratica:

- Dados muito importantes ou unica copia extra: a cada **3 meses**.
- Backup frio comum com mais de uma copia: a cada **6 meses**.
- Discos antigos, suspeitos ou que ja tiveram alerta: revisar com mais frequencia e considerar substituicao.

Sempre que possivel, mantenha mais de uma copia dos dados importantes. Verificacao ajuda muito, mas nao substitui redundancia.

## Arquivos do projeto

```text
hdd-integrity-check.ps1       Script principal
install-local.ps1             Instalador local da CLI hddscrub
install.ps1                   Bootstrap local/remoto de instalacao
uninstall.ps1                 Desinstalador
VERSION                       Versao atual da CLI
bin/hddscrub.cmd              Comando Windows instalado no PATH
bin/hddscrub.ps1              Wrapper da CLI
bin/hddscrub-help.ps1         Help da CLI
assets/hddscrub-logo.svg      Logo do projeto
docs/HDD_BACKUP_INTEGRITY_SPEC.md  Especificacao tecnica original
AGENTS.md                     Contexto para agentes implementadores
README.md                     Este guia
```

## Documentacao tecnica

- [Especificacao original](docs/HDD_BACKUP_INTEGRITY_SPEC.md)
- [Spec para conversao em CLI instalavel](docs/CLI_INSTALLER_CONVERSION_SPEC.md)

Durante o uso, o script cria automaticamente:

```text
manifests/   Manifestos SHA-256 por serial do HDD
reports/     Relatorios TXT/JSON por serial do HDD
logs/        Logs de execucao
```

## Requisitos

- Windows 10 ou Windows 11.
- PowerShell executado como Administrador.
- PowerShell 7 recomendado.
- `smartctl.exe` do smartmontools instalado e disponivel no `PATH`, ou instalado no caminho padrao:
  - `C:\Program Files\smartmontools\bin\smartctl.exe`

O script tambem usa cmdlets nativos do Windows, como `Get-Volume`, `Get-Partition`, `Get-Disk`, `Set-Disk`, `Get-CimInstance`, `Get-FileHash` e `Repair-Volume` quando disponivel.

## Instalacao da CLI

Nao precisa preparar ambiente Python, Node ou compilar nada. A CLI e um wrapper PowerShell para Windows.

### Instalar direto do repositorio

Depois que o projeto estiver publicado no GitHub, da para instalar direto com:

```powershell
irm https://raw.githubusercontent.com/antonio-abrantes/hddscrub/main/install.ps1 | iex
```

Abra um novo terminal e execute:

```powershell
hddscrub
```

O instalador retorna para o prompt ao concluir; ele nao deve fechar a janela do terminal.

Se o repositorio for publicado com outro nome, ajuste a URL acima.

Para instalar de outro repositorio/branch usando o mesmo bootstrap:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/antonio-abrantes/hddscrub/main/install.ps1))) -Repository "antonio-abrantes/hddscrub" -Branch "main"
```

### Instalar a partir da pasta local

Se voce ja baixou ou clonou o projeto, instale para o usuario atual:

```powershell
.\install-local.ps1
```

Depois abra um novo terminal e execute:

```powershell
hddscrub
```

Opcoes do instalador:

```powershell
.\install-local.ps1 -Scope User
.\install-local.ps1 -Scope Machine
.\install-local.ps1 -InstallDir "D:\Tools\HddScrub"
.\install-local.ps1 -NoPath
.\install-local.ps1 -Force
.\install-local.ps1 -PreserveData
.\install-local.ps1 -Clean
```

O `install.ps1` tambem funciona localmente:

```powershell
.\install.ps1
```

O escopo `User` instala por padrao em:

```text
%LOCALAPPDATA%\HddScrub
```

O escopo `Machine` instala por padrao em:

```text
%ProgramData%\HddScrub
```

Nesta primeira versao, manifestos, relatorios e logs ficam dentro da propria pasta instalada, para manter o projeto portatil e preservar compatibilidade com o script principal atual.

Se a pasta de instalacao ja existir, o instalador pergunta se voce quer:

- reinstalar/atualizar mantendo `manifests`, `reports` e `logs`;
- fazer instalacao limpa apagando app e dados locais;
- cancelar.

Atalhos nao interativos:

```powershell
.\install-local.ps1 -PreserveData
.\install-local.ps1 -Clean
```

`-Force` continua funcionando como reinstalacao preservando dados.

Verificar a instalacao:

```powershell
hddscrub doctor
```

Ajuda e versao:

```powershell
hddscrub help
hddscrub help smart
hddscrub --version
hddscrub -v
hddscrub logs
hddscrub reports
```

A versao exibida pela CLI vem do arquivo:

```text
VERSION
```

Para publicar uma nova versao, altere esse arquivo e mantenha o README/changelog coerentes.

Remover a CLI preservando historico:

```powershell
hddscrub uninstall
```

O desinstalador pede confirmacao antes de remover e, sem flags, pergunta se voce quer manter ou apagar `manifests`, `reports` e `logs`.

Remover ja indicando que deseja preservar dados:

```powershell
hddscrub uninstall --keep-data
```

Remover tambem manifestos, relatorios e logs, com confirmacao extra:

```powershell
hddscrub uninstall --remove-data
```

## Instalar o smartctl.exe

O `smartctl.exe` vem no pacote smartmontools.

Opcao recomendada no Windows 10/11, usando winget:

```powershell
winget install --id smartmontools.smartmontools --exact
```

Depois feche e abra o PowerShell novamente e confira:

```powershell
smartctl --version
```

Se preferir instalar manualmente, baixe o instalador do smartmontools no site oficial do projeto e instale normalmente. O script procura automaticamente em:

```text
C:\Program Files\smartmontools\bin\smartctl.exe
```

Se voce colocar `smartctl.exe` manualmente em uma pasta, adicione essa pasta ao `PATH` do Windows antes de executar o script.

Como alternativa portatil, voce pode deixar o executavel em um destes caminhos do projeto:

```text
smartctl.exe
tools\smartctl.exe
```

## Creditos de terceiros

Este projeto pode distribuir arquivos do **smartmontools** para permitir uso portatil no Windows:

```text
tools\smartctl.exe
tools\drivedb.h
```

O smartmontools e um projeto independente usado para consultar informacoes SMART de HDDs/SSDs.

Links oficiais:

- smartmontools: https://www.smartmontools.org/
- downloads/codigo-fonte: https://sourceforge.net/projects/smartmontools/

Arquivos observados nesta copia local:

```text
smartctl 7.5
drivedb.h
```

Licenca do smartmontools:

```text
GPL-2.0-or-later
```

Creditos: smartmontools e seus componentes sao de autoria de Bruce Allen, Christian Franke, Michael Cornwell e demais contribuidores do projeto smartmontools. Este projeto apenas usa/distribui esses arquivos como dependencia de diagnostico SMART.

Antes de uma distribuicao publica, mantenha os creditos, a licenca aplicavel e a referencia para o codigo-fonte correspondente do smartmontools.

## Fluxo de uso

1. Ligue fisicamente apenas o HDD que deseja revisar.
2. Abra PowerShell como Administrador.
3. Entre na pasta do projeto.
4. Execute:

```powershell
.\hdd-integrity-check.ps1
```

Se a CLI estiver instalada, voce pode executar de qualquer pasta:

```powershell
hddscrub
```

5. Escolha o modo de verificacao na interface.
6. Escolha manualmente a unidade, por indice ou letra, por exemplo `E` ou `E:`.
7. Confira modelo, serial, tamanho e numero do disco.
8. Confirme se e realmente o HDD correto.
9. O script executa as etapas habilitadas:
   - SMART inicial.
   - SMART Long/Extended Self-Test, se voce confirmar.
   - Verificacao nao destrutiva de filesystem.
   - SHA-256 e comparacao com historico.
   - Relatorios persistentes.
10. Ao final, o script pergunta separadamente:

```text
Deseja preparar o HDD para desligamento fisico agora? [S/N]
```

Se responder `N`, o disco permanece online.

Se responder `S`, o script mostra novamente unidade, disco, modelo e serial, pede uma segunda confirmacao, revalida a identidade do disco e executa:

```powershell
Set-Disk -IsOffline $true
```

Somente depois de confirmar `IsOffline=True`, ele mostra:

```text
AGORA VOCE PODE DESLIGAR O HDD NO CONTROLADOR FISICO.
```

## Primeira execucao em um HDD

Na primeira execucao para um serial ainda sem manifesto, o script pode criar uma baseline SHA-256.

Essa baseline registra o estado atual dos arquivos. Ela e util para comparacoes futuras, mas nao prova que os arquivos ja estavam integros antes da data de criacao.

O manifesto principal fica fora do HDD verificado:

```text
manifests/<SERIAL>/manifest.jsonl
```

## Execucoes futuras

Em revisoes posteriores do mesmo HDD, o script compara os arquivos atuais com o manifesto salvo.

Classificacoes possiveis:

- `OK`: arquivo confere com o historico.
- `MODIFIED`: hash SHA-256 mudou. O relatorio usa `CHECKSUM MISMATCH`, sem declarar automaticamente corrupcao.
- `MISSING`: arquivo existia no manifesto e nao foi encontrado.
- `NEW`: arquivo existe no HDD, mas nao no manifesto.
- `ERROR`: houve erro de leitura/hash.

Divergencias ficam registradas em um arquivo `*_checksum-details.jsonl` dentro da pasta de relatorios do serial.

## Modos opcionais

Sem parametros, o script oferece uma escolha na propria interface:

```text
[1] Scrub preventivo completo dos dados
[2] Somente scrub SHA-256
[3] Somente filesystem scan
[4] Revisao completa
[5] Reconhecimento SMART seguro
[6] Somente SMART
[0] Sair
```

Com a CLI instalada, os atalhos equivalentes sao:

| Comando | Modo |
| --- | --- |
| `hddscrub` | Abre a interface interativa |
| `hddscrub data --drive X` | Scrub preventivo completo dos dados |
| `hddscrub scrub --drive X` | Somente scrub SHA-256 |
| `hddscrub fs --drive X` | Somente filesystem scan |
| `hddscrub smart --drive X` | Somente SMART |
| `hddscrub full --drive X` | Revisao completa |
| `hddscrub quick --drive X` | Reconhecimento SMART seguro |
| `hddscrub help` | Lista comandos, opcoes e exemplos |
| `hddscrub help smart` | Ajuda de um comando especifico |
| `hddscrub --version` | Mostra versao da CLI e do smartctl |
| `hddscrub -v` | Atalho de versao |
| `hddscrub doctor` | Diagnostico da instalacao |
| `hddscrub paths` | Mostra caminhos usados |
| `hddscrub logs` | Abre a pasta de logs |
| `hddscrub reports` | Abre a pasta de relatorios |
| `hddscrub manifests` | Abre a pasta de manifestos/historico |
| `hddscrub open reports` | Abre uma pasta especifica do app |
| `hddscrub uninstall` | Remove a CLI e pergunta se mantem ou apaga historico |

O modo principal do projeto e **Scrub preventivo completo dos dados**. Ele confirma o HDD, pergunta se voce quer executar SMART antes, e entao segue para filesystem nao destrutivo e SHA-256/historico. Se voce responder `N` para SMART, ele pula essa camada e vai direto para a leitura completa dos arquivos.

O SHA-256 nao e apenas uma "olhada no historico": para calcular o hash, o script precisa ler o conteudo completo de cada arquivo. Portanto, esse modo realiza a acao preventiva principal do projeto:

```text
ler periodicamente todos os arquivos do HDD
forcar o disco a acessar os dados armazenados
detectar erro de leitura cedo
comparar o conteudo com a baseline anterior
registrar historico por serial
```

O modo **Reconhecimento SMART seguro** identifica unidade, disco fisico, modelo, serial e dispositivo SMART, executa apenas SMART inicial e para antes de Long Test, filesystem scan e SHA-256.

Executar diretamente o scrub preventivo dos dados:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -Mode DataOnly
```

Executar apenas o scrub SHA-256, sem SMART e sem filesystem scan:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -Mode ScrubOnly
```

Executar apenas o filesystem scan nao destrutivo:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -Mode FilesystemOnly
```

Executar diretamente o reconhecimento seguro:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -Mode Quick
```

Executar diretamente a revisao completa:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -Mode Full
```

Selecionar unidade, mantendo confirmacao manual:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E
```

Pular SMART Long/Extended Self-Test:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -SkipLongTest
```

Executar somente checksums:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -ChecksumOnly
```

Equivalente com o parametro novo:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -Mode ChecksumOnly
```

O parametro legado `-ChecksumOnly` equivale ao modo `ScrubOnly`.

Executar somente filesystem scan:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -FilesystemOnly
```

Executar somente SMART:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -SmartOnly
```

Equivalente com o parametro novo:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -Mode SmartOnly
```

Nenhum parametro remove as protecoes contra disco de sistema, unidade `C:`, pagefile ativo ou divergencia de serial.

Depois do SMART inicial, nos modos que podem seguir para etapas mais pesadas, o script usa um portao de seguranca. Se o SMART vier com `WARNING`, `CRITICAL` ou `UNKNOWN`, ele avisa que as proximas etapas podem exigir leitura prolongada ou teste longo e pede confirmacao explicita antes de continuar.

### Quando o smartctl nao informa serial

Alguns discos/controladores no Windows permitem ler dados SMART, mas retornam serial SMART vazio. Nessa situacao, o script primeiro tenta o modo mais seguro, que e associar por serial. Se isso falhar, ele tenta uma alternativa controlada:

```text
Windows Disk <N> -> smartctl /dev/pd<N>
```

Exemplo:

```text
Windows Disk 6 -> /dev/pd6
```

Esse fallback so e aceito quando:

- o numero fisico do disco do Windows e usado diretamente;
- o modelo informado pelo Windows confere com o modelo informado pelo smartctl;
- nao ha serial SMART divergente;
- voce confirma explicitamente no terminal.

Para chamadas diretas em que voce ja quer permitir esse fallback, use:

```powershell
.\hdd-integrity-check.ps1 -DriveLetter X -Mode Quick -AllowPhysicalDiskSmartFallback
```

Mesmo com esse parametro, o script continua bloqueando disco de sistema, unidade `C:`, pagefile ativo e divergencia de serial quando houver serial disponivel.

## Seguranca do scrub preventivo dos dados

O scrub preventivo dos dados foi desenhado para ser nao destrutivo:

- nao apaga arquivos;
- nao move arquivos;
- nao sobrescreve arquivos no HDD;
- nao formata;
- nao particiona;
- nao executa reparo automatico;
- le todos os arquivos para calcular SHA-256;
- grava manifestos, logs e relatorios fora do HDD verificado, na pasta do projeto.

Ou seja: o script nao tem uma etapa de delecao/correcao dos dados do HDD.

Ainda assim, nao existe "100% sem risco" em um disco fisicamente degradado. A comparacao SHA-256 precisa ler os arquivos; se um HDD ja estiver morrendo, qualquer leitura longa pode revelar ou piorar uma falha mecanica existente. Para discos saudaveis, essa leitura e uma operacao normal.

## Tempo e cancelamento

O filesystem scan costuma ser bem mais rapido que o SHA-256, porque nao le necessariamente o conteudo completo de todos os arquivos.

O scrub SHA-256 e a parte demorada, pois le todos os arquivos. Em um HDD mecanico de 2 TB, pode levar algumas horas dependendo da quantidade de dados, velocidade real do disco e numero de arquivos pequenos.

Durante o scrub SHA-256, pressione `Q` para pedir cancelamento limpo. O script pergunta se deseja cancelar, para entre arquivos, marca a execucao como `INCOMPLETE`, preserva contadores parciais e gera relatorio.

Durante a estimativa de escopo, o script tambem aceita `Q` para cancelar de forma limpa. A cada intervalo ele mostra uma linha compacta com arquivos encontrados, bytes estimados e tempo decorrido. Durante o scrub, ele mostra arquivos processados, bytes lidos, percentual, taxa e estimativa restante.

Se o cancelamento acontecer durante a primeira baseline, o manifesto oficial nao e substituido. O arquivo parcial fica com sufixo `.partial.jsonl` dentro da pasta do serial, para auditoria.

`Ctrl+C` tambem nao apaga dados, porque o script esta lendo arquivos, mas e uma interrupcao brusca: pode deixar logs ou detalhes parciais e pode nao gerar o relatorio final daquela execucao.

## Historico preventivo

Cada scrub com SHA-256 registra um resumo portatil em:

```text
manifests/<SERIAL>/scrub-history.jsonl
```

Esse arquivo guarda, por execucao:

- data/hora;
- modo usado;
- resultado geral;
- quantidade de arquivos lidos;
- bytes processados;
- status do checksum;
- caminho relativo para os relatorios TXT/JSON.

Os caminhos gravados sao relativos a pasta do projeto, para que voce possa copiar a pasta inteira para outro lugar sem quebrar o historico.

## Configuracao opcional

Crie um `config.json` ao lado do script para limitar escopo ou ajustar comportamento:

```json
{
  "include": [
    "Fotos",
    "Documentos",
    "Projetos"
  ],
  "exclude": [
    "Temp",
    "*.tmp"
  ],
  "alwaysLongTest": false,
  "longTestPollSeconds": 60
}
```

Por padrao, o script ignora apenas diretorios tecnicos:

```text
$RECYCLE.BIN
System Volume Information
.hdd-integrity/temp
```

## Relatorios

Cada execucao salva relatorios por serial:

```text
reports/<SERIAL>/2026-08-13_093600.txt
reports/<SERIAL>/2026-08-13_093600.json
```

O TXT e feito para leitura rapida. O JSON guarda dados estruturados para historico e comparacao futura.

Ao final da verificacao, o script mostra os caminhos absolutos do TXT, JSON, pasta do relatorio e log. Ele tambem oferece abrir o TXT no Notepad, abrir a pasta do relatorio ou abrir a pasta de logs.

Com a CLI instalada, voce tambem pode abrir as pastas principais diretamente:

```powershell
hddscrub logs
hddscrub reports
hddscrub manifests
hddscrub open tools
```

## O que a ferramenta ajuda a detectar

- Falha SMART geral.
- Setores pendentes.
- Setores offline uncorrectable.
- Crescimento de setores realocados em relacao ao relatorio anterior.
- Falhas em self-test SMART.
- Possiveis inconsistencias NTFS sem reparo automatico.
- Arquivos ausentes, novos, modificados ou com erro de leitura.
- Divergencias SHA-256 entre a baseline e a revisao atual.

## O que ela nao faz

- Nao controla energia fisica do HDD.
- Nao formata discos.
- Nao limpa discos.
- Nao particiona discos.
- Nao repara filesystem automaticamente.
- Nao corrige nem remove arquivos.
- Nao sincroniza backups.
- Nao atualiza firmware.
- Nao executa testes simultaneos em varios HDDs.

## Recomendacao de rotina

Para HDDs de backup frio, uma rotina pratica e fazer scrub de cada disco periodicamente, por exemplo a cada alguns meses:

1. Ligar fisicamente o HDD.
2. Executar o script.
3. Escolher `Scrub preventivo dos dados`.
4. Pular SMART ou executar SMART opcional, conforme quiser.
5. Ler todos os arquivos via SHA-256 e comparar com o historico.
6. Guardar o relatorio.
7. Colocar o disco offline pelo script.
8. Desligar fisicamente somente depois da mensagem de seguranca.

Se aparecer `WARNING` ou `CRITICAL`, leia o TXT e o JSON antes de tomar qualquer decisao. Um checksum diferente pode ser uma alteracao legitima de arquivo, mas deve ser investigado.
