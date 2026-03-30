-- Memo: wrap a render function so it only re-renders when props change.
-- Inspired by React.memo and React.PureComponent.
--
-- Usage:
--   local MyComp = Memo.wrap(function(props, api)
--       return { [label] = { Text = props.name } }
--   end)
--
--   local comp = Component.new(frame, MyComp, {
--       initialState = { name = "Alice" }
--   })
--
-- The wrapped renderFn receives (props, api) and only runs when any
-- key in `props` has changed since the last render (shallow compare).
-- A custom `compare(oldProps, newProps) -> bool` can be provided.

local Logger  = require(script.Parent.Logger)
local Metrics = require(script.Parent.Metrics)

local log = Logger.child("Memo")

local Memo = {}

local function shallowEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

-- Wrap a renderFn so it bails out when props haven't changed.
-- `compare(old, new) -> bool`  defaults to shallow equality.
function Memo.wrap(renderFn, compare)
	assert(type(renderFn) == "function", "Memo.wrap: renderFn must be a function")
	compare = compare or shallowEqual

	local lastProps = nil
	local lastResult = nil

	return function(props, api)
		if lastProps ~= nil and compare(lastProps, props) then
			Metrics.inc("memo.bailouts", 1)
			log.trace("Memo bailed out (props unchanged)")
			return lastResult
		end

		lastProps  = props
		lastResult = renderFn(props, api)
		Metrics.inc("memo.renders", 1)
		return lastResult
	end
end

-- forwardRef: lets a parent access a child component handle via ref.
-- The renderFn receives (props, ref) where ref is a { current } table
-- that the child can write a handle into.
--
-- Usage:
--   local MyInput = Memo.forwardRef(function(props, ref)
--       if ref then ref.current = { focus = function() ... end } end
--       return { [textBox] = { Text = props.value } }
--   end)
--
--   local inputRef = { current = nil }
--   local comp = Component.new(frame, MyInput, {
--       initialState = { value = "" },
--       ref = inputRef,
--   })
--   -- inputRef.current.focus() -- call methods on the child
function Memo.forwardRef(renderFn)
	assert(type(renderFn) == "function", "Memo.forwardRef: renderFn must be a function")

	return {
		_isForwardRef = true,
		render        = renderFn,
	}
end

-- Check if a value is a forwardRef-wrapped component.
function Memo.isForwardRef(value)
	return type(value) == "table" and value._isForwardRef == true
end

return Memo
