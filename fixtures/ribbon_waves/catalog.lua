-- ribbon_waves v5 fixture catalog (world-scale, 5 continuous zero-gap slides).
--
-- Captured from the peggle_evolved dev tree with
-- scripts/capture_ribbon_waves.sh.  Each ribbon is one `Lines.generate`
-- line (the squiggly_circle/mustache primitive), not a chain of bricks.
-- Aim 900 is the straight drop; aim 0 launches toward +x (right wall) and
-- aim 1800 toward -x (left wall).
return {
	version = 1,
	fixtures = {
		{ id = "ribbon_waves_center", category = "completion", kind = "shot",
		  level = "ribbon_waves", aim_index = 900, trace = true,
		  note = "center: 156 steps, 12 pegs, 3 red, 0 spawned, 20,560 points" },
		{ id = "ribbon_waves_left_wall", category = "style", kind = "shot",
		  level = "ribbon_waves", aim_index = 1800, trace = true,
		  note = "left_wall: 590 steps, 25 pegs, 6 red, 0 spawned, 24,750 points" },
		{ id = "ribbon_waves_ribbon", category = "power", kind = "shot",
		  level = "ribbon_waves", aim_index = 80, trace = true,
		  note = "ribbon: 265 steps, 6 pegs, 1 red, 0 spawned, 900 points" },
	},
}
