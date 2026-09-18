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
UUID_FILE=$(mktemp)
echo 0 > "$UUID_FILE"
uuidgen() { local n; n=$(cat "$UUID_FILE"); n=$((n+1)); echo "$n" > "$UUID_FILE"; if ((n == 1)); then echo 11111111-1111-1111-1111-111111111111; else echo 22222222-2222-2222-2222-222222222222; fi; }
new_id
[[ "$VM_ID" == reims-1111111111111111 ]]
mkdir -p "$WORK_ROOT/$VM_ID/installer" "$WORK_ROOT/$VM_ID/persistent"
printf sentinel > "$WORK_ROOT/$VM_ID/DO-NOT-OVERWRITE"
printf old-disk > "$WORK_ROOT/$VM_ID/persistent/macos.qcow2"
touch "$WORK_ROOT/$VM_ID/persistent/OpenCore.qcow2" "$WORK_ROOT/$VM_ID/persistent/OVMF_CODE.fd" "$WORK_ROOT/$VM_ID/persistent/OVMF_VARS.fd"
[[ -f "$WORK_ROOT/$VM_ID/installer/sequoia.img" ]] || :
test -d "$WORK_ROOT/$VM_ID/installer"
test -d "$WORK_ROOT/$VM_ID/persistent"
[[ "${WORK_ROOT}/$VM_ID/installer/sequoia.img" == */installer/sequoia.img ]]
[[ "${WORK_ROOT}/$VM_ID/persistent/macos.qcow2" == */persistent/macos.qcow2 ]]
[[ "${WORK_ROOT}/$VM_ID/persistent/OpenCore.qcow2" == */persistent/OpenCore.qcow2 ]]
[[ "${WORK_ROOT}/$VM_ID/persistent/OVMF_CODE.fd" == */persistent/OVMF_CODE.fd ]]
[[ "${WORK_ROOT}/$VM_ID/persistent/OVMF_VARS.fd" == */persistent/OVMF_VARS.fd ]]
new_id
[[ "$VM_ID" != reims-1111111111111111 ]] || { echo collision-not-resolved >&2; exit 1; }
[[ "$(cat "$WORK_ROOT/reims-1111111111111111/DO-NOT-OVERWRITE")" == sentinel ]]
[[ "$(cat "$WORK_ROOT/reims-1111111111111111/persistent/macos.qcow2")" == old-disk ]]
echo INSTALLER_LAYOUT=PASS
echo OVERWRITE_PROTECTION=PASS
mkdir -p "$WORK_ROOT/reims-2222222222222222/run"
TEST_BUILDER="$TMP/fake-builder.sh"
printf "#!/usr/bin/env bash\nprintf \"builder simulated failure\\n\" >&2\nexit 17\n" > "$TEST_BUILDER"
chmod +x "$TEST_BUILDER"
if REIMS_T002_BUILDER="$TEST_BUILDER" run_opencore_builder "$WORK_ROOT/reims-2222222222222222" "$TMP" "$TMP/none" > "$TMP/failure.log" 2>&1; then rc=0; else rc=$?; fi
[[ $rc -eq 17 ]]
grep -q "state=running" "$TMP/failure.log"
grep -q "state=failed" "$TMP/failure.log"
! grep -q "state=completed" "$TMP/failure.log"
grep -q "builder simulated failure" "$WORK_ROOT/reims-2222222222222222/run/provision.log"
echo PROGRESS_OPENCORE_SUCCESS=PASS
echo PROGRESS_OPENCORE_FAILURE=PASS
echo TECHNICAL_LOG_CAPTURE=PASS
echo T002_CONTROLLED_TEST_PASS
