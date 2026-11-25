--!strict
--[[
	Vertical-aware 3D hit volumes for enemy attacks: projectiles, melee swings and oval explosions.

	An ellipsoid rather than a cylinder is what gives jumping a real defensive role (plans/gdd/
	systems.md): for a flattened dome (verticalRadius < horizontalRadius), the ceiling slopes down
	toward the outer rim, so a player jumping near the edge of an explosion escapes much more
	easily than someone standing dead centre.
]]

local Hitbox = {}

-- True when `target` lies inside the axis-aligned ellipsoid centred at `origin` with horizontal
-- radius `horizontalRadius` (X/Z) and vertical semi-axis `verticalRadius` (Y). Passing equal radii
-- tests an exact 3D sphere.
function Hitbox.inEllipsoid(origin: Vector3, target: Vector3, horizontalRadius: number, verticalRadius: number): boolean
	if horizontalRadius <= 0 or verticalRadius <= 0 then
		return false
	end
	local dx = target.X - origin.X
	local dy = target.Y - origin.Y
	local dz = target.Z - origin.Z
	local horiz = (dx * dx + dz * dz) / (horizontalRadius * horizontalRadius)
	local vert = (dy * dy) / (verticalRadius * verticalRadius)
	return horiz + vert <= 1 + 1e-6
end

--=============================================================================
-- Self test
--=============================================================================

function Hitbox.selfTest()
	-- Ranged projectile at Y = 2 (R = 3, H = 2.6): standing player (Y = 3) is hit; jumping clears.
	local shot = Vector3.new(0, 2, 0)
	assert(Hitbox.inEllipsoid(shot, Vector3.new(0, 3, 0), 3, 2.6), "standing player is hit by Y=2 shot")
	assert(Hitbox.inEllipsoid(shot, Vector3.new(2.5, 3, 0), 3, 2.6), "standing player near shot edge is hit")
	assert(not Hitbox.inEllipsoid(shot, Vector3.new(0, 5.5, 0), 3, 2.6), "jumping player dodges Y=2 shot")

	-- Melee swing from enemy at Y = 2.5 (R = 9.6, H = 4.5): standing is hit; high jump clears.
	local meleeOrigin = Vector3.new(0, 2.5, 0)
	assert(Hitbox.inEllipsoid(meleeOrigin, Vector3.new(6, 3, 0), 9.6, 4.5), "standing player in melee reach is hit")
	assert(not Hitbox.inEllipsoid(meleeOrigin, Vector3.new(6, 8, 0), 9.6, 4.5), "jumping over melee strike dodges it")

	-- Oval explosion at Y = 1.75 (R = 10, H = 7): jumping near the outer rim escapes the dome
	-- while the same low jump at dead centre is still caught inside it.
	local blastOrigin = Vector3.new(0, 1.75, 0)
	assert(Hitbox.inEllipsoid(blastOrigin, Vector3.new(8.5, 3, 0), 10, 7), "standing near blast rim is hit")
	assert(
		not Hitbox.inEllipsoid(blastOrigin, Vector3.new(8.5, 5.8, 0), 10, 7),
		"jumping near blast rim escapes the oval dome"
	)
	assert(
		Hitbox.inEllipsoid(blastOrigin, Vector3.new(0, 5.8, 0), 10, 7),
		"same low jump at dead centre is still inside the dome"
	)
	assert(not Hitbox.inEllipsoid(blastOrigin, Vector3.new(0, 9.5, 0), 10, 7), "high jump clears the top of the dome")

	-- Boundary and degenerate inputs.
	assert(Hitbox.inEllipsoid(Vector3.zero, Vector3.new(10, 0, 0), 10, 7), "exact horizontal edge counts as hit")
	assert(Hitbox.inEllipsoid(Vector3.zero, Vector3.new(0, 7, 0), 10, 7), "exact vertical apex counts as hit")
	assert(not Hitbox.inEllipsoid(Vector3.zero, Vector3.zero, 0, 7), "zero horizontal radius never hits")
	assert(not Hitbox.inEllipsoid(Vector3.zero, Vector3.zero, 10, -1), "negative vertical radius never hits")
end

return Hitbox
