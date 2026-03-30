local Types        = require(script.Parent.Types)
local Logger       = require(script.Parent.Logger)
local Metrics      = require(script.Parent.Metrics)
local Scheduler    = require(script.Parent.Scheduler)
local SignalBus    = require(script.Parent.SignalBus)
local Renderer     = require(script.Parent.Renderer)
local Hooks        = require(script.Parent.Hooks)
local Binding      = require(script.Parent.Binding)
local EventMarkers = require(script.Parent.EventMarkers)
local Memo         = require(script.Parent.Memo)
local HttpSvc      = game:GetService("HttpService")

local log = Logger.child("Component")

local Component = {}
Component.__index = Component

local _registry = {}

local function uid()
	return HttpSvc:GenerateGUID(false):sub(1, 8)
end

-- ── Reconciler ──────────────────────────────────────────────────────────────
-- Handles plain props, Event/Change markers, and Binding links.
-- Diffs oldPatch vs newPatch and applies only what changed.

local function reconcileInstance(instance, oldProps, newProps, connections)
	oldProps = oldProps or {}
	connections = connections or {}

	-- Tear down removed or changed event/change/binding connections
	for key, conn in pairs(connections) do
		local newVal = newProps[key]
		if newVal == nil or newVal ~= oldProps[key] then
			if type(conn) == "function" then
				conn() -- disconnect / unlink
			elseif type(conn) == "table" and conn.Disconnect then
				conn:Disconnect()
			end
			connections[key] = nil
		end
	end

	-- Apply new / changed values
	local goals    = {}
	local hasGoals = false

	local duration   = newProps._duration   or 0.25
	local easing     = newProps._easing     or Types.Easing.EASE_OUT
	local delay      = newProps._delay      or 0
	local onComplete = newProps._onComplete

	for key, value in pairs(newProps) do
		if type(key) == "string" and key:sub(1, 1) == "_" then
			continue
		end

		-- Binding link
		if type(value) == "table" and value._impl then
			if not connections[key] then
				local property = key
				local disconnect = Binding.link(value, instance, property)
				connections[key] = disconnect
			end
			continue
		end

		-- Event marker
		if EventMarkers.isEvent(key) then
			if not connections[key] then
				local ok, conn = pcall(function()
					return instance[key.name]:Connect(function(...)
						pcall(value, instance, ...)
					end)
				end)
				if ok then
					connections[key] = function() conn:Disconnect() end
					Metrics.inc("component.events.connected", 1)
				else
					log.warn("Event connection failed", { instance = instance.Name, event = key.name })
				end
			end
			continue
		end

		-- Change marker
		if EventMarkers.isChange(key) then
			if not connections[key] then
				local ok, conn = pcall(function()
					return instance:GetPropertyChangedSignal(key.name):Connect(function()
						pcall(value, instance)
					end)
				end)
				if ok then
					connections[key] = function() conn:Disconnect() end
					Metrics.inc("component.changes.connected", 1)
				else
					log.warn("Change connection failed", { instance = instance.Name, property = key.name })
				end
			end
			continue
		end

		-- Plain property: diff and tween
		if oldProps[key] ~= value then
			goals[key] = value
			hasGoals   = true
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

	-- Handle removed instances (in old but not new)
	return connections
end

local function reconcile(oldPatch, newPatch, connectionMap)
	oldPatch      = oldPatch or {}
	connectionMap = connectionMap or {}

	for instance, newProps in pairs(newPatch) do
		if typeof(instance) ~= "Instance" then continue end
		local oldProps = oldPatch[instance] or {}
		connectionMap[instance] = reconcileInstance(
			instance, oldProps, newProps,
			connectionMap[instance] or {}
		)
	end

	for instance in pairs(oldPatch) do
		if typeof(instance) == "Instance" and not newPatch[instance] then
			-- Tear down all connections for removed instance
			if connectionMap[instance] then
				for _, conn in pairs(connectionMap[instance]) do
					if type(conn) == "function" then conn()
					elseif type(conn) == "table" and conn.Disconnect then conn:Disconnect() end
				end
				connectionMap[instance] = nil
			end
			if instance.Parent then
				Renderer.animate(instance, { BackgroundTransparency = 1 }, {
					duration   = 0.2,
					onComplete = function(inst)
						SignalBus.emit("component:instanceRemoved", { instance = inst })
					end,
				})
			end
		end
	end

	return connectionMap
end

-- ── Constructor ─────────────────────────────────────────────────────────────

function Component.new(frame, renderFn, opts)
	assert(typeof(frame)  == "Instance", "Component.new: frame must be a Roblox Instance")
	opts = opts or {}

	-- Unwrap forwardRef
	local actualRenderFn = renderFn
	local isForwardRef   = false
	if Memo.isForwardRef(renderFn) then
		actualRenderFn = renderFn.render
		isForwardRef   = true
	end
	assert(type(actualRenderFn) == "function", "Component.new: renderFn must be a function")

	local id   = uid()
	local name = opts.name or (frame.Name .. "_" .. id:sub(1, 4))

	local self = setmetatable({
		id              = id,
		name            = name,
		frame           = frame,
		_renderFn       = actualRenderFn,
		_isForwardRef   = isForwardRef,
		_ref            = opts.ref,          -- { current } table for forwardRef
		_state          = opts.initialState or {},
		_lifecycle      = Types.LifecycleState.IDLE,
		_lastPatch      = {},
		_connectionMap  = {},                -- instance → { key → disconnect }
		_effects        = {},
		_memos          = {},
		_subscriptions  = {},
		_contextCleanup = {},
		_bindingLinks   = {},
		_errorBoundary  = opts.errorBoundary,
		_onMount        = opts.onMount,
		_onUnmount      = opts.onUnmount,
		_onError        = opts.onError,
		_renderCount    = 0,
		_pendingBatch   = nil,
	}, Component)

	log.debug("Component created", { id = id, name = name })
	Metrics.adjust("component.count", 1)

	return self
end

-- ── API table for renderFn ───────────────────────────────────────────────────

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

		-- Binding: returns (binding, updater). The binding can be used directly
		-- as a prop value; the reconciler wires up Binding.link automatically.
		useBinding = function(initialValue)
			local binding, updater = Binding.create(initialValue)
			-- No extra tracking needed: links are cleaned up via connectionMap
			return binding, updater
		end,

		-- Context: provide a context value for this subtree.
		-- Returns a cleanup function (automatically called on unmount).
		useContext = function(ctx)
			local cleanup = ctx.provide and nil or nil
			-- Read-only: just return current value
			return ctx.use()
		end,

		-- Provide a context value from this component downward.
		provideContext = function(ctx, value)
			local cleanup = ctx.provide(value)
			self_._contextCleanup[#self_._contextCleanup + 1] = cleanup
			return cleanup
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

-- ── Render ───────────────────────────────────────────────────────────────────

function Component:_render()
	if self._lifecycle == Types.LifecycleState.UNMOUNTED or
	   self._lifecycle == Types.LifecycleState.UNMOUNTING then
		return
	end

	local stopTimer = Metrics.startTimer("component.render.duration_ms")
	self._renderCount = self._renderCount + 1

	local api = self:_buildApi()

	-- forwardRef: pass ref as second argument
	local ok, patchOrErr
	if self._isForwardRef then
		ok, patchOrErr = pcall(self._renderFn, self._state, self._ref, api)
	else
		ok, patchOrErr = pcall(self._renderFn, self._state, api)
	end

	stopTimer()

	if not ok then
		self:_handleError("render", patchOrErr)
		return
	end

	local patch = type(patchOrErr) == "table" and patchOrErr or {}

	local ok2, errOrMap = pcall(reconcile, self._lastPatch, patch, self._connectionMap)
	if not ok2 then
		self:_handleError("reconcile", errOrMap)
		return
	end

	self._connectionMap = errOrMap
	self._lastPatch     = patch

	Metrics.inc("component.render.count", 1)
	log.trace("Component rendered", { id = self.id, name = self.name, render = self._renderCount })

	for _, effect in ipairs(self._effects) do
		if effect.depsChanged() then
			effect.run()
		end
	end
end

-- ── Error handling ───────────────────────────────────────────────────────────

function Component:_handleError(phase, err)
	self._lifecycle = Types.LifecycleState.ERROR
	Metrics.inc("component.errors", 1)

	log.error("Component error", {
		id    = self.id,
		name  = self.name,
		phase = phase,
		error = tostring(err),
	})

	if self._onError then pcall(self._onError, err, self) end

	if self._errorBoundary then
		pcall(function()
			self._errorBoundary:_handleError("boundary_child:" .. self.name, err)
		end)
	end

	SignalBus.emit("component:error", { id = self.id, name = self.name, error = err, phase = phase })
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function Component:mount()
	assert(self._lifecycle == Types.LifecycleState.IDLE,
		"Component.mount: already mounted — id=" .. self.id)

	self._lifecycle    = Types.LifecycleState.MOUNTING
	_registry[self.id] = self

	Scheduler.schedule(function()
		self:_render()
		self._lifecycle = Types.LifecycleState.MOUNTED

		if self._onMount then pcall(self._onMount, self) end

		SignalBus.emit("component:mounted", { id = self.id, name = self.name, frame = self.frame })
		Metrics.adjust("component.mounted.count", 1)

		log.info("Component mounted", { id = self.id, name = self.name })
	end, { priority = Scheduler.Priority.NORMAL })

	return self
end

function Component:setState(patch)
	assert(type(patch) == "table", "Component.setState: patch must be a table")

	if not self._pendingBatch then
		self._pendingBatch = {}
	end
	for k, v in pairs(patch) do
		self._pendingBatch[k] = v
	end

	Scheduler.schedule(function()
		if not self._pendingBatch then return end

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

		Metrics.inc("component.setState.count", 1)
	end, {
		priority = Scheduler.Priority.NORMAL,
		id       = "setState:" .. self.id,
	})
end

function Component:forceUpdate()
	Scheduler.schedule(function()
		self:_render()
	end, { priority = Scheduler.Priority.NORMAL })
end

function Component:getState()
	local copy = {}
	for k, v in pairs(self._state) do copy[k] = v end
	return copy
end

function Component:unmount()
	if self._lifecycle == Types.LifecycleState.UNMOUNTED or
	   self._lifecycle == Types.LifecycleState.UNMOUNTING then
		return
	end

	self._lifecycle = Types.LifecycleState.UNMOUNTING
	log.info("Component unmounting", { id = self.id, name = self.name })

	-- Tear down all instance connections (events, changes, binding links)
	for _, conns in pairs(self._connectionMap) do
		for _, conn in pairs(conns) do
			if type(conn) == "function" then conn()
			elseif type(conn) == "table" and conn.Disconnect then conn:Disconnect() end
		end
	end
	self._connectionMap = {}

	for _, effect in ipairs(self._effects) do effect.destroy() end
	self._effects = {}

	for _, memo in ipairs(self._memos) do memo.destroy() end
	self._memos = {}

	for _, sub in ipairs(self._subscriptions) do sub.disconnect() end
	self._subscriptions = {}

	for _, cleanup in ipairs(self._contextCleanup) do pcall(cleanup) end
	self._contextCleanup = {}

	if self._onUnmount then pcall(self._onUnmount, self) end

	self._lifecycle    = Types.LifecycleState.UNMOUNTED
	_registry[self.id] = nil

	Metrics.adjust("component.mounted.count", -1)
	Metrics.adjust("component.count",         -1)

	SignalBus.emit("component:unmounted", { id = self.id, name = self.name })
	log.info("Component unmounted", { id = self.id, name = self.name, renders = self._renderCount })
end

-- ── Registry ─────────────────────────────────────────────────────────────────

function Component.getById(id)   return _registry[id] end

function Component.getAll()
	local out = {}
	for _, c in pairs(_registry) do out[#out + 1] = c end
	return out
end

function Component.unmountAll()
	for _, c in pairs(_registry) do c:unmount() end
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
