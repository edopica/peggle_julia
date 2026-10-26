.PHONY: help verify export fixtures fixture-list check check-all list self-check quick baseline test julia-test julia-scripts-test julia-scripts-integration julia-parity julia-bench capture-m2 capture-m2-check math-census math-census-check core-math-build core-math-verify wpd-math wpd-state-capture wpd-state-compare wpd-state wpd-trace wpd-compare-hosts wpd-perf wpd-parity m3-trace m3-mustache m3-sweep m3-bench m4-parity m4-replay m4-bench

JULIA = julia --project=julia/PeggleSim

help:
	@echo "Targets:"
	@echo "  verify       verify the vendored reference against its manifest"
	@echo "  export       regenerate interchange artifacts and SVG level previews"
	@echo "  fixtures     capture reference fixture records (needs LÖVE/display)"
	@echo "  fixture-list list the reference fixture catalog"
	@echo "  check        interchange reproducibility + schema validation"
	@echo "  check-all    check plus fixture re-capture comparison (needs display)"
	@echo "  list         list baseline workloads"
	@echo "  self-check   validate grid identity and candidate determinism"
	@echo "  quick        short sweep (every 20th aim index) on all workloads"
	@echo "  baseline     full-grid M0 baseline (long; writes results/raw/)"
	@echo "  test         run the reference Lua test suite (pinned tree)"
	@echo "  julia-test   run the Julia package test suite"
	@echo "  julia-scripts-test run the Julia benchmark-execution harness tests"
	@echo "  julia-scripts-integration run one real end-to-end benchmark smoke (~30 s)"
	@echo "  julia-parity recompute the cross-machine parity manifest"
	@echo "  julia-bench  checkpoint/reset benchmark (writes results/)"
	@echo "  capture-m2   capture RNG/peg-color/checkpoint fixtures (needs LÖVE)"
	@echo "  capture-m2-check re-capture the M2 fixtures and require equality"
	@echo "  math-census  capture the math census fixture and emit the Julia summary"
	@echo "  math-census-check re-capture the math census fixture and compare"
	@echo "  core-math-build build the pinned native math component (linux-x86_64)"
	@echo "  core-math-verify verify the native pin, artifact, and ABI/symbol audit"
	@echo "  wpd-parity   experimental CORE-MATH-era parity capture + local comparison"
	@echo "  m4-parity    M4 correctness-breadth parity (replay, sweeps, threads, scenarios)"
	@echo "  m4-replay    M4 fixture replay + trace parity into results/m4/"
	@echo "  m4-bench     M4 representative performance benchmark (throughput, latency, alloc, RSS)"

verify:
	scripts/verify_reference.sh

export:
	scripts/export_interchange.sh

fixtures:
	scripts/capture_fixtures.sh

fixture-list:
	scripts/capture_fixtures.sh --list-fixtures

check:
	scripts/check_interchange.sh

check-all:
	scripts/check_interchange.sh --with-fixtures

list:
	scripts/love.sh love harness -- --list

self-check:
	scripts/love.sh love harness -- --self-check --check-candidates 3

quick:
	scripts/run_baseline.sh --stride 20

baseline:
	scripts/run_baseline.sh

test:
	rm -rf tmp/testrun
	mkdir -p tmp/testrun
	cp -r reference/peggle_evolved/. tmp/testrun/
	mkdir -p tmp/testrun/temp tmp/testrun/replays
	cd tmp/testrun && luajit tests/run.lua

julia-test:
	$(JULIA) -e 'using Pkg; Pkg.test()'

julia-scripts-test:
	$(JULIA) scripts/tests/runtests.jl

julia-scripts-integration:
	$(JULIA) scripts/tests/integration_runner.jl

julia-parity:
	$(JULIA) julia/PeggleSim/bin/parity_emit.jl

julia-bench:
	$(JULIA) julia/PeggleSim/bin/checkpoint_bench.jl

capture-m2:
	scripts/capture_m2.sh

capture-m2-check:
	scripts/capture_m2.sh --check

math-census:
	scripts/capture_math_census.sh
	$(JULIA) julia/PeggleSim/bin/math_census.jl

math-census-check:
	scripts/capture_math_census.sh --check

core-math-build:
	native/build.sh

core-math-verify:
	scripts/verify_core_math.sh

# WP-D experimental comparisons (CORE-MATH vs historical vs oracle).
# Outputs land under tmp/core-math/; historical fixtures are never modified.
wpd-math:
	scripts/core_math_compare.sh

wpd-state-capture:
	scripts/capture_wpd_state.sh

wpd-state-compare:
	scripts/compare_wpd_state.sh

wpd-state: wpd-state-capture wpd-state-compare

# WP-E: gameplay traces and candidate samples (single host; needs LÖVE).
wpd-trace:
	scripts/core_math_trace.sh

# WP-E: compare two scripts/wpd_capture_host.sh capture dirs (Linux; python3).
wpd-compare-hosts:
	scripts/wpd_compare_hosts.sh $(ARGS)

# WP-F: math/checkpoint/sweep performance comparison.
wpd-perf:
	scripts/core_math_perf.sh

# M3 shot evaluator: mustache traces, Lua-vs-Julia control comparison, and a
# short parallel sweep. The level/config artifacts are the dev-tree corpus
# under fixtures/mustache/.
M3_LEVEL = fixtures/mustache/artifact/mustache.v1.json
M3_CONFIG = fixtures/mustache/config.dev.v1.json
M3_SHOT_BENCH = julia/PeggleSim/bin/shot_bench.jl

m3-trace:
	$(JULIA) $(M3_SHOT_BENCH) --fixture m3_mustache_center --level $(M3_LEVEL) --config $(M3_CONFIG) --aim 900 --category completion --snapshots --trace-out results/m3/traces/m3_mustache_center.jsonl --expected-out results/m3/expected/m3_mustache_center.json
	$(JULIA) $(M3_SHOT_BENCH) --fixture m3_mustache_left_wall --level $(M3_LEVEL) --config $(M3_CONFIG) --aim 0 --category power --snapshots --trace-out results/m3/traces/m3_mustache_left_wall.jsonl --expected-out results/m3/expected/m3_mustache_left_wall.json
	$(JULIA) $(M3_SHOT_BENCH) --fixture m3_mustache_right_wall --level $(M3_LEVEL) --config $(M3_CONFIG) --aim 1800 --category style --snapshots --trace-out results/m3/traces/m3_mustache_right_wall.jsonl --expected-out results/m3/expected/m3_mustache_right_wall.json

m3-mustache:
	scripts/compare_m3_mustache.sh

m3-sweep:
	$(JULIA) -t auto $(M3_SHOT_BENCH) --sweep --level $(M3_LEVEL) --config $(M3_CONFIG) --stride 200 --verify-serial --out results/m3/sweep.jsonl --summary results/m3/sweep-summary.json

m3-bench:
	scripts/bench_m3.sh

# M4 correctness-breadth parity: fixture/trace replay, candidate sweeps for the
# M4 workloads, thread identity, the scenario probe, and a combined report
# under results/m4/. The Lua sweeps run the frozen pinned tree
# (reference/peggle_evolved), which stays read-only.
M4_REPLAY = julia/PeggleSim/bin/replay_fixtures.jl

m4-parity:
	scripts/m4_parity.sh

m4-replay:
	$(JULIA) $(M4_REPLAY)

# M4 representative performance gate: seven workloads x Lua/Julia, thread
# scaling, allocation, peak process RSS, and a tracing on/off diagnostic. The
# full-grid stride-1 reference is reused read-only from results/m4/. Raw
# artifacts land under results/raw/ (gitignored); the report is
# results/m4/bench-report.json. Pass options with ARGS=..., e.g.
#   make m4-bench ARGS="--threads '1 2 4'"
m4-bench:
	scripts/bench_m4.sh $(ARGS)

# WP-D open item: experimental CORE-MATH-era parity inputs and local manifests.
# Captures the census through the dev tree + core_math, emits one manifest from
# those inputs, then runs the two-run local comparison. Historical fixtures
# and results/parity/local.json are never modified.
wpd-parity:
	scripts/capture_wpd_parity_census.sh
	PEGGLE_MATH_BACKEND=core_math $(JULIA) julia/PeggleSim/bin/parity_emit.jl \
	  --census tmp/core-math/parity/math_census.v1.json \
	  --label core_math-local \
	  --out tmp/core-math/parity/core_math-local.json
	scripts/wpd_parity_check.sh
