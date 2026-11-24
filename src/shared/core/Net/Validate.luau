--[[
	Pure argument guards for the net contract. Each is `(value) -> boolean` and refuses the
	whole family of nonsense a client can put on the wire: wrong types, NaN, infinities.
	Anything finer than a type — a range, a catalogue id — belongs to the handler that knows
	what the value means.
]]

local Validate = {}

function Validate.any(_value: any): boolean
	return true
end

function Validate.string(value: any): boolean
	return type(value) == "string"
end

function Validate.boolean(value: any): boolean
	return type(value) == "boolean"
end

-- Finite and real: NaN is the classic smuggled value, and it survives most arithmetic.
function Validate.number(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Validate.vector3(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	-- Per component, through the same guard a bare number gets. Comparing the vector to
	-- itself catches NaN but passes an infinity, which then survives `.Unit` as a NaN and is
	-- broadcast to every client as a garbage tracer.
	return Validate.number(value.X) and Validate.number(value.Y) and Validate.number(value.Z)
end

-- For a handler validating a Color3 inside a payload the contract only checked was a table.
-- A contract entry can name this directly too — it is here as a positional guard like the rest.
function Validate.color3(value: any): boolean
	return typeof(value) == "Color3"
end

function Validate.table(value: any): boolean
	return type(value) == "table"
end

return Validate
