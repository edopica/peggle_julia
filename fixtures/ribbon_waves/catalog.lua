-- ribbon_waves v3 fixture catalog (world-scale, 5 continuous zero-gap slides).
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
		  note = "center drop: 312 steps, 21 pegs (5 circles + 16 ribbon), 5 red, 0 spawned, 13,860 pts (peg 13,860), multiplier 1, no styles" },
		{ id = "ribbon_waves_left_wall", category = "style", kind = "shot",
		  level = "ribbon_waves", aim_index = 1800, trace = true,
		  note = "true left-wall launch (vx < 0): 658 steps, 20 pegs (7 circles + 13 ribbon), 2 red, 0 spawned, 7,600 pts, multiplier 1, no style awarded" },
		{ id = "ribbon_waves_ribbon", category = "power", kind = "shot",
		  level = "ribbon_waves", aim_index = 120, trace = true,
		  note = "shallow launch across the waves: 434 steps, 41 pegs (13 circles + 28 ribbon), 7 red, 2 spawned, 47,640 pts (peg 42,640 + 5,000 slide), multiplier 1, slide style awarded (1)" },
	},
}
