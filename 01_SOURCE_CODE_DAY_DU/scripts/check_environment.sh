#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$(getconf LONG_BIT)" != 64 ]]; then
    printf 'UNSUPPORTED_HOST expected=64-bit-Linux actual=%s/%s-bit\n' \
      "$(uname -s)" "$(getconf LONG_BIT 2>/dev/null || printf unknown)" >&2
    exit 1
fi

for tool in \
    bash awk grep cmp cut sort stat tr wc head readlink timeout tee mktemp chmod \
    date realpath sed uniq xargs sha256sum find tar cp git uname getconf; do
    command -v "$tool" >/dev/null || {
        printf 'MISSING_REQUIRED_TOOL %s\n' "$tool" >&2
        exit 1
    }
done

if [[ ! -x /usr/bin/python3 ]]; then
    printf '%s\n' 'MISSING_REQUIRED_TOOL /usr/bin/python3' >&2
    exit 1
fi

vivado_bin=${VIVADO_BIN:-}
if [[ -z "$vivado_bin" ]] && command -v vivado >/dev/null 2>&1; then
    vivado_bin=$(command -v vivado)
fi

if [[ -z "$vivado_bin" ]]; then
    printf '%s\n' 'M8_CONTENT_ENVIRONMENT_PASS'
    printf '%s\n' 'M8_VIVADO_TOOLCHAIN_PENDING set VIVADO_BIN to an external Vivado 2023.2 executable'
    exit 0
fi

test -x "$vivado_bin" || {
    printf 'VIVADO_BIN_NOT_EXECUTABLE %s\n' "$vivado_bin" >&2
    exit 1
}

version=$($vivado_bin -version 2>&1 | head -n 4)
grep -Fiq 'vivado v2023.2' <<<"$version" || {
    printf 'VIVADO_VERSION_MISMATCH expected=2023.2 binary=%s\n%s\n' "$vivado_bin" "$version" >&2
    exit 1
}

printf '%s\n' 'M8_CONTENT_ENVIRONMENT_PASS'
printf 'M8_VIVADO_2023_2_TOOLCHAIN_READY_PASS binary=%s\n' "$vivado_bin"
