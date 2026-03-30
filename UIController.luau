--[[
  MODULES:
    UIController.open(frame, opts)
    UIController.close(frame, opts)
    UIController.toggle(frame, opts)
    UIController.animate(frame, props, opts)
    UIController.loopAnimate(frame, keyframes, opts)
    UIController.stopLoop(id)
    UIController.typewrite(label, text, opts)
    UIController.formatNumber(n, style)
    UIController.formatText(template, data)
    UIController.setColor(instance, color, opts)
    UIController.on(signal, callback)
    UIController.emit(signal, ...)
    UIController.debris(instance, lifetime)
    UIController.mount(frame, component)
    UIController.useState(initial)
    UIController.useEffect(fn, deps)
--]]

local TweenService   = game:GetService("TweenService")
local RunService     = game:GetService("RunService")
local Debris         = game:GetService("Debris")
local HttpService    = game:GetService("HttpService")

--  INTERNAL STATE
local UIController   = {}
local _signals       = {}          -- signal name → { callbacks }
local _loops         = {}          -- loopId → { active, connection }
local _typewriters   = {}          -- label → coroutine handle
local _mounted       = {}          -- frame → component state

--  HELPERS
local function uid()
	return HttpService:GenerateGUID(false):sub(1, 8)
end

local function clamp01(v)
	return math.max(0, math.min(1, v))
end

local function defaultTI(duration, style, direction)
	return TweenInfo.new(
		duration   or 0.35,
		style      or Enum.EasingStyle.Quart,
		direction  or Enum.EasingDirection.Out
	)
end

-- Merge tables (shallow)
local function merge(base, override)
	local t = {}
	for k, v in pairs(base)    do t[k] = v end
	for k, v in pairs(override or {}) do t[k] = v end
	return t
end

--  SIGNAL SYSTEM  (like RBXScriptSignal, but custom)

--[[
  UIController.on(signal, callback)   → returns connection (has :Disconnect())
  UIController.emit(signal, ...)      → fires all listeners
  UIController.once(signal, callback) → fires only once then disconnects
--]]

function UIController.on(signal, callback)
	_signals[signal] = _signals[signal] or {}
	local entry = { fn = callback, active = true }
	table.insert(_signals[signal], entry)
	return {
		Disconnect = function()
			entry.active = false
		end
	}
end

function UIController.once(signal, callback)
	local conn
	conn = UIController.on(signal, function(...)
		conn:Disconnect()
		callback(...)
	end)
	return conn
end

function UIController.emit(signal, ...)
	if not _signals[signal] then return end
	local args = { ... }
	-- iterate copy so disconnects mid-loop are safe
	local list = { table.unpack(_signals[signal]) }
	for _, entry in ipairs(list) do
		if entry.active then
			task.spawn(entry.fn, table.unpack(args))
		end
	end
	-- clean disconnected
	for i = #_signals[signal], 1, -1 do
		if not _signals[signal][i].active then
			table.remove(_signals[signal], i)
		end
	end
end

--  TWEEN BUILDER  (internal)

--[[
  opts = {
    duration  = 0.35,
    style     = Enum.EasingStyle.Quart,
    direction = Enum.EasingDirection.Out,
    delay     = 0,
    repeat    = 0,
    reverses  = false,
    onComplete = function() end,
  }
--]]

local function buildTween(instance, goals, opts)
	opts = opts or {}
	local ti = TweenInfo.new(
		opts.duration  or 0.35,
		opts.style     or Enum.EasingStyle.Quart,
		opts.direction or Enum.EasingDirection.Out,
		opts.repeatCount or 0,
		opts.reverses  or false,
		opts.delay     or 0
	)
	local tween = TweenService:Create(instance, ti, goals)
	if opts.onComplete then
		tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				opts.onComplete(instance)
			end
		end)
	end
	return tween
end

--  OPEN / CLOSE / TOGGLE

--[[
  opts = {
    duration   = 0.35,
    style      = Enum.EasingStyle.Quart,
    direction  = Enum.EasingDirection.Out,
    fromSize   = UDim2,        -- scale-in origin size
    toSize     = UDim2,        -- target size  (default: current)
    fromPos    = UDim2,        -- slide-in start position
    toPos      = UDim2,        -- target position (default: current)
    fade       = true,         -- animate GroupTransparency / BackgroundTransparency
    fadeFrom   = 1,
    fadeTo     = 0,
    onComplete = function() end,
    signal     = "ui:opened",  -- optional emit after complete
  }
--]]

function UIController.open(frame, opts)
	opts = opts or {}
	frame.Visible = true

	local goals = {}

	-- position
	if opts.fromPos then
		frame.Position = opts.fromPos
	end
	if opts.toPos then
		goals.Position = opts.toPos
	end

	-- size
	if opts.fromSize then
		frame.Size = opts.fromSize
	end
	if opts.toSize then
		goals.Size = opts.toSize
	end

	-- transparency (GroupTransparency preferred for containers, BackgroundTransparency for frames)
	if opts.fade ~= false then
		local fadeFrom = opts.fadeFrom ~= nil and opts.fadeFrom or 1
		local fadeTo   = opts.fadeTo   ~= nil and opts.fadeTo   or 0
		if frame:IsA("Frame") or frame:IsA("ScrollingFrame") or frame:IsA("ImageLabel") then
			frame.BackgroundTransparency = fadeFrom
			goals.BackgroundTransparency = fadeTo
		end
		-- For CanvasGroup / Frame with children, also tween GroupTransparency
		if frame:FindFirstChildWhichIsA("UIStroke") or opts.groupFade then
			-- GroupTransparency is only on CanvasGroup (new API)
			pcall(function() frame.GroupTransparency = fadeFrom end)
			if goals then
				pcall(function() goals.GroupTransparency = fadeTo end)
			end
		end
	end

	local tween = buildTween(frame, goals, merge(opts, {
		onComplete = function(inst)
			if opts.signal then UIController.emit(opts.signal, inst) end
			if opts.onComplete then opts.onComplete(inst) end
		end
	}))
	tween:Play()
	return tween
end

function UIController.close(frame, opts)
	opts = opts or {}
	local goals = {}

	if opts.toPos then
		goals.Position = opts.toPos
	end
	if opts.toSize then
		goals.Size = opts.toSize
	end

	-- fade out
	if opts.fade ~= false then
		local fadeTo = opts.fadeTo ~= nil and opts.fadeTo or 1
		if frame:IsA("Frame") or frame:IsA("ScrollingFrame") or frame:IsA("ImageLabel") then
			goals.BackgroundTransparency = fadeTo
		end
		pcall(function() goals.GroupTransparency = fadeTo end)
	end

	local tween = buildTween(frame, goals, merge(opts, {
		onComplete = function(inst)
			inst.Visible = false
			if opts.signal then UIController.emit(opts.signal, inst) end
			if opts.onComplete then opts.onComplete(inst) end
		end
	}))
	tween:Play()
	return tween
end

function UIController.toggle(frame, opts)
	if frame.Visible then
		return UIController.close(frame, opts)
	else
		return UIController.open(frame, opts)
	end
end

--  GENERIC ANIMATE  (any property → tween)

--[[
  UIController.animate(frame, { Position = UDim2, Size = UDim2, ... }, opts)
  Supports chaining:  .animate(...):andThen(fn)
--]]

function UIController.animate(instance, props, opts)
	local tween = buildTween(instance, props, opts)
	tween:Play()
	local handle = {
		tween = tween,
		andThen = function(self, fn)
			tween.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed then fn() end
			end)
			return self
		end,
		cancel = function(self)
			tween:Cancel()
		end,
	}
	return handle
end

--  LOOP ANIMATE  (keyframe array, optimized)

--[[
  keyframes = {
    { props = { Position = UDim2 }, duration = 0.5, style = ... },
    { props = { Position = UDim2 }, duration = 0.5 },
  }
  opts = { pingpong = false, delay = 0 }
  returns loopId (string)  →  UIController.stopLoop(loopId)
--]]

function UIController.loopAnimate(instance, keyframes, opts)
	opts = opts or {}
	local loopId = uid()
	local state  = { active = true }
	_loops[loopId] = state

	task.spawn(function()
		if opts.delay then task.wait(opts.delay) end
		local frames = keyframes
		local forward = true

		while state.active do
			local list = forward and frames or { table.unpack(frames, 1) }
			if not forward then
				-- reverse
				list = {}
				for i = #frames, 1, -1 do list[#list + 1] = frames[i] end
			end

			for _, kf in ipairs(list) do
				if not state.active then break end
				local ti = TweenInfo.new(
					kf.duration  or 0.5,
					kf.style     or Enum.EasingStyle.Sine,
					kf.direction or Enum.EasingDirection.InOut
				)
				local tw = TweenService:Create(instance, ti, kf.props)
				tw:Play()
				tw.Completed:Wait()
				if kf.pause then task.wait(kf.pause) end
			end

			if opts.pingpong then
				forward = not forward
			end
		end
	end)

	return loopId
end

function UIController.stopLoop(loopId)
	if _loops[loopId] then
		_loops[loopId].active = false
		_loops[loopId] = nil
	end
end

--  COLOR  (tween + palette)

--[[
  UIController.setColor(instance, Color3, opts)
  instance can be: Frame, TextLabel, ImageLabel, UIStroke, etc.
  opts.property = "BackgroundColor3" | "TextColor3" | "Color" (default: auto-detect)
--]]

function UIController.setColor(instance, color, opts)
	opts = opts or {}
	local prop = opts.property

	if not prop then
		if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
			prop = "TextColor3"
		elseif instance:IsA("UIStroke") or instance:IsA("UIGradient") then
			prop = "Color"
		else
			prop = "BackgroundColor3"
		end
	end

	if opts.duration and opts.duration > 0 then
		local tween = buildTween(instance, { [prop] = color }, opts)
		tween:Play()
		return tween
	else
		instance[prop] = color
	end
end

--  NUMBER FORMATTER

--[[
  styles:
    "comma"     → 1,000,000
    "space"     → 1 000 000
    "short"     → 1M / 1.5K / 2.3B
    "compact"   → 1m / 1.5k
    "currency"  → R$ 1.000,00   (USD default; pass opts.symbol for others)
    "percent"   → 42.5%
--]]

local SHORTS = {
	{ 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" }
}
local SHORTS_LOWER = {
	{ 1e12, "t" }, { 1e9, "b" }, { 1e6, "m" }, { 1e3, "k" }
}

local function commaFmt(n, sep)
	sep = sep or ","
	local s = tostring(math.floor(math.abs(n)))
	local result = ""
	local count  = 0
	for i = #s, 1, -1 do
		count = count + 1
		result = s:sub(i, i) .. result
		if count % 3 == 0 and i ~= 1 then
			result = sep .. result
		end
	end
	return (n < 0 and "-" or "") .. result
end

function UIController.formatNumber(n, style, opts)
	opts = opts or {}
	style = style or "comma"
	n = tonumber(n) or 0

	if style == "comma" then
		return commaFmt(n, ",")

	elseif style == "space" then
		return commaFmt(n, " ")

	elseif style == "short" or style == "compact" then
		local tbl = (style == "compact") and SHORTS_LOWER or SHORTS
		local sign = n < 0 and "-" or ""
		local abs  = math.abs(n)
		for _, pair in ipairs(tbl) do
			local divisor, suffix = pair[1], pair[2]
			if abs >= divisor then
				local val = abs / divisor
				local dec = opts.decimals ~= nil and opts.decimals or 1
				local fmt = string.format("%." .. dec .. "f", val)
				-- strip trailing .0 unless forced
				if not opts.keepDecimal then
					fmt = fmt:gsub("%.0+$", "")
				end
				return sign .. fmt .. suffix
			end
		end
		return sign .. tostring(math.floor(abs))

	elseif style == "currency" then
		local sym   = opts.symbol   or "$"
		local dec   = opts.decimals ~= nil and opts.decimals or 2
		local whole = commaFmt(math.floor(math.abs(n)), ".")
		local frac  = string.format("%0" .. dec .. "d", math.floor((math.abs(n) % 1) * (10 ^ dec) + 0.5))
		return (n < 0 and "-" or "") .. sym .. " " .. whole .. "," .. frac

	elseif style == "percent" then
		local dec = opts.decimals ~= nil and opts.decimals or 1
		return string.format("%." .. dec .. "f", n) .. "%"

	elseif style == "raw" then
		return tostring(n)
	end

	return tostring(n)
end

--  TEXT FORMATTER  (template interpolation)

--[[
  UIController.formatText("Hello {name}, you have {coins} coins!", {
    name  = "Alex",
    coins = UIController.formatNumber(15000, "comma"),
  })
  → "Olá Alex, você tem 15,000 moedas!"
--]]

function UIController.formatText(template, data)
	return (template:gsub("{(%w+)}", function(key)
		local val = data[key]
		if val == nil then return "{" .. key .. "}" end
		return tostring(val)
	end))
end

--  TYPEWRITER  (máquina de escrever, coroutine-based)

--[[
  opts = {
    speed       = 0.05,   -- seconds per character
    richText    = false,  -- skip RichText tags from delay
    sound       = Sound,  -- optional Sound instance to play per char
    onChar      = function(char, index) end,
    onComplete  = function(label) end,
    signal      = "ui:typeComplete",
  }
  Returns a handle:
    handle.skip()    → jump to end immediately
    handle.cancel()  → stop and clear
    handle.pause()
    handle.resume()
--]]

function UIController.typewrite(label, text, opts)
	opts  = opts or {}

	-- cancel previous on same label
	if _typewriters[label] then
		_typewriters[label].active = false
	end

	local handle = {
		active  = true,
		paused  = false,
		_skip   = false,
	}
	_typewriters[label] = handle

	handle.skip = function()
		handle._skip = true
	end
	handle.cancel = function()
		handle.active = false
		label.Text = ""
	end
	handle.pause = function()
		handle.paused = true
	end
	handle.resume = function()
		handle.paused = false
	end

	task.spawn(function()
		local speed = opts.speed or 0.05
		label.Text  = ""

		-- parse: if richText, extract visible chars vs tags
		local chars = {}
		if opts.richText then
			-- simple parser: skip <tag> sequences
			local i = 1
			while i <= #text do
				if text:sub(i, i) == "<" then
					local close = text:find(">", i)
					if close then
						-- push the tag as-is (no delay)
						table.insert(chars, { tag = text:sub(i, close), visible = false })
						i = close + 1
					else
						table.insert(chars, { char = text:sub(i, i), visible = true })
						i = i + 1
					end
				else
					table.insert(chars, { char = text:sub(i, i), visible = true })
					i = i + 1
				end
			end
		else
			for i = 1, #text do
				table.insert(chars, { char = text:sub(i, i), visible = true })
			end
		end

		local built  = ""
		local visIdx = 0

		for _, entry in ipairs(chars) do
			if not handle.active then return end
			if handle._skip then break end

			if entry.visible then
				visIdx = visIdx + 1
				built  = built .. entry.char
				label.Text = built
				if opts.sound then pcall(function() opts.sound:Play() end) end
				if opts.onChar then opts.onChar(entry.char, visIdx) end
				-- wait, respecting pause
				local elapsed = 0
				while elapsed < speed do
					if not handle.active then return end
					if handle._skip then break end
					while handle.paused do task.wait(0.05) end
					task.wait(0.016)
					elapsed = elapsed + 0.016
				end
			else
				-- tag: append immediately, no delay
				built = built .. entry.tag
				label.Text = built
			end
		end

		-- ensure final text is set
		if handle.active then
			label.Text = text
			if opts.onComplete then opts.onComplete(label) end
			if opts.signal then UIController.emit(opts.signal, label, text) end
		end
	end)

	return handle
end

--  DEBRIS  (add with optional signal on expire)

--[[
  UIController.debris(instance, lifetime, opts)
  opts = {
    signal    = "ui:debrisExpired",
    onExpire  = function(instance) end,
  }
--]]

function UIController.debris(instance, lifetime, opts)
	opts = opts or {}
	if opts.signal or opts.onExpire then
		task.delay(lifetime, function()
			if opts.onExpire and instance and instance.Parent then
				opts.onExpire(instance)
			end
			if opts.signal then UIController.emit(opts.signal, instance) end
			if instance and instance.Parent then
				instance:Destroy()
			end
		end)
	else
		Debris:AddItem(instance, lifetime)
	end
end

--  REACT-LIKE STATE SYSTEM  (useState / useEffect / mount)

--[[
  Lightweight component model:
  
  local comp = UIController.mount(frame, function(state, setState)
    -- called on every state change
    -- return a table of { instance → props } to auto-tween
    return {
      [frame.Title] = { TextColor3 = state.active and Color3.new(1,1,0) or Color3.new(1,1,1) },
    }
  end)
  
  comp.setState({ active = true })   -- triggers re-render + tweens
  comp.getState()                    -- returns current state
  comp.unmount()                     -- cleanup
--]]

function UIController.mount(frame, renderFn, initialState)
	local state  = initialState or {}
	local effects = {}
	local comp = {}

	local function render()
		local patches = renderFn(state, function(newState)
			state = merge(state, newState)
			render()
		end)
		if type(patches) == "table" then
			for instance, props in pairs(patches) do
				if typeof(instance) == "Instance" then
					local duration = props._duration or 0.25
					local style    = props._style    or Enum.EasingStyle.Quart
					-- remove meta keys
					local goals = {}
					for k, v in pairs(props) do
						if k:sub(1, 1) ~= "_" then goals[k] = v end
					end
					if next(goals) then
						local tw = buildTween(instance, goals, { duration = duration, style = style })
						tw:Play()
					end
				end
			end
		end
	end

	comp.setState = function(newState)
		state = merge(state, newState)
		render()
	end
	comp.getState = function() return state end
	comp.unmount  = function()
		_mounted[frame] = nil
	end

	_mounted[frame] = comp
	render()
	return comp
end

-- Lightweight standalone state (returns get/set pair + onChange)
function UIController.useState(initial)
	local value     = initial
	local listeners = {}

	local function get() return value end
	local function set(newVal)
		value = newVal
		for _, fn in ipairs(listeners) do task.spawn(fn, value) end
	end
	local function onChange(fn)
		table.insert(listeners, fn)
		return {
			Disconnect = function()
				for i, f in ipairs(listeners) do
					if f == fn then table.remove(listeners, i) break end
				end
			end
		}
	end

	return get, set, onChange
end

-- Simple useEffect: runs fn, returns cleanup
function UIController.useEffect(fn, deps)
	local cleanup = fn()
	return cleanup or function() end
end

--  PRESET ANIMATIONS  (convenience shortcuts)

UIController.presets = {}

-- Bounce open from center
function UIController.presets.bounceIn(frame, opts)
	opts = opts or {}
	local origSize = frame.Size
	frame.Size     = UDim2.new(0, 0, 0, 0)
	frame.Visible  = true
	return UIController.animate(frame, { Size = origSize }, merge(opts, {
		style     = Enum.EasingStyle.Back,
		direction = Enum.EasingDirection.Out,
		duration  = opts.duration or 0.45,
	}))
end

-- Slide in from direction
function UIController.presets.slideIn(frame, direction, opts)
	opts = opts or {}
	direction = direction or "bottom"
	local origPos = frame.Position
	local from
	if direction == "bottom" then
		from = UDim2.new(origPos.X.Scale, origPos.X.Offset, 1.2, 0)
	elseif direction == "top" then
		from = UDim2.new(origPos.X.Scale, origPos.X.Offset, -1.2, 0)
	elseif direction == "left" then
		from = UDim2.new(-1.2, 0, origPos.Y.Scale, origPos.Y.Offset)
	elseif direction == "right" then
		from = UDim2.new(1.2, 0, origPos.Y.Scale, origPos.Y.Offset)
	end
	frame.Position = from
	frame.Visible  = true
	return UIController.animate(frame, { Position = origPos }, merge(opts, {
		style    = Enum.EasingStyle.Quart,
		duration = opts.duration or 0.4,
	}))
end

-- Shake (for errors / damage)
function UIController.presets.shake(frame, opts)
	opts = opts or {}
	local origPos  = frame.Position
	local strength = opts.strength or 6
	local count    = opts.count    or 6
	local duration = opts.duration or 0.06
	task.spawn(function()
		for i = 1, count do
			local dx = (math.random() - 0.5) * 2 * strength
			local dy = (math.random() - 0.5) * 2 * strength
			local tw = buildTween(frame, {
				Position = UDim2.new(
					origPos.X.Scale, origPos.X.Offset + dx,
					origPos.Y.Scale, origPos.Y.Offset + dy
				)
			}, { duration = duration })
			tw:Play()
			tw.Completed:Wait()
		end
		local restore = buildTween(frame, { Position = origPos }, { duration = duration })
		restore:Play()
		restore.Completed:Wait()
		if opts.onComplete then opts.onComplete() end
	end)
end

-- Pulse (scale up then back — via Size)
function UIController.presets.pulse(frame, opts)
	opts = opts or {}
	local origSize = frame.Size
	local scale    = opts.scale or 1.08
	local pulsedSize = UDim2.new(
		origSize.X.Scale * scale, origSize.X.Offset,
		origSize.Y.Scale * scale, origSize.Y.Offset
	)
	local id = UIController.loopAnimate(frame, {
		{ props = { Size = pulsedSize }, duration = opts.duration or 0.5, style = Enum.EasingStyle.Sine, direction = Enum.EasingDirection.InOut },
		{ props = { Size = origSize  }, duration = opts.duration or 0.5, style = Enum.EasingStyle.Sine, direction = Enum.EasingDirection.InOut },
	}, { pingpong = false })
	return id
end

-- Fade-only open/close
function UIController.presets.fadeIn(frame, opts)
	opts = opts or {}
	frame.BackgroundTransparency = 1
	frame.Visible = true
	return UIController.animate(frame, { BackgroundTransparency = 0 }, opts)
end
function UIController.presets.fadeOut(frame, opts)
	opts = opts or {}
	return UIController.animate(frame, { BackgroundTransparency = 1 }, merge(opts, {
		onComplete = function(inst) inst.Visible = false end
	}))
end

--  RETURN

return UIController
