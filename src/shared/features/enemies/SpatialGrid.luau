--!strict
--[[
	Uniform 2D spatial hash grid for local enemy queries (explosion splash and crowd separation).

	Enemies live on a flat room floor, so hashing (X, Z) into fixed-size cells lets an explosion
	or separation step inspect only the few cells overlapping its radius instead of scanning every
	enemy or world object. Numeric cell keys avoid per-frame string allocations, and `move` is a
	no-op whenever an enemy stays in the same cell.
]]

local SpatialGrid = {}

-- Bias/stride pack signed 16-bit cell coordinates into one exact Luau double without string keys.
local KEY_BIAS = 32768
local KEY_STRIDE = 65536

export type Grid<T> = {
	cellSize: number,
	invCellSize: number,
	cells: { [number]: { [T]: boolean } },
	itemCell: { [T]: number },
	insert: (self: Grid<T>, item: T, x: number, z: number) -> (),
	move: (self: Grid<T>, item: T, x: number, z: number) -> (),
	remove: (self: Grid<T>, item: T) -> (),
	queryRadius: (self: Grid<T>, x: number, z: number, radius: number, out: { T }?) -> { T },
	clear: (self: Grid<T>) -> (),
}

local function cellKey(cx: number, cz: number): number
	return (cx + KEY_BIAS) * KEY_STRIDE + (cz + KEY_BIAS)
end

local function removeFromCell<T>(grid: Grid<T>, item: T, key: number)
	local bucket = grid.cells[key]
	if not bucket then
		return
	end
	bucket[item] = nil
	if next(bucket) == nil then
		grid.cells[key] = nil
	end
end

local function addToCell<T>(grid: Grid<T>, item: T, key: number)
	local bucket = grid.cells[key]
	if not bucket then
		bucket = {}
		grid.cells[key] = bucket
	end
	bucket[item] = true
	grid.itemCell[item] = key
end

function SpatialGrid.new<T>(cellSize: number): Grid<T>
	assert(cellSize > 0, "SpatialGrid cellSize must be positive")

	local grid: Grid<T> = {
		cellSize = cellSize,
		invCellSize = 1 / cellSize,
		cells = {},
		itemCell = {},
		insert = nil :: any,
		move = nil :: any,
		remove = nil :: any,
		queryRadius = nil :: any,
		clear = nil :: any,
	}

	function grid:insert(item: T, x: number, z: number)
		local existing = self.itemCell[item]
		local key = cellKey(math.floor(x * self.invCellSize), math.floor(z * self.invCellSize))
		if existing == key then
			return
		end
		if existing ~= nil then
			removeFromCell(self, item, existing)
		end
		addToCell(self, item, key)
	end

	function grid:move(item: T, x: number, z: number)
		local key = cellKey(math.floor(x * self.invCellSize), math.floor(z * self.invCellSize))
		local existing = self.itemCell[item]
		if existing == key then
			return
		end
		if existing ~= nil then
			removeFromCell(self, item, existing)
		end
		addToCell(self, item, key)
	end

	function grid:remove(item: T)
		local existing = self.itemCell[item]
		if existing == nil then
			return
		end
		removeFromCell(self, item, existing)
		self.itemCell[item] = nil
	end

	-- Returns every item sitting in cells that overlap the square [x - r, x + r] x [z - r, z + r].
	-- Callers still run their exact distance/ellipsoid check on the small candidate list returned.
	function grid:queryRadius(x: number, z: number, radius: number, out: { T }?): { T }
		local results: { T } = if out then out else {}
		if out then
			table.clear(results)
		end
		if radius < 0 then
			return results
		end
		local inv = self.invCellSize
		local minCx = math.floor((x - radius) * inv)
		local maxCx = math.floor((x + radius) * inv)
		local minCz = math.floor((z - radius) * inv)
		local maxCz = math.floor((z + radius) * inv)
		local cells = self.cells
		for cx = minCx, maxCx do
			local rowBase = (cx + KEY_BIAS) * KEY_STRIDE
			for cz = minCz, maxCz do
				local bucket = cells[rowBase + (cz + KEY_BIAS)]
				if bucket then
					for item in pairs(bucket) do
						table.insert(results, item)
					end
				end
			end
		end
		return results
	end

	function grid:clear()
		table.clear(self.cells)
		table.clear(self.itemCell)
	end

	return grid
end

--=============================================================================
-- Self test
--=============================================================================

function SpatialGrid.selfTest()
	local grid = SpatialGrid.new(12)
	local a = { id = "a" }
	local b = { id = "b" }
	local far = { id = "far" }

	grid:insert(a, 1, 1)
	grid:insert(b, -3, 4)
	grid:insert(far, 100, -100)

	local function contains(list: { any }, target: any): boolean
		for _, item in ipairs(list) do
			if item == target then
				return true
			end
		end
		return false
	end

	local near = grid:queryRadius(0, 0, 10)
	assert(#near == 2 and contains(near, a) and contains(near, b), "local query returns only nearby cell items")
	assert(not contains(near, far), "distant items are never visited or returned")

	-- Moving within the same cell keeps membership; moving across cells updates buckets cleanly.
	grid:move(a, 5, 5)
	assert(contains(grid:queryRadius(0, 0, 10), a), "moving inside same cell preserves item")

	grid:move(a, 98, -98)
	local nearOrigin = grid:queryRadius(0, 0, 10)
	assert(#nearOrigin == 1 and contains(nearOrigin, b), "moved item leaves old cell")
	local nearFar = grid:queryRadius(100, -100, 10)
	assert(#nearFar == 2 and contains(nearFar, a) and contains(nearFar, far), "moved item enters new cell")

	-- Reusable output buffer is cleared before writing.
	local scratch = {}
	grid:queryRadius(100, -100, 10, scratch)
	assert(#scratch == 2, "reusable output buffer gets populated")
	grid:queryRadius(0, 0, 10, scratch)
	assert(#scratch == 1 and scratch[1] == b, "reusable output buffer is cleared on reuse")

	-- Removing deletes item and frees empty cells.
	grid:remove(b)
	assert(#grid:queryRadius(0, 0, 10) == 0, "removed item is no longer returned")
	assert(next(grid.cells) ~= nil, "other cells remain populated")

	grid:clear()
	assert(next(grid.cells) == nil and next(grid.itemCell) == nil, "clear empties all cells and tracking")
end

return SpatialGrid
