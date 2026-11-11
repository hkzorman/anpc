-- Walk to a position (resolving a walkable accessing position first).
-- args: pos (required), force_accessing_node, access_node_search_method,
-- door_close ("immediate" default | "pause" | "none").
npc.proc.register_program("npc:walk_to_pos", {
	{name = "npc:var:set", args = {key = "has_reached_pos", value = "false", storage_type = "local"}, srcmap = 16},
	{key = "@local.end_pos", name = "npc:env:node:get_accessing_pos", args = {pos = "@args.pos", force = "@args.force_accessing_node", search_method = "@args.access_node_search_method"}, srcmap = 17},
		{key = "@local.has_reached_pos", name = "npc:move:walk_to_pos", args = {target_pos = "@local.end_pos", original_target_pos = "@args.pos", check_end_pos_walkable = false, door_close = "@args.door_close"}, srcmap = 19},
		{name = "npc:jump_if", args = {expr = {left = "@local.has_reached_pos", op = "==", right = nil}, offset = true, negate = true, pos = 1}, srcmap = 20}, -- IF [2],
			{name = "npc:break", srcmap = 21},
	{name = "npc:jump_if", args = {expr = {left = "@local.has_reached_pos", op = "==", right = false}, negate = false, offset = true, pos = -4}, srcmap = 18}, -- WHILE end [6]
})

-- Follow a player or NPC continuously: stand N cells behind
-- (default) or ahead of the leader. The goal cell is the first
-- standable slot for the leader's *predicted* cell (npc:nav:
-- follow_goal) and is re-tracked per tick while the walk is active
-- (npc.nav.follow_track: the remaining path is truncated or a small
-- A* runs only when the predicted cell changes; unreachable goals
-- fall back to the slot ladder, then direct steering). The walk
-- (npc:move:walk_to_cell_ll) uses block-middle walking with cell
-- arrival, so the NPC rests at the middle of the goal cell.
--
-- args: object (required, the leader's name - players resolve by
-- name with no range limit; a tracked nearby object of that name is
-- the NPC-leader fallback), follow_mode ("behind" default or
-- "ahead"), follow_distance (cells, default 2), lead (predictive
-- lead in seconds, default 0 - the goal aims at the leader's
-- position lead seconds into the future along its velocity; 0 = the
-- leader's current cell, a positive lead can push the goal onto the
-- leader's own cell at small distances and make the NPC bump into a
-- walking leader),
-- door_close ("immediate" default | "pause" | "none", passed through
-- to the walk), speed (m/s, default: the leader's walk speed minus
-- 0.25 m/s - the engine setting movement_speed_walk scaled by the
-- leader's physics overrides, not a Minetest-Game constant; an
-- explicit value overrides it), catch_up (cells, default 2 x
-- follow_distance: the follower only resumes a walk - and only
-- switches to the catch-up speed - once the gap to the leader
-- reaches this distance, so a leader moving a couple of steps around
-- a place does not drag the NPC; the catch-up speed (the speed plus
-- 0.5 m/s: the leader's walk speed plus 0.25 m/s on the default)
-- stays in effect until the gap closes back to follow_distance).
--
-- The 0.05 s proc interval keeps the pass cadence fast: each pass is
-- 4 cheap instructions, and while the walk (ll task) is active the
-- instructions are paused anyway, so the cost is only the ~20 tiny
-- passes/s of follow_goal + jump_if between walks.
npc.proc.register_program("npc:follow", {
	-- Initial pass interval: one pass per cell the leader crosses
	-- (1 / leader's walk speed, 0.25 s at the 4 m/s default). Refined
	-- per-leader on every pass by npc.nav.follow_goal (clamped
	-- 0.1..0.5 s).
	{name = "npc:set_proc_interval", args = {value = 0.25}, srcmap = 35},
	{key = "@local.follow_goal", name = "npc:nav:follow_goal", args = {name = "@args.object", object = "@objs.get[@args.object]", mode = "@args.follow_mode", distance = "@args.follow_distance", lead = "@args.lead", catch_up = "@args.catch_up"}, srcmap = 36},
	{name = "npc:jump_if", args = {expr = {left = "@local.follow_goal", op = "~=", right = nil}, offset = true, negate = true, pos = 2}, srcmap = 37}, -- IF [3],
		{name = "npc:move:walk_to_cell_ll", args = {target_pos = "@local.follow_goal", door_close = "@args.door_close", speed = "@args.speed"}, srcmap = 38},
	{name = "npc:jump", args = {offset = true, pos = 1}, srcmap = 39}, -- ELSE [5],
		{name = "npc:move:stand", args = {}, srcmap = 40}
})

