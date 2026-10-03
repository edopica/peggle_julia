-- ===========================================================================
-- State Machine Router
-- ===========================================================================
local States = { current = nil, mode = nil }

function States.switch(name, ...)
	if States.current and States.current.leave then
		States.current:leave()
	end
	local state = States[name]
	if state and state.enter then
		state:enter(...)
	end
	States.current = state
end

return States
