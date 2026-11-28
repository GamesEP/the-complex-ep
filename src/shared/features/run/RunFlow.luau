--!strict
--[[
	Pure single-floor Run state machine (plans/gdd/loop.md, plans/roadmap.md VS-10).

	Tracks floor/room progression (`1 -> 2 -> 3 -> 4 -> 5 -> victory`), wipe detection (`defeat`),
	run telemetry (rooms cleared, elapsed seconds, kills), and clean resets on retry. Pure so
	`make test` verifies every branch offline without Studio.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local RunFlow = {}

export type RunStatus = "preparing" | "fighting" | "transition" | "victory" | "defeat"

export type State = {
	status: RunStatus,
	floor: number,
	floorCount: number,
	room: number,
	roomCount: number,
	roomsCleared: number,
	kills: number,
	startedAt: number,
	endedAt: number?,
}

export type Summary = {
	victory: boolean,
	floor: number,
	floorCount: number,
	roomsCleared: number,
	roomCount: number,
	totalRoomCount: number,
	kills: number,
	elapsedSeconds: number,
}

function RunFlow.initial(roomCount: number?, floorCount: number?): State
	local count = math.max(roomCount or Config.ROOMS_PER_FLOOR or 5, 1)
	local floors = math.max(floorCount or Config.FLOORS_PER_RUN or 5, 1)
	return {
		status = "preparing",
		floor = 1,
		floorCount = floors,
		room = 1,
		roomCount = count,
		roomsCleared = 0,
		kills = 0,
		startedAt = 0,
		endedAt = nil,
	}
end

function RunFlow.start(state: State, now: number): State
	local nextState = table.clone(state)
	nextState.status = "fighting"
	nextState.floor = 1
	nextState.room = 1
	nextState.roomsCleared = 0
	nextState.kills = 0
	nextState.startedAt = now
	nextState.endedAt = nil
	return nextState
end

function RunFlow.recordKill(state: State): State
	if state.status ~= "fighting" then
		return state
	end
	local nextState = table.clone(state)
	nextState.kills += 1
	return nextState
end

-- True when the player just cleared the final room of a non-final floor and stepping through the
-- North Blast Door will advance to Floor N+1 (triggering floor-exit upgrade queue auto-resolve).
function RunFlow.isFloorBoundary(state: State): boolean
	return state.status == "transition" and state.room >= state.roomCount and state.floor < state.floorCount
end

-- Called when every wave in the current room is defeated. Non-final rooms/floors open the Blast
-- Door (`transition`); defeating the final room of the final floor completes the run (`victory`).
function RunFlow.onRoomCleared(state: State, now: number): State
	if state.status ~= "fighting" then
		return state
	end
	local nextState = table.clone(state)
	nextState.roomsCleared += 1
	if state.room >= state.roomCount and state.floor >= state.floorCount then
		nextState.status = "victory"
		nextState.endedAt = now
	else
		nextState.status = "transition"
	end
	return nextState
end

-- Called when the player steps through the opened North Blast Door during `transition`.
function RunFlow.advanceRoom(state: State): State
	if state.status ~= "transition" then
		return state
	end
	local nextState = table.clone(state)
	if state.room < state.roomCount then
		nextState.room += 1
		nextState.status = "fighting"
		return nextState
	elseif state.floor < state.floorCount then
		nextState.floor += 1
		nextState.room = 1
		nextState.status = "fighting"
		return nextState
	end
	return state
end

function RunFlow.onWipe(state: State, now: number): State
	if state.status ~= "fighting" and state.status ~= "transition" then
		return state
	end
	local nextState = table.clone(state)
	nextState.status = "defeat"
	nextState.endedAt = now
	return nextState
end

-- Admin debug transition: jump directly to any room (`1..roomCount`) in `fighting` state.
function RunFlow.jumpToRoom(state: State, roomIndex: number, now: number): State
	local clamped = math.clamp(math.floor(roomIndex), 1, state.roomCount)
	local nextState = table.clone(state)
	nextState.status = "fighting"
	nextState.room = clamped
	nextState.roomsCleared = math.max(clamped - 1, 0)
	if nextState.startedAt <= 0 then
		nextState.startedAt = now
	end
	nextState.endedAt = nil
	return nextState
end

-- Admin debug transition: force `preparing`, `victory`, or `defeat` regardless of current phase.
function RunFlow.forceStatus(state: State, status: "preparing" | "victory" | "defeat", now: number): State
	if status == "preparing" then
		return RunFlow.initial(state.roomCount)
	end
	local nextState = table.clone(state)
	if nextState.startedAt <= 0 then
		nextState.startedAt = now
	end
	nextState.status = status
	nextState.endedAt = now
	if status == "victory" then
		nextState.room = state.roomCount
		nextState.roomsCleared = state.roomCount
	end
	return nextState
end

function RunFlow.summary(state: State, now: number): Summary
	local endTime = state.endedAt or now
	local elapsed = if state.startedAt > 0 then math.max(endTime - state.startedAt, 0) else 0
	return {
		victory = state.status == "victory",
		floor = state.floor,
		floorCount = state.floorCount,
		roomsCleared = state.roomsCleared,
		roomCount = state.roomCount,
		totalRoomCount = state.roomCount * state.floorCount,
		kills = state.kills,
		elapsedSeconds = elapsed,
	}
end

function RunFlow.inDoorZone(pos: Vector3): boolean
	return pos.Z <= Config.BLAST_DOOR_TRIGGER_Z and math.abs(pos.X) <= Config.BLAST_DOOR_TRIGGER_HALF_X
end

--=============================================================================
-- Self test
--=============================================================================

function RunFlow.selfTest()
	local function is(a: any, b: any): boolean
		return a == b
	end

	-- Single-floor victory path (5 rooms, 1 floor).
	local s = RunFlow.initial(5, 1)
	assert(is(s.status, "preparing") and s.room == 1 and s.roomCount == 5 and s.floorCount == 1, "initial state is preparing room 1/5")

	s = RunFlow.start(s, 10)
	assert(is(s.status, "fighting") and s.startedAt == 10, "start enters fighting")

	for r = 1, 4 do
		s = RunFlow.recordKill(s)
		s = RunFlow.onRoomCleared(s, 10 + r * 20)
		assert(is(s.status, "transition") and s.roomsCleared == r and not RunFlow.isFloorBoundary(s), `clearing room {r} opens transition door`)
		s = RunFlow.advanceRoom(s)
		assert(is(s.status, "fighting") and s.room == r + 1, `advancing enters room {r + 1}`)
	end

	-- Room 5 boss kill -> victory!
	s = RunFlow.recordKill(s)
	s = RunFlow.onRoomCleared(s, 150)
	assert(is(s.status, "victory") and s.roomsCleared == 5 and s.kills == 5, "clearing room 5 wins the floor")
	local sum = RunFlow.summary(s, 200)
	assert(sum.victory and sum.elapsedSeconds == 140 and sum.kills == 5 and sum.roomsCleared == 5, "victory summary freezes elapsed time")

	-- Full 5-floor (25-room) victory path with floor boundaries.
	local mf = RunFlow.start(RunFlow.initial(5, 5), 0)
	for f = 1, 5 do
		for r = 1, 5 do
			mf = RunFlow.recordKill(mf)
			mf = RunFlow.onRoomCleared(mf, (f - 1) * 100 + r * 10)
			if f < 5 or r < 5 then
				assert(is(mf.status, "transition"), `Floor {f} Room {r} opens transition`)
				assert(RunFlow.isFloorBoundary(mf) == (r == 5), `Floor {f} Room {r} boundary flag exact`)
				mf = RunFlow.advanceRoom(mf)
			else
				assert(is(mf.status, "victory") and mf.roomsCleared == 25, "Floor 5 Room 5 completes 25-room run")
			end
		end
	end

	-- Defeat on Room 2 + clean retry reset.
	local d = RunFlow.start(RunFlow.initial(5, 5), 50)
	d = RunFlow.recordKill(d)
	d = RunFlow.onRoomCleared(d, 70)
	d = RunFlow.advanceRoom(d)
	d = RunFlow.onWipe(d, 95)
	assert(is(d.status, "defeat") and d.roomsCleared == 1, "wipe records defeat with rooms cleared so far")
	local dSum = RunFlow.summary(d, 120)
	assert(not dSum.victory and dSum.elapsedSeconds == 45 and dSum.roomsCleared == 1 and dSum.totalRoomCount == 25, "defeat summary freezes time")

	local retry = RunFlow.start(RunFlow.initial(5, 5), 130)
	assert(is(retry.status, "fighting") and retry.floor == 1 and retry.room == 1 and retry.kills == 0 and retry.roomsCleared == 0, "retry resets cleanly")

	-- Doorway trigger geometry check.
	assert(RunFlow.inDoorZone(Vector3.new(0, 3, -63)), "standing in North Blast Door triggers advance")
	assert(not RunFlow.inDoorZone(Vector3.new(0, 3, -30)), "center arena does not trigger door")
	assert(not RunFlow.inDoorZone(Vector3.new(30, 3, -63)), "far NE corner outside door width does not trigger")

	-- Admin debug jump & force-status transitions.
	local jumped = RunFlow.jumpToRoom(RunFlow.initial(5), 5, 25)
	assert(is(jumped.status, "fighting") and jumped.room == 5 and jumped.roomsCleared == 4 and jumped.startedAt == 25, "jumpToRoom enters fighting at target room")
	local forcedWin = RunFlow.forceStatus(jumped, "victory", 40)
	assert(is(forcedWin.status, "victory") and forcedWin.roomsCleared == 5 and forcedWin.endedAt == 40, "forceStatus victory completes floor")
	local forcedLoss = RunFlow.forceStatus(jumped, "defeat", 45)
	assert(is(forcedLoss.status, "defeat") and forcedLoss.endedAt == 45, "forceStatus defeat ends run")
	local forcedPrep = RunFlow.forceStatus(forcedLoss, "preparing", 50)
	assert(is(forcedPrep.status, "preparing") and forcedPrep.room == 1 and forcedPrep.kills == 0, "forceStatus preparing resets cleanly")
end

return RunFlow
