-- Imported screenshot levels (b1, b2, g1, m1, m2) fixture catalog.
--
-- Captured from the peggle_evolved dev tree with
-- scripts/capture_imported_levels.sh. Five fixed aims per level span the
-- grid (0 = toward the right wall, 900 = straight drop, 1800 = toward the
-- left wall). The corpus checks Lua/Julia shot parity on boards that use the
-- dev-tree `ribbon` gameplay peg; b2 is the annular/rectangle control.
return {
	version = 1,
	fixtures = {
		-- B1: 6 circles, 24 rectangles, 64 ribbons
		{ id = "b1_right_wall", category = "completion", kind = "shot",
		  level = "b1", aim_index = 0, trace = true },
		{ id = "b1_right", category = "completion", kind = "shot",
		  level = "b1", aim_index = 450, trace = true },
		{ id = "b1_center", category = "completion", kind = "shot",
		  level = "b1", aim_index = 900, trace = true },
		{ id = "b1_left", category = "completion", kind = "shot",
		  level = "b1", aim_index = 1350, trace = true },
		{ id = "b1_left_wall", category = "completion", kind = "shot",
		  level = "b1", aim_index = 1800, trace = true },
		-- B2: 19 circles, 57 rectangles, 13 annular (no ribbons)
		{ id = "b2_right_wall", category = "completion", kind = "shot",
		  level = "b2", aim_index = 0, trace = true },
		{ id = "b2_right", category = "completion", kind = "shot",
		  level = "b2", aim_index = 450, trace = true },
		{ id = "b2_center", category = "completion", kind = "shot",
		  level = "b2", aim_index = 900, trace = true },
		{ id = "b2_left", category = "completion", kind = "shot",
		  level = "b2", aim_index = 1350, trace = true },
		{ id = "b2_left_wall", category = "completion", kind = "shot",
		  level = "b2", aim_index = 1800, trace = true },
		-- G1: 35 circles, 61 ribbons
		{ id = "g1_right_wall", category = "completion", kind = "shot",
		  level = "g1", aim_index = 0, trace = true },
		{ id = "g1_right", category = "completion", kind = "shot",
		  level = "g1", aim_index = 450, trace = true },
		{ id = "g1_center", category = "completion", kind = "shot",
		  level = "g1", aim_index = 900, trace = true },
		{ id = "g1_left", category = "completion", kind = "shot",
		  level = "g1", aim_index = 1350, trace = true },
		{ id = "g1_left_wall", category = "completion", kind = "shot",
		  level = "g1", aim_index = 1800, trace = true },
		-- M1: 68 circles, 22 ribbons
		{ id = "m1_right_wall", category = "completion", kind = "shot",
		  level = "m1", aim_index = 0, trace = true },
		{ id = "m1_right", category = "completion", kind = "shot",
		  level = "m1", aim_index = 450, trace = true },
		{ id = "m1_center", category = "completion", kind = "shot",
		  level = "m1", aim_index = 900, trace = true },
		{ id = "m1_left", category = "completion", kind = "shot",
		  level = "m1", aim_index = 1350, trace = true },
		{ id = "m1_left_wall", category = "completion", kind = "shot",
		  level = "m1", aim_index = 1800, trace = true },
		-- M2: 63 circles, 52 ribbons
		{ id = "m2_right_wall", category = "completion", kind = "shot",
		  level = "m2", aim_index = 0, trace = true },
		{ id = "m2_right", category = "completion", kind = "shot",
		  level = "m2", aim_index = 450, trace = true },
		{ id = "m2_center", category = "completion", kind = "shot",
		  level = "m2", aim_index = 900, trace = true },
		{ id = "m2_left", category = "completion", kind = "shot",
		  level = "m2", aim_index = 1350, trace = true },
		{ id = "m2_left_wall", category = "completion", kind = "shot",
		  level = "m2", aim_index = 1800, trace = true },
	},
}
