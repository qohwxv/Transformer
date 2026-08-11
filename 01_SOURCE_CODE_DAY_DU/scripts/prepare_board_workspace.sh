#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
package_root=$(CDPATH= cd -- "${script_dir}/.." && pwd -P)
receipt="${package_root}/immutable/full_vivado_receipt"
pause_tar="${package_root}/immutable/board_candidate_pause_checkpoint/M8_BOARD_CANDIDATE_PACKAGE.tar"
digilent_src="${package_root}/board_support/third_party/digilent_embeddedsw_genesys_zu_22_1"
runtime_dir="${package_root}/board_runtime"
runtime_hashes="${runtime_dir}/RUNTIME_ARTIFACTS.sha256"
run_name='20260809T032300Z-m8-board-candidate-67c18532-full-vivado-pass-receipt'

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s /fresh/m8_board_workspace\n' "$0" >&2
    exit 2
fi
destination=$1
if [[ -z "$destination" || "$destination" == / || "$destination" == . || -e "$destination" ]]; then
    printf 'UNSAFE_OR_EXISTING_DESTINATION %s\n' "$destination" >&2
    exit 2
fi

"${script_dir}/verify_content.sh"
"${script_dir}/check_environment.sh"
(
  cd "$runtime_dir"
  sha256sum -c "$(basename "$runtime_hashes")"
)

mkdir -p -- "$destination"
destination=$(CDPATH= cd -- "$destination" && pwd -P)
project_root="${destination}/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2"
cp -a --reflink=auto -- "$receipt/remote_snapshot" "$project_root"
chmod -R u+w -- "$project_root"
receipt_parent="${project_root}/reports/m8/server_runs"
mkdir -p -- "$receipt_parent"
cp -a --reflink=auto -- "$receipt" "${receipt_parent}/${run_name}"

stage="${destination}/.pause_payload_stage"
mkdir -p -- "$stage"
tar -xf "$pause_tar" -C "$stage"

mkdir -p \
  "${destination}/tools/board" \
  "${destination}/build/board_identities/m8" \
  "${destination}/build/model_package/v3_blocked_b_fp16_mixed" \
  "${destination}/results" \
  "${destination}/third_party" \
  "${destination}/.venv/bin"
cp -a -- "$stage/board/tools" "${destination}/tools/board/m8"
cp -a -- "$stage/board/m8_v3_mode3_50mhz.identity" \
  "${destination}/build/board_identities/m8/m8_v3_mode3_50mhz.identity"
cp -a -- "$stage/model/." "${destination}/build/model_package/v3_blocked_b_fp16_mixed/"
cp -a -- "$stage/model/post_encoder_step_32_logits_f32.hex" \
  "${destination}/results/post_encoder_step_32_logits_f32.hex"
cp -a -- "$stage/model/post_encoder_step_33p_probabilities_f32.hex" \
  "${destination}/results/post_encoder_step_33p_probabilities_f32.hex"
cp -a --reflink=auto -- "$digilent_src" \
  "${destination}/third_party/digilent_embeddedsw_genesys_zu_22_1"

# Add the portable retained-DDR runner and exact boot ELF/receipt without
# changing either immutable evidence tree.
chmod -R u+w -- \
  "${destination}/tools" "${destination}/build" "${destination}/results" \
  "${destination}/third_party" "${destination}/.venv"
tar -xzf "${runtime_dir}/M8_DATASET_RUNTIME.tar.gz" -C "$destination"
tar -xzf "${runtime_dir}/M8_BOOT_RUNTIME.tar.gz" -C "$destination"

printf '%s\n' '#!/usr/bin/env bash' 'exec /usr/bin/python3 "$@"' \
  >"${destination}/.venv/bin/python"
chmod 0755 "${destination}/.venv/bin/python"

chmod -R u+w -- \
  "${destination}/tools" "${destination}/build" "${destination}/results" \
  "${destination}/third_party" "${destination}/.venv"

# Xóa staging generated duy nhất; receipt/reference không bị sửa.
chmod -R u+w -- "$stage"
rm -rf -- "$stage"

(
  cd "$destination"
  .venv/bin/python -m unittest tools.board.m8.test_m8_board_tools
  .venv/bin/python -m py_compile \
    tools/board/m8/dataset/m8_dataset_common.py \
    tools/board/m8/dataset/configure_portable.py \
    tools/board/m8/dataset/setup_m8_session.py \
    tools/board/m8/dataset/run_m8_images.py
  bash -n tools/board/m8/dataset/*.sh
  tools/board/m8/run_m8_board.sh \
    --identity build/board_identities/m8/m8_v3_mode3_50mhz.identity \
    --preflight-only
)

printf 'M8_BOARD_WORKSPACE_PREPARE_PASS destination=%s jtag=NOT_TOUCHED\n' "$destination"
