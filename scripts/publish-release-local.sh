#!/usr/bin/env bash
# scripts/publish-release-local.sh
#
# ATENÇÃO: este script foi substituído por `scripts/release.sh`.
#
# Ele empacotava à mão e publicava direto, e ficou quebrado quando a árvore
# mudou: 4 dos 5 caminhos que copiava não existem mais —
#
#   vendor/qemu/build/qemu-system-x86_64        (agora é build/bin/qemu-system-x86_64)
#   crates/reims-vgpu-efi/out/reims-vgpu-gop.rom (removido pelo commit 98fe2a3b)
#   vm/ovmf                                      (só existe em algumas árvores)
#   vm/boot-x86.sh                               (idem)
#
# Com `set -e` ele abortava no primeiro `cp`, antes de publicar qualquer coisa.
#
# Pior: mantê-lo vivo criaria um SEGUNDO publicador do mesmo Release, e os dois
# competiriam pela mesma tag — o `release.sh` empurra a tag `v*` e só depois
# cria o Release, então um outro processo publicando a mesma tag dá colisão.
#
# O `release.sh` faz o mesmo trabalho de forma completa: calcula a versão a
# partir dos commits (gitmoji), empacota no layout que o QEMU reconhece
# (bin/ + share/qemu/ReimsVgpu.rom), cria a tag anotada, empurra e publica.
#
# Este arquivo fica apenas como aviso e encaminhador para quem usar o nome antigo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cat >&2 <<'AVISO'
publish-release-local.sh foi substituído por scripts/release.sh.

Ele estava quebrado (4 dos 5 caminhos que copiava não existem mais) e, se
funcionasse, competiria com o release.sh pela mesma tag.

Use:

  ./scripts/release.sh                 # calcula a versão e publica
  ./scripts/release.sh --dry-run       # só empacota, para inspecionar
  ./scripts/release.sh --skip-push     # empacota e cria a tag local, sem publicar
  ./scripts/release.sh --help          # todas as opções
AVISO

if [ -x "${SCRIPT_DIR}/release.sh" ]; then
    echo >&2
    echo "Encaminhando para ./scripts/release.sh $* ..." >&2
    exec "${SCRIPT_DIR}/release.sh" "$@"
fi

echo "Erro: ${SCRIPT_DIR}/release.sh não encontrado ou não executável." >&2
exit 1
