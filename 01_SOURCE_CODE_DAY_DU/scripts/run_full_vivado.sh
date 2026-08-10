#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

if [[ $# -ne 1 ]]; then
    printf 'Usage: VIVADO_BIN=/path/to/vivado %s /fresh/m8_worktree\n' "$0" >&2
    exit 2
fi

worktree=$1
if [[ -e "$worktree" ]]; then
    printf 'WORKTREE_MUST_BE_FRESH path=%s\n' "$worktree" >&2
    exit 2
fi

vivado_bin=${VIVADO_BIN:-}
if [[ -z "$vivado_bin" ]] && command -v vivado >/dev/null 2>&1; then
    vivado_bin=$(command -v vivado)
fi
if [[ -z "$vivado_bin" || ! -x "$vivado_bin" ]]; then
    printf '%s\n' 'VIVADO_NOT_READY: set VIVADO_BIN to external Vivado 2023.2' >&2
    exit 2
fi
VIVADO_BIN=$vivado_bin "${script_dir}/check_environment.sh"

"${script_dir}/prepare_worktree.sh" "$worktree"
worktree_abs=$(CDPATH= cd -- "$worktree" && pwd -P)
run_id=$(date -u +%Y%m%dT%H%M%SZ)
log_path="${worktree_abs}/portable_full_flow_${run_id}.log"

cd "$worktree_abs"
set -o pipefail
env \
  VIVADO_BIN="$vivado_bin" \
  VIT_REUSE_PROJECT=0 \
  VIT_RUN_XSIM=1 \
  VIT_RUN_OOC_SYNTH=1 \
  VIT_RUN_IMPLEMENTATION=1 \
  VIT_VIVADO_JOBS="${VIT_VIVADO_JOBS:-1}" \
  VIT_VIVADO_THREADS="${VIT_VIVADO_THREADS:-2}" \
  VIT_XSIM_THREADS="${VIT_XSIM_THREADS:-2}" \
  VIT_XSIM_TIMEOUT_SECONDS="${VIT_XSIM_TIMEOUT_SECONDS:-14400}" \
  VIT_VIVADO_TIMEOUT_SECONDS="${VIT_VIVADO_TIMEOUT_SECONDS:-172800}" \
  ./run/run_all.sh 2>&1 | tee "$log_path"

printf 'M8_PORTABLE_FULL_VIVADO_RUN_FINISHED worktree=%s log=%s\n' "$worktree_abs" "$log_path"
