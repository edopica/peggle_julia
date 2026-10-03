.PHONY: help verify list self-check baseline quick test

help:
	@echo "Targets:"
	@echo "  verify      verify the vendored reference against its manifest"
	@echo "  list        list baseline workloads"
	@echo "  self-check  validate grid identity and candidate determinism"
	@echo "  quick       short sweep (every 20th aim index) on all workloads"
	@echo "  baseline    full-grid M0 baseline (long; writes results/raw/)"
	@echo "  test        run the reference Lua test suite (pinned tree)"

verify:
	scripts/verify_reference.sh

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
