#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: batch_branch_solver_smoke.sh [pdlp|madipm|both]

Runs a tiny binary MIP through cuopt_cli with batch-only strong branching.
Use "madipm" or "both" with CUOPT_LIBMAD_PATH pointing at libMad.so.

Environment:
  CUOPT_CLI          Optional path to cuopt_cli. Defaults to PATH, then cpp/build/cuopt_cli.
  CUOPT_LIBMAD_PATH  Required for the MadIPM/libMad backend unless libMad.so is discoverable.
  SMOKE_TIME_LIMIT   Solver time limit in seconds. Defaults to 120 to cover libMad startup.
EOF
}

case "${1:-both}" in
    pdlp|madipm|both) BACKEND="${1:-both}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CUOPT_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
CUOPT_CLI=${CUOPT_CLI:-}
if [[ -z "$CUOPT_CLI" ]]; then
    if command -v cuopt_cli >/dev/null 2>&1; then
        CUOPT_CLI=$(command -v cuopt_cli)
    else
        CUOPT_CLI="$CUOPT_ROOT/cpp/build/cuopt_cli"
    fi
fi
if [[ ! -x "$CUOPT_CLI" ]]; then
    echo "cuopt_cli not found or not executable: $CUOPT_CLI" >&2
    exit 1
fi

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/cuopt_batch_branch_smoke.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT
MPS="$TMPDIR/batch_branch_smoke.mps"

cat > "$MPS" <<'MPS'
NAME          BBATCH
ROWS
 N  COST
 L  CAP
COLUMNS
    MARK0000  'MARKER'                 'INTORG'
    X1        COST      -1.0            CAP        2.0
    X2        COST      -1.0            CAP        2.0
    MARK0001  'MARKER'                 'INTEND'
RHS
    RHS       CAP        3.0
BOUNDS
 BV BND       X1
 BV BND       X2
ENDATA
MPS

run_backend() {
    local name=$1
    local value=$2
    local expected=$3
    local log="$TMPDIR/${name}.log"
    local time_limit="${SMOKE_TIME_LIMIT:-120}"

    if [[ "$name" == "madipm" && -z "${CUOPT_LIBMAD_PATH:-}" ]]; then
        echo "CUOPT_LIBMAD_PATH must point to libMad.so for the MadIPM backend" >&2
        exit 1
    fi

    echo "Running $name batch branching smoke test"
    "$CUOPT_CLI" "$MPS" \
        --time-limit "$time_limit" \
        --num-cpu-threads 4 \
        --presolve 0 \
        --mip-cut-passes 0 \
        --mip-batch-pdlp-strong-branching 2 \
        --mip-batch-pdlp-reliability-branching 2 \
        --mip-batch-branch-solver "$value" \
        --log-to-console true \
        2>&1 | tee "$log"

    grep -q "$expected" "$log" || {
        echo "Expected batch backend marker not found in $name output: $expected" >&2
        exit 1
    }
    grep -q "Optimal solution found." "$log" || {
        echo "Optimal solution marker not found in $name output" >&2
        exit 1
    }
}

if [[ "$BACKEND" == "pdlp" || "$BACKEND" == "both" ]]; then
    run_backend pdlp 0 "Batch PDLP only for strong branching"
fi

if [[ "$BACKEND" == "madipm" || "$BACKEND" == "both" ]]; then
    run_backend madipm 1 "Batch MadIPM only for strong branching"
fi
