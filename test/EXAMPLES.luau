local UI = require(path.to.UIFramework)

--1. Basic component
local comp = UI.mount(myFrame, function(state, api)
	api.useEffect(function()
		print("mounted!")
		return function() print("cleanup") end
	end, {})

	return {
		[myFrame.Title] = {
			TextColor3 = state.active and Color3.new(1,1,0) or Color3.new(1,1,1),
			_duration  = 0.3,
		}
	}
end, { initialState = { active = false } })

comp:setState({ active = true })
comp:unmount()


-- 2. Event & Change markers
local Event  = UI.Event
local Change = UI.Change

UI.mount(frame, function(state, api)
	return {
		[button] = {
			Text = state.label,
			[Event.MouseButton1Click] = function(rbx)
				api.setState({ label = "Clicked!" })
			end,
			[Change.Text] = function(rbx)
				print("text changed to", rbx.Text)
			end,
		}
	}
end, { initialState = { label = "Click me" } })


-- 3. Bindings (zero re-render animations)
local hp, setHp = UI.createBinding(100)

-- Link directly to a property with an optional transform:
local disconnect = UI.linkBinding(hp, healthBar, "Size", function(v)
	return UDim2.new(v / 100, 0, 1, 0)
end)

setHp(75)   -- healthBar.Size updates instantly, no re-render

-- Derived binding:
local hpPct = hp:map(function(v) return math.floor(v) .. "%" end)

-- Join multiple bindings:
local stats = UI.joinBindings({ hp = hp, mp = mpBinding })
print(stats:getValue())  -- { hp = 75, mp = 50 }

disconnect()  -- stop the link


--4. Context (pass values without prop drilling) 
local ThemeContext = UI.createContext({ primary = Color3.new(1, 1, 1) })

-- Parent component provides a theme:
UI.mount(rootFrame, function(state, api)
	api.provideContext(ThemeContext, { primary = Color3.new(0.2, 0.4, 1) })
	return {}
end)

-- Any descendant reads it:
UI.mount(childFrame, function(state, api)
	local theme = api.useContext(ThemeContext)
	return {
		[childFrame] = { BackgroundColor3 = theme.primary }
	}
end)


--5. Memo (skip renders when props unchanged) 
local ExpensiveRow = UI.memo(function(state, api)
	-- Only re-runs when state keys actually change
	return { [rowFrame] = { Text = state.label } }
end)

UI.mount(rowFrame, ExpensiveRow, { initialState = { label = "Row 1" } })


--6. forwardRef (expose child API to parent) 
local InputComp = UI.forwardRef(function(state, ref, api)
	if ref then
		ref.current = {
			focus  = function() textBox:CaptureFocus() end,
			clear  = function() api.setState({ value = "" }) end,
		}
	end
	return { [textBox] = { Text = state.value } }
end)

local inputRef = { current = nil }
UI.mount(frame, InputComp, {
	initialState = { value = "" },
	ref          = inputRef,
})

inputRef.current.focus()   -- call child methods from parent


--7. Signals
UI.on("player:died", function(player) print(player, "died") end)
UI.emit("player:died", player)


--8. Animations 
UI.animate(frame, { Size = UDim2.new(1,0,1,0) }, { duration = 0.5 })
UI.Presets.bounceIn(frame)
UI.Presets.shake(frame, { strength = 10 })

local loopId = UI.loop(frame, {
	{ goals = { Rotation = 360 }, duration = 2, easing = UI.Types.Easing.LINEAR },
}, {})
UI.stopLoop(loopId)


-- 9. Standalone hooks 
local get, set, sub = UI.useState(0)
set(42)
sub(function(v) print("changed to", v) end)

local hp2, setHp2 = UI.useBinding(100)
setHp2(80)
print(hp2:getValue())  -- 80
