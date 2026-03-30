--[[
  ============================================================
  UIFramework / renderer / Renderer.lua
  ============================================================
  The animation and rendering engine.

  Responsibilities (Single Responsibility per sub-system):
    - TweenPool      : reuse Tween objects (avoid GC pressure)
    - AnimationPipeline : chainable tween sequences
    - LoopManager    : managed animation loops with back-pressure
    - TransitionLib  : named transition presets (open/close/slide/fade)
    - PropertyPatcher: apply React-style property diffs to instances

  All operations are instrumented (timing + counters).
  ============================================================
--]]

local Types     = require(script.Parent.Parent.core.Types)
local Logger    = require(script.Parent.Parent.logger.Logger)
local Metrics   = require(script.Parent.Parent.metrics.Metrics)
local Scheduler = require(script.Parent.Parent.scheduler.Scheduler)
local HttpSvc   = game:GetService("HttpService")
local TweenSvc  = game:GetService("TweenService")

local log = Logger.child("Renderer")

local Renderer = {}

--  HELPERS
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

--  ════════════════════════════════════════════════════════
--  PROPERTY PATCHER
--  Applies a flat { prop → value } patch to an instance.
--  Animated vs instant is determined by the patch itself.
--  ════════════════════════════════════════════════════════

local PropertyPatcher = {}

--- Apply props immediately (no tween).
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

--- Extract meta keys (_duration, _easing, _delay, _onComplete) from a props table.
--- Returns { goals, opts }
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

--  ════════════════════════════════════════════════════════
--  TWEEN BUILDER  (internal core)
--  ════════════════════════════════════════════════════════

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

--  ════════════════════════════════════════════════════════
--  ANIMATION HANDLE  (returned from all animate calls)
--  Supports chaining: handle:andThen(fn):andThen(fn)
--  ════════════════════════════════════════════════════════

local function makeHandle(tween, id)
	local handle = {
		id    = id or uid(),
		tween = tween,
		_chain = {},
	}

	function handle:andThen(fn)
		self._chain[#self._chain + 1] = fn
		self.tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				pcall(fn)
				-- resolve remaining chain links
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

--  ════════════════════════════════════════════════════════
--  PUBLIC: animate
--  ════════════════════════════════════════════════════════

--[[
  opts = {
    duration    = 0.35,
    easing      = Types.Easing.EASE_OUT,
    delay       = 0,
    repeatCount = 0,
    reverses    = false,
    onComplete  = fn,
  }
  Returns AnimationHandle
--]]
function Renderer.animate(instance, goals, opts)
	assert(typeof(instance) == "Instance", "Renderer.animate: instance must be a Roblox Instance")
	assert(type(goals) == "table",         "Renderer.animate: goals must be a table")

	local stopTimer = Metrics.startTimer("renderer.tween.duration_ms", "Tween execution time")
	local id     = uid()
	local tween  = createTween(instance, goals, opts or {})

	local origOnComplete = opts and opts.onComplete

	-- wrap onComplete to stop timer + metrics
	local wrappedOpts = {}
	if opts then
		for k, v in pairs(opts) do wrappedOpts[k] = v end
	end
	wrappedOpts.onComplete = function(inst)
		stopTimer()
		Metrics.inc("renderer.tween.completed", 1)
		if origOnComplete then pcall(origOnComplete, inst) end
	end

	tween.Completed:Once(function(state)
		if state ~= Enum.PlaybackState.Completed then
			stopTimer()
		end
	end)

	tween:Play()
	Metrics.inc("renderer.tween.started", 1, "Tweens started")

	log.trace("Tween started", {
		id       = id,
		instance = instance.Name,
		duration = wrappedOpts.duration or 0.35,
	})

	return makeHandle(tween, id)
end

--  ════════════════════════════════════════════════════════
--  ANIMATION SEQUENCE  (chainable pipeline)
--  ════════════════════════════════════════════════════════

--[[
  local seq = Renderer.sequence()
  seq:add(frame, { Position = ... }, opts)
  seq:add(frame, { Size = ... }, opts)
  seq:parallel({ ... })  -- run next steps in parallel
  seq:wait(0.5)
  seq:play()
  seq:cancel()
--]]

function Renderer.sequence()
	local steps = {}
	local activeHandles = {}
	local cancelled = false

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

	--- Run a set of steps in parallel before continuing.
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
					local done = 0
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

--  ════════════════════════════════════════════════════════
--  LOOP MANAGER
--  ════════════════════════════════════════════════════════

local _loops = {}  -- id → { active, task }

--[[
  keyframes = {
    { goals = { Size = UDim2 }, duration = 0.5, easing = Types.Easing.SINE_IO, pause = 0 },
    ...
  }
  opts = {
    pingpong = false,
    delay    = 0,
    onCycle  = fn,   -- called after each full cycle
  }
  Returns loopId string
--]]
function Renderer.loop(instance, keyframes, opts)
	opts = opts or {}
	local id    = uid()
	local state = { active = true }
	_loops[id]  = state

	Metrics.adjust("renderer.loops.active", 1, "Active animation loops")

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
					duration  = kf.duration,
					easing    = kf.easing,
					delay     = kf.delay,
				})
				h:await()
				if kf.pause then task.wait(kf.pause) end
			end

			cycles = cycles + 1
			Metrics.inc("renderer.loop.cycles", 1, "Total loop cycles executed")

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
	for id, state in pairs(_loops) do
		state.active = false
	end
	_loops = {}
end

--  ════════════════════════════════════════════════════════
--  OPEN / CLOSE / TOGGLE  (transition library)
--  ════════════════════════════════════════════════════════

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
		-- CanvasGroup / GroupTransparency
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
			local bus = require(script.Parent.Parent.signals.SignalBus)
			bus.emit(opts.signal, frame)
		end)
	end

	Metrics.inc("renderer.open.calls", 1, "UIController.open calls")
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
			local bus = require(script.Parent.Parent.signals.SignalBus)
			bus.emit(opts.signal, frame)
		end
		if opts.onComplete then pcall(opts.onComplete, frame) end
	end)

	Metrics.inc("renderer.close.calls", 1, "UIController.close calls")
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
