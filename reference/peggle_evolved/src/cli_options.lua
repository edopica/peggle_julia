-- Session-wide CLI options shared between main.lua entry points and the
-- game state machine. main.lua populates this table after parsing arg;
-- consumers (GameState, BenchMode) read from it to wire the Engine.
local cli_options = {
	gameplay_trace_file = nil,
	retain_shot_timeline = false,
	headless = false,
}

return cli_options
