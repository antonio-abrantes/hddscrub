# HDD Backup Integrity Checker — Especificação Técnica

## 1. Objetivo

Implementar uma solução em **PowerShell para Windows** que automatize a verificação periódica de HDDs usados como armazenamento/backup frio.

O usuário liga fisicamente apenas o HDD desejado no controlador de alimentação. Em seguida, executa o script e **seleciona manualmente a unidade** recém-disponibilizada, por exemplo `E:`.

O script deve:

1. listar as unidades elegíveis;
2. permitir a seleção manual da letra da unidade;
3. resolver a unidade selecionada para o disco físico correspondente;
4. identificar o HDD por modelo, serial, tamanho e número do disco;
5. executar verificações SMART;
6. executar SMART Long/Extended Self-Test quando habilitado;
7. verificar o sistema de arquivos de forma não destrutiva;
8. ler/verificar os arquivos e seus checksums;
9. gerar relatório persistente;
10. ao final, perguntar separadamente se o usuário deseja colocar o disco offline;
11. somente se o usuário confirmar, colocar o disco físico offline no Windows;
12. avisar explicitamente quando for seguro desligar o HDD no controlador físico.

A solução **não controla eletricamente o HDD**. O ON/OFF físico continua sendo feito manualmente.

## 2. Plataforma e dependências

### Obrigatório

- Windows 10 ou Windows 11.
- PowerShell 7 preferencialmente; Windows PowerShell 5.1 pode ser aceito se todas as funções funcionarem.
- Execução elevada como Administrador para operações que exigem acesso ao disco/SMART/offline.
- `smartctl.exe` do projeto **smartmontools**.

### APIs/Cmdlets nativos esperados

- `Get-Volume`
- `Get-Partition`
- `Get-Disk`
- `Set-Disk`
- `Get-CimInstance`
- `Get-FileHash`
- `Get-ChildItem`
- `Test-Path`

O agente deve verificar a disponibilidade dos cmdlets antes de iniciar.

## 3. Nome sugerido

Script principal:

```text
hdd-integrity-check.ps1
```

Estrutura opcional:

```text
hdd-integrity/
├── hdd-integrity-check.ps1
├── config.json
├── manifests/
├── reports/
└── logs/
```

## 4. Experiência de uso desejada

O fluxo deve ser interativo e simples.

Exemplo:

```text
HDD Backup Integrity Checker

Unidades disponíveis:

[1] D:  DATA            3.64 TB
[2] E:  BACKUP-01       7.28 TB
[3] F:  BACKUP-02      10.91 TB

Selecione a unidade que deseja verificar: 2

Unidade selecionada: E:

Disco físico:
  Número : 4
  Modelo : ST8000VN004
  Serial : XXXXXXXX
  Tamanho: 8 TB
  Status : Online

Confirma que deseja verificar este disco? [S/N]:
```

Também aceitar entrada direta:

```text
E
```

ou:

```text
E:
```

O script deve normalizar ambas para `E:`.

## 5. Regra de segurança mais importante

O script **nunca deve escolher automaticamente um disco para executar ações destrutivas ou alterar seu estado**.

A unidade de trabalho deve ser selecionada manualmente pelo usuário.

O script deve abortar se:

- a unidade selecionada não existir;
- a unidade for `C:`;
- o disco contiver partição de boot/sistema;
- o disco contiver o pagefile ativo;
- o disco físico não puder ser determinado com segurança;
- houver mais de um dispositivo SMART compatível com o mesmo serial e não for possível desambiguar;
- a unidade desaparecer durante a execução;
- houver inconsistência entre o serial inicialmente identificado e o serial observado posteriormente.

Nenhum comando de formatação, limpeza, particionamento ou reparo destrutivo é permitido.

São explicitamente proibidos por padrão:

```text
Format-Volume
Clear-Disk
Initialize-Disk
Remove-Partition
diskpart clean
chkdsk /f
chkdsk /r
```

## 6. Seleção manual da unidade

### Fluxo

1. Executar `Get-Volume`.
2. Mostrar apenas volumes adequados para seleção.
3. Exibir índice, letra, label, filesystem, tamanho e espaço usado/livre.
4. Solicitar seleção.
5. Resolver a letra escolhida até o disco físico correspondente.
6. Registrar:
   - `Disk.Number`
   - `Disk.SerialNumber`
   - `Disk.FriendlyName`
   - `Disk.UniqueId`
   - `Disk.BusType`
   - tamanho físico.

Exemplo de resolução:

```powershell
Get-Partition -DriveLetter E | Get-Disk
```

### Identidade primária

Nunca persistir identidade do HDD somente pela letra.

A identidade primária deve ser:

```text
SerialNumber
```

com `UniqueId` e modelo como dados auxiliares.

A letra é apenas a forma manual de seleção no início.

## 7. Identificação SMART

Não assumir que:

```text
E: == /dev/sdX
```

O agente deve detectar o dispositivo compatível com `smartctl`.

Fluxo sugerido:

1. localizar `smartctl.exe`;
2. executar scan compatível com Windows;
3. obter candidatos;
4. consultar modelo/serial de cada candidato;
5. comparar com o serial do `Get-Disk`;
6. selecionar somente quando houver correspondência inequívoca.

Se não houver correspondência segura:

```text
ERRO: não foi possível associar com segurança a unidade E:
ao dispositivo SMART correspondente.
Nenhum teste SMART será iniciado.
```

O restante da verificação deve ser abortado por padrão, com motivo registrado no relatório.

## 8. Etapas da verificação

A execução deve ser sequencial.

### Etapa A — Snapshot inicial

Registrar:

- data/hora;
- hostname;
- letra;
- label;
- filesystem;
- serial;
- modelo;
- firmware, se disponível;
- capacidade;
- número físico do disco;
- temperatura;
- Power-On Hours;
- Power Cycle Count;
- estado SMART geral.

### Etapa B — SMART inicial

Executar consulta SMART completa suficiente para extrair pelo menos:

- SMART overall-health/self-assessment;
- temperatura;
- Reallocated Sector Count;
- Current Pending Sector Count;
- Offline Uncorrectable;
- UDMA CRC Error Count, quando disponível;
- histórico de self-tests;
- Power-On Hours;
- Power Cycle Count.

Os atributos variam por fabricante. O parser não deve falhar se um atributo não existir.

Classificação:

```text
OK
WARNING
CRITICAL
UNKNOWN
```

Exemplos de alertas:

- SMART overall-health falhou -> `CRITICAL`
- setores pendentes > 0 -> `WARNING`
- offline uncorrectable > 0 -> `WARNING`
- crescimento de setores realocados comparado ao relatório anterior -> `WARNING`
- falha em self-test -> `CRITICAL`

Não declarar automaticamente que um HDD está condenado apenas por um único atributo sem contexto. Registrar os dados objetivos.

### Etapa C — SMART Long/Extended Self-Test

Por padrão, perguntar:

```text
Executar SMART Long/Extended Self-Test? [S/N]
```

Opcionalmente permitir configuração para sempre executar.

O teste deve ser iniciado via `smartctl` usando Long/Extended Self-Test.

O script deve:

1. iniciar o teste;
2. detectar estimativa de duração, quando fornecida;
3. exibir status;
4. aguardar;
5. consultar periodicamente o progresso;
6. permitir cancelamento pelo usuário sem corromper dados;
7. ao terminar, consultar o log do self-test;
8. registrar resultado.

Não iniciar checksum/leitura massiva simultaneamente com o Long Self-Test.

## 9. Verificação do sistema de arquivos

A verificação deve ser **somente leitura/não destrutiva por padrão**.

Para NTFS, pode ser utilizado mecanismo de scan online apropriado do Windows.

Se o filesystem não suportar o método escolhido:

- registrar como `SKIPPED`;
- não executar reparo automático;
- continuar para a etapa seguinte quando seguro.

Nunca corrigir automaticamente inconsistências.

Se forem encontradas inconsistências:

```text
WARNING: foram encontradas inconsistências no sistema de arquivos.
Nenhuma correção automática foi executada.
```

## 10. Integridade por checksum

### Algoritmo

Utilizar:

```text
SHA-256
```

### Primeira execução

Se ainda não existir manifesto confiável para o serial do HDD, o script deve informar:

```text
Nenhum manifesto anterior foi encontrado.

Esta execução pode criar uma LINHA DE BASE de checksums.
Ela não comprova que os arquivos já estavam íntegros antes de hoje.
```

Solicitar confirmação para criar a baseline.

### Execuções posteriores

Para cada arquivo do escopo:

1. localizar entrada no manifesto;
2. calcular SHA-256 atual;
3. comparar;
4. classificar:

```text
OK
MODIFIED
MISSING
NEW
ERROR
```

### Importante

Arquivos alterados legitimamente depois da baseline também resultarão em hash diferente.

Portanto, o script não deve escrever automaticamente `CORROMPIDO` apenas por um hash diferente.

Deve informar:

```text
CHECKSUM MISMATCH
```

## 11. Local do manifesto

O manifesto principal **não deve existir somente no HDD verificado**.

Armazenar no computador principal, por exemplo:

```text
%ProgramData%\HddIntegrity\manifests\<SERIAL>\
```

ou, para execução sem instalação:

```text
.\manifests\<SERIAL>\
```

Formato sugerido:

```text
manifest.jsonl
```

Cada entrada:

```json
{
  "relativePath": "Fotos/2019/img001.jpg",
  "size": 5849201,
  "lastWriteTimeUtc": "2026-08-13T12:00:00Z",
  "sha256": "..."
}
```

Opcionalmente manter uma cópia do manifesto dentro do próprio HDD em `.hdd-integrity/`, mas essa cópia é apenas redundante. A referência principal permanece fora do disco.

## 12. Escopo dos arquivos

Suportar dois modos.

### Modo padrão

Verificar todos os arquivos da unidade, exceto diretórios técnicos configuráveis.

Exclusões padrão sugeridas:

```text
$RECYCLE.BIN
System Volume Information
.hdd-integrity/temp
```

Não excluir arquivos do usuário silenciosamente.

### Modo configurável

Permitir `config.json`:

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
  ]
}
```

## 13. Performance

Como HDDs podem possuir muitos TB:

- processar arquivos em streaming;
- não carregar a lista completa de hashes em memória sem necessidade;
- gravar progresso periodicamente;
- suportar retomada futura como melhoria;
- exibir arquivos processados, bytes processados, percentual estimado, taxa de leitura e tempo decorrido;
- não executar hashes em paralelo agressivamente em um único HDD mecânico.

O padrão deve favorecer leitura sequencial e estabilidade.

## 14. Relatório final

Criar relatório legível e também versão estruturada.

Sugestão:

```text
reports/
└── <SERIAL>/
    ├── 2026-08-13_093600.json
    └── 2026-08-13_093600.txt
```

Resumo:

```text
============================================================
HDD BACKUP INTEGRITY CHECK
============================================================

Unidade:       E:
Modelo:        ST8000VN004
Serial:        XXXXXXXX
Capacidade:    8 TB

SMART:         OK
Long Test:     PASSED
Filesystem:    OK

Checksum:
  Verificados: 184392
  OK:          184392
  Mismatch:    0
  Missing:     0
  Erros:       0

Resultado geral: OK

Início:        13/08/2026 09:36
Fim:           13/08/2026 18:42
============================================================
```

## 15. Etapa de desligamento DEVE ser separada

Esta é uma exigência funcional.

Depois que todas as verificações terminarem, **não colocar o disco offline automaticamente**.

Mostrar primeiro o resultado.

Depois perguntar:

```text
Deseja preparar o HDD para desligamento físico agora? [S/N]:
```

### Se responder N

```text
O HDD permanecerá ONLINE.
Nenhuma alteração foi feita no estado do disco.
```

Encerrar.

### Se responder S

Executar uma segunda confirmação contendo identificação completa:

```text
Você está prestes a colocar OFFLINE:

Unidade : E:
Disco   : 4
Modelo  : ST8000VN004
Serial  : XXXXXXXX

Confirma? [S/N]:
```

Somente após `S`:

1. verificar novamente se letra -> disco -> serial continuam correspondendo;
2. garantir que não seja disco de sistema;
3. tentar sincronizar/encerrar acessos possíveis;
4. colocar o **disco físico** offline com `Set-Disk -Number <N> -IsOffline $true`;
5. confirmar que `IsOffline == True`.

Resultado esperado:

```text
============================================================
DISCO OFFLINE COM SUCESSO
============================================================

HDD: ST8000VN004
Serial: XXXXXXXX

O Windows não está mais usando este disco.

>>> AGORA VOCÊ PODE DESLIGAR O HDD NO CONTROLADOR FÍSICO. <<<
============================================================
```

Se `Set-Disk` falhar, **não dizer que é seguro desligar**.

## 16. Recuperação na próxima vez

Quando o HDD for fisicamente ligado novamente, ele pode continuar marcado como Offline no Windows.

O script deve detectar isso.

Ao listar discos offline elegíveis, oferecer:

```text
O disco BACKUP-01 está OFFLINE no Windows.
Deseja colocá-lo ONLINE para iniciar a verificação? [S/N]
```

Depois de confirmação explícita:

```powershell
Set-Disk -Number <N> -IsOffline $false
```

Nunca colocar discos online indiscriminadamente.

## 17. Argumentos opcionais

Mesmo sendo interativo, permitir automação futura:

```powershell
.\hdd-integrity-check.ps1
```

Modo normal interativo.

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E
```

Pré-seleciona `E:` mas ainda solicita confirmação.

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -SkipLongTest
```

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -ChecksumOnly
```

```powershell
.\hdd-integrity-check.ps1 -DriveLetter E -SmartOnly
```

Nenhum parâmetro deve permitir pular as proteções contra disco de sistema.

## 18. Logging

Toda operação relevante deve ser registrada.

Exemplo:

```text
2026-08-13 09:36:02 INFO  Selected drive E:
2026-08-13 09:36:03 INFO  Physical disk 4 serial XXXXXXXX
2026-08-13 09:36:04 INFO  SMART device matched by serial
2026-08-13 09:36:05 INFO  SMART overall-health PASSED
2026-08-13 09:37:01 INFO  Long self-test started
```

## 19. Tratamento de erros

O script deve usar `try/catch` e códigos de saída consistentes.

Sugestão:

```text
0  = OK
1  = Warning/integrity issue
2  = SMART critical
3  = Checksum mismatch
4  = Filesystem warning
10 = Invalid selection
11 = Unsafe/system disk
12 = SMART device mapping failure
20 = Dependency missing
30 = User cancelled
40 = Disk disappeared
50 = Offline operation failed
```

Um erro em uma etapa não deve ser ocultado.

## 20. Resultado geral

Classificação final:

```text
OK
WARNING
CRITICAL
INCOMPLETE
```

### OK

- SMART sem alertas relevantes;
- Long Test passou ou foi explicitamente pulado;
- filesystem sem erro;
- checksums válidos.

### WARNING

Exemplos:

- setores pendentes;
- crescimento de realocados;
- filesystem reportou problema;
- arquivos novos/missing;
- teste opcional pulado.

### CRITICAL

Exemplos:

- SMART overall-health falhou;
- Long Self-Test falhou;
- checksum mismatch em arquivo existente;
- erro irrecuperável de leitura.

### INCOMPLETE

- usuário cancelou;
- HDD desconectado;
- dependência ausente;
- alguma etapa obrigatória não pôde ser executada.

## 21. Requisitos de UX

A interface CLI deve usar cores apenas como complemento.

Nunca depender exclusivamente de cor.

Exemplo:

```text
[OK]       SMART aprovado
[WARNING]  2 setores pendentes
[ERROR]    1 checksum divergente
[SKIPPED]  Long Test não executado
```

Mostrar sempre modelo + serial antes de qualquer ação que altere o estado do disco.

## 22. Segurança contra unidade errada

Antes do `Set-Disk -IsOffline $true`, repetir a resolução:

```text
DriveLetter -> Partition -> Disk -> Serial
```

Comparar com o serial capturado no início.

Se for diferente, **ABORTAR IMEDIATAMENTE**.

Isso protege contra troca de letras ou mudanças de hardware durante uma execução longa.

## 23. Não objetivos da primeira versão

Não implementar inicialmente:

- GUI;
- serviço do Windows;
- monitoramento em background;
- controle eletrônico dos botões do painel;
- RAID;
- sincronização automática de backup;
- correção automática de arquivos;
- reparo automático de filesystem;
- deleção automática de arquivos;
- atualização automática de firmware;
- SMART simultâneo em vários HDDs.

Primeiro entregar uma CLI PowerShell confiável.

## 24. Critérios de aceitação

A implementação só deve ser considerada concluída quando:

- [ ] lista corretamente unidades disponíveis;
- [ ] aceita seleção manual por índice ou letra;
- [ ] resolve corretamente volume -> disco físico;
- [ ] mostra modelo e serial antes de iniciar;
- [ ] bloqueia disco de sistema;
- [ ] encontra `smartctl`;
- [ ] associa SMART ao HDD pelo serial, não pela letra;
- [ ] coleta SMART;
- [ ] consegue iniciar e acompanhar Long Self-Test;
- [ ] não faz Long Test e checksum pesado simultaneamente;
- [ ] executa verificação não destrutiva de filesystem;
- [ ] cria baseline SHA-256;
- [ ] compara checksums em execuções futuras;
- [ ] gera relatório TXT;
- [ ] gera relatório JSON;
- [ ] persiste histórico por serial;
- [ ] pergunta separadamente se o usuário deseja preparar o HDD para desligamento;
- [ ] exige segunda confirmação antes de colocar offline;
- [ ] revalida o serial antes do offline;
- [ ] executa `Set-Disk -IsOffline $true`;
- [ ] somente diz "pode desligar" depois de confirmar `IsOffline=True`;
- [ ] consegue reconhecer posteriormente esse disco offline e oferecer colocá-lo online;
- [ ] nenhuma operação destrutiva é executada automaticamente.

## 25. Fluxo completo esperado

```text
USUÁRIO
  │
  ├─ liga fisicamente HDD desejado
  │
  ▼
SCRIPT
  │
  ├─ lista unidades
  │
  ├─ usuário escolhe E:
  │
  ├─ identifica disco físico
  │
  ├─ confirma modelo + serial
  │
  ├─ SMART inicial
  │
  ├─ SMART Long Test
  │
  ├─ filesystem scan
  │
  ├─ checksum / comparação
  │
  ├─ relatório
  │
  ▼
RESULTADO
  │
  └─ "Deseja preparar para desligamento?"
             │
       ┌─────┴─────┐
       │           │
      NÃO         SIM
       │           │
   permanece      confirma novamente
    online         │
                   ▼
             Set-Disk Offline
                   │
                   ▼
              valida Offline
                   │
                   ▼
          "PODE DESLIGAR O HDD"
                   │
                   ▼
               USUÁRIO
        desliga botão físico
```

## 26. Prioridade de implementação

Ordem recomendada:

1. seleção manual da unidade;
2. resolução segura para disco físico;
3. bloqueios de segurança;
4. identificação SMART por serial;
5. relatório SMART;
6. ação offline separada e segura;
7. baseline SHA-256;
8. comparação de checksum;
9. filesystem scan;
10. Long Self-Test + polling;
11. histórico e relatórios;
12. melhorias de UX.

A primeira entrega funcional deve priorizar **segurança e identificação correta do HDD**, não estética.

## 27. Regra final para o agente implementador

O script trabalha com discos contendo backups importantes.

Quando houver dúvida entre:

```text
continuar automaticamente
```

e:

```text
abortar e pedir ação explícita do usuário
```

escolher sempre a segunda opção.

Nenhuma conveniência justifica executar ação potencialmente perigosa sobre um disco cuja identidade não tenha sido confirmada.
