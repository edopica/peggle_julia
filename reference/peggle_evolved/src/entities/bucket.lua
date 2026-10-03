local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")
local Bucket = {}

-- Half the total span of the bucket (hole plus both edges), measured from its center.
local function halfSpan(bucket)
	return bucket.hole / 2 + bucket.edge
end

function Bucket.new()
	local w = LevelManager.virtual_width
	local h = LevelManager.virtual_height
	return {
		x = w / 2, -- center x
		prev_x = w / 2,
		top = h - Config.bucket_margin - Config.bucket_height, -- y of the catch opening
		hole = Config.bucket_hole,
		edge = Config.bucket_edge,
		height = Config.bucket_height,
		phase = math.pi / 2, -- starts at center, moving right
	}
end

-- Slide the bucket back and forth, bouncing off the screen sides.
function Bucket.update(bucket, dt)
	local w = LevelManager.virtual_width
	local half = halfSpan(bucket)
	local center = w / 2
	local amplitude = center - half

	-- Calculate the max acceleration based on level width and config multiplier
	local max_accel = Config.bucket_accel_multiplier * w

	-- Calculate the angular frequency (omega) for the sinusoidal motion
	-- Based on the formula: a_max = amplitude * omega^2
	local omega = math.sqrt(max_accel / amplitude)

	-- Advance the phase
	bucket.phase = bucket.phase + omega * dt
	bucket.phase = bucket.phase % (math.pi * 2) -- prevent float precision loss over time

	-- Calculate new position based on phase
	bucket.x = center - amplitude * math.cos(bucket.phase)
end

-- Resolve the ball against the bucket as it falls past the opening's top edge.
-- Resolve a circle (the ball) against an axis-aligned rectangle, reflecting off
-- the actual surface normal (top, side, or corner) with restitution applied so
-- the ball loses energy instead of being flung away. Returns true on contact.
local function collideRect(ball, rx, ry, rw, rh)
	local r = ball.radius

	-- Closest point on the rectangle to the ball's center.
	local cx = math.max(rx, math.min(ball.x, rx + rw))
	local cy = math.max(ry, math.min(ball.y, ry + rh))
	local dx = ball.x - cx
	local dy = ball.y - cy
	local d2 = dx * dx + dy * dy

	if d2 >= r * r then
		return false
	end

	local nx, ny
	if d2 > 1e-8 then
		-- Outside the rect: normal points from the closest surface point to the center.
		local dist = math.sqrt(d2)
		nx, ny = dx / dist, dy / dist
		ball.x = cx + nx * r
		ball.y = cy + ny * r
	else
		-- Center inside the rect: eject along the shallowest axis.
		local toLeft, toRight = ball.x - rx, (rx + rw) - ball.x
		local toTop, toBottom = ball.y - ry, (ry + rh) - ball.y
		local m = math.min(toLeft, toRight, toTop, toBottom)
		if m == toLeft then
			nx, ny, ball.x = -1, 0, rx - r
		elseif m == toRight then
			nx, ny, ball.x = 1, 0, rx + rw + r
		elseif m == toTop then
			nx, ny, ball.y = 0, -1, ry - r
		else
			nx, ny, ball.y = 0, 1, ry + rh + r
		end
	end

	-- Reflect the velocity along the contact normal (only if moving into the surface).
	local dot = ball.vx * nx + ball.vy * ny
	if dot < 0 then
		local e = 1 + Config.restitution
		ball.vx = ball.vx - e * dot * nx
		ball.vy = ball.vy - e * dot * ny
	end
	return true
end

-- Returns:
--   "caught"  - ball fell into the hole (award the bonus, end the turn)
--   "bounced" - ball struck a solid wall or the base (reflected off the surface)
--   nil       - no interaction this step
function Bucket.resolve(bucket, ball)
	local holeHalf = bucket.hole / 2

	-- Caught: the ball drops into the opening between the two walls.
	if ball.vy > 0
		and ball.y + ball.radius >= bucket.top
		and ball.y - ball.radius <= bucket.top + bucket.height
		and math.abs(ball.x - bucket.x) <= holeHalf
	then
		return "caught"
	end

	-- Otherwise collide with the solid parts: the two side walls and the base.
	local edge, height, top = bucket.edge, bucket.height, bucket.top
	local leftX = bucket.x - holeHalf - edge
	local rightX = bucket.x + holeHalf

	local hit = false
	if collideRect(ball, leftX, top, edge, height) then hit = true end
	if collideRect(ball, rightX, top, edge, height) then hit = true end
	if collideRect(ball, leftX, top + height, bucket.hole + edge * 2, edge) then hit = true end

	return hit and "bounced" or nil
end

function Bucket.draw(bucket, alpha)
	alpha = alpha or 1
	love.graphics.setColor(Config.bucket_color)

	local holeHalf = bucket.hole / 2
	local y = bucket.top
	local height = bucket.height
	local edge = bucket.edge

	local draw_x = bucket.prev_x + (bucket.x - bucket.prev_x) * alpha

	-- Two solid side walls flanking the open hole.
	love.graphics.rectangle("fill", draw_x - holeHalf - edge, y, edge, height)
	love.graphics.rectangle("fill", draw_x + holeHalf, y, edge, height)
	-- Base connecting the walls (sits below the catch line, so the hole stays open).
	love.graphics.rectangle("fill", draw_x - holeHalf - edge, y + height, bucket.hole + edge * 2, edge)
end

return Bucket
