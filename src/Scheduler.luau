--[[
  ============================================================
  UIFramework / scheduler / Scheduler.lua
  ============================================================
  React-inspired batched task scheduler.

  Priorities (high → low):
    IMMEDIATE  — sync, this frame (critical UI corrections)
    NORMAL     — next microtask batch (state updates, renders)
    LOW        — idle / background (pre-loading, cleanup)
    IDLE       — only when nothing else queued

  Features:
    - Batching: multiple setState calls in one frame collapse into one render
    - Priority lanes (like React's concurrent mode lanes)
    - Cancelable tasks
    - Per-task error boundaries (a failing task never kills the queue)
    - Metrics: queue depth, task durations, dropped tasks
    - Flush budget: cap CPU per frame to avoid jank
  ============================================================
--]]

local Types   = require(script.Parent.Parent.core.Types)
local Logger  = require(script.Parent.Parent.logger.Logger)
local Metrics = require(script.Parent.Parent.metrics.Metrics)
local HttpSvc = game:GetService("HttpService")

local log = Logger.child("Scheduler")

local Scheduler = {}

--  PRIORITY LANES
Scheduler.Priority = {
	IMMEDIATE = 1,
	NORMAL    = 2,
	LOW       = 3,
	IDLE      = 4,
}

local PRIORITY_NAMES = {
	[1] = "IMMEDIATE",
	[2] = "NORMAL",
	[3] = "LOW",
	[4] = "IDLE",
}

--  CONFIG
local FRAME_BUDGET_MS = 4       -- max ms spent flushing per frame
local BATCH_DELAY     = 0       -- seconds between NORMAL batch flushes (0 = next frame)

--  INTERNAL QUEUES  (one per priority lane)
local _queues = {
	[1] = {},  -- IMMEDIATE
	[2] = {},  -- NORMAL
	[3] = {},  -- LOW
	[4] = {},  -- IDLE
}

local _flushing = false  -- reentrancy guard
local _batchPending = false

local function uid()
	return HttpSvc:GenerateGUID(false):sub(1, 8)
end

--  SCHEDULE A TASK

--[[
  opts = {
    priority  = Scheduler.Priority.NORMAL,
    id        = "unique-key",   -- if same id enqueued twice, deduplicated
    onError   = fn,             -- called instead of propagating
  }
  Returns handle: { cancel() }
--]]

local _dedupeSet = {}  -- id → true for dedup

function Scheduler.schedule(fn, opts)
	assert(type(fn) == "function", "Scheduler.schedule: fn must be a function")
	opts = opts or {}

	local priority = opts.priority or Scheduler.Priority.NORMAL
	local taskId   = opts.id or uid()

	-- deduplicate by id
	if opts.id and _dedupeSet[opts.id] then
		log.trace("Deduplicated task", { id = taskId })
		Metrics.inc("scheduler.deduped", 1, "Deduplicated tasks")
		return {
			id     = taskId,
			cancel = function() end,
		}
	end

	local task_ = {
		id       = taskId,
		fn       = fn,
		priority = priority,
		active   = true,
		enqueued = tick(),
		onError  = opts.onError,
	}

	if opts.id then
		_dedupeSet[opts.id] = true
	end

	_queues[priority][#_queues[priority] + 1] = task_
	Metrics.adjust("scheduler.queue.depth", 1, "Tasks in scheduler queue")
	Metrics.inc("scheduler.enqueued", 1, "Total tasks enqueued")

	log.trace("Task scheduled", { id = taskId, priority = PRIORITY_NAMES[priority] })

	-- trigger flush for non-immediate priorities
	if priority == Scheduler.Priority.IMMEDIATE then
		Scheduler._flushPriority(Scheduler.Priority.IMMEDIATE)
	elseif not _batchPending then
		_batchPending = true
		task.defer(function()
			_batchPending = false
			Scheduler.flush()
		end)
	end

	return {
		id = taskId,
		cancel = function()
			task_.active = false
			if opts.id then _dedupeSet[opts.id] = nil end
			Metrics.adjust("scheduler.queue.depth", -1)
			Metrics.inc("scheduler.cancelled", 1, "Cancelled tasks")
		end,
	}
end

--- Schedule with a delay (uses task.delay, bypasses dedup).
function Scheduler.scheduleAfter(delay, fn, opts)
	task.delay(delay, function()
		Scheduler.schedule(fn, opts)
	end)
end

--  BATCH HELPER
--  Accumulate calls, run once: useful for setState batching.
--  Returns a flush function that runs all accumulated fns as ONE task.

function Scheduler.batch(priority)
	priority = priority or Scheduler.Priority.NORMAL
	local pending = {}
	local handle

	return {
		add = function(fn)
			pending[#pending + 1] = fn
			if handle then return end
			handle = Scheduler.schedule(function()
				handle = nil
				local fns = pending
				pending = {}
				for _, f in ipairs(fns) do
					local ok, err = pcall(f)
					if not ok then
						log.error("Batch task threw", { error = err })
					end
				end
			end, { priority = priority })
		end,
		flush = function()
			if handle then
				handle.cancel()
				handle = nil
			end
			for _, f in ipairs(pending) do
				pcall(f)
			end
			pending = {}
		end,
	}
end

--  FLUSH

function Scheduler._flushPriority(priority)
	local queue = _queues[priority]
	if #queue == 0 then return end

	local stopTimer = Metrics.startTimer("scheduler.flush.duration_ms", "Scheduler flush time")
	local ran = 0

	-- snapshot to allow scheduling during flush
	local snapshot = {}
	for _, t in ipairs(queue) do snapshot[#snapshot + 1] = t end
	_queues[priority] = {}

	for _, task_ in ipairs(snapshot) do
		if task_.active then
			if task_.id then _dedupeSet[task_.id] = nil end

			local t0 = tick()
			local ok, err = pcall(task_.fn)
			local dt = (tick() - t0) * 1000

			Metrics.adjust("scheduler.queue.depth", -1)
			Metrics.observe("scheduler.task.duration_ms", dt, "Task execution time in ms")
			ran = ran + 1

			if not ok then
				Metrics.inc("scheduler.errors", 1, "Task execution errors")
				log.error("Task threw", {
					id       = task_.id,
					priority = PRIORITY_NAMES[priority],
					error    = err,
					duration_ms = dt,
				})
				if task_.onError then
					pcall(task_.onError, err)
				end
			end
		else
			if task_.id then _dedupeSet[task_.id] = nil end
			Metrics.adjust("scheduler.queue.depth", -1)
		end
	end

	local elapsed = stopTimer()
	if ran > 0 then
		log.trace("Flush done", {
			priority   = PRIORITY_NAMES[priority],
			tasks      = ran,
			elapsed_ms = math.floor(elapsed * 10) / 10,
		})
	end
end

--- Flush all lanes respecting frame budget.
function Scheduler.flush()
	if _flushing then return end
	_flushing = true

	local frameStart = tick()

	for priority = 1, 4 do
		local elapsed = (tick() - frameStart) * 1000
		if elapsed > FRAME_BUDGET_MS and priority >= Scheduler.Priority.LOW then
			-- over budget — defer lower-priority work
			if #_queues[priority] > 0 then
				task.defer(function()
					Scheduler.flush()
				end)
			end
			break
		end
		Scheduler._flushPriority(priority)
	end

	_flushing = false
end

--- Configure frame budget.
function Scheduler.setFrameBudget(ms)
	FRAME_BUDGET_MS = ms
end

--- Total pending tasks across all queues.
function Scheduler.pendingCount()
	local n = 0
	for _, q in ipairs(_queues) do n = n + #q end
	return n
end

return Scheduler
