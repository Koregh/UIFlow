-- Bindings: reactive values that update Roblox Instance properties directly
-- WITHOUT triggering a full component re-render. Ideal for animations and
-- high-frequency updates (health bars, position tracking, etc).
--
--
-- Usage:
--   local hp, setHp = Binding.create(100)
--
--   -- Link directly to a property (no re-render on change):
--   local disconnect = Binding.link(hp, healthBar, "Size", function(v)
--       return UDim2.new(v / 100, 0, 1, 0)
--   end)
--
--   setHp(75)  -- healthBar.Size updates instantly, zero re-renders
--
--   -- Derived bindings:
--   local pct = hp:map(function(v) return v / 100 end)
--
--   -- Join multiple bindings:
--   local combined = Binding.join({ hp = hp, mp = mp })
--   combined:getValue()  --> { hp = 75, mp = 50 }

local Logger  = require(script.Parent.Logger)
local Metrics = require(script.Parent.Metrics)

local log = Logger.child("Binding")

local Binding = {}

local BindingMeta = {}
BindingMeta.__index = BindingMeta

function BindingMeta:getValue()
	return self._impl.getValue()
end

function BindingMeta:map(fn)
	assert(type(fn) == "function", "Binding:map requires a function")
	return Binding._makeFromImpl({
		getValue   = function() return fn(self._impl.getValue()) end,
		subscribe  = function(cb)
			return self._impl.subscribe(function(v)
				cb(fn(v))
			end)
		end,
		update     = function()
			error("Mapped bindings cannot be updated directly", 2)
		end,
	})
end

function BindingMeta:__tostring()
	return string.format("UIBinding(%s)", tostring(self:getValue()))
end

function Binding._makeFromImpl(impl)
	return setmetatable({ _impl = impl }, BindingMeta)
end

-- Create a new binding with an initial value.
-- Returns: binding, updater
function Binding.create(initialValue)
	local value      = initialValue
	local listeners  = {}

	local function subscribe(cb)
		listeners[#listeners + 1] = cb
		return function()
			for i, l in ipairs(listeners) do
				if l == cb then
					table.remove(listeners, i)
					break
				end
			end
		end
	end

	local impl = {
		getValue  = function() return value end,
		subscribe = subscribe,
		update    = function(newValue)
			if newValue == value then return end
			value = newValue
			for _, cb in ipairs(listeners) do
				pcall(cb, newValue)
			end
			Metrics.inc("binding.updates", 1)
		end,
	}

	Metrics.adjust("binding.active", 1)
	log.trace("Binding created")

	local binding = Binding._makeFromImpl(impl)
	return binding, impl.update
end

-- Join multiple bindings into one that emits a table.
-- Input: { key = binding, ... }
function Binding.join(bindings)
	assert(type(bindings) == "table", "Binding.join: expected table of bindings")

	local function getValue()
		local out = {}
		for k, b in pairs(bindings) do
			out[k] = b:getValue()
		end
		return out
	end

	local disconnects = {}

	local impl = {
		getValue  = getValue,
		update    = function() error("Joined bindings cannot be updated directly", 2) end,
		subscribe = function(cb)
			local subs = {}
			for k, b in pairs(bindings) do
				subs[#subs + 1] = b._impl.subscribe(function()
					cb(getValue())
				end)
			end
			return function()
				for _, unsub in ipairs(subs) do unsub() end
			end
		end,
	}

	return Binding._makeFromImpl(impl)
end

-- Link a binding to a Roblox Instance property.
-- `transform` is optional: (value) -> property_value
-- Returns a disconnect function.
function Binding.link(binding, instance, property, transform)
	assert(typeof(instance) == "Instance", "Binding.link: instance must be a Roblox Instance")
	assert(type(property) == "string",     "Binding.link: property must be a string")

	local function apply(v)
		local val = transform and transform(v) or v
		local ok, err = pcall(function() instance[property] = val end)
		if not ok then
			log.warn("Binding.link: failed to set property", {
				instance = instance.Name,
				property = property,
				error    = err,
			})
		end
	end

	-- Apply immediately
	apply(binding:getValue())

	local disconnect = binding._impl.subscribe(apply)
	Metrics.adjust("binding.links", 1)

	log.trace("Binding linked", { instance = instance.Name, property = property })

	return function()
		disconnect()
		Metrics.adjust("binding.links", -1)
	end
end

-- useBinding: integrates with the component system.
-- Returns a binding + updater, and registers cleanup on unmount via the
-- provided destroy table (populated by Component._buildApi's useEffect pattern).
function Binding.useBinding(initialValue)
	return Binding.create(initialValue)
end

return Binding
