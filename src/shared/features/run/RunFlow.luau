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
	room: number,
	roomCount: number,
	roomsCleared: number,
	kills: number,
	startedAt: number,
	endedAt: number?,
}

export type Summary = {
	victory: boolean,
	roomsCleared: number,
	roomCount: number,
	kills: number,
	elapsedSeconds: number,
}

function RunFlow.initial(roomCount: number?): State
	local count = math.max(roomCount or Config.ROOMS_PER_FLOOR or 5, 1)
	return {
		status = "preparing",
		floor = 1,
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

-- Called when every wave in the current room is defeated. Rooms 1..(N-1) open the Blast Door
-- (`transition`); defeating the final room (Boss Oh in Room 5) finishes the floor (`victory`).
function RunFlow.onRoomCleared(state: State, now: number): State
	if state.status ~= "fighting" then
		return state
	end
	local nextState = table.clone(state)
	nextState.roomsCleared = math.max(nextState.roomsCleared, state.room)
	if state.room >= state.roomCount then
		nextState.status = "victory"
		nextState.endedAt = now
	else
		nextState.status = "transition"
	end
	return nextState
end

-- Called when the player steps through the opened North Blast Door during `transition`.
function RunFlow.advanceRoom(state: State): State
	if state.status ~= "transition" or state.room >= state.roomCount then
		return state
	end
	local nextState = table.clone(state)
	nextState.room += 1
	nextState.status = "fighting"
	return nextState
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

function RunFlow.summary(state: State, now: number): Summary
	local endTime = state.endedAt or now
	local elapsed = if state.startedAt > 0 then math.max(endTime - state.startedAt, 0) else 0
	return {
		victory = state.status == "victory",
		roomsCleared = state.roomsCleared,
		roomCount = state.roomCount,
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

	-- Full 5-room victory path.
	local s = RunFlow.initial(5)
	assert(is(s.status, "preparing") and s.room == 1 and s.roomCount == 5, "initial state is preparing room 1/5")

	s = RunFlow.start(s, 10)
	assert(is(s.status, "fighting") and s.startedAt == 10, "start enters fighting")

	for r = 1, 4 do
		s = RunFlow.recordKill(s)
		s = RunFlow.onRoomCleared(s, 10 + r * 20)
		assert(is(s.status, "transition") and s.roomsCleared == r, `clearing room {r} opens transition door`)
		s = RunFlow.advanceRoom(s)
		assert(is(s.status, "fighting") and s.room == r + 1, `advancing enters room {r + 1}`)
	end

	-- Room 5 boss kill -> victory!
	s = RunFlow.recordKill(s)
	s = RunFlow.onRoomCleared(s, 150)
	assert(is(s.status, "victory") and s.roomsCleared == 5 and s.kills == 5, "clearing room 5 wins the floor")
	local sum = RunFlow.summary(s, 200)
	assert(sum.victory and sum.elapsedSeconds == 140 and sum.kills == 5 and sum.roomsCleared == 5, "victory summary freezes elapsed time")

	-- Defeat on Room 2 + clean retry reset.
	local d = RunFlow.start(RunFlow.initial(5), 50)
	d = RunFlow.recordKill(d)
	d = RunFlow.onRoomCleared(d, 70)
	d = RunFlow.advanceRoom(d)
	d = RunFlow.onWipe(d, 95)
	assert(is(d.status, "defeat") and d.roomsCleared == 1, "wipe records defeat with rooms cleared so far")
	local dSum = RunFlow.summary(d, 120)
	assert(not dSum.victory and dSum.elapsedSeconds == 45 and dSum.roomsCleared == 1, "defeat summary freezes time")

	local retry = RunFlow.start(RunFlow.initial(5), 130)
	assert(is(retry.status, "fighting") and retry.room == 1 and retry.kills == 0 and retry.roomsCleared == 0, "retry resets cleanly")

	-- Doorway trigger geometry check.
	assert(RunFlow.inDoorZone(Vector3.new(0, 3, -63)), "standing in North Blast Door triggers advance")
	assert(not RunFlow.inDoorZone(Vector3.new(0, 3, -30)), "center arena does not trigger door")
	assert(not RunFlow.inDoorZone(Vector3.new(30, 3, -63)), "far NE corner outside door width does not trigger")
end

return RunFlow
