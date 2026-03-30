local Types   = require(script.Parent.Parent.core.Types)
local Logger  = require(script.Parent.Parent.logger.Logger)
local HttpSvc = game:GetService("HttpService")

local log = Logger.child("Metrics")

local Metrics = {}

--  INTERNAL REGISTRY
local _registry = {}    -- name → metric table
local _reporters = {}   -- array of reporter fns: (snapshot) → void
local _reportInterval = 60  -- seconds between auto-reports (0 = disabled)
local _reportTimer    = 0
local _enabled        = true

--  HELPERS
local function uid8()
	return HttpSvc:GenerateGUID(false):sub(1, 8)
end

local function now()
	return tick()
end

local function getOrCreate(name, kind, description, tags)
	if _registry[name] then
		assert(_registry[name].kind == kind,
			"Metrics: name collision — '" .. name .. "' already registered as " .. _registry[name].kind)
		return _registry[name]
	end

	local m = {
		id          = uid8(),
		name        = name,
		kind        = kind,
		description = description or "",
		tags        = tags or {},
		createdAt   = now(),
	}

	if kind == Types.MetricKind.COUNTER then
		m.value = 0
	elseif kind == Types.MetricKind.GAUGE then
		m.value = 0
	elseif kind == Types.MetricKind.HISTOGRAM then
		m.buckets  = {}  -- { le: number, count: number }
		m.sum      = 0
		m.count    = 0
		m.min      = math.huge
		m.max      = -math.huge
	elseif kind == Types.MetricKind.TIMING then
		m.active   = {}  -- id → startTime
		m.samples  = {}  -- array of durations (capped)
		m.sum      = 0
		m.count    = 0
		m.min      = math.huge
		m.max      = -math.huge
	end

	_registry[name] = m
	log.debug("Metric registered", { name = name, kind = kind })
	return m
end

--  COUNTER

--- Increment a counter by `amount` (default 1).
function Metrics.inc(name, amount, description, tags)
	if not _enabled then return end
	amount = amount or 1
	local m = getOrCreate(name, Types.MetricKind.COUNTER, description, tags)
	m.value = m.value + amount
end

--- Get current counter value.
function Metrics.getCounter(name)
	local m = _registry[name]
	return m and m.value or 0
end

--  GAUGE

--- Set a gauge to an absolute value.
function Metrics.set(name, value, description, tags)
	if not _enabled then return end
	local m = getOrCreate(name, Types.MetricKind.GAUGE, description, tags)
	m.value = value
	m.lastUpdated = now()
end

--- Adjust a gauge by a delta.
function Metrics.adjust(name, delta, description, tags)
	if not _enabled then return end
	local m = getOrCreate(name, Types.MetricKind.GAUGE, description, tags)
	m.value = (m.value or 0) + delta
	m.lastUpdated = now()
end

--- Get current gauge value.
function Metrics.getGauge(name)
	local m = _registry[name]
	return m and m.value or 0
end

--  HISTOGRAM

--- Default bucket boundaries (in ms for timing, units for general)
local DEFAULT_BUCKETS = { 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 }

--- Record a value in a histogram.
function Metrics.observe(name, value, description, tags, bucketBoundaries)
	if not _enabled then return end
	local m = getOrCreate(name, Types.MetricKind.HISTOGRAM, description, tags)

	-- init buckets lazily
	if #m.buckets == 0 then
		local bounds = bucketBoundaries or DEFAULT_BUCKETS
		for _, le in ipairs(bounds) do
			m.buckets[#m.buckets + 1] = { le = le, count = 0 }
		end
		m.buckets[#m.buckets + 1] = { le = math.huge, count = 0 }  -- +Inf
	end

	-- accumulate
	m.sum   = m.sum + value
	m.count = m.count + 1
	m.min   = math.min(m.min, value)
	m.max   = math.max(m.max, value)

	for _, bucket in ipairs(m.buckets) do
		if value <= bucket.le then
			bucket.count = bucket.count + 1
		end
	end
end

--- Compute a percentile from histogram (approximate, linear interp per bucket).
function Metrics.percentile(name, p)
	local m = _registry[name]
	if not m or m.kind ~= Types.MetricKind.HISTOGRAM or m.count == 0 then return nil end
	local target = p * m.count
	local prev = { le = 0, count = 0 }
	for _, bucket in ipairs(m.buckets) do
		if bucket.count >= target then
			-- linear interpolation within bucket
			local span  = bucket.le - prev.le
			local ratio = (target - prev.count) / math.max(1, bucket.count - prev.count)
			return prev.le + span * ratio
		end
		prev = bucket
	end
	return m.max
end

--  TIMING (high-level stopwatch backed by histogram)

--- Start a timing. Returns a stop function.
function Metrics.startTimer(name, description, tags)
	if not _enabled then
		return function() end
	end
	local m = getOrCreate(name, Types.MetricKind.TIMING, description, tags)
	local id    = uid8()
	local start = now()
	m.active[id] = start

	return function()
		local elapsed = (now() - start) * 1000  -- ms
		m.active[id]  = nil
		m.sum    = m.sum + elapsed
		m.count  = m.count + 1
		m.min    = math.min(m.min, elapsed)
		m.max    = math.max(m.max, elapsed)

		-- keep last 256 samples
		local samples = m.samples
		samples[#samples + 1] = elapsed
		if #samples > 256 then
			table.remove(samples, 1)
		end

		log.trace("Timer stopped", { name = name, elapsed_ms = math.floor(elapsed * 10) / 10 })
		return elapsed
	end
end

--- Wrap a function with automatic timing.
function Metrics.timed(name, fn, description, tags)
	return function(...)
		local stop = Metrics.startTimer(name, description, tags)
		local ok, result = pcall(fn, ...)
		stop()
		if not ok then error(result, 2) end
		return result
	end
end

--- Get timing summary.
function Metrics.getTimingSummary(name)
	local m = _registry[name]
	if not m or (m.kind ~= Types.MetricKind.TIMING and m.kind ~= Types.MetricKind.HISTOGRAM) then
		return nil
	end
	local avg = m.count > 0 and (m.sum / m.count) or 0
	return {
		count  = m.count,
		sum_ms = m.sum,
		avg_ms = avg,
		min_ms = m.min == math.huge  and 0 or m.min,
		max_ms = m.max == -math.huge and 0 or m.max,
	}
end

--  SNAPSHOT / EXPORT

--- Return a full snapshot of all metrics.
function Metrics.snapshot()
	local snap = {
		timestamp = now(),
		metrics   = {},
	}
	for name, m in pairs(_registry) do
		local entry = {
			name        = m.name,
			kind        = m.kind,
			description = m.description,
			tags        = m.tags,
		}

		if m.kind == Types.MetricKind.COUNTER or m.kind == Types.MetricKind.GAUGE then
			entry.value = m.value
		elseif m.kind == Types.MetricKind.HISTOGRAM then
			entry.count   = m.count
			entry.sum     = m.sum
			entry.min     = m.min == math.huge  and 0 or m.min
			entry.max     = m.max == -math.huge and 0 or m.max
			entry.avg     = m.count > 0 and (m.sum / m.count) or 0
			entry.p50     = Metrics.percentile(name, 0.50)
			entry.p95     = Metrics.percentile(name, 0.95)
			entry.p99     = Metrics.percentile(name, 0.99)
			entry.buckets = m.buckets
		elseif m.kind == Types.MetricKind.TIMING then
			entry.count    = m.count
			entry.sum_ms   = m.sum
			entry.avg_ms   = m.count > 0 and (m.sum / m.count) or 0
			entry.min_ms   = m.min == math.huge  and 0 or m.min
			entry.max_ms   = m.max == -math.huge and 0 or m.max
			entry.active   = 0
			for _ in pairs(m.active) do entry.active = entry.active + 1 end
		end

		snap.metrics[name] = entry
	end
	return snap
end

--- Print a human-readable report to output.
function Metrics.report()
	local snap = Metrics.snapshot()
	print(string.rep("=", 60))
	print(string.format("[UIFramework Metrics] @ %.2f", snap.timestamp))
	print(string.rep("-", 60))
	for name, m in pairs(snap.metrics) do
		if m.kind == Types.MetricKind.COUNTER then
			print(string.format("  COUNTER  %-40s %d", name, m.value))
		elseif m.kind == Types.MetricKind.GAUGE then
			print(string.format("  GAUGE    %-40s %.2f", name, m.value))
		elseif m.kind == Types.MetricKind.HISTOGRAM then
			print(string.format("  HIST     %-40s count=%d avg=%.2f p95=%.2f p99=%.2f",
				name, m.count, m.avg or 0, m.p95 or 0, m.p99 or 0))
		elseif m.kind == Types.MetricKind.TIMING then
			print(string.format("  TIMING   %-40s count=%d avg=%.1fms min=%.1fms max=%.1fms active=%d",
				name, m.count, m.avg_ms or 0, m.min_ms or 0, m.max_ms or 0, m.active or 0))
		end
	end
	print(string.rep("=", 60))
end

--- Add a reporter. Called periodically or on Metrics.flush().
--- Reporter fn signature: (snapshot) → void
function Metrics.addReporter(fn)
	assert(type(fn) == "function", "Metrics.addReporter: fn must be a function")
	_reporters[#_reporters + 1] = fn
end

--- Immediately push current snapshot to all reporters.
function Metrics.flush()
	local snap = Metrics.snapshot()
	for _, reporter in ipairs(_reporters) do
		pcall(reporter, snap)
	end
end

--- Reset a specific metric (or all if name omitted).
function Metrics.reset(name)
	if name then
		_registry[name] = nil
	else
		_registry = {}
	end
end

--- Enable/disable collection entirely.
function Metrics.setEnabled(v)
	_enabled = v
end

--  AUTO-REPORT HEARTBEAT  (hook into game RunService in the consumer layer)
--  Exposed as a tick function so the Framework root can call it from RunService.Heartbeat
function Metrics._tick(dt)
	if _reportInterval <= 0 then return end
	_reportTimer = _reportTimer + dt
	if _reportTimer >= _reportInterval then
		_reportTimer = 0
		Metrics.flush()
	end
end

function Metrics.setReportInterval(seconds)
	_reportInterval = seconds
end

return Metrics
