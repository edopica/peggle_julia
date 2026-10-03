-- Slide level regression test.
--
-- Regression: the shared-boundary reducer in Engine:reducePegContacts
-- (src/engine/core.lua) collapses adjacent same-iteration grazes on a
-- zero-gap line into a single score. A straight-down launch on the real
-- slide rail must graze/score EVERY rail peg, but four are silently dropped.
local H = require("tests.helpers.engine_helpers")
local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")
local Path = require("src.systems.path")
local Lines = require("src.systems.lines")

return {
	setup = function()
		LevelManager.virtual_width = 1200
		LevelManager.virtual_height = 1900
		Config.virtual_width = 1200
		Config.virtual_height = 1900
		Config.gravity = 1000
		Config.launch_speed = 800
	end,

	test_straight_drop_scores_every_rail_peg = function()
		-- Regression for the shared-boundary reducer dropping adjacent
		-- same-iteration grazes: a straight drop must score all 38 rail pegs.
		local launch_x = 600
		local rail = Path.new({
			{ kind = "line", p0 = { launch_x - 16.25, 220 }, p1 = { launch_x - 16.25, 980 } },
		})
		local line_pegs = Lines.generate({
			id = "slide_rail",
			path = rail,
			peg = { kind = "circle", radius = 10 },
			gap = 0,
		})

		local eng = H.new_engine()
		H.setup_engine(eng, line_pegs, { red = 0, green = 0 }, 1)
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)

		local missed = {}
		for _, p in ipairs(line_pegs) do
			if p.hit ~= true then
				table.insert(missed, p.line.index)
			end
		end

		assert_eq(#missed, 0,
			"every rail peg must score on a straight drop; total=" .. #line_pegs ..
			" missed indices=[" .. table.concat(missed, ",") .. "]")
	end,
}
