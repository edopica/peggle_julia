-- ===========================================================================
-- Powers: green-peg special effects.
--
-- Powers.activate is called by the Engine during the authoritative peg-hit
-- reduction phase (outside the CCD collision loop). It returns a list of ball
-- spawn specs; the Engine creates, registers (stable IDs), and stages the
-- spawned balls so they begin physics on the following fixed step.
--
-- `peg` is the green peg that was hit.
-- Returns: an array of { x=, y=, vx=, vy= } spawn specs (may be empty).
-- ===========================================================================

local Powers = {}

function Powers.activate(peg)
	--print("[Powers] Green peg special power triggered. Spawning Multiball!")
	return {
		{ x = peg.x, y = peg.y - 10, vx = 150, vy = -200 },
		{ x = peg.x, y = peg.y - 10, vx = -150, vy = -200 },
	}
end

return Powers
