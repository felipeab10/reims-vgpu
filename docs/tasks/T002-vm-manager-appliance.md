# T002 — Simplificar o VM Manager para fluxo de appliance

Status: `[ ]` não iniciada

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
- impedir sobrescrita acidental de uma instalação existente.

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
8. um reboot do instalador mantém o mesmo QEMU/sessão ativo e continua usando os mesmos discos persistentes, sem intervenção manual do usuário.

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

## Histórico

Nenhuma implementação validada ainda.
