local Config = require("src.config")
local ContactEvents = require("src.systems.contact_events")
local Ball = {}

function Ball.new(x, y)
	return {
		x = x,
		y = y,
		prev_x = x,
		prev_y = y,
		vx = 0,
		vy = 0,
		radius = Config.ball_radius,
		launched = false,
	}
end

-- Pure interpolated draw position for a given alpha. This is exactly the
-- calculation Ball.draw uses, factored out so instrumentation and rendering
-- always agree.
function Ball.sampleDrawPosition(ball, alpha)
	alpha = math.max(0, math.min(1, alpha or 1))
	local draw_x = ball.x
	local draw_y = ball.y

	if ball.draw_path and #ball.draw_path > 1 then
		for i = 1, #ball.draw_path - 1 do
			local p1 = ball.draw_path[i]
			local p2 = ball.draw_path[i+1]
			if alpha >= p1.t and alpha <= p2.t then
				local range = p2.t - p1.t
				local segment_t = (range > 0) and ((alpha - p1.t) / range) or 1
				draw_x = p1.x + (p2.x - p1.x) * segment_t
				draw_y = p1.y + (p2.y - p1.y) * segment_t
				break
			end
		end
	else
		draw_x = ball.prev_x + (ball.x - ball.prev_x) * alpha
		draw_y = ball.prev_y + (ball.y - ball.prev_y) * alpha
	end

	return draw_x, draw_y
end

function Ball.draw(ball, alpha)
	local draw_x, draw_y = Ball.sampleDrawPosition(ball, alpha)

	-- Render-only contact presentation: for exactly one frame per collision,
	-- draw the ball at the exact impact center (physics state untouched).
	local ox, oy = ContactEvents.ball_override(ball)
	if ox then
		draw_x, draw_y = ox, oy
	end

	love.graphics.setColor(Config.ball_color)
	love.graphics.circle("fill", draw_x, draw_y, ball.radius)
end

return Ball
