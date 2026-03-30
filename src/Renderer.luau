local Types     = require(script.Parent.Types)
local Logger    = require(script.Parent.Logger)
local Metrics   = require(script.Parent.Metrics)
local HttpSvc   = game:GetService("HttpService")
local TweenSvc  = game:GetService("TweenService")

local log = Logger.child("Renderer")

local Renderer = {}

local function uid()
	return HttpSvc:GenerateGUID(false):sub(1, 8)
end

local function buildTweenInfo(opts)
	opts = opts or {}
	local easing = opts.easing or Types.Easing.EASE_OUT
	return TweenInfo.new(
		opts.duration    or 0.35,
		opts.style       or easing.style,
		opts.direction   or easing.dir,
		opts.repeatCount or 0,
		opts.reverses    or false,
		opts.delay       or 0
	)
end

local PropertyPatcher = {}

function PropertyPatcher.apply(instance, props)
	for key, value in pairs(props) do
		if key:sub(1, 1) ~= "_" then
			local ok, err = pcall(function()
				instance[key] = value
			end)
			if not ok then
				log.warn("PropertyPatcher: failed to set prop", { instance = instance.Name, prop = key, error = err })
			end
		end
	end
end

function PropertyPatcher.split(props)
	local goals = {}
	local opts  = {
		duration   = props._duration,
		easing     = props._easing,
		delay      = props._delay,
		onComplete = props._onComplete,
	}
	for k, v in pairs(props) do
		if k:sub(1, 1) ~= "_" then
			goals[k] = v
		end
	end
	return goals, opts
end

Renderer.PropertyPatcher = PropertyPatcher

local function createTween(instance, goals, opts)
	local ti    = buildTweenInfo(opts)
	local tween = TweenSvc:Create(instance, ti, goals)

	if opts and opts.onComplete then
		tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				pcall(opts.onComplete, instance)
			end
		end)
	end

	return tween
end

local function makeHandle(tween, id)
	local handle = {
		id     = id or uid(),
		tween  = tween,
		_chain = {},
	}

	function handle:andThen(fn)
		self._chain[#self._chain + 1] = fn
		self.tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				pcall(fn)
				for i = 2, #self._chain do
					pcall(self._chain[i])
				end
			end
		end)
		return self
	end

	function handle:cancel()
		self.tween:Cancel()
		Metrics.inc("renderer.tween.cancelled", 1)
	end

	function handle:await()
		self.tween.Completed:Wait()
		return self
	end

	return handle
end

function Renderer.animate(instance, goals, opts)
	assert(typeof(instance) == "Instance", "Renderer.animate: instance must be a Roblox Instance")
	assert(type(goals) == "table",         "Renderer.animate: goals must be a table")

	local stopTimer = Metrics.startTimer("renderer.tween.duration_ms")
	local id        = uid()
	local tween     = createTween(instance, goals, opts or {})

	local origOnComplete = opts and opts.onComplete

	tween.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed then
			stopTimer()
			Metrics.inc("renderer.tween.completed", 1)
			if origOnComplete then pcall(origOnComplete, instance) end
		else
			stopTimer()
		end
	end)

	tween:Play()
	Metrics.inc("renderer.tween.started", 1)

	log.trace("Tween started", {
		id       = id,
		instance = instance.Name,
		duration = (opts and opts.duration) or 0.35,
	})

	return makeHandle(tween, id)
end

function Renderer.sequence()
	local steps         = {}
	local activeHandles = {}
	local cancelled     = false

	local seq = {}

	function seq:add(instance, goals, opts)
		steps[#steps + 1] = { type = "tween", instance = instance, goals = goals, opts = opts }
		return self
	end

	function seq:wait(duration)
		steps[#steps + 1] = { type = "wait", duration = duration }
		return self
	end

	function seq:call(fn)
		steps[#steps + 1] = { type = "call", fn = fn }
		return self
	end

	function seq:parallel(stepList)
		steps[#steps + 1] = { type = "parallel", steps = stepList }
		return self
	end

	function seq:play(onComplete)
		task.spawn(function()
			for _, step in ipairs(steps) do
				if cancelled then break end

				if step.type == "tween" then
					local h = Renderer.animate(step.instance, step.goals, step.opts)
					activeHandles[#activeHandles + 1] = h
					h:await()

				elseif step.type == "wait" then
					task.wait(step.duration)

				elseif step.type == "call" then
					pcall(step.fn)

				elseif step.type == "parallel" then
					local done  = 0
					local total = #step.steps
					if total == 0 then continue end
					local thread = coroutine.running()
					for _, ps in ipairs(step.steps) do
						task.spawn(function()
							local h = Renderer.animate(ps.instance, ps.goals, ps.opts)
							h:await()
							done = done + 1
							if done >= total then
								coroutine.resume(thread)
							end
						end)
					end
					coroutine.yield()
				end
			end

			if onComplete and not cancelled then
				pcall(onComplete)
			end
		end)

		return seq
	end

	function seq:cancel()
		cancelled = true
		for _, h in ipairs(activeHandles) do
			h:cancel()
		end
	end

	return seq
end

local _loops = {}

function Renderer.loop(instance, keyframes, opts)
	opts = opts or {}
	local id    = uid()
	local state = { active = true }
	_loops[id]  = state

	Metrics.adjust("renderer.loops.active", 1)

	task.spawn(function()
		if opts.delay then task.wait(opts.delay) end

		local frames  = keyframes
		local forward = true
		local cycles  = 0

		while state.active do
			local list
			if opts.pingpong then
				list = forward and frames or (function()
					local r = {}
					for i = #frames, 1, -1 do r[#r+1] = frames[i] end
					return r
				end)()
			else
				list = frames
			end

			for _, kf in ipairs(list) do
				if not state.active then break end
				local h = Renderer.animate(instance, kf.goals, {
					duration = kf.duration,
					easing   = kf.easing,
					delay    = kf.delay,
				})
				h:await()
				if kf.pause then task.wait(kf.pause) end
			end

			cycles = cycles + 1
			Metrics.inc("renderer.loop.cycles", 1)

			if opts.pingpong then
				forward = not forward
			end

			if opts.onCycle then
				pcall(opts.onCycle, cycles)
			end
		end

		Metrics.adjust("renderer.loops.active", -1)
		log.debug("Loop stopped", { id = id, cycles = cycles })
	end)

	log.debug("Loop started", { id = id, instance = instance.Name })
	return id
end

function Renderer.stopLoop(id)
	if _loops[id] then
		_loops[id].active = false
		_loops[id] = nil
	end
end

function Renderer.stopAllLoops()
	for _, state in pairs(_loops) do
		state.active = false
	end
	_loops = {}
end

local function resolveTransparencyProp(frame)
	if frame:IsA("TextLabel") or frame:IsA("TextButton") or frame:IsA("TextBox") then
		return "TextTransparency"
	end
	return "BackgroundTransparency"
end

function Renderer.open(frame, opts)
	opts = opts or {}
	frame.Visible = true

	local goals = {}

	if opts.fromPos  then frame.Position = opts.fromPos  end
	if opts.fromSize then frame.Size     = opts.fromSize end
	if opts.toPos    then goals.Position = opts.toPos    end
	if opts.toSize   then goals.Size     = opts.toSize   end

	if opts.fade ~= false then
		local prop     = resolveTransparencyProp(frame)
		local fadeFrom = opts.fadeFrom ~= nil and opts.fadeFrom or 1
		local fadeTo   = opts.fadeTo   ~= nil and opts.fadeTo   or 0
		frame[prop]    = fadeFrom
		goals[prop]    = fadeTo
		pcall(function()
			if frame.GroupTransparency ~= nil then
				frame.GroupTransparency = fadeFrom
				goals.GroupTransparency = fadeTo
			end
		end)
	end

	local handle = Renderer.animate(frame, goals, opts)

	if opts.signal then
		handle:andThen(function()
			local bus = require(script.Parent.SignalBus)
			bus.emit(opts.signal, frame)
		end)
	end

	Metrics.inc("renderer.open.calls", 1)
	return handle
end

function Renderer.close(frame, opts)
	opts = opts or {}
	local goals = {}

	if opts.toPos  then goals.Position = opts.toPos  end
	if opts.toSize then goals.Size     = opts.toSize end

	if opts.fade ~= false then
		local prop   = resolveTransparencyProp(frame)
		local fadeTo = opts.fadeTo ~= nil and opts.fadeTo or 1
		goals[prop]  = fadeTo
		pcall(function()
			if frame.GroupTransparency ~= nil then
				goals.GroupTransparency = fadeTo
			end
		end)
	end

	local handle = Renderer.animate(frame, goals, opts)
	handle:andThen(function()
		frame.Visible = false
		if opts.signal then
			local bus = require(script.Parent.SignalBus)
			bus.emit(opts.signal, frame)
		end
		if opts.onComplete then pcall(opts.onComplete, frame) end
	end)

	Metrics.inc("renderer.close.calls", 1)
	return handle
end

function Renderer.toggle(frame, opts)
	if frame.Visible then
		return Renderer.close(frame, opts)
	else
		return Renderer.open(frame, opts)
	end
end

return Renderer
