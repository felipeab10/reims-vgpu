#!/usr/bin/env bash
# ==============================================================================
# scripts/release.sh — gera a próxima versão, empacota e publica o Release.
#
# Uso típico (dentro do checkout do fork):
#   ./scripts/release.sh                 # calcula a versão, confirma, empacota, publica
#   ./scripts/release.sh --dry-run       # mostra tudo, não cria tag nem publica
#   ./scripts/release.sh --minor         # força o componente minor
#   ./scripts/release.sh --major         # força o componente major
#   ./scripts/release.sh --tag v2.0.0    # usa uma tag exata, sem inferência
#   ./scripts/release.sh --yes           # não pede confirmação
#
# O que ele faz, em ordem:
#   1. Lê a última tag `v*` e os commits desde então, e sugere a próxima versão
#      (feat/:new: sobem minor; fix/:bug: sobem patch; BREAKING sobe major).
#   2. Confere que os artefatos do pacote existem ANTES de mexer no git.
#   3. Empacota no mesmo layout que o appliance consome (ver
#      core/reims_release.py no vhackintosh e o workflow
#      .github/workflows/release.yml — os três têm de concordar).
#   4. Cria a tag anotada, empurra e publica o Release com o `gh`.
#
# Se algo falhar no meio, a tag local é removida para o repositório não ficar
# com uma tag apontando para um Release que não existe.
# ==============================================================================
set -euo pipefail

REPO="felipeab10/reims-vgpu"
ASSET="reims-vgpu-linux-x86_64.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED}Erro: $*${NC}" >&2; exit 1; }

# O bloco de ajuda do topo do arquivo, sem depender de `sed | sed` (que quebra
# com SIGPIPE sob pipefail e vazava o `set -euo pipefail` no fim).
usage() {
    cat <<'USAGE'
scripts/release.sh — gera a próxima versão, empacota e publica o Release.

Uso típico (dentro do checkout do fork):
  ./scripts/release.sh                 # calcula a versão, confirma, empacota, publica
  ./scripts/release.sh --dry-run       # mostra tudo, não cria tag nem publica
  ./scripts/release.sh --minor         # força o componente minor
  ./scripts/release.sh --major         # força o componente major
  ./scripts/release.sh --patch         # força o componente patch
  ./scripts/release.sh --tag v2.0.0    # usa uma tag exata, sem inferência
  ./scripts/release.sh --yes           # não pede confirmação
  ./scripts/release.sh --skip-push     # cria a tag e o Release, sem `git push`

O que ele faz, em ordem:
  1. Lê a última tag `v*` e os commits desde então, e sugere a próxima versão
     (feat/:new: sobem minor; fix/:bug: sobem patch; BREAKING sobe major).
  2. Confere que os artefatos do pacote existem ANTES de mexer no git.
  3. Empacota no mesmo layout que o appliance consome (ver
     core/reims_release.py no vhackintosh e o workflow
     .github/workflows/release.yml — os três têm de concordar).
  4. Cria a tag anotada, empurra e publica o Release com o `gh`.

Se algo falhar no meio, a tag local é removida para o repositório não ficar
com uma tag apontando para um Release que não existe.
USAGE
}

DRY_RUN=0
ASSUME_YES=0
FORCED_TAG=""
FORCED_BUMP=""
SKIP_PUSH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        --minor)     FORCED_BUMP="minor"; shift ;;
        --major)     FORCED_BUMP="major"; shift ;;
        --patch)     FORCED_BUMP="patch"; shift ;;
        --tag)       FORCED_TAG="$2"; shift 2 ;;
        --skip-push) SKIP_PUSH=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "opção inválida: $1 (use --help)" ;;
    esac
done

cd "${REPO_ROOT}"

# ------------------------------------------------------------------------------
# 0. Ferramentas e estado do repositório
# ------------------------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git não encontrado"
git rev-parse --git-dir >/dev/null 2>&1 || die "${REPO_ROOT} não é um repositório git"

if [[ "${DRY_RUN}" -eq 0 && "${SKIP_PUSH}" -eq 0 ]]; then
    command -v gh >/dev/null 2>&1 || die "o 'gh' (GitHub CLI) não está instalado; ele é necessário para abrir o Release"
    gh auth status >/dev/null 2>&1 || die "o 'gh' não está autenticado; rode: gh auth login"
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${CURRENT_BRANCH}" != "master" && "${CURRENT_BRANCH}" != "main" && "${DRY_RUN}" -eq 0 ]]; then
    say "${YELLOW}Aviso: você está em '${CURRENT_BRANCH}', não em master/main.${NC}"
    if [[ "${ASSUME_YES}" -eq 0 ]]; then
        read -r -p "Continuar mesmo assim? [s/N] " _ans
        [[ "${_ans,,}" == "s" || "${_ans,,}" == "y" ]] || die "cancelado pelo usuário"
    fi
fi

# ------------------------------------------------------------------------------
# 1. Última tag e próxima versão
# ------------------------------------------------------------------------------
LAST_TAG="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n1 || true)"
if [[ -z "${LAST_TAG}" ]]; then
    LAST_TAG="v0.0.0"
    say "${YELLOW}Nenhuma tag encontrada; partindo de ${LAST_TAG}.${NC}"
fi
say "${BLUE}▶ Última tag: ${LAST_TAG}${NC}"

if git rev-parse --verify --quiet "${LAST_TAG}^{commit}" >/dev/null; then
    RANGE="${LAST_TAG}..HEAD"
else
    RANGE="HEAD"
fi
COMMITS="$(git log --format='%s%n%b' "${RANGE}" 2>/dev/null || true)"
COMMIT_COUNT="$(git rev-list --count "${RANGE}" 2>/dev/null || echo 0)"

VER="${LAST_TAG#v}"
VER="${VER%%-*}"                      # descarta sufixo tipo -rc1
IFS='.' read -r MAJOR MINOR PATCH <<<"${VER}"
MAJOR="${MAJOR:-0}"; MINOR="${MINOR:-0}"; PATCH="${PATCH:-0}"
[[ "${MAJOR}" =~ ^[0-9]+$ ]] || MAJOR=0
[[ "${MINOR}" =~ ^[0-9]+$ ]] || MINOR=0
[[ "${PATCH}" =~ ^[0-9]+$ ]] || PATCH=0

# Classificação. O fork usa gitmoji (":bug:", ":new:") e também aceita
# Conventional Commits ("fix:", "feat:").
BREAKING=0
HAS_FEAT=0
HAS_FIX=0
# Herestring, e NÃO `printf | grep -q`: com `set -o pipefail`, o `grep -q` sai no
# primeiro casamento, o `printf` leva SIGPIPE e o pipeline inteiro é dado como
# falho — o `if` cai no `else` e TODO commit é classificado como nenhum dos dois.
# Foi exatamente o que fazia 100 commits (com 28 `:bug:`) sugerirem "patch".
if grep -qE 'BREAKING CHANGE|^[a-z]+(\([^)]*\))?!:' <<<"${COMMITS}"; then BREAKING=1; fi
if grep -qE '^(feat|:new:|:sparkles:|:arrow_up:)' <<<"${COMMITS}"; then HAS_FEAT=1; fi
if grep -qE '^(fix|:bug:|:ambulance:)' <<<"${COMMITS}"; then HAS_FIX=1; fi

if [[ -n "${FORCED_BUMP}" ]]; then
    BUMP="${FORCED_BUMP}"
elif [[ "${BREAKING}" -eq 1 ]]; then
    BUMP="major"
elif [[ "${HAS_FEAT}" -eq 1 ]]; then
    BUMP="minor"
elif [[ "${HAS_FIX}" -eq 1 ]]; then
    BUMP="patch"
else
    BUMP="patch"
fi

if [[ -n "${FORCED_TAG}" ]]; then
    NEXT_TAG="${FORCED_TAG}"
    [[ "${NEXT_TAG}" == v* ]] || NEXT_TAG="v${NEXT_TAG}"
else
    case "${BUMP}" in
        major) NEXT_TAG="v$((MAJOR + 1)).0.0" ;;
        minor) NEXT_TAG="v${MAJOR}.$((MINOR + 1)).0" ;;
        patch) NEXT_TAG="v${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
    esac
fi

say ""
say "${CYAN}── Versão ──────────────────────────────────────────────${NC}"
say "  commits desde ${LAST_TAG}: ${COMMIT_COUNT}"
say "  breaking: ${BREAKING} | feat: ${HAS_FEAT} | fix: ${HAS_FIX}"
say "  bump sugerido: ${YELLOW}${BUMP}${NC}  →  ${GREEN}${NEXT_TAG}${NC}"
say "${CYAN}────────────────────────────────────────────────────────${NC}"
say ""

if git rev-parse --verify --quiet "refs/tags/${NEXT_TAG}" >/dev/null; then
    die "a tag ${NEXT_TAG} já existe. Use --tag para escolher outra, ou --minor/--major."
fi

# ------------------------------------------------------------------------------
# 2. Artefatos ANTES de qualquer coisa irreversível
# ------------------------------------------------------------------------------
say "${BLUE}▶ Conferindo os artefatos do pacote...${NC}"

# De onde este checkout realmente constrói: o install-ctl.sh deixa o QEMU em
# ~/.cache/reims-ctl/qemu-build-<plataforma>/ e o bundle com as ROMs em
# <target>/dist-vulkan/. A ROM do vGPU hoje é `ReimsVgpu.rom`, instalada pelo
# próprio QEMU (vendor/qemu/meson.build); o antigo `reims-vgpu-gop.rom` vinha de
# crates/reims-vgpu-efi, que o commit 98fe2a3b removeu da árvore.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/reims-ctl"
BUILD_PLATFORM="linux-x86_64"

# Aceita o caminho que o usuário já tem; senão, procura no cache do install-ctl.
if [[ -z "${QEMU_BIN_OVERRIDE:-}" ]]; then
    QEMU_BIN="vendor/qemu/build/qemu-system-x86_64"
    if [[ ! -f "${QEMU_BIN}" ]]; then
        FOUND_QEMU="$(find "${CACHE_DIR}" -maxdepth 3 -name qemu-system-x86_64 -type f 2>/dev/null | head -n1 || true)"
        [[ -n "${FOUND_QEMU}" ]] && QEMU_BIN="${FOUND_QEMU}"
    fi
else
    QEMU_BIN="${QEMU_BIN_OVERRIDE}"
fi

# A ROM do vGPU: procura o nome atual e, só se não achar, o antigo.
ROM_BIN=""
for candidato in \
    "crates/reims-vgpu-efi/out/reims-vgpu-gop.rom" \
    "vendor/qemu/build/share/reims-vgpu/ReimsVgpu.rom" \
    "vendor/qemu/pc-bios/ReimsVgpu.rom"
do
    [[ -f "${candidato}" ]] && { ROM_BIN="${candidato}"; break; }
done
if [[ -z "${ROM_BIN}" ]]; then
    FOUND_ROM="$(find target vendor -name 'ReimsVgpu.rom' -type f 2>/dev/null | head -n1 || true)"
    [[ -z "${FOUND_ROM}" ]] && FOUND_ROM="$(find "${CACHE_DIR}" -name 'ReimsVgpu.rom' -type f 2>/dev/null | head -n1 || true)"
    [[ -n "${FOUND_ROM}" ]] && ROM_BIN="${FOUND_ROM}"
fi

MISSING=()
[[ -f "${QEMU_BIN}" ]] || MISSING+=("QEMU (${QEMU_BIN})")
[[ -n "${ROM_BIN}" && -f "${ROM_BIN}" ]] || MISSING+=("a ROM do vGPU (ReimsVgpu.rom)")
[[ -d "vendor/qemu/pc-bios" ]] || MISSING+=("vendor/qemu/pc-bios/")

if [[ "${#MISSING[@]}" -gt 0 ]]; then
    say "${RED}Erro: artefatos ausentes:${NC}"
    for m in "${MISSING[@]}"; do say "  - ${m}"; done
    say ""
    say "Compile antes de publicar. O construtor deste checkout é o install-ctl.sh,"
    say "que deixa o QEMU e as ROMs prontos no cache:"
    say "  ${GREEN}./scripts/install-ctl.sh --yes${NC}"
    say ""
    say "Depois rode este script de novo: ele encontra o QEMU em"
    say "  ${CACHE_DIR}/qemu-build-${BUILD_PLATFORM}/"
    say "e a ROM em"
    say "  target/dist-vulkan/share/reims-vgpu/ReimsVgpu.rom"
    say ""
    say "Para apontar o QEMU na mão: ${GREEN}QEMU_BIN_OVERRIDE=/caminho/qemu-system-x86_64 $0${NC}"
    say ""
    say "Nada foi criado nem publicado (a tag seria ${NEXT_TAG})."
    exit 1
fi
say "  ✓ QEMU: ${QEMU_BIN} ($(du -h "${QEMU_BIN}" | cut -f1))"
say "  ✓ ROM:  ${ROM_BIN}"
say "  ✓ pc-bios presente"

if ! "${QEMU_BIN}" --version >/dev/null 2>&1; then
    say "${YELLOW}Aviso: '${QEMU_BIN} --version' falhou; o binário pode não ser executável neste host.${NC}"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    say "${YELLOW}Aviso: há mudanças não commitadas:${NC}"
    git status --short | sed 's/^/    /'
    say "${YELLOW}O binário publicado reflete o diretório de trabalho, mas a tag apontará"
    say "para o último commit. Considere commitar antes.${NC}"
fi

# ------------------------------------------------------------------------------
# 3. Confirmação e empacotamento
# ------------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 1 ]]; then
    say ""
    say "${BLUE}▶ --dry-run: pulando empacotamento e publicação.${NC}"
    say "  seria publicada a tag ${GREEN}${NEXT_TAG}${NC} no repo ${REPO}"
    exit 0
fi

if [[ "${ASSUME_YES}" -eq 0 ]]; then
    say ""
    read -r -p "Criar a tag ${NEXT_TAG} e publicar o Release em ${REPO}? [s/N] " _confirm
    [[ "${_confirm,,}" == "s" || "${_confirm,,}" == "y" ]] || die "cancelado pelo usuário"
fi

DIST_TMP="$(mktemp -d)"
TAG_CREATED=0
OUT_TAR="${REPO_ROOT}/${ASSET}"
cleanup() {
    local rc=$?
    rm -rf "${DIST_TMP}"
    # Se falhamos depois de criar a tag e antes de publicar, desfaz a tag local
    # para não deixar o repositório mentindo sobre o que existe.
    if [[ "${rc}" -ne 0 && "${TAG_CREATED}" -eq 1 ]]; then
        printf '%b\n' "${YELLOW}Limpando: removendo a tag local ${NEXT_TAG} (o Release não foi publicado).${NC}"
        git tag -d "${NEXT_TAG}" >/dev/null 2>&1 || true
    fi
    # Em qualquer saída, o tarball não fica no diretório de trabalho: ele já foi
    # publicado (ou não vai ser), e sobrar sujaria o `git status` da próxima vez.
    rm -f "${OUT_TAR}" "${OUT_TAR}.sha256"
    exit "${rc}"
}
trap cleanup EXIT INT TERM

say ""
say "${BLUE}▶ Empacotando ${ASSET}...${NC}"

# Mesmo layout que o QEMU instalado pelo install-ctl.sh usa:
#   bin/qemu-system-x86_64
#   share/qemu/ReimsVgpu.rom   <- o QEMU a procura pelo `romfile`, relativo
#                                 ao seu próprio prefixo
#   share/qemu/... (pc-bios)   <- as ROMs padrão do QEMU
# O appliance só precisa copiar esta árvore para o prefixo dele.
mkdir -p "${DIST_TMP}/vendor/qemu/build/bin"
mkdir -p "${DIST_TMP}/vendor/qemu/build/share/qemu"
mkdir -p "${DIST_TMP}/vm/ovmf"

cp -a "${QEMU_BIN}" "${DIST_TMP}/vendor/qemu/build/bin/qemu-system-x86_64"

# A ROM do vGPU, com o nome que o binário pede (`romfile ReimsVgpu.rom`).
ROM_DEST_NAME="$(basename "${ROM_BIN}")"
if [[ "${ROM_DEST_NAME}" != "ReimsVgpu.rom" ]]; then
    say "${YELLOW}  Aviso: a ROM encontrada é ${ROM_DEST_NAME}; ela será publicada como ReimsVgpu.rom, que é o nome que o binário procura.${NC}"
fi
cp -a "${ROM_BIN}" "${DIST_TMP}/vendor/qemu/build/share/qemu/ReimsVgpu.rom"

# pc-bios: as ROMs padrão do QEMU (pxe, vgabios, edk2), ao lado da do vGPU.
if [[ -d "vendor/qemu/pc-bios" ]]; then
    cp -a vendor/qemu/pc-bios/. "${DIST_TMP}/vendor/qemu/build/share/qemu/"
fi

# OVMF: do repositório, se houver; senão do sistema.
if [[ -d vm/ovmf ]] && [[ -n "$(ls -A vm/ovmf 2>/dev/null)" ]]; then
    cp -a vm/ovmf/. "${DIST_TMP}/vm/ovmf/"
elif [[ -d /usr/share/OVMF ]]; then
    say "  (vm/ovmf vazio; usando /usr/share/OVMF)"
    cp -a /usr/share/OVMF/. "${DIST_TMP}/vm/ovmf/"
else
    say "${YELLOW}  Aviso: sem OVMF (nem vm/ovmf nem /usr/share/OVMF); o pacote sairá sem firmware UEFI.${NC}"
fi

[[ -f vm/boot-x86.sh ]] && cp -a vm/boot-x86.sh "${DIST_TMP}/vm/"

tar -czf "${OUT_TAR}" -C "${DIST_TMP}" .
sha256sum "${OUT_TAR}" > "${OUT_TAR}.sha256"

say "  ✓ ${ASSET} ($(du -h "${OUT_TAR}" | cut -f1))"
say "  ✓ ${ASSET}.sha256"

# Sanidade: o tarball contém o que o appliance procura? Publicar um pacote
# incompleto cria uma release que só falha na mão do usuário.
# Uma listagem só, em memória: `tar | grep -q` fecha o pipe no primeiro match e
# o `tar` morre com SIGPIPE, que sob `pipefail` viraria falha do script.
TAR_LIST="$(tar -tzf "${OUT_TAR}")" || die "não consegui listar o tarball gerado"

for esperado in \
    'vendor/qemu/build/bin/qemu-system-x86_64' \
    'vendor/qemu/build/share/qemu/ReimsVgpu.rom' \
    'vendor/qemu/build/share/qemu/'
do
    if [[ "${TAR_LIST}" != *"${esperado}"* ]]; then
        die "o tarball gerado não contém ${esperado}"
    fi
done

# ------------------------------------------------------------------------------
# 4. Tag, push e Release
# ------------------------------------------------------------------------------
say ""
say "${BLUE}▶ Criando a tag anotada ${NEXT_TAG}...${NC}"
git tag -a "${NEXT_TAG}" -m "Reims vGPU ${NEXT_TAG}"
TAG_CREATED=1

if [[ "${SKIP_PUSH}" -eq 0 ]]; then
    say "${BLUE}▶ Empurrando a tag para origin...${NC}"
    git push origin "${NEXT_TAG}"
fi

# `--skip-push` significa "não toque no remoto": pular só o `git push` deixava
# o `gh release create` publicar de verdade — foi assim que ele criou Releases
# de teste indesejadas. Aqui ele para antes de qualquer escrita remota.
if [[ "${SKIP_PUSH}" -eq 1 ]]; then
    say ""
    say "${YELLOW}▶ --skip-push: parei antes de qualquer escrita no remoto.${NC}"
    say "  Tag local criada: ${GREEN}${NEXT_TAG}${NC} (não empurrada)"
    say "  Pacote:           ${OUT_TAR} (mantido neste diretório)"
    say "  ${CYAN}Nenhum Release foi publicado.${NC}"
    say ""
    say "Para publicar de verdade, rode sem --skip-push:"
    say "  ./scripts/release.sh --tag ${NEXT_TAG}"
    TAG_CREATED=0
    # Sem publicação: a tag é local e o pacote fica para inspeção.
    trap - EXIT
    exit 0
fi

say "${BLUE}▶ Publicando o Release ${NEXT_TAG} em ${REPO}...${NC}"
gh release create "${NEXT_TAG}" "${OUT_TAR}" "${OUT_TAR}.sha256" \
    --repo "${REPO}" \
    --title "Reims vGPU ${NEXT_TAG} (x86_64 Linux)" \
    --notes "Binários pré-compilados do Reims vGPU (QEMU com backend Vulkan + ROM UEFI GOP).

Linux x86-64. Carrega o Vulkan em runtime via dlopen(\"libvulkan.so.1\"),
então o mesmo binário serve em qualquer host com Vulkan 1.2+.

O appliance (vhackintosh) baixa este asset automaticamente:
  appliance/build-iso.sh --release ${NEXT_TAG}" \
    || die "falha ao publicar o Release ${NEXT_TAG}"

# Publicado: a tag não deve mais ser desfeita em caso de saída normal.
# (O tarball é removido pelo trap, que roda em toda saída.)
TAG_CREATED=0

say ""
say "${GREEN}✔ Release ${NEXT_TAG} publicada.${NC}"
say "  ${CYAN}https://github.com/${REPO}/releases/tag/${NEXT_TAG}${NC}"
say ""
say "Para usar esta versão na ISO:"
say "  cd /home/felipeab10/vhackintosh && sudo ./appliance/build-iso.sh --release ${NEXT_TAG}"
