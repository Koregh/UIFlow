local Logger   = require(script.Parent.Logger)
local Metrics  = require(script.Parent.Metrics)
local TweenSvc = game:GetService("TweenService")
local Debris   = game:GetService("Debris")

local log = Logger.child("Utils")

local Utils = {}

Utils.Number = {}

local SUFFIX_LONG  = { { 1e15,"Q" }, { 1e12,"T" }, { 1e9,"B" }, { 1e6,"M" }, { 1e3,"K" } }
local SUFFIX_SHORT = { { 1e15,"q" }, { 1e12,"t" }, { 1e9,"b" }, { 1e6,"m" }, { 1e3,"k" } }

local function rawComma(n, sep)
	sep = sep or ","
	local s   = tostring(math.floor(math.abs(n)))
	local res = ""
	local cnt = 0
	for i = #s, 1, -1 do
		cnt = cnt + 1
		res = s:sub(i, i) .. res
		if cnt % 3 == 0 and i ~= 1 then
			res = sep .. res
		end
	end
	return (n < 0 and "-" or "") .. res
end

function Utils.Number.format(n, style, opts)
	opts  = opts  or {}
	style = style or "comma"
	n     = tonumber(n) or 0

	if style == "comma" then
		return rawComma(n, opts.groupSep or ",")

	elseif style == "space" then
		return rawComma(n, " ")

	elseif style == "short" or style == "compact" then
		local tbl  = (style == "compact") and SUFFIX_SHORT or SUFFIX_LONG
		local sign = n < 0 and "-" or ""
		local abs  = math.abs(n)
		local dec  = opts.decimals ~= nil and opts.decimals or 1

		for _, pair in ipairs(tbl) do
			local div, sfx = pair[1], pair[2]
			if abs >= div then
				local val = abs / div
				local fmt = string.format("%." .. dec .. "f", val)
				if not opts.keepDecimal then
					fmt = fmt:gsub("%.0+$", "")
				end
				return sign .. fmt .. sfx
			end
		end
		return sign .. tostring(math.floor(abs))

	elseif style == "currency" then
		local sym   = opts.symbol     or "$"
		local dec   = opts.decimals   ~= nil and opts.decimals or 2
		local gSep  = opts.groupSep   or "."
		local dSep  = opts.decimalSep or ","
		local whole = rawComma(math.floor(math.abs(n)), gSep)
		local frac  = string.format("%0" .. dec .. "d",
			math.floor((math.abs(n) % 1) * (10 ^ dec) + 0.5))
		return (n < 0 and "-" or "") .. sym .. " " .. whole .. dSep .. frac

	elseif style == "percent" then
		local dec = opts.decimals ~= nil and opts.decimals or 1
		return string.format("%." .. dec .. "f", n) .. "%"

	elseif style == "ordinal" then
		local i      = math.floor(math.abs(n))
		local suffix
		local mod100 = i % 100
		if mod100 >= 11 and mod100 <= 13 then
			suffix = "th"
		else
			local mod10 = i % 10
			if     mod10 == 1 then suffix = "st"
			elseif mod10 == 2 then suffix = "nd"
			elseif mod10 == 3 then suffix = "rd"
			else                    suffix = "th"
			end
		end
		return (n < 0 and "-" or "") .. rawComma(i) .. suffix

	elseif style == "raw" then
		return tostring(n)
	end

	return tostring(n)
end

function Utils.Number.comma(n, opts)   return Utils.Number.format(n, "comma",   opts) end
function Utils.Number.short(n, opts)   return Utils.Number.format(n, "short",   opts) end
function Utils.Number.compact(n, opts) return Utils.Number.format(n, "compact", opts) end
function Utils.Number.percent(n, opts) return Utils.Number.format(n, "percent", opts) end
function Utils.Number.ordinal(n)       return Utils.Number.format(n, "ordinal")       end

Utils.Text = {}

function Utils.Text.format(template, data)
	return (template:gsub("{([^}]+)}", function(expr)
		local key, fallback = expr:match("^([^|]+)|(.*)$")
		if not key then key = expr end

		local parts = {}
		for p in key:gmatch("[^%.]+") do parts[#parts + 1] = p end

		local val = data
		for _, p in ipairs(parts) do
			if type(val) ~= "table" then val = nil break end
			val = val[p]
		end

		if val == nil then
			return fallback or ("{" .. expr .. "}")
		end
		return tostring(val)
	end))
end

function Utils.Text.plural(n, singular, plural_)
	return tostring(n) .. " " .. (math.abs(n) == 1 and singular or (plural_ or singular .. "s"))
end

function Utils.Text.truncate(s, maxLen, ellipsis)
	ellipsis = ellipsis or "…"
	if #s <= maxLen then return s end
	return s:sub(1, maxLen - #ellipsis) .. ellipsis
end

Utils.Typewriter = {}

local _typewriters = {}

function Utils.Typewriter.write(label, text, opts)
	opts = opts or {}

	local existing = _typewriters[label]
	if existing then
		existing._active = false
	end

	local handle = {
		_active = true,
		_skip   = false,
		_paused = false,
		_done   = false,
	}
	_typewriters[label] = handle

	handle.skip   = function() handle._skip   = true  end
	handle.cancel = function() handle._active = false; label.Text = "" end
	handle.pause  = function() handle._paused = true   end
	handle.resume = function() handle._paused = false  end
	handle.isDone = function() return handle._done      end

	task.spawn(function()
		local speed = opts.speed or 0.05
		label.Text  = ""

		local chars = {}
		if opts.richText then
			local i = 1
			while i <= #text do
				if text:sub(i, i) == "<" then
					local close = text:find(">", i)
					if close then
						chars[#chars + 1] = { s = text:sub(i, close), visible = false }
						i = close + 1
					else
						chars[#chars + 1] = { s = text:sub(i, i), visible = true }
						i = i + 1
					end
				else
					chars[#chars + 1] = { s = text:sub(i, i), visible = true }
					i = i + 1
				end
			end
		else
			for i = 1, #text do
				chars[#chars + 1] = { s = text:sub(i, i), visible = true }
			end
		end

		local built  = ""
		local visIdx = 0

		for _, ch in ipairs(chars) do
			if not handle._active then return end
			if handle._skip       then break  end

			built = built .. ch.s
			label.Text = built

			if ch.visible then
				visIdx = visIdx + 1

				if opts.sound  then pcall(function() opts.sound:Play() end) end
				if opts.onChar then pcall(opts.onChar, ch.s, visIdx)        end

				local elapsed = 0
				while elapsed < speed do
					if not handle._active then return end
					if handle._skip       then break  end
					while handle._paused  do task.wait(0.05) end
					local dt = task.wait(0.016)
					elapsed = elapsed + dt
				end
			end
		end

		if handle._active then
			label.Text   = text
			handle._done = true
			if opts.onComplete then pcall(opts.onComplete, label) end
			if opts.signal then
				local bus = require(script.Parent.SignalBus)
				bus.emit(opts.signal, label, text)
			end
			Metrics.inc("utils.typewriter.completed", 1)
		end

		_typewriters[label] = nil
	end)

	Metrics.inc("utils.typewriter.started", 1)
	return handle
end

function Utils.Typewriter.cancelAll()
	for _, h in pairs(_typewriters) do
		h._active = false
	end
	_typewriters = {}
end

Utils.Color = {}

function Utils.Color.set(instance, color, opts)
	opts = opts or {}
	local prop = opts.property

	if not prop then
		if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
			prop = "TextColor3"
		elseif instance:IsA("UIStroke") then
			prop = "Color"
		elseif instance:IsA("UIGradient") then
			prop = "Color"
		elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			prop = "ImageColor3"
		else
			prop = "BackgroundColor3"
		end
	end

	if opts.duration and opts.duration > 0 then
		local ti    = TweenInfo.new(opts.duration or 0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		local tween = TweenSvc:Create(instance, ti, { [prop] = color })
		tween:Play()
		return tween
	else
		instance[prop] = color
	end
end

function Utils.Color.lerp(a, b, t)
	return a:Lerp(b, t)
end

function Utils.Color.fromHex(hex)
	hex = hex:gsub("^#", "")
	local r = tonumber(hex:sub(1, 2), 16) / 255
	local g = tonumber(hex:sub(3, 4), 16) / 255
	local b = tonumber(hex:sub(5, 6), 16) / 255
	return Color3.new(r, g, b)
end

function Utils.Color.adjust(color, factor)
	return Color3.new(
		math.clamp(color.R * factor, 0, 1),
		math.clamp(color.G * factor, 0, 1),
		math.clamp(color.B * factor, 0, 1)
	)
end

Utils.Debris = {}

function Utils.Debris.add(instance, lifetime, opts)
	opts = opts or {}

	if opts.tween then
		task.delay(lifetime - (opts.tween.opts and opts.tween.opts.duration or 0.35), function()
			if not instance or not instance.Parent then return end
			local Renderer = require(script.Parent.Renderer)
			local handle = Renderer.animate(instance, opts.tween.goals, opts.tween.opts)
			handle:andThen(function()
				if opts.onExpire and instance.Parent then
					pcall(opts.onExpire, instance)
				end
				if opts.signal then
					local bus = require(script.Parent.SignalBus)
					bus.emit(opts.signal, instance)
				end
				if instance.Parent then instance:Destroy() end
			end)
		end)
	elseif opts.onExpire or opts.signal then
		task.delay(lifetime, function()
			if opts.onExpire and instance and instance.Parent then
				pcall(opts.onExpire, instance)
			end
			if opts.signal then
				local bus = require(script.Parent.SignalBus)
				bus.emit(opts.signal, instance)
			end
			if instance and instance.Parent then instance:Destroy() end
		end)
	else
		Debris:AddItem(instance, lifetime)
	end

	Metrics.inc("utils.debris.scheduled", 1)
end

return Utils
