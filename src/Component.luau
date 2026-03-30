--[[
  ============================================================
  UIFramework / core / Component.lua
  ============================================================
  React-faithful component system with full lifecycle.

  Lifecycle order:
    1. new()         → allocate fiber
    2. mount()       → MOUNTING → MOUNTED
       - runs all useEffect hooks
       - emits "component:mounted"
    3. setState()    → UPDATING → MOUNTED (batched via Scheduler)
       - reconciler diffs old props vs new props
       - applies only changed properties via Renderer
       - re-runs effects whose deps changed
    4. unmount()     → UNMOUNTING → UNMOUNTED
       - runs all effect cleanups
       - emits "component:unmounted"
       - removes from registry

  Error boundaries:
    - Any render/effect error is caught
    - Component enters ERROR state
    - Parent boundary (if set) receives the error
    - Component still unmounts cleanly

  Reconciler:
    - Receives renderFn(state) → { [instance] → props }
    - Diffs previous props vs current props per instance
    - Only tweens changed properties (like React's virtual DOM diff)
  ============================================================
--]]

local Types     = require(script.Parent.Types)
local Logger    = require(script.Parent.Parent.logger.Logger)
local Metrics   = require(script.Parent.Parent.metrics.Metrics)
local Scheduler = require(script.Parent.Parent.scheduler.Scheduler)
local SignalBus = require(script.Parent.Parent.signals.SignalBus)
local Renderer  = require(script.Parent.Parent.renderer.Renderer)
local Hooks     = require(script.Parent.Parent.hooks.Hooks)
local HttpSvc   = game:GetService("HttpService")

local log = Logger.child("Component")

local Component = {}
Component.__index = Component

--  REGISTRY  (all mounted components)
local _registry = {}  -- id → component

--  HELPERS
local function uid()
	return HttpSvc:GenerateGUID(false):sub(1, 8)
end

--  ══════════════════════════════════════
--  RECONCILER
--  Diffs oldPatch vs newPatch, applies delta
--  ══════════════════════════════════════

local function reconcile(oldPatch, newPatch)
	oldPatch = oldPatch or {}

	for instance, newProps in pairs(newPatch) do
		if typeof(instance) ~= "Instance" then continue end

		local oldProps = oldPatch[instance] or {}
		local goals    = {}
		local tweenOpts = {}
		local hasGoals  = false

		-- extract animation meta from newProps
		local duration   = newProps._duration  or 0.25
		local easing     = newProps._easing    or Types.Easing.EASE_OUT
		local delay      = newProps._delay     or 0
		local onComplete = newProps._onComplete

		for k, v in pairs(newProps) do
			if k:sub(1, 1) == "_" then continue end

			-- only tween if value changed
			local old = oldProps[k]
			if old ~= v then
				goals[k]  = v
				hasGoals  = true
			end
		end

		if hasGoals then
			Renderer.animate(instance, goals, {
				duration   = duration,
				easing     = easing,
				delay      = delay,
				onComplete = onComplete,
			})
		end
	end

	-- handle removed instances (instances in old but not new)
	for instance, _ in pairs(oldPatch) do
		if typeof(instance) == "Instance" and not newPatch[instance] then
			-- nothing to do by default; consumer can handle via onComplete / signal
		end
	end
end

--  ══════════════════════════════════════
--  COMPONENT CONSTRUCTOR
--  ══════════════════════════════════════

--[[
  Component.new(frame, renderFn, opts)

  renderFn(state, api) → patch table { [instance] → props }
    api = {
      setState(patch),
      getState(),
      useEffect(fn, deps),
      useMemo(fn, deps),
      useRef(initial),
      emit(signal, ...),
    }

  opts = {
    initialState   = table,
    name           = string,        -- display name for logs
    errorBoundary  = Component,     -- parent boundary (receives errors)
    onMount        = fn,
    onUnmount      = fn,
    onError        = fn(err, comp),
  }
--]]
function Component.new(frame, renderFn, opts)
	assert(typeof(frame)    == "Instance",  "Component.new: frame must be a Roblox Instance")
	assert(type(renderFn)   == "function",  "Component.new: renderFn must be a function")
	opts = opts or {}

	local id   = uid()
	local name = opts.name or (frame.Name .. "_" .. id:sub(1, 4))

	local self = setmetatable({
		id            = id,
		name          = name,
		frame         = frame,
		_renderFn     = renderFn,
		_state        = opts.initialState or {},
		_lifecycle    = Types.LifecycleState.IDLE,
		_lastPatch    = {},
		_effects      = {},   -- array of effect handles from Hooks.useEffect
		_memos        = {},   -- array of memo handles
		_subscriptions = {},  -- signal subscriptions to clean on unmount
		_errorBoundary = opts.errorBoundary,
		_onMount      = opts.onMount,
		_onUnmount    = opts.onUnmount,
		_onError      = opts.onError,
		_renderCount  = 0,
		_pendingBatch = nil,
	}, Component)

	log.debug("Component created", { id = id, name = name })
	Metrics.adjust("component.count", 1, "Total component instances")

	return self
end

--  ══════════════════════════════════════
--  INTERNAL: BUILD API TABLE FOR renderFn
--  ══════════════════════════════════════

function Component:_buildApi()
	local self_ = self

	return {
		setState = function(patch) self_:setState(patch) end,
		getState = function()      return self_._state   end,

		useEffect = function(fn, deps)
			local effect = Hooks.useEffect(fn, deps)
			self_._effects[#self_._effects + 1] = effect
			return effect
		end,

		useMemo = function(fn, deps)
			local memo = Hooks.useMemo(fn, deps)
			self_._memos[#self_._memos + 1] = memo
			return memo
		end,

		useRef = function(initial)
			return Hooks.useRef(initial)
		end,

		emit = function(signal, ...)
			SignalBus.emit(signal, ...)
		end,

		on = function(signal, callback, opts_)
			local handle = SignalBus.on(signal, callback, opts_)
			self_._subscriptions[#self_._subscriptions + 1] = handle
			return handle
		end,
	}
end

--  ══════════════════════════════════════
--  RENDER  (internal — always called via Scheduler)
--  ══════════════════════════════════════

function Component:_render()
	if self._lifecycle == Types.LifecycleState.UNMOUNTED or
	   self._lifecycle == Types.LifecycleState.UNMOUNTING then
		return
	end

	local stopTimer = Metrics.startTimer("component.render.duration_ms", "Component render time")
	self._renderCount = self._renderCount + 1

	local ok, patchOrErr = pcall(self._renderFn, self._state, self:_buildApi())

	stopTimer()

	if not ok then
		self:_handleError("render", patchOrErr)
		return
	end

	local patch = type(patchOrErr) == "table" and patchOrErr or {}

	-- reconcile: diff and apply
	local ok2, err2 = pcall(reconcile, self._lastPatch, patch)
	if not ok2 then
		self:_handleError("reconcile", err2)
		return
	end

	self._lastPatch = patch

	Metrics.inc("component.render.count", 1, "Total component renders")
	log.trace("Component rendered", {
		id     = self.id,
		name   = self.name,
		render = self._renderCount,
	})

	-- re-run effects whose deps may have changed
	for _, effect in ipairs(self._effects) do
		effect.run()
	end
end

--  ══════════════════════════════════════
--  ERROR HANDLING
--  ══════════════════════════════════════

function Component:_handleError(phase, err)
	self._lifecycle = Types.LifecycleState.ERROR
	Metrics.inc("component.errors", 1, "Component render/effect errors")

	log.error("Component error", {
		id    = self.id,
		name  = self.name,
		phase = phase,
		error = tostring(err),
	})

	if self._onError then
		pcall(self._onError, err, self)
	end

	if self._errorBoundary then
		pcall(function()
			self._errorBoundary:_handleError("boundary_child:" .. self.name, err)
		end)
	end

	SignalBus.emit("component:error", { id = self.id, name = self.name, error = err, phase = phase })
end

--  ══════════════════════════════════════
--  PUBLIC API
--  ══════════════════════════════════════

--- Mount the component. Triggers first render.
function Component:mount()
	assert(self._lifecycle == Types.LifecycleState.IDLE,
		"Component.mount: already mounted or mounting — id=" .. self.id)

	self._lifecycle = Types.LifecycleState.MOUNTING
	_registry[self.id] = self

	Scheduler.schedule(function()
		self:_render()
		self._lifecycle = Types.LifecycleState.MOUNTED

		if self._onMount then pcall(self._onMount, self) end

		SignalBus.emit("component:mounted", { id = self.id, name = self.name, frame = self.frame })
		Metrics.adjust("component.mounted.count", 1, "Currently mounted components")

		log.info("Component mounted", { id = self.id, name = self.name })
	end, { priority = Scheduler.Priority.NORMAL })

	return self
end

--- Batch multiple setState calls into one render.
function Component:setState(patch)
	assert(type(patch) == "table", "Component.setState: patch must be a table")

	-- merge patch into pending batch
	if not self._pendingBatch then
		self._pendingBatch = {}
	end
	for k, v in pairs(patch) do
		self._pendingBatch[k] = v
	end

	-- schedule a single flush (deduped by component id)
	Scheduler.schedule(function()
		if not self._pendingBatch then return end

		-- merge into state
		for k, v in pairs(self._pendingBatch) do
			self._state[k] = v
		end
		self._pendingBatch = nil

		if self._lifecycle ~= Types.LifecycleState.MOUNTED and
		   self._lifecycle ~= Types.LifecycleState.UPDATING then
			return
		end

		self._lifecycle = Types.LifecycleState.UPDATING
		self:_render()
		self._lifecycle = Types.LifecycleState.MOUNTED

		Metrics.inc("component.setState.count", 1, "setState calls")
	end, {
		priority = Scheduler.Priority.NORMAL,
		id       = "setState:" .. self.id,   -- dedup: multiple setState in same frame = one render
	})
end

--- Force a re-render without state change.
function Component:forceUpdate()
	Scheduler.schedule(function()
		self:_render()
	end, { priority = Scheduler.Priority.NORMAL })
end

--- Get current state (read-only copy).
function Component:getState()
	local copy = {}
	for k, v in pairs(self._state) do copy[k] = v end
	return copy
end

--- Unmount. Runs all effect cleanups, disconnects signals, removes from registry.
function Component:unmount()
	if self._lifecycle == Types.LifecycleState.UNMOUNTED or
	   self._lifecycle == Types.LifecycleState.UNMOUNTING then
		return
	end

	self._lifecycle = Types.LifecycleState.UNMOUNTING
	log.info("Component unmounting", { id = self.id, name = self.name })

	-- cleanup effects
	for _, effect in ipairs(self._effects) do
		effect.destroy()
	end
	self._effects = {}

	-- destroy memos
	for _, memo in ipairs(self._memos) do
		memo.destroy()
	end
	self._memos = {}

	-- disconnect signal subscriptions
	for _, sub in ipairs(self._subscriptions) do
		sub.disconnect()
	end
	self._subscriptions = {}

	-- call user callback
	if self._onUnmount then pcall(self._onUnmount, self) end

	self._lifecycle = Types.LifecycleState.UNMOUNTED
	_registry[self.id] = nil

	Metrics.adjust("component.mounted.count", -1)
	Metrics.adjust("component.count",         -1)

	SignalBus.emit("component:unmounted", { id = self.id, name = self.name })
	log.info("Component unmounted", { id = self.id, name = self.name, renders = self._renderCount })
end

--  ══════════════════════════════════════
--  STATIC REGISTRY UTILITIES
--  ══════════════════════════════════════

function Component.getById(id)
	return _registry[id]
end

function Component.getAll()
	local out = {}
	for _, c in pairs(_registry) do out[#out + 1] = c end
	return out
end

function Component.unmountAll()
	for _, c in pairs(_registry) do
		c:unmount()
	end
end

function Component.report()
	local all = Component.getAll()
	print(string.rep("=", 50))
	print("[UIFramework Components] " .. #all .. " mounted")
	for _, c in ipairs(all) do
		print(string.format("  [%s] %s renders=%d lifecycle=%s",
			c.id:sub(1, 6), c.name, c._renderCount, c._lifecycle))
	end
	print(string.rep("=", 50))
end

return Component
