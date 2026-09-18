# T002 — Simplificar o VM Manager para fluxo de appliance

Status: `[-]` em andamento — implementação parcial; validação da imagem OpenCore pendente

Dependência: **T001** deve estar implementada ou disponível para integração.

## Objetivo

Transformar `scripts/reims-vm-manager.sh` no provisionador de uma única instalação macOS principal, escondendo opções internas que não fazem parte da experiência do Reims OS.

## Resultado esperado

No primeiro boot, o usuário deve escolher apenas:

1. macOS Ventura, Sonoma ou Sequoia;
2. quantidade de CPUs;
3. memória RAM;
4. tamanho do disco, mínimo 70 GiB.

Ao terminar a preparação, o macOS deve iniciar automaticamente com `reims-vgpu-pci`, sem perguntar se o usuário deseja ativar Reims.

## Escopo

- limitar a lista de versões a `ventura`, `sonoma` e `sequoia`;
- remover a pergunta de nome da VM;
- gerar um identificador interno aleatório e persistível, por exemplo `reims-<8+ caracteres>`;
- remover a escolha interativa de SMBIOS;
- usar um único SMBIOS interno/configurável e documentado, sem exposição no wizard;
- manter validação de CPU/RAM e margem reservada ao host;
- manter disco mínimo de 70 GiB;
- reaproveitar download do OSX-KVM, chunklist, `dmg2img`, `qemu-img` e geração de identidade/OpenCore existentes;
- iniciar Reims automaticamente após o provisionamento;
- integrar com o modo persistente criado em T001;
- durante a instalação, iniciar o launcher com política de reboot que mantenha o mesmo processo QEMU/janela vivo entre os reboots normais do instalador (equivalente a `QEMU_REBOOT_ACTION=reset`);
- impedir sobrescrita acidental de uma instalação existente;
- gerar um `OpenCore.qcow2` realmente personalizado para a VM, contendo o `EFI/OC/config.plist` gerado para aquela identidade;
- configurar OpenCore para permitir seleção padrão persistente e boot automático do sistema instalado;
- preservar a flexibilidade necessária aos estágios intermediários `Recovery`, `macOS Installer` e Preboot durante a instalação;
- estruturar o provisionamento em etapas observáveis, emitindo progresso/estado consumível pela futura UI sem expor logs técnicos ao usuário.

## Fora de escopo

- fullscreen nativo, tratado em T003;
- schema definitivo de `/var/lib/reims/state.json`, tratado em T004;
- systemd/first boot automático;
- updater;
- ISO;
- suporte Tahoe;
- múltiplas VMs simultâneas.

## Requisitos de implementação

1. O menu principal da 0.1.0 deve ter somente o fluxo `Instalar macOS`.
2. A lista visível deve conter exatamente Ventura, Sonoma e Sequoia.
3. `NAME` não pode mais ser solicitado ao usuário.
4. O identificador interno deve ser gerado automaticamente, ser válido para uso como diretório/rail e ter risco desprezível de colisão.
5. Se houver colisão com diretório/estado existente, gerar outro ID em vez de sobrescrever.
6. O usuário não deve escolher SMBIOS. O modelo interno escolhido deve ficar explícito no código/configuração e registrado nos artefatos da VM.
7. A identidade gerada pelo `osx-serial-generator` deve continuar sendo única por instalação.
8. CPU, RAM e disco devem ser validados antes de download/build pesado.
9. O disco não pode aceitar valor inferior a 70 GiB.
10. Não perguntar `Iniciar com Reims agora?`; o fluxo deve seguir automaticamente.
11. O dispositivo gráfico do fluxo de produto deve ser `reims-vgpu-pci`.
12. O provisionamento não pode modificar a imagem OpenCore compartilhada do projeto.
13. Um erro deve encerrar com mensagem clara e sem deixar uma instalação marcada como pronta.
14. Não remover capacidades de desenvolvimento necessárias aos testes do repositório sem justificar e documentar.
15. Enquanto a instalação estiver em andamento, reboots normais do guest não podem fechar a janela/QEMU nem exigir relançamento manual; o fluxo deve continuar automaticamente no mesmo storage persistente.
16. A política de reboot da fase de instalação não deve ser confundida com a política pós-instalação de T007.
17. O `config.plist` gerado deve ser gravado dentro da partição EFI do `OpenCore.qcow2` dedicado; um plist externo/orfão não satisfaz o requisito.
18. A imagem OpenCore final deve ser validada por inspeção read-only, comprovando pelo menos `EFI/BOOT/BOOTX64.EFI`, `EFI/OC/OpenCore.efi` e `EFI/OC/config.plist`.
19. O config final deve habilitar `Misc.Security.AllowSetDefault=true` e preservar `UEFI.Quirks.RequestBootVarRouting=true` quando disponível na base.
20. Durante `installing`, a configuração não pode forçar permanentemente o volume final e impedir os boots temporários do instalador.
21. Depois que a instalação for marcada `installed`, o próximo boot deve selecionar automaticamente o volume macOS principal sem exigir interação do usuário.
22. O picker/recovery deve continuar acessível por mecanismo de recuperação documentado, mesmo com autoboot normal.
23. Operações longas do manager devem possuir fases identificáveis e emitir estado estruturado suficiente para exibir etapa atual e tempo decorrido.
24. Percentual só deve ser emitido quando houver métrica real. Processos como build sem progresso quantificável devem suportar estado indeterminado.
25. Logs detalhados devem permanecer separados da saída amigável/estruturada de progresso.

## Critérios de aceitação

### Estático

- `bash -n scripts/reims-vm-manager.sh` passa;
- não existem prompts interativos para nome, SMBIOS ou confirmação de Reims;
- Tahoe e versões pré-Ventura não aparecem no menu de produto;
- o mínimo de 70 GiB continua validado.

### Provisionamento controlado

Executar com diretórios temporários/dedicados sempre que possível e provar que:

1. um ID interno foi gerado automaticamente;
2. o diretório da VM usa esse ID;
3. identidade OpenCore foi gerada;
4. disco recebeu o tamanho solicitado;
5. versão selecionada corresponde ao artefato baixado/preparado;
6. ao final o launcher é chamado automaticamente com `reims-vgpu-pci` e modo persistente;
7. uma segunda execução não sobrescreve silenciosamente a primeira instalação;
8. um reboot do instalador mantém o mesmo QEMU/sessão ativo e continua usando os mesmos discos persistentes, sem intervenção manual do usuário;
9. a inspeção read-only do `OpenCore.qcow2` comprova que o `config.plist` personalizado está realmente dentro da imagem;
10. após instalação concluída, rebootar a VM sem interação no picker inicia o volume macOS instalado automaticamente;
11. Recovery/picker continua acessível pelo mecanismo de recuperação escolhido.

### Segurança

- nenhuma VM/snapshot/golden existente deve ser alterada durante a validação;
- nenhum broad `pkill`;
- nenhum `qemu-img commit` destrutivo;
- downloads e arquivos intermediários devem permanecer isolados na VM criada.

## Evidência para concluir

Registrar nesta task:

- commit/PR;
- arquivos alterados;
- modelo SMBIOS interno adotado e justificativa;
- exemplo do ID gerado;
- comandos de validação;
- saída resumida dos testes;
- prova de que o launcher final usa `reims-vgpu-pci` e persistência;
- confirmação de que uma instalação existente não foi sobrescrita.

## Implementação parcial em validação

Branch local:

```text
feat/t002-vm-manager-appliance
```

HEAD reportado mais recente:

```text
4efae714
```

Commits reportados:

```text
df4a3397 feat(appliance): simplify VM manager flow [T002]
c4bcd075 fix(appliance): stage OpenCore builder per VM
ff2cb676 fix(appliance): stage OpenCore sources outside builder workdir
81183c22 fix(appliance): copy staged OpenCore EFI into image
4efae714 fix(appliance): complete T002 controlled validation
```

Arquivos alterados:

```text
scripts/reims-vm-manager.sh
tests/t002-vm-manager.sh
```

Resultados já reportados:

```text
STATIC_TESTS=PASS
CONTROLLED_TESTS=PASS
INSTALLER_LAYOUT=PASS
OVERWRITE_PROTECTION=PASS
LAUNCHER_TEST=PASS
OPENCORE_IMAGE_TEST=PENDING
RUNTIME_INSTALL_REBOOT=PENDING_RUNTIME_VALIDATION
RUNTIME_AUTOBOOT=PENDING_RUNTIME_VALIDATION
RUNTIME_RECOVERY=PENDING_RUNTIME_VALIDATION
```

O fluxo reportado já contém wizard reduzido, ID automático, storage persistente, launch com `--persistent --device reims-vgpu-pci` e `QEMU_REBOOT_ACTION=reset`.

A T002 não pode ser aprovada ainda. Antes da validação runtime é obrigatório gerar uma imagem OpenCore descartável e comprovar, por inspeção read-only, que a imagem final contém `EFI/BOOT/BOOTX64.EFI`, `EFI/OC/OpenCore.efi` e o `EFI/OC/config.plist` personalizado com os campos exigidos.

Também deve ser reconciliado o path efetivo da mídia de instalação: o layout reportado lista `<vm>/<version>.img`, enquanto a chamada de launch reportada usa `<vm>/installer/<version>.img`. O código e os testes devem usar um contrato único.

### Builder OpenCore — diagnóstico complementar

A validação controlada chegou a `guestfish 1.60.1` e `libguestfs-test-tool=PASS`, portanto o bloqueio não deve ser atribuído genericamente ao libguestfs.

Foi identificado no upstream `osx-serial-generator` que o fluxo nativo de criação de bootdisk usado por `generate-unique-machine-values.sh` chama `opencore-image-ng.sh` quando `--create-bootdisks`/`--output-bootdisk` é usado. Esse builder usa um diretório temporário próprio e espera, ao lado do script, a árvore `EFI` e `resources/OcBinaryData/Resources`, além de `startup.nsh` no diretório de execução.

A variante `opencore-image-ng-linux.sh` usa contrato `.fish` diferente e está introduzindo complexidade adicional no staging atual. Antes de adicionar novos workarounds, T002 deve validar o uso do builder padrão `opencore-image-ng.sh` (ou o fluxo nativo `--output-bootdisk`) em staging privado por VM, mantendo a imagem compartilhada intacta.

O objetivo continua sendo gerar uma imagem dedicada e então executar `qemu-img check` + inspeção read-only de `EFI/BOOT/BOOTX64.EFI`, `EFI/OC/OpenCore.efi` e `EFI/OC/config.plist`.

## OpenCore dedicado — validação controlada PASS

Implementação reportada em:

```text
branch: feat/t002-vm-manager-appliance
HEAD: 04d34e53
commit: 04d34e53 fix(appliance): finalize per-VM OpenCore image build
```

Builder selecionado:

```text
third_party/osx-serial-generator/generate-specific-bootdisk.sh
→ third_party/osx-serial-generator/opencore-image-ng.sh
```

Fixture exclusiva:

```text
/home/felipeab10/Documentos/reims-t002-fixtures/opencore
```

Resultados reportados:

```text
OPENCORE_BUILD=PASS
QEMU_IMG_INFO=PASS
QEMU_IMG_CHECK=PASS
OPENCORE_BOOTX64=PASS
OPENCORE_EFI=PASS
OPENCORE_CONFIG=PASS
CONFIG_IMAGE_MATCH=PASS
SHOW_PICKER=PASS
PICKER_MODE=PASS
TIMEOUT=PASS
ALLOW_SET_DEFAULT=PASS
REQUEST_BOOT_VAR_ROUTING=PASS
IDENTITY_IN_IMAGE=PASS
SHARED_OPENCORE_UNCHANGED=PASS
INSTALLER_LAYOUT=PASS
OVERWRITE_PROTECTION=PASS
LAUNCHER_TEST=PASS
STATIC_TESTS=PASS
CONTROLLED_TESTS=PASS
```

A inspeção final foi read-only via `guestfish --ro`, com descoberta de partições/filesystems e extração do `EFI/OC/config.plist`. O plist extraído foi semanticamente equivalente ao plist gerado e, nessa execução, também byte-identical.

A pendência estática remanescente é pequena: a fase `build_opencore` já emite `running` e `completed`, porém `failed` ainda não é garantido em todos os caminhos de erro do builder. Antes do runtime completo, fechar esse contrato e garantir que stdout/stderr técnico do builder possa ser capturado em log separado da saída amigável.

Pendências runtime continuam:

```text
RUNTIME_INSTALL_REBOOT=PENDING_RUNTIME_VALIDATION
RUNTIME_AUTOBOOT=PENDING_RUNTIME_VALIDATION
RUNTIME_RECOVERY=PENDING_RUNTIME_VALIDATION
```

## Histórico

Nenhuma implementação validada ainda.
