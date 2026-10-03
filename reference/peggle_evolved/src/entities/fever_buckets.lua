local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")
local FeverBuckets = {}

function FeverBuckets.new()
	local w = LevelManager.virtual_width
	local h = LevelManager.virtual_height

	local separator_radius = 40
	local segment = w / 5

	local fever = {
		target_top = h,
		top = h,
		animating = false,
		height = 40,
		dividers = {},
		buckets = {}
	}

	for i = 0, 5 do
		table.insert(fever.dividers, {
			x = i * segment,
			y = fever.top,
			radius = separator_radius,
			is_divider = true
		})
	end

	local values = {10000, 50000, 100000, 50000, 10000}
	for i = 1, 5 do
		table.insert(fever.buckets, {
			x = (i - 1) * segment + separator_radius,
			width = segment - 2 * separator_radius,
			value = values[i]
		})
	end

	return fever
end

function FeverBuckets.activate(fever)
	fever.top = fever.target_top + fever.height + 50
	fever.animating = true
	for _, d in ipairs(fever.dividers) do
		d.y = fever.top
	end
end

function FeverBuckets.update(fever, dt)
	if not fever.animating then
		return
	end

	fever.top = fever.top - Config.fever_bucket_raise_speed * dt

	for _, d in ipairs(fever.dividers) do
		d.y = fever.top
	end

	if fever.top <= fever.target_top then
		fever.top = fever.target_top
		fever.animating = false
		for _, d in ipairs(fever.dividers) do
			d.y = fever.top
		end
	end
end

function FeverBuckets.resolve(fever, ball)
	if ball.y > fever.top and ball.vy > 0 then
		for _, b in ipairs(fever.buckets) do
			if ball.x >= b.x and ball.x <= b.x + b.width then
				return "caught", b.value
			end
		end
		return "caught", 10000
	end
	return nil
end

function FeverBuckets.draw(fever)
	local rect_y = fever.top - fever.height
	for i, b in ipairs(fever.buckets) do
		if i % 2 == 0 then
			love.graphics.setColor(0.2, 0.2, 0.3, 0.8)
		else
			love.graphics.setColor(0.15, 0.15, 0.25, 0.8)
		end
		love.graphics.rectangle("fill", b.x, rect_y, b.width, fever.height)

		love.graphics.setColor(1, 0.8, 0, 1)
		love.graphics.printf(tostring(b.value), b.x, rect_y + 15, b.width, "center")
	end

	love.graphics.setColor(0.8, 0.8, 0.8, 1)
	for _, d in ipairs(fever.dividers) do
		love.graphics.circle("fill", d.x, d.y, d.radius)
	end
end

return FeverBuckets
