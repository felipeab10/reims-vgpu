# T001 — Implementar modo persistente no launcher

Status: `[-]` em andamento — implementação publicada, revisão solicitou ajustes

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

Arquivo alterado:

```text
vm/boot-x86.sh
```

A implementação adicionou `--persistent`, `PERSISTENT_DIR`, resolução direta de `macos.qcow2`, `OpenCore.qcow2` e `OVMF_VARS.fd`, serial em arquivo e preservação do QMP.

### Revisão 1 — CHANGES_REQUESTED

O commit ainda não pode ser validado como concluído.

#### Bloqueador: estado duplicado `BOOT_CLASS` x `IS_PERSISTENT`

`--persistent` define simultaneamente:

```text
BOOT_CLASS=persistent
IS_PERSISTENT=1
```

mas `--testing`, `--interactive`, `--capture` e o `--snapshot` sem label alteram `BOOT_CLASS` sem necessariamente limpar `IS_PERSISTENT`.

Isso quebra a semântica de “última classe informada vence” e pode misturar modos. Exemplos:

```text
--persistent --interactive
```

pode terminar com `BOOT_CLASS=interactive` usando storage persistente write-through.

```text
--persistent --capture
```

pode usar storage persistente e depois entrar no caminho de promoção de snapshot; `CURRENT` nem é resolvido no ramo persistente.

A correção preferida é ter uma única fonte de verdade para a classe de boot, derivando o comportamento persistente de `BOOT_CLASS=persistent` em vez de manter `IS_PERSISTENT` independente.

#### Ajuste recomendado: combinações inválidas

`--persistent` com `--snapshot LABEL` não deve ignorar silenciosamente o snapshot. Rejeitar a combinação ou definir semântica explícita.

`--list-snapshots` deve continuar sendo uma ação de listagem e nunca iniciar uma VM apenas porque `--persistent` também foi informado.

#### Ajuste recomendado: writability

Além de verificar existência, o preflight do persistent deve verificar que a área e os arquivos que precisam ser graváveis realmente são graváveis pelo usuário que executará QEMU.

#### Ajuste recomendado: par OVMF

O fluxo de snapshots já preserva a relação entre `OVMF_VARS.fd` e um `OVMF_CODE.fd` específico. O modo persistente deve preservar essa propriedade, preferencialmente aceitando `PERSISTENT_DIR/OVMF_CODE.fd` quando presente, sem sobrepor um `OVMF_CODE` explicitamente fornecido pelo ambiente.

### Validação funcional pendente

Ainda não houve boot runtime em guest descartável para provar:

- persistência após shutdown;
- persistência após reboot;
- reutilização dos mesmos discos persistentes.

Até essa validação existir, T001 não pode mudar para `[x]`.

## Histórico

- 2026-09-17 — implementação inicial publicada em `311435ce873666f01284cd36b94ad182b58b819a`.
- 2026-09-17 — revisão estática: `CHANGES_REQUESTED`; task permanece `[-]`.