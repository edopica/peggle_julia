#!/usr/bin/env bash
# Invoke via ssh deathstar. Arguments: WORKSPACE prepare|measure|validate [LABEL] [BASELINE_JSON]
set -euo pipefail
[[ $(hostname -s) == deathstar ]] || { echo 'Run on deathstar' >&2; exit 2; }
workspace=${1:?workspace required}
mode=${2:?prepare, measure, or validate required}
cd "$workspace"
export JULIA_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=1 JULIA_PKG_PRECOMPILE_AUTO=0
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 PEGGLE_MATH_BACKEND=system_libm
mkdir -p tmp/allocation
julia_bin=/home/picazio/.julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia
julia_cmd=(nice -n 10 timeout 900 "$julia_bin" --startup-file=no --gcthreads=1 --project=julia/PeggleSim)
verify_after() { make verify > tmp/allocation/verify-after.log 2>&1; }
make verify > tmp/allocation/verify-before.log 2>&1
trap verify_after EXIT
case "$mode" in
  prepare)
    "${julia_cmd[@]}" -t 1,0 -e 'using Pkg; Pkg.instantiate(;allow_autoprecomp=false); Pkg.precompile()'
    ;;
  measure)
    extra=()
    [[ $# -lt 4 ]] || extra+=("$4")
    taskset -c 0 "${julia_cmd[@]}" -t 1,0 scripts/allocation_bench.jl \
      tmp/allocation/measurement.json "${3:?label required}" "${extra[@]}"
    ;;
  validate)
    "${julia_cmd[@]}" -t 1,0 -e 'using Pkg; Pkg.test(; julia_args=["--startup-file=no", "--threads=1,0", "--gcthreads=1"])' \
      > tmp/allocation/tests.log 2>&1
    "${julia_cmd[@]}" -t 1,0 julia/PeggleSim/bin/parity_emit.jl \
      --out tmp/allocation/parity.json --label deathstar-allocation > tmp/allocation/parity.log 2>&1
    for threads in 1 2 4; do
      "${julia_cmd[@]}" -t "$threads,0" julia/PeggleSim/bin/shot_bench.jl --sweep \
        --level fixtures/mustache/artifact/mustache.v1.json --config fixtures/mustache/config.dev.v1.json \
        --indices 0,200,400,570,600,800,900,1000,1200,1400,1600,1800 \
        --threads "$threads" --verify-serial --out "tmp/allocation/sweep-t$threads.jsonl" \
        --summary "tmp/allocation/sweep-t$threads.json" > "tmp/allocation/sweep-t$threads.log" 2>&1
    done
    cmp tmp/allocation/sweep-t1.jsonl tmp/allocation/sweep-t2.jsonl
    cmp tmp/allocation/sweep-t1.jsonl tmp/allocation/sweep-t4.jsonl
    ;;
  *) echo "Unknown mode: $mode" >&2; exit 2 ;;
esac
