# T001 — Implementar modo persistente no launcher

Status: `[-]` em andamento — revisão de código aprovada; validação runtime pendente

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

### Próxima validação obrigatória

Criar uma fixture Sequoia descartável e executar:

1. boot persistent;
2. criar marcador no guest;
3. shutdown limpo;
4. boot persistent novamente;
5. confirmar marcador;
6. reboot do guest;
7. confirmar marcador novamente;
8. confirmar que os mesmos paths persistentes foram reutilizados;
9. confirmar que snapshots históricos permaneceram inalterados.

Somente após essa evidência T001 pode mudar para `[x]`.

## Histórico

- 2026-09-17 — implementação inicial publicada em `311435ce873666f01284cd36b94ad182b58b819a`.
- 2026-09-17 — revisão 1: `CHANGES_REQUESTED`.
- 2026-09-17 — correções publicadas em `bb171c33dbee75ab01453173afae9422552a2343`.
- 2026-09-18 — revisão 2: `APPROVED_PENDING_RUNTIME_VALIDATION`.
- 2026-09-18 — QEMU customizado reconstruído e sanity checks concluídos; ambiente pronto para fixture Sequoia.
