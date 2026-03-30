local Types    = require(script.Parent.Types)
local Logger   = require(script.Parent.Logger)
local Metrics  = require(script.Parent.Metrics)
local Renderer = require(script.Parent.Renderer)

local log = Logger.child("Presets")

local Presets = {}

function Presets.bounceIn(frame, opts)
	opts = opts or {}
	local origSize = frame.Size
	frame.Size    = UDim2.new(0, 0, 0, 0)
	frame.Visible = true
	Metrics.inc("presets.bounceIn", 1)
	return Renderer.animate(frame, { Size = origSize }, {
		duration   = opts.duration or 0.45,
		easing     = Types.Easing.BACK_OUT,
		onComplete = opts.onComplete,
	})
end

function Presets.slideIn(frame, direction, opts)
	opts      = opts      or {}
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
	else
		error("Presets.slideIn: unknown direction '" .. tostring(direction) .. "'")
	end

	frame.Position = from
	frame.Visible  = true

	Metrics.inc("presets.slideIn", 1)
	return Renderer.animate(frame, { Position = origPos }, {
		duration   = opts.duration or 0.4,
		easing     = opts.easing   or Types.Easing.EASE_OUT,
		delay      = opts.delay    or 0,
		onComplete = opts.onComplete,
	})
end

function Presets.slideOut(frame, direction, opts)
	opts      = opts      or {}
	direction = direction or "bottom"

	local origPos = frame.Position
	local to

	if direction == "bottom" then
		to = UDim2.new(origPos.X.Scale, origPos.X.Offset, 1.2, 0)
	elseif direction == "top" then
		to = UDim2.new(origPos.X.Scale, origPos.X.Offset, -1.2, 0)
	elseif direction == "left" then
		to = UDim2.new(-1.2, 0, origPos.Y.Scale, origPos.Y.Offset)
	elseif direction == "right" then
		to = UDim2.new(1.2, 0, origPos.Y.Scale, origPos.Y.Offset)
	end

	Metrics.inc("presets.slideOut", 1)
	return Renderer.animate(frame, { Position = to }, {
		duration   = opts.duration or 0.4,
		easing     = opts.easing   or Types.Easing.EASE_IN,
		onComplete = function(inst)
			inst.Visible   = false
			inst.Position  = origPos
			if opts.onComplete then opts.onComplete(inst) end
		end,
	})
end

function Presets.fadeIn(frame, opts)
	opts = opts or {}
	frame.BackgroundTransparency = 1
	frame.Visible = true
	Metrics.inc("presets.fadeIn", 1)
	return Renderer.animate(frame, { BackgroundTransparency = opts.targetAlpha or 0 }, {
		duration   = opts.duration or 0.3,
		easing     = opts.easing   or Types.Easing.EASE_OUT,
		onComplete = opts.onComplete,
	})
end

function Presets.fadeOut(frame, opts)
	opts = opts or {}
	Metrics.inc("presets.fadeOut", 1)
	return Renderer.animate(frame, { BackgroundTransparency = 1 }, {
		duration   = opts.duration or 0.3,
		easing     = opts.easing   or Types.Easing.EASE_IN,
		onComplete = function(inst)
			inst.Visible = false
			if opts.onComplete then opts.onComplete(inst) end
		end,
	})
end

function Presets.pop(frame, opts)
	opts = opts or {}
	local orig   = frame.Size
	local factor = opts.factor or 1.12
	local big    = UDim2.new(
		orig.X.Scale * factor, orig.X.Offset,
		orig.Y.Scale * factor, orig.Y.Offset
	)
	Metrics.inc("presets.pop", 1)
	return Renderer.sequence()
		:add(frame, { Size = big }, {
			duration = opts.upDuration or 0.12,
			easing   = Types.Easing.EASE_OUT,
		})
		:add(frame, { Size = orig }, {
			duration = opts.downDuration or 0.2,
			easing   = Types.Easing.BACK_OUT,
		})
		:play(opts.onComplete)
end

function Presets.pulse(frame, opts)
	opts = opts or {}
	local orig   = frame.Size
	local factor = opts.scale or 1.08
	local big    = UDim2.new(
		orig.X.Scale * factor, orig.X.Offset,
		orig.Y.Scale * factor, orig.Y.Offset
	)
	Metrics.inc("presets.pulse.started", 1)
	return Renderer.loop(frame, {
		{ goals = { Size = big  }, duration = opts.duration or 0.6, easing = Types.Easing.SINE_IO },
		{ goals = { Size = orig }, duration = opts.duration or 0.6, easing = Types.Easing.SINE_IO },
	}, { pingpong = false, delay = opts.delay or 0, onCycle = opts.onCycle })
end

function Presets.float(frame, opts)
	opts = opts or {}
	local orig   = frame.Position
	local amount = opts.amount or 6
	local up     = UDim2.new(orig.X.Scale, orig.X.Offset, orig.Y.Scale, orig.Y.Offset - amount)
	local down   = UDim2.new(orig.X.Scale, orig.X.Offset, orig.Y.Scale, orig.Y.Offset + amount)
	Metrics.inc("presets.float.started", 1)
	return Renderer.loop(frame, {
		{ goals = { Position = up   }, duration = opts.duration or 1.2, easing = Types.Easing.SINE_IO },
		{ goals = { Position = down }, duration = opts.duration or 1.2, easing = Types.Easing.SINE_IO },
	}, { pingpong = false })
end

function Presets.spin(frame, opts)
	opts = opts or {}
	local duration = opts.duration or 2
	Metrics.inc("presets.spin.started", 1)
	return Renderer.loop(frame, {
		{ goals = { Rotation = 360 }, duration = duration, easing = Types.Easing.LINEAR },
	}, {
		onCycle = function()
			pcall(function() frame.Rotation = 0 end)
		end,
	})
end

function Presets.shake(frame, opts)
	opts = opts or {}
	local origPos  = frame.Position
	local strength = opts.strength or 6
	local count    = opts.count    or 6
	local dur      = opts.duration or 0.06

	Metrics.inc("presets.shake", 1)

	task.spawn(function()
		for _ = 1, count do
			local dx = (math.random() - 0.5) * 2 * strength
			local dy = (math.random() - 0.5) * 2 * strength
			local h  = Renderer.animate(frame, {
				Position = UDim2.new(
					origPos.X.Scale, origPos.X.Offset + dx,
					origPos.Y.Scale, origPos.Y.Offset + dy
				)
			}, { duration = dur, easing = Types.Easing.LINEAR })
			h:await()
		end
		Renderer.animate(frame, { Position = origPos }, { duration = dur, easing = Types.Easing.EASE_OUT })
			:andThen(function()
				if opts.onComplete then opts.onComplete() end
			end)
	end)
end

function Presets.flash(frame, opts)
	opts = opts or {}
	local origColor  = frame.BackgroundColor3
	local flashColor = opts.color or Color3.new(1, 0.3, 0.3)

	Metrics.inc("presets.flash", 1)

	return Renderer.sequence()
		:add(frame, { BackgroundColor3 = flashColor }, {
			duration = opts.inDuration  or 0.1,
			easing   = Types.Easing.EASE_IN,
		})
		:add(frame, { BackgroundColor3 = origColor }, {
			duration = opts.outDuration or 0.3,
			easing   = Types.Easing.EASE_OUT,
		})
		:play(opts.onComplete)
end

function Presets.wipeIn(frame, opts)
	opts = opts or {}
	local origSize = frame.Size
	frame.Size    = UDim2.new(0, 0, origSize.Y.Scale, origSize.Y.Offset)
	frame.Visible = true

	Metrics.inc("presets.wipeIn", 1)
	return Renderer.animate(frame, { Size = origSize }, {
		duration   = opts.duration or 0.4,
		easing     = opts.easing   or Types.Easing.EASE_OUT,
		onComplete = opts.onComplete,
	})
end

return Presets
