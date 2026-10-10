.PHONY: help verify export fixtures fixture-list check check-all list self-check quick baseline test julia-test julia-parity julia-bench capture-m2 capture-m2-check math-census math-census-check core-math-build core-math-verify wpd-math wpd-state-capture wpd-state-compare wpd-state wpd-trace wpd-perf

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
	@echo "  julia-parity recompute the cross-machine parity manifest"
	@echo "  julia-bench  checkpoint/reset benchmark (writes results/)"
	@echo "  capture-m2   capture RNG/peg-color/checkpoint fixtures (needs LÖVE)"
	@echo "  capture-m2-check re-capture the M2 fixtures and require equality"
	@echo "  math-census  capture the math census fixture and emit the Julia summary"
	@echo "  math-census-check re-capture the math census fixture and compare"
	@echo "  core-math-build build the pinned native math component (linux-x86_64)"
	@echo "  core-math-verify verify the native pin, artifact, and ABI/symbol audit"

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

# WP-F: math/checkpoint/sweep performance comparison.
wpd-perf:
	scripts/core_math_perf.sh
