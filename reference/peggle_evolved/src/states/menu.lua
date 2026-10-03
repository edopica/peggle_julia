local States = require("src.states")

-- ===========================================================================
-- Menu State
-- ===========================================================================
local MenuState = {}

function MenuState:enter() end
function MenuState:leave() end

function MenuState:update(dt) end

function MenuState:draw()
	love.graphics.setColor(0.05, 0.05, 0.1)
	love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

	local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
	local font = love.graphics.getFont()

	love.graphics.setColor(1, 1, 1, 0.9)
	local title = love.graphics.newText(font, "PEGGLE EVOLVED")
	love.graphics.draw(title, ww / 2 - title:getWidth() / 2, wh * 0.15)

	local bw, bh, gap = 260, 64, 24
	local by = wh * 0.45
	local bx = ww / 2 - bw / 2
	local mx, my = love.mouse.getPosition()

	-- Solo button
	local solo_hover = mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
	love.graphics.setColor(solo_hover and { 0.2, 0.5, 0.8 } or { 0.15, 0.35, 0.6 })
	love.graphics.rectangle("fill", bx, by, bw, bh, 8)
	love.graphics.setColor(1, 1, 1)
	local solo_text = love.graphics.newText(font, "SOLO MODE")
	love.graphics.draw(solo_text, bx + bw / 2 - solo_text:getWidth() / 2, by + bh / 2 - solo_text:getHeight() / 2)

	-- 1v1 button
	by = by + bh + gap
	local pvp_hover = mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
	love.graphics.setColor(pvp_hover and { 0.8, 0.3, 0.3 } or { 0.5, 0.15, 0.15 })
	love.graphics.rectangle("fill", bx, by, bw, bh, 8)
	love.graphics.setColor(1, 1, 1)
	local pvp_text = love.graphics.newText(font, "1v1 MODE")
	love.graphics.draw(pvp_text, bx + bw / 2 - pvp_text:getWidth() / 2, by + bh / 2 - pvp_text:getHeight() / 2)
end

function MenuState:mousepressed(x, y, button)
	if button ~= 1 then return end
	local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
	local bw, bh, gap = 260, 64, 24
	local by1 = wh * 0.45
	local by2 = by1 + bh + gap
	local bx = ww / 2 - bw / 2

	if x >= bx and x <= bx + bw and y >= by1 and y <= by1 + bh then
		States.switch("level_select", "solo")
	elseif x >= bx and x <= bx + bw and y >= by2 and y <= by2 + bh then
		States.switch("level_select", "1v1")
	end
end

function MenuState:keypressed(key)
	if key == "escape" then
		love.event.quit()
	end
end

States.menu = MenuState
return MenuState
