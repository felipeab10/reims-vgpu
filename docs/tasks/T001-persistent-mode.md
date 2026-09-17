# T001 — Implementar modo persistente no launcher

Status: `[ ]` não iniciada

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

## Histórico

Nenhuma implementação validada ainda.
