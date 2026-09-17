#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OSX_KVM="${OSX_KVM:-$ROOT/third_party/OSX-KVM}"
WORK_ROOT="${REIMS_VM_WORK_ROOT:-$HOME/.local/share/reims-vgpu/vms}"
RAILS_DIR="${RAILS_DIR:-$ROOT/vm/disks/rails}"
PERSIST_MODE="${REIMS_PERSIST_MODE:-capture}"
RESERVE_CORES="${REIMS_RESERVE_CORES:-2}"; RESERVE_RAM="${REIMS_RESERVE_RAM_GB:-4}"
die(){ echo "ERRO: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || missing+=("$1"); }
preflight(){ missing=(); for x in bash python3 cargo qemu-img dmg2img pkg-config llvm-dis spirv-val guestfish uuidgen curl make; do need "$x"; done; [[ -d "$OSX_KVM" ]]||missing+=(OSX-KVM); [[ -d "$ROOT/third_party/osx-serial-generator" ]]||missing+=(osx-serial-generator); [[ -r /dev/kvm ]]||missing+=(/dev/kvm); [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]||missing+=(graphical-session); hc=$(nproc); hr=$(awk '/MemTotal:/{printf "%d",$2/1024/1024}' /proc/meminfo); echo "HOST: $hc CPUs, $hr GiB RAM; reserve $RESERVE_CORES CPUs/$RESERVE_RAM GiB"; ((hc>RESERVE_CORES&&hr>RESERVE_RAM))||missing+=(host-margin); if ((${#missing[@]})); then printf 'REQUISITOS AUSENTES:\n - %s\n' "${missing[@]}"; return 1; fi; HOST_CORES=$((hc-RESERVE_CORES)); HOST_RAM=$((hr-RESERVE_RAM)); }
choose(){ local o=(high-sierra mojave catalina big-sur monterey ventura sonoma sequoia tahoe); select VERSION in "${o[@]}"; do [[ -n "$VERSION" ]]&&break; done; case "$VERSION" in high-sierra|mojave|catalina|big-sur|sonoma|sequoia) OS_TYPE=default;;*) OS_TYPE=latest;;esac; }
resources(){ read -r -p 'Nome [tahoe-vgpu]: ' NAME; NAME=${NAME:-tahoe-vgpu}; echo 'SMBIOS:'; select SMBIOS_MODEL in iMacPro1,1 MacPro7,1 iMac20,1; do [[ -n "$SMBIOS_MODEL" ]]&&break; done; read -r -p "CPUs [$HOST_CORES]: " CORES; CORES=${CORES:-4}; read -r -p "RAM GiB [$HOST_RAM]: " RAM; RAM=${RAM:-8}; read -r -p 'Disco GiB [mínimo 70]: ' DISK; DISK=${DISK:-70}; [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]||die name; ((CORES>0&&CORES<=HOST_CORES&&RAM>=2&&RAM<=HOST_RAM&&DISK>=70))||die resources; }
verify(){ python3 - "$1" "$2" <<'PY'
import hashlib,struct,sys
p,c=sys.argv[1:]; b=open(c,'rb').read(); H=struct.Struct('<4sIBBBxQQQ'); C=struct.Struct('<I32s'); m,hs,v,cm,sig,n,o,so=H.unpack_from(b); assert (m,hs,v,cm,sig)==(b'CNKL',36,1,1,1); f=open(p,'rb')
for i in range(n): z,w=C.unpack_from(b,o+i*C.size); assert hashlib.sha256(f.read(z)).digest()==w
assert f.read(1)==b''
PY
}
generate_opencore(){ base=$1; sw="$base/serial-work"; mkdir -p "$sw" "$base/serial"; ln -sfn "$ROOT/third_party/osx-serial-generator/opencore-image-ng-linux.sh" "$sw/opencore-image-ng.sh"; ln -sfn "$OSX_KVM/OpenCore" "$sw/OpenCore"; mkdir -p "$sw/resources/OcBinaryData"; cp -a "$OSX_KVM/OpenCore/EFI/OC/Resources" "$sw/resources/OcBinaryData/Resources"; (cd "$sw" && bash "$ROOT/third_party/osx-serial-generator/generate-unique-machine-values.sh" --count 1 --model "$SMBIOS_MODEL" --width 1920 --height 1080 --output-dir "$base/serial" --master-plist "$ROOT/third_party/osx-serial-generator/config-custom.plist" --create-envs --create-plists); generated=$(find "$base/serial/plists" -type f -name '*.plist' -print -quit); [[ -n "$generated" ]]||die plist; cp "$generated" "$base/serial/config-auto.plist"; python3 - "$base/serial/config-auto.plist" <<'PY'
import plistlib,sys,tempfile,os
path=sys.argv[1]; data=open(path,'rb').read(); start=data.find(b'<?xml'); assert start>=0
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path)); os.close(fd); open(tmp,'wb').write(data[start:]); p=plistlib.load(open(tmp,'rb')); p.setdefault('Misc',{}).setdefault('Boot',{}).update(ShowPicker=True,Timeout=5,PickerMode='Builtin'); plistlib.dump(p,open(path,'wb'),sort_keys=False); os.unlink(tmp)
PY
cp --reflink=auto "$OSX_KVM/OpenCore/OpenCore.qcow2" "$base/OpenCore.qcow2"; printf 'model=%s\nplist=%s\n' "$SMBIOS_MODEL" "$generated" > "$base/serial-generator.txt"; }
prepare(){ base="$WORK_ROOT/$NAME"; mkdir -p "$base" "$RAILS_DIR/$NAME/snapshots"; d="$base/$VERSION.dmg"; c="$base/$VERSION.chunklist"; m="$base/$VERSION.img"; disk="$base/macos.img"; if [[ ! -f "$d" || ! -f "$c" ]]; then python3 "$OSX_KVM/fetch-macOS-v2.py" --action download --shortname "$VERSION" --os-type "$OS_TYPE" --outdir "$base" --basename "$VERSION" || true; fi; [[ -f "$d"&&-f "$c" ]]||die download; verify "$d" "$c"; [[ -f "$m" ]]||dmg2img -i "$d" "$m"; [[ -f "$disk" ]]||qemu-img create -f qcow2 "$disk" "${DISK}G"; [[ -f "$base/OVMF_VARS.fd" ]]||cp --reflink=auto "$OSX_KVM/OVMF_VARS-1920x1080.fd" "$base/OVMF_VARS.fd"; [[ -f "$base/OpenCore.qcow2" ]]||generate_opencore "$base"; read -r -p 'Iniciar com Reims agora? [s/N] ' ok; [[ "$ok" =~ ^[sS]$ ]]||exit 0; port=$((2222+($(printf '%s' "$NAME"|cksum|awk '{print $1}')%1000))); while ss -ltn 2>/dev/null|grep -q ":$port "; do port=$((port+1)); done; run="$base/run"; mkdir -p "$run"; export REIMS_VGPU_BACKEND=vulkan DISPLAY_REFRESH_HZ=60 QEMU_REBOOT_ACTION=reset SSH_PORT="$port" RUN_DIR="$run" DISKS_DIR="$base" DISK_MASTER="$disk" OPENCORE_MASTER="$base/OpenCore.qcow2" OVMF_VARS_MASTER="$base/OVMF_VARS.fd" INSTALL_MEDIA="$m" RAM="${RAM}G" CPU_CORES="$CORES" CPU_THREADS="$CORES" RAILS_DIR="$RAILS_DIR"; if [[ "$PERSIST_MODE" == capture ]]; then "$ROOT/vm/boot-x86.sh" --capture --device reims-vgpu-pci --rail "$NAME"; else "$ROOT/vm/boot-x86.sh" --interactive --device reims-vgpu-pci --rail "$NAME"; fi; }
preflight; echo '1) Instalar macOS'; read -r -p 'Escolha [1]: ' q; [[ "$q" == 1 ]]||exit 0; choose; resources; prepare
