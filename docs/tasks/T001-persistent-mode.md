# T001 — Implementar modo persistente no launcher

Status: `[!]` bloqueada — implementação aprovada; validação runtime bloqueada no UEFI Interactive Shell

## Objetivo

Adicionar ao fluxo x86 um modo de uso diário que grave diretamente os discos persistentes da VM, sem clone descartável e sem promoção obrigatória de snapshot no shutdown.

## Motivação

Os modos atuais (`--testing`, `--interactive`, `--capture`) foram projetados para desenvolvimento e snapshots imutáveis. O appliance precisa comportar-se como uma máquina normal: alterações feitas no macOS devem permanecer após reboot e shutdown.

## Escopo

Adicionar uma nova classe de boot, conceitualmente:

```bash
vm/boot-x86.sh --persistent
```

Quando usada:

- `macos.qcow2` deve ser aberto diretamente read/write;
- `OpenCore.qcow2` deve ser persistente;
- `OVMF_VARS.fd` deve ser persistente;
- não criar clone temporário para ser descartado;
- não promover snapshot ao final;
- manter QMP e logs;
- preservar os modos existentes sem regressão.

## Fora de escopo

- supervisor de lifecycle do host;
- fullscreen;
- updater;
- ISO;
- mudanças na semântica dos modos existentes.

## Requisitos de implementação

1. Atualizar `usage()` e documentação inline do `vm/boot-x86.sh`.
2. Resolver de forma explícita os paths persistentes usados pelo modo.
3. Evitar qualquer chamada a `discard_clone` no caminho persistente.
4. Não alterar snapshots históricos.
5. Não escrever diretamente em um snapshot marcado como imutável.
6. O modo deve falhar cedo se os arquivos persistentes necessários não existirem.
7. O shutdown limpo do QEMU deve deixar os arquivos intactos e reutilizáveis.
8. QMP e serial/logs devem continuar disponíveis.

## Critérios de aceitação

### Estático

- `bash -n vm/boot-x86.sh` passa.
- Help mostra `--persistent`.
- Modos existentes continuam aceitos.

### Funcional

Em uma VM de teste dedicada:

1. boot em `--persistent`;
2. criar um marcador dentro do guest;
3. shutdown limpo;
4. iniciar novamente em `--persistent`;
5. marcador continua presente.

Repetir com reboot.

### Segurança

- snapshots existentes não são modificados;
- golden/control existentes não são alterados;
- nenhum `qemu-img commit` destrutivo;
- nenhum broad `pkill`.

## Evidência para concluir

Registrar nesta task:

- commit/PR;
- arquivos alterados;
- comandos de teste;
- resultados;
- paths dos discos usados no teste;
- confirmação de persistência após shutdown e reboot.

## Implementação em revisão

Branch:

```text
feat/t001-persistent-mode
```

Commit inicial:

```text
311435ce873666f01284cd36b94ad182b58b819a
```

Commit de correção da revisão:

```text
bb171c33dbee75ab01453173afae9422552a2343
```

Arquivo de código alterado:

```text
vm/boot-x86.sh
```

### Revisão 1 — CHANGES_REQUESTED

Foram encontrados quatro pontos:

- estado duplicado `BOOT_CLASS` x `IS_PERSISTENT`;
- combinação `--persistent --snapshot LABEL` ambígua;
- ausência de validação de writability;
- necessidade de preservar o par `OVMF_CODE.fd`/`OVMF_VARS.fd`.

### Revisão 2 — APPROVED_PENDING_RUNTIME_VALIDATION

O commit `bb171c33dbee75ab01453173afae9422552a2343` corrige os pontos da revisão anterior:

- `BOOT_CLASS` passou a ser a única fonte de verdade;
- o comportamento persistent é derivado de `BOOT_CLASS=persistent`;
- combinações de classes preservam a semântica de “última classe vence”;
- `--persistent --snapshot LABEL` é rejeitado com erro;
- `--list-snapshots` é resolvido antes do caminho persistent e continua saindo sem boot;
- `PERSISTENT_DIR`, `macos.qcow2`, `OpenCore.qcow2` e `OVMF_VARS.fd` são validados como graváveis;
- `PERSISTENT_DIR/OVMF_CODE.fd` é usado quando presente e não há override explícito de `OVMF_CODE`;
- o caminho persistent continua sem `discard_clone` e sem `promote_to_snapshot`.

A revisão de código está aprovada. A task ainda não está concluída porque os critérios funcionais de persistência exigem boot real.

## Runtime recovery/preflight

Ambiente preparado em worktree separado:

```text
/home/felipeab10/Documentos/reims-macos-appliance-runtime
```

Superproject:

```text
bb171c33dbee75ab01453173afae9422552a2343
```

QEMU submodule:

```text
bd88218da09b86ed9c78bf5f9354168812a7ba6b
```

QEMU:

```text
QEMU emulator version 11.0.50
SHA256=e81ab010180f6c0a9d3bb9c45153688b0a49e622314a21a4acbe27ab332d3f32
```

Build oficial executado com sucesso:

```bash
REIMS_VGPU_BACKEND=vulkan \
scripts/qemu-build/qemu-build.sh \
  --target x86_64 \
  --backend vulkan
```

Sanity checks:

- `qemu-system-x86_64 --version` — PASS;
- `-machine help` — PASS;
- `-device help` — PASS;
- `reims-vgpu-pci` — presente;
- `vmware-svga` — presente.

Os submodules em `vendor/qemu/roms/*` ficaram dirty apenas por artefatos do build local; nenhuma alteração de código do superproject foi feita.

### Tentativa runtime 1 — BLOCKED

Fixture dedicada:

```text
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia
```

Persistent storage:

```text
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/persistent
```

Resultado observado:

- download e conversão do instalador Sequoia concluídos;
- disco qcow2 de 80 GiB criado;
- OpenCore e OVMF dedicados criados;
- boot com `--persistent --device reims-vgpu-pci` iniciado;
- instalador e telas de progresso foram observados;
- aproximadamente 11,7 GiB foram gravados no disco persistente;
- os mesmos paths `macos.qcow2`, `OpenCore.qcow2` e `OVMF_VARS.fd` foram reutilizados entre boots;
- QMP funcionou;
- serial funcionou e registrou handoff para XNU;
- snapshots históricos permaneceram intocados;
- Setup Assistant/desktop ainda não foi alcançado.

A solicitação `system_powerdown` via QMP durante o estado de instalação não encerrou o guest no intervalo observado. O QEMU foi posteriormente parado para não deixar a VM ativa. Por isso não existe evidência suficiente para validar persistência após shutdown ou reboot.

Resultado desta rodada:

```text
INSTALL_RESULT=PARTIAL
SHUTDOWN_PERSISTENCE=NOT_TESTED
REBOOT_PERSISTENCE=NOT_TESTED
STORAGE_REUSED=yes
QMP=PASS
SERIAL=PASS
SNAPSHOT_SAFETY=PASS
```

Evidências principais:

```text
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/evidence/validation-summary.txt
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/evidence/baseline.txt
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/evidence/final-state.txt
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/evidence/final-sha256.txt
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/evidence/boot-1-launch.log
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/evidence/boot-2-launch.log
/home/felipeab10/Documentos/reims-t001-fixtures/sequoia/evidence/boot-3-launch.log
```

### Próxima validação obrigatória

Retomar a MESMA fixture, sem recriar discos/OpenCore/OVMF, até alcançar Setup Assistant e desktop funcional.

Depois:

1. criar marcador no guest;
2. shutdown limpo pelo próprio macOS;
3. boot persistent novamente;
4. confirmar marcador;
5. reboot pelo próprio macOS;
6. confirmar marcador novamente;
7. confirmar reutilização dos mesmos paths persistentes;
8. confirmar que snapshots históricos permaneceram inalterados.

Não usar `system_powerdown` como substituto do shutdown funcional do macOS para o critério de aceitação da T001.

Somente após essa evidência T001 pode mudar para `[x]`.



### Tentativa runtime 2 — BLOCKED NO UEFI INTERACTIVE SHELL

A mesma fixture foi reutilizada sem recriar ou regenerar artefatos.

Boot observado:

```text
BdsDxe: starting Boot0002 "UEFI QEMU HARDDISK QM00017"
```

Estado visual final:

```text
UEFI Interactive Shell
```

Resultado:

```text
INSTALL_RESULT=PARTIAL
DESKTOP_REACHED=no
SHUTDOWN_PERSISTENCE=NOT_TESTED
REBOOT_PERSISTENCE=NOT_TESTED
STORAGE_REUSED=yes
QMP=PASS
SERIAL=PASS
SNAPSHOT_SAFETY=PASS
```

O bloqueio atual é de boot da fixture persistente, não uma evidência de falha de persistência. Antes de alterar código ou regenerar OpenCore/OVMF, deve-se determinar:

1. para qual dispositivo/caminho EFI `Boot0002` aponta;
2. se o `OpenCore.qcow2` persistente ainda contém e expõe o bootloader EFI esperado;
3. se o boot retomado anexou a mesma mídia de instalação usada nos boots anteriores;
4. se iniciar manualmente o OpenCore a partir do UEFI Shell permite continuar a instalação;
5. se o `OVMF_VARS.fd` persistente alterou `BootOrder` durante a instalação.

Não regenerar a fixture até concluir esse diagnóstico.

## Histórico

- 2026-09-17 — implementação inicial publicada em `311435ce873666f01284cd36b94ad182b58b819a`.
- 2026-09-17 — revisão 1: `CHANGES_REQUESTED`.
- 2026-09-17 — correções publicadas em `bb171c33dbee75ab01453173afae9422552a2343`.
- 2026-09-18 — revisão 2: `APPROVED_PENDING_RUNTIME_VALIDATION`.
- 2026-09-18 — QEMU customizado reconstruído e sanity checks concluídos; ambiente pronto para fixture Sequoia.
- 2026-09-18 — tentativa runtime 1: instalação Sequoia parcial, storage reutilizado, QMP/serial/snapshot safety PASS; validação de shutdown/reboot bloqueada antes do Setup Assistant.
- 2026-09-18 — tentativa runtime 2: mesma fixture caiu no UEFI Interactive Shell após `Boot0002`; T001 marcada como bloqueada até diagnóstico da cadeia de boot.
