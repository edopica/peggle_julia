.PHONY: run trace bench test-styles replays replay help

# Extract positional arguments for test-styles
TEST_STYLE = $(word 2, $(MAKECMDGOALS))
ifeq ($(TEST_STYLE),)
  TEST_STYLE = long_shot
endif

# Extract positional argument for replay (default: latest saved replay)
REPLAY = $(word 2, $(MAKECMDGOALS))
ifeq ($(REPLAY),)
  REPLAY = latest
endif

help:
	@echo "Available commands:"
	@echo "  make run                            - Run the game normally"
	@echo "  make trace                          - Replay the last shot and export traces to debug_trace.jsonl"
	@echo "  make bench                          - Run the game in benchmark mode"
	@echo "  make test-styles [style]            - Run the style shot brute-forcer (default: long_shot)"
	@echo "  make replays                        - List saved replays in replays/"
	@echo "  make replay [name]                  - Replay a saved replay (default: latest)"

run:
	love .

trace:
	love . -- --replay src/replays/last_shot.lua --export-traces debug_trace.jsonl

bench:
	love . -- --bench

test-styles:
	love . -- --test-style-shot --level $(TEST_STYLE) --target-style $(TEST_STYLE)

replays:
	love . -- --list-replays

replay:
	love . -- --replay $(REPLAY)

# Catch-all target for positional arguments
%:
	@:
