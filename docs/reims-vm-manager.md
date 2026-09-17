# Reims VM Manager

`scripts/reims-vm-manager.sh` faz preflight do host, lista versões do OSX-KVM, coleta nome/CPU/RAM/disco (mínimo 70 GiB), valida o chunklist Apple, prepara DMG/IMG/QCOW2 e inicia o primeiro boot com `reims-vgpu-pci`. Margem padrão: 2 CPUs e 4 GiB. Durante a preparação, o submódulo `third_party/osx-serial-generator` gera uma identidade única por VM (MLB, ROM, modelo, serial e UUID) e um OpenCore QCOW2 próprio com partição EFI/config.plist; a imagem OpenCore compartilhada nunca é modificada.

## Evolução

O `config.plist` de cada VM usa `Misc.Boot.ShowPicker=true`, `PickerMode=Builtin` e timeout de 5 segundos: após o primeiro reboot, o OpenCore enumera a partição APFS instalada e inicia automaticamente a entrada padrão, mantendo o picker disponível para seleção manual. A configuração portátil preserva `ProvideCurrentCpuInfo`, `AvoidRuntimeDefrag`, `ProvideCustomSlide`, `EnableVectorAcceleration` e `ProvideConsoleGop`; `ResizeAppleGpuBars=-1` fica em modo automático, evitando assumir um tamanho de BAR específico do hardware. O gerenciador valida esse contrato após gerar o plist e recusa iniciar se ele for alterado de forma incompatível. O programa não sobrescreve VMs nem usa pkill amplo.

```bash
./scripts/reims-vm-manager.sh
```
