local Types   = require(script.Parent.Types)
local Logger  = require(script.Parent.Logger)
local Metrics = require(script.Parent.Metrics)
local HttpSvc = game:GetService("HttpService")

local log = Logger.child("SignalBus")

local SignalBus = {}

local _channels      = {}
local _middlewares   = {}
local _deadLetters   = {}
local _deadLetterMax = 100

local function uid()
	return HttpSvc:GenerateGUID(false):sub(1, 8)
end

local function now()
	return tick()
end

local function getChannel(signal)
	if not _channels[signal] then
		_channels[signal] = {
			name        = signal,
			subscribers = {},
			createdAt   = now(),
			emitCount   = 0,
		}
	end
	return _channels[signal]
end

local function insertSorted(list, entry)
	local lo, hi = 1, #list
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if list[mid].priority >= entry.priority then
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	table.insert(list, lo, entry)
end

function SignalBus.use(fn)
	assert(type(fn) == "function", "SignalBus.use: middleware must be a function")
	_middlewares[#_middlewares + 1] = fn
	return {
		remove = function()
			for i, m in ipairs(_middlewares) do
				if m == fn then table.remove(_middlewares, i) break end
			end
		end
	}
end

function SignalBus.on(signal, callback, opts)
	assert(type(signal)   == "string",   "SignalBus.on: signal must be a string")
	assert(type(callback) == "function", "SignalBus.on: callback must be a function")
	opts = opts or {}

	local ch    = getChannel(signal)
	local id    = uid()
	local entry = {
		id        = id,
		fn        = callback,
		priority  = opts.priority or 0,
		once      = opts.once     or false,
		async     = opts.async    or false,
		filter    = opts.filter,
		active    = true,
		signal    = signal,
		createdAt = now(),
		fireCount = 0,
	}

	insertSorted(ch.subscribers, entry)
	Metrics.adjust("signal.subscriptions.active", 1)

	log.debug("Subscribed", { signal = signal, id = id, priority = entry.priority })

	local handle = {
		id     = id,
		signal = signal,
		disconnect = function()
			if not entry.active then return end
			entry.active = false
			Metrics.adjust("signal.subscriptions.active", -1)
			log.debug("Unsubscribed", { signal = signal, id = id })
		end,
	}

	handle.Disconnect = handle.disconnect
	return handle
end

function SignalBus.once(signal, callback, opts)
	opts = opts or {}
	opts.once = true
	return SignalBus.on(signal, callback, opts)
end

function SignalBus.waitFor(signal, timeout)
	local thread = coroutine.running()
	assert(thread, "SignalBus.waitFor must be called from inside a coroutine or task.spawn")

	local handle
	local fired  = false
	local result = nil

	handle = SignalBus.once(signal, function(...)
		fired  = true
		result = { ... }
		task.spawn(thread)
	end)

	if timeout then
		task.delay(timeout, function()
			if not fired then
				handle.disconnect()
				task.spawn(thread)
			end
		end)
	end

	coroutine.yield()
	return result and table.unpack(result)
end

function SignalBus.emit(signal, ...)
	local ch   = getChannel(signal)
	local args = { ... }

	for _, mw in ipairs(_middlewares) do
		local newArgs = mw(signal, args)
		if newArgs == nil then
			log.debug("Emit vetoed by middleware", { signal = signal })
			Metrics.inc("signal.vetoed", 1)
			return
		end
		if type(newArgs) == "table" then
			args = newArgs
		end
	end

	ch.emitCount = ch.emitCount + 1
	Metrics.inc("signal.emit.total", 1)
	Metrics.inc("signal." .. signal .. ".emit", 1)

	if #ch.subscribers == 0 then
		local entry = { signal = signal, args = args, timestamp = now() }
		_deadLetters[#_deadLetters + 1] = entry
		if #_deadLetters > _deadLetterMax then
			table.remove(_deadLetters, 1)
		end
		log.trace("Dead letter", { signal = signal })
		return
	end

	local snapshot = {}
	for _, s in ipairs(ch.subscribers) do
		if s.active then snapshot[#snapshot + 1] = s end
	end

	local stopTimer = Metrics.startTimer("signal.dispatch.duration_ms")

	for _, sub in ipairs(snapshot) do
		if not sub.active then continue end

		if sub.filter and not sub.filter(table.unpack(args)) then
			continue
		end

		sub.fireCount = sub.fireCount + 1

		local function deliver()
			local ok, err = pcall(sub.fn, table.unpack(args))
			if not ok then
				log.error("Subscriber threw", { signal = signal, id = sub.id, error = err })
				Metrics.inc("signal.subscriber.errors", 1)
			end
		end

		if sub.async then
			task.spawn(deliver)
		else
			deliver()
		end

		if sub.once then
			sub.active = false
			Metrics.adjust("signal.subscriptions.active", -1)
		end
	end

	stopTimer()

	for i = #ch.subscribers, 1, -1 do
		if not ch.subscribers[i].active then
			table.remove(ch.subscribers, i)
		end
	end
end

function SignalBus.getDeadLetters()
	return { table.unpack(_deadLetters) }
end

function SignalBus.clearDeadLetters()
	_deadLetters = {}
end

function SignalBus.getChannelInfo(signal)
	local ch = _channels[signal]
	if not ch then return nil end
	local activeSubs = 0
	for _, s in ipairs(ch.subscribers) do
		if s.active then activeSubs = activeSubs + 1 end
	end
	return {
		name       = ch.name,
		emitCount  = ch.emitCount,
		activeSubs = activeSubs,
		createdAt  = ch.createdAt,
	}
end

function SignalBus.getAllChannels()
	local out = {}
	for name, _ in pairs(_channels) do
		out[#out + 1] = SignalBus.getChannelInfo(name)
	end
	return out
end

function SignalBus.clear(signal)
	if _channels[signal] then
		for _, s in ipairs(_channels[signal].subscribers) do
			s.active = false
		end
		_channels[signal].subscribers = {}
	end
end

function SignalBus.reset()
	_channels    = {}
	_middlewares = {}
	_deadLetters = {}
end

return SignalBus
