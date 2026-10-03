local Screen = {}

Screen.scale = 1
Screen.offsetX = 0
Screen.offsetY = 0

function Screen.resize(w, h)
	-- LevelManager is the source of truth for virtual dimensions.
	-- Lazy-require to break the circular dependency (LevelManager requires Screen).
	local LevelManager = require("src.systems.level_manager")
	local vw = LevelManager.virtual_width
	local vh = LevelManager.virtual_height

	local scaleX = w / vw
	local scaleY = h / vh

	Screen.scale = math.min(scaleX, scaleY)
	Screen.offsetX = (w - (vw * Screen.scale)) / 2
	Screen.offsetY = (h - (vh * Screen.scale)) / 2
end

function Screen.to_world(x, y)
	return (x - Screen.offsetX) / Screen.scale, (y - Screen.offsetY) / Screen.scale
end

function Screen.apply()
	love.graphics.push()
	love.graphics.translate(Screen.offsetX, Screen.offsetY)
	love.graphics.scale(Screen.scale, Screen.scale)

	-- LevelManager is the source of truth for virtual dimensions.
	local LevelManager = require("src.systems.level_manager")
	local vw = LevelManager.virtual_width
	local vh = LevelManager.virtual_height
	love.graphics.setScissor(Screen.offsetX, Screen.offsetY, vw * Screen.scale, vh * Screen.scale)
end

function Screen.clear()
	love.graphics.setScissor()
	love.graphics.pop()
end

return Screen
