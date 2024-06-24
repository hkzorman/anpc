npc.proc.register_program("npc:walk_to_pos", {
	{name = "npc:var:set", args = {key = "has_reached_pos", value = "false", storage_type = "local"}, srcmap = 16},
	{key = "@local.end_pos", name = "npc:env:node:get_accessing_pos", args = {pos = "@args.pos", force = "@args.force_accessing_node", search_method = "@args.access_node_search_method"}, srcmap = 17},
		{key = "@local.has_reached_pos", name = "npc:move:walk_to_pos", args = {target_pos = "@local.end_pos", original_target_pos = "@args.pos", check_end_pos_walkable = false}, srcmap = 19},
		{name = "npc:jump_if", args = {expr = {left = "@local.has_reached_pos", op = "==", right = nil}, offset = true, negate = true, pos = 1}, srcmap = 20}, -- IF [2],
			{name = "npc:break", srcmap = 21},
	{name = "npc:jump_if", args = {expr = {left = "@local.has_reached_pos", op = "==", right = false}, negate = false, offset = true, pos = -4}, srcmap = 18}, -- WHILE end [6]
})

npc.proc.register_program("npc:follow", {
	{name = "npc:set_proc_interval", args = {value = 0.25}, srcmap = 35},
	{name = "npc:var:set", args = {key = "reach", value = "@args.reach_distance", storage_type = "local"}, srcmap = 36},
	{name = "npc:jump_if", args = {expr = {left = "@args.reach_distance", op = "==", right = nil}, offset = true, negate = true, pos = 1}, srcmap = 37}, -- IF [3],
		{name = "npc:var:set", args = {key = "reach", value = 2, storage_type = "local"}, srcmap = 38},
	{key = "@local.actual_pos", name = "npc:obj:get_pos", args = {object = "@objs.get[@args.object]"}, srcmap = 41},
	{key = "@local.target_pos", name = "npc:obj:get_pos", args = {object = "@objs.get[@args.object]", round = true}, srcmap = 42},
	{name = "npc:jump_if", args = {expr = {left = "@local.target_pos", op = "~=", right = nil}, offset = true, negate = true, pos = 6}, srcmap = 49}, -- IF [7],
		{key = "@local._inline_npc:distance_to0", name = "npc:distance_to", args = {pos = "@local.target_pos"}},
		{name = "npc:jump_if", args = {expr = {left = "@local._inline_npc:distance_to0", op = "<", right = "@local.reach"}, offset = true, negate = true, pos = 3}, srcmap = 51}, -- IF [2],
			{name = "npc:move:stand", args = {}, srcmap = 52},
			{name = "npc:move:rotate", args = {target_pos = "@local.actual_pos"}, srcmap = 53},
		{name = "npc:jump", args = {offset = true, pos = 1}, srcmap = 55}, -- ELSE [5],
			{name = "npc:move:walk_to_pos_ll", args = {target = "@objs.get[@args.object]", original_target_pos = "@local.target_pos", check_end_pos_walkable = false, access_node_search_method = "prefer_closest"}, srcmap = 56}
})

