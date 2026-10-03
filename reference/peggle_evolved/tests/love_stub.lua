-- Minimal LÖVE stub for headless unit/integration tests.
-- Provides only what the gameplay modules need to run deterministically without
-- a window/graphics context. No real rendering, input, or timers are emulated
-- beyond the deterministic surface the modules touch.

local love = {}

-- math
love.math = {}
local RandomGenerator = {}
RandomGenerator.__index = RandomGenerator
function love.math.newRandomGenerator(seed)
	local self = setmetatable({}, RandomGenerator)
	self.s = seed or 0
	self:random() -- warm
	return self
end
function RandomGenerator:random(a, b)
	-- Simple deterministic LCG (not crypto; just stable across runs).
	self.s = (self.s * 1664525 + 1013904223) % 2147483648
	local r = (self.s / 2147483648)
	if a == nil then return r end
	if b == nil then return math.floor(r * a) + 1 end
	return math.floor(r * (b - a + 1)) + a
end
function RandomGenerator:seed(s) self.s = s or 0 end

-- graphics (no-ops)
love.graphics = {
	color = {1,1,1,1},
	setColor = function() end,
	rectangle = function() end,
	circle = function() end,
	polygon = function() end,
	push = function() end,
	pop = function() end,
	translate = function() end,
	rotate = function() end,
	scale = function() end,
	setScissor = function() end,
	clear = function() end,
	print = function() end,
	printf = function() end,
	draw = function() end,
	getFont = function() return {} end,
	newText = function(_, s) return {getWidth=function() return 1 end, getHeight=function() return 1 end} end,
	getDimensions = function() return 1920, 1080 end,
	getWidth = function() return 1920 end,
	getHeight = function() return 1080 end,
}

-- window
love.window = {
	setMode = function() end,
	setTitle = function() end,
	getVSync = function() return 1 end,
	getDisplayCount = function() return 1 end,
	getDesktopDimensions = function() return 1920, 1080 end,
}

-- timer
love.timer = {
	getTime = function() return 0 end,
	getDelta = function() return 1/60 end,
	getAverageDelta = function() return 1/60 end,
	getFPS = function() return 60 end,
}

-- keyboard
love.keyboard = {
	isDown = function() return false end,
}

-- mouse
love.mouse = {
	isDown = function() return false end,
	getPosition = function() return 0, 0 end,
}

-- event
love.event = {
	quit = function() end,
}

_G.love = love
return love
