#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/reims-vm-manager.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WORK_ROOT="$TMP/work"
RAILS_DIR="$TMP/rails"
mkdir -p "$WORK_ROOT" "$RAILS_DIR"
HOST_CORES=8
HOST_RAM=16
check_resources() {
  local cores=$1 ram=$2 disk=$3
  [[ "$cores" =~ ^[0-9]+$ && "$ram" =~ ^[0-9]+$ && "$disk" =~ ^[0-9]+$ ]] && ((cores > 0 && cores <= HOST_CORES && ram >= 2 && ram <= HOST_RAM && disk >= 70))
}
! check_resources 4 8 69
check_resources 4 8 70
! check_resources 0 8 70
! check_resources 4 1 70
uuidgen() { echo 11111111-1111-1111-1111-111111111111; }
new_id
[[ "$VM_ID" == reims-1111111111111111 ]]
mkdir -p "$WORK_ROOT/$VM_ID"
echo T002_CONTROLLED_TEST_PASS
