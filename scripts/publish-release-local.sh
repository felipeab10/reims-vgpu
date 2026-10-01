#!/usr/bin/env bash
# scripts/publish-release-local.sh
# Empacota os binários pré-compilados locais e publica um Release no GitHub via gh CLI.
set -euo pipefail

TAG="${1:-v1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "▶ Empacotando binários locais do Reims vGPU para release $TAG..."
DIST_TMP="$(mktemp -d)"
trap 'rm -rf "$DIST_TMP"' EXIT

mkdir -p "$DIST_TMP/vendor/qemu/build"
mkdir -p "$DIST_TMP/crates/reims-vgpu-efi/out"
mkdir -p "$DIST_TMP/vm/ovmf"

cp -a "$REPO_ROOT/vendor/qemu/build/qemu-system-x86_64" "$DIST_TMP/vendor/qemu/build/"
cp -a "$REPO_ROOT/vendor/qemu/pc-bios" "$DIST_TMP/vendor/qemu/"
cp -a "$REPO_ROOT/crates/reims-vgpu-efi/out/reims-vgpu-gop.rom" "$DIST_TMP/crates/reims-vgpu-efi/out/"
cp -a "$REPO_ROOT/vm/ovmf/"* "$DIST_TMP/vm/ovmf/"
cp -a "$REPO_ROOT/vm/boot-x86.sh" "$DIST_TMP/vm/"

TAR_OUT="/tmp/reims-vgpu-linux-x86_64.tar.gz"
tar -czf "$TAR_OUT" -C "$DIST_TMP" .
sha256sum "$TAR_OUT" > "$TAR_OUT.sha256"

echo "✔ Pacote gerado: $TAR_OUT ($(du -h "$TAR_OUT" | cut -f1))"
echo "▶ Publicando Release $TAG no repositório felipeab10/reims-vgpu..."

gh release create "$TAG" "$TAR_OUT" "$TAR_OUT.sha256" \
  --repo felipeab10/reims-vgpu \
  --title "Reims vGPU $TAG (x86_64 Linux)" \
  --notes "Binários pré-compilados do Reims vGPU (QEMU com backend Vulkan + ROM UEFI GOP)."

echo "✔ Release $TAG publicada com sucesso no GitHub!"
