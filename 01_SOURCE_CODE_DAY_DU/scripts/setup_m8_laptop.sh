#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
package_root=$(CDPATH= cd -- "${script_dir}/.." && pwd -P)

workspace=''
cable_serial=''
xilinx_root=''
vivado_bin=${VIVADO_BIN:-}
xsct_bin=${XSCT:-}
hw_server_bin=${HW_SERVER:-}
python_bin=${M8_BOOTSTRAP_PYTHON:-python3}
skip_python_install=0

usage() {
    cat <<'EOF'
Usage:
  setup_m8_laptop.sh --workspace /path/m8_board_work [options]

Required for final configuration:
  --cable-serial HEX       Serial printed by XSCT "jtag targets".

Tool options (auto-detected when omitted):
  --xilinx-root DIR        Directory containing Vivado/2023.2 and Vitis/2023.2.
  --vivado-bin FILE        Exact Vivado 2023.2 executable.
  --xsct FILE              Exact XSCT 2023.2 executable.
  --hw-server FILE         Exact hw_server 2023.2 executable.

Other options:
  --python FILE            Python 3 used to create .venv_m8.
  --skip-python-install    Prepare/configure without pip installing dependencies.
  -h, --help               Show this help.

If --cable-serial is omitted, the script prepares the workspace and Python,
then prints the commands needed to read the serial. Re-run with the serial to
finish the host-only configuration. It never touches JTAG by itself.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace)
            workspace=${2:?missing value for --workspace}
            shift 2
            ;;
        --cable-serial)
            cable_serial=${2:?missing value for --cable-serial}
            shift 2
            ;;
        --xilinx-root)
            xilinx_root=${2:?missing value for --xilinx-root}
            shift 2
            ;;
        --vivado-bin)
            vivado_bin=${2:?missing value for --vivado-bin}
            shift 2
            ;;
        --xsct)
            xsct_bin=${2:?missing value for --xsct}
            shift 2
            ;;
        --hw-server)
            hw_server_bin=${2:?missing value for --hw-server}
            shift 2
            ;;
        --python)
            python_bin=${2:?missing value for --python}
            shift 2
            ;;
        --skip-python-install)
            skip_python_install=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'UNKNOWN_ARGUMENT %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$workspace" || "$workspace" == / || "$workspace" == . ]]; then
    printf '%s\n' 'A safe absolute --workspace path is required' >&2
    exit 2
fi
workspace=$(realpath -m -- "$workspace")

first_executable() {
    local candidate
    for candidate in "$@"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            realpath -- "$candidate"
            return 0
        fi
    done
    return 1
}

path_candidate() {
    local command_name=$1
    command -v "$command_name" 2>/dev/null || true
}

user_home=${HOME:?HOME is not set}
if [[ -n "$xilinx_root" ]]; then
    xilinx_root=$(realpath -m -- "$xilinx_root")
fi

vivado_bin=$(first_executable \
    "$vivado_bin" \
    "${xilinx_root:+${xilinx_root}/Vivado/2023.2/bin/vivado}" \
    "$(path_candidate vivado)" \
    "${user_home}/Xilinx/Vivado/2023.2/bin/vivado" \
    "${user_home}/Downloads/Xilinx/Vivado/2023.2/bin/vivado" \
    "${user_home}/Downloads/Vivado/Vivado/2023.2/bin/vivado" \
    '/opt/Xilinx/Vivado/2023.2/bin/vivado' \
    '/tools/Xilinx/Vivado/2023.2/bin/vivado') || {
        printf '%s\n' 'VIVADO_NOT_FOUND: pass --xilinx-root or --vivado-bin' >&2
        exit 1
    }

xsct_bin=$(first_executable \
    "$xsct_bin" \
    "${xilinx_root:+${xilinx_root}/Vitis/2023.2/bin/xsct}" \
    "$(path_candidate xsct)" \
    "${user_home}/Xilinx/Vitis/2023.2/bin/xsct" \
    "${user_home}/Downloads/Xilinx/Vitis/2023.2/bin/xsct" \
    "${user_home}/Downloads/Vivado/Vitis/2023.2/bin/xsct" \
    '/opt/Xilinx/Vitis/2023.2/bin/xsct' \
    '/tools/Xilinx/Vitis/2023.2/bin/xsct') || {
        printf '%s\n' 'XSCT_NOT_FOUND: pass --xilinx-root or --xsct' >&2
        exit 1
    }

hw_server_bin=$(first_executable \
    "$hw_server_bin" \
    "${xilinx_root:+${xilinx_root}/Vivado/2023.2/bin/hw_server}" \
    "$(path_candidate hw_server)" \
    "$(dirname -- "$vivado_bin")/hw_server") || {
        printf '%s\n' 'HW_SERVER_NOT_FOUND: pass --hw-server' >&2
        exit 1
    }

python_bin=$(command -v "$python_bin" 2>/dev/null || true)
if [[ -z "$python_bin" || ! -x "$python_bin" ]]; then
    printf '%s\n' 'PYTHON3_NOT_FOUND: install Python 3 and python3-venv' >&2
    exit 1
fi

VIVADO_BIN="$vivado_bin" "${script_dir}/check_environment.sh"

if [[ ! -e "$workspace" ]]; then
    "${script_dir}/prepare_board_workspace.sh" "$workspace"
elif [[ ! -f "$workspace/tools/board/m8/dataset/configure_portable.py" || \
        ! -f "$workspace/build/model_package/v3_blocked_b_fp16_mixed/vit_model.bin" ]]; then
    printf 'EXISTING_WORKSPACE_IS_NOT_M8 %s\n' "$workspace" >&2
    exit 1
else
    printf 'M8_EXISTING_BOARD_WORKSPACE_REUSE path=%s\n' "$workspace"
fi

venv_python="${workspace}/.venv_m8/bin/python"
if [[ ! -x "$venv_python" ]]; then
    "$python_bin" -m venv "${workspace}/.venv_m8"
fi

if [[ "$skip_python_install" -eq 0 ]]; then
    "$venv_python" -m pip install --upgrade pip
    "$venv_python" -m pip install -r "${package_root}/board_runtime/requirements-board.txt"
    "$venv_python" -c \
      'import numpy, PIL, torch, transformers; print("M8_PYTHON_READY_PASS")'
else
    printf '%s\n' 'M8_PYTHON_DEPENDENCY_INSTALL_SKIPPED'
fi

env_file="${workspace}/m8_env.sh"
{
    printf 'export BOARD_WORK=%q\n' "$workspace"
    printf 'export VIVADO_BIN=%q\n' "$vivado_bin"
    printf 'export XSCT=%q\n' "$xsct_bin"
    printf 'export HW_SERVER=%q\n' "$hw_server_bin"
    printf 'export VIT_PYTHON=%q\n' "$venv_python"
} >"$env_file"
chmod 0600 "$env_file"

if [[ -z "$cable_serial" ]]; then
    printf 'M8_LAPTOP_PREPARE_PASS workspace=%s config=PENDING_CABLE_SERIAL jtag=NOT_TOUCHED\n' \
      "$workspace"
    printf '\nTerminal A:\n  %q -s tcp::3121\n' "$hw_server_bin"
    printf '\nTerminal B:\n  %q\n' "$xsct_bin"
    printf '%s\n' \
      '  connect -url tcp:127.0.0.1:3121' \
      '  jtag targets' \
      '  disconnect' \
      '  exit'
    printf '\nThen re-run:\n  %q --workspace %q --cable-serial SERIAL\n' "$0" "$workspace"
    exit 0
fi

"$venv_python" "${workspace}/tools/board/m8/dataset/configure_portable.py" \
  --xsct "$xsct_bin" \
  --cable-serial "$cable_serial" \
  --force

VIT_PYTHON="$venv_python" \
  "${workspace}/tools/board/m8/dataset/setup_m8_session.sh" --preflight-only

printf 'M8_LAPTOP_CONFIG_PASS workspace=%s env=%s jtag=NOT_TOUCHED\n' \
  "$workspace" "$env_file"
printf '\nTerminal A:\n  source %q\n  "$HW_SERVER" -s tcp::3121\n' "$env_file"
printf '\nTerminal B (cold setup once):\n  source %q\n  cd "$BOARD_WORK"\n  tools/board/m8/dataset/setup_m8_session.sh\n' "$env_file"
printf '\nThen run one image:\n  tools/board/m8/dataset/run_1.sh --images inputs/test1.png\n'
