npc.proc.register_program("torcherer:init", {
	{name = "npc:var:set", args = {key = "hunger", value = 0, storage_type = "global"}, srcmap = 4},
	{name = "npc:var:set", args = {key = "name", value = "Torcherer", storage_type = "global"}, srcmap = 5},
	{name = "npc:execute", args = {name = "torcherer:find_bed"}, srcmap = 6}
})

npc.proc.register_program("torcherer:find_bed", {
	{key = "@local.bed_pos", name = "npc:env:node:find", args = {matches = "single", radius = 35, nodenames = {"beds:bed_bottom"}, nodenames = {"beds:bed_bottom"}}, srcmap = 10},
	{name = "npc:jump_if", args = {expr = {left = "@local.bed_pos.length", op = ">", right = 0}, offset = true, negate = true, pos = 2}, srcmap = 11}, -- IF [2],
		{name = "npc:env:node:set_owned", args = {value = true, pos = "@local.bed_pos[1]", categories = "beds"}, srcmap = 12},
		{name = "npc:env:node:set_metadata", args = {pos = "@local.bed_pos[1]", meta = "Torcherer's bed"}, srcmap = 13}
})

npc.proc.register_program("torcherer:idle", {
	{name = "npc:move:stand", args = {}, srcmap = 18},
	{name = "npc:jump_if", args = {expr = {left = "@time", op = ">", right = 16000}, offset = true, negate = true, pos = 1}, srcmap = 20}, -- IF [2],
		{name = "npc:execute", args = {name = "torcherer:turn_on_torches"}, srcmap = 21},
	{name = "npc:jump_if", args = {expr = {left = "@time", op = ">", right = 22000}, offset = true, negate = true, pos = 1}, srcmap = 24}, -- IF [4],
		{name = "npc:execute", args = {name = "torcherer:sleep"}, srcmap = 25},
	{name = "npc:var:set", args = {key = "hunger", value = {left = "@global.hunger", op = "+", right = 2}, storage_type = "global"}, srcmap = 28},
	{name = "npc:jump_if", args = {expr = {left = "@global.hunger", op = ">", right = 100}, offset = true, negate = true, pos = 0}, srcmap = 29}, -- IF [7],
	{name = "npc:var:set", args = {key = "should_ack_obj", value = "false", storage_type = "local"}, srcmap = 41},
	{name = "npc:var:set", args = {key = "for_index", value = 1, storage_type = "local"}, srcmap = 42}, -- FOR start [9],
		{key = "@local._inline_npc:random0", name = "npc:random", args = {start = 1, ["end"] = 100}},
		{name = "npc:jump_if", args = {expr = {left = "@local._inline_npc:random0", op = ">=", right = {left = 100, op = "-", right = "@args.ack_nearby_objs_chance"}}, offset = true, negate = true, pos = 4}, srcmap = 43}, -- IF [2],
			{name = "npc:var:set", args = {key = "obj", value = "@objs.get[@local.for_index]", storage_type = "local"}, srcmap = 44},
			{name = "npc:jump_if", args = {expr = {left = "@local.obj", op = "~=", right = nil}, offset = true, negate = true, pos = 2}, srcmap = 45}, -- IF [2],
				{key = "@local.dist", name = "npc:distance_to", args = {object = "@local.obj"}, srcmap = 46},
				{name = "npc:var:set", args = {key = "should_ack_obj", value = {left = {left = "@local.dist", op = "<=", right = "@args.ack_nearby_objs_dist"}, op = "&&", right = {left = "@local.dist", op = ">", right = 0}}, storage_type = "local"}, srcmap = 47},
		{name = "npc:jump_if", args = {expr = {left = "@local.should_ack_obj", op = "==", right = true}, offset = true, negate = true, pos = 9}, srcmap = 51}, -- IF [7],
			{key = "@local.ack_times", name = "npc:random", args = {start = 15, ["end"] = 30}, srcmap = 52},
			{name = "npc:var:set", args = {key = "for_index", value = 1, storage_type = "local"}, srcmap = 53}, -- FOR start [2],
				{key = "@local.obj_pos", name = "npc:obj:get_pos", args = {object = "@local.obj"}, srcmap = 54},
				{name = "npc:move:rotate", args = {target_pos = "@local.obj_pos"}, srcmap = 55},
			{name = "npc:var:set", args = {key = "for_index", value = {left = "@local.for_index", op = "+", right = 1}, storage_type = "local"}, srcmap = 53},
			{name = "npc:jump_if", args = {expr = {left = "@local.for_index", op = "<=", right = "@local.ack_times"}, negate = false, offset = true, pos = -4}, srcmap = 53}, -- FOR end [6],
			{name = "npc:var:set", args = {key = "hunger", value = {left = "@global.hunger", op = "+", right = {left = "@local.ack_times", op = "*", right = 2}}, storage_type = "global"}, srcmap = 57},
			{name = "npc:break", srcmap = 58},
		{name = "npc:jump", args = {offset = true, pos = 3}, srcmap = 59}, -- ELSE [16],
			{key = "@local._inline_npc:random0", name = "npc:random", args = {start = 1, ["end"] = 10}},
			{name = "npc:jump_if", args = {expr = {left = "@local._inline_npc:random0", op = "<=", right = 5}, offset = true, negate = true, pos = 1}, srcmap = 60}, -- IF [2],
				{name = "npc:execute", args = {name = "torcherer:wander"}, srcmap = 61},
	{name = "npc:var:set", args = {key = "for_index", value = {left = "@local.for_index", op = "+", right = 1}, storage_type = "local"}, srcmap = 42},
	{name = "npc:jump_if", args = {expr = {left = "@local.for_index", op = "<=", right = "@objs.all.length"}, negate = false, offset = true, pos = -21}, srcmap = 42}, -- FOR end [30]
})

npc.proc.register_program("torcherer:turn_on_torches", {
	{key = "@local.nodes", name = "npc:env:node:find", args = {radius = 5, nodenames = {"mesecraft_torch:torch_wall"}, nodenames = {"mesecraft_torch:torch_wall"}}, srcmap = 68},
	{name = "npc:jump_if", args = {expr = {left = "@local.nodes.length", op = ">", right = 0}, offset = true, negate = true, pos = 9}, srcmap = 69}, -- IF [2],
		{name = "npc:var:set", args = {key = "for_index", value = 1, storage_type = "local"}, srcmap = 70}, -- FOR start [1],
			{name = "npc:var:set", args = {key = "chosen_node", value = "@local.nodes[@local.for_index]", storage_type = "local"}, srcmap = 71},
			{name = "npc:execute", args = {name = "npc:walk_to_pos", args = {pos = "@local.chosen_node", force_accessing_node = true}, args = {pos = "@local.chosen_node", force_accessing_node = true}}, srcmap = 72},
			{key = "@local.node", name = "npc:env:node:get", args = {pos = "@local.chosen_node"}, srcmap = 73},
			{key = "@local.new_name", name = "npc:util:str:replace", args = {str = "@local.node[name]", target = "mesecraft_torch", replacement = "default"}, srcmap = 75},
			{name = "npc:env:node:set", args = {pos = "@local.chosen_node", node = "@local.new_name", param2 = "@local.node[param2]"}, srcmap = 77},
		{name = "npc:var:set", args = {key = "for_index", value = {left = "@local.for_index", op = "+", right = 1}, storage_type = "local"}, srcmap = 70},
		{name = "npc:jump_if", args = {expr = {left = "@local.for_index", op = "<", right = "@local.nodes.length"}, negate = false, offset = true, pos = -7}, srcmap = 70}, -- FOR end [8],
	{name = "npc:jump", args = {offset = true, pos = 1}, srcmap = 79}, -- ELSE [11],
		{name = "npc:execute", args = {name = "torcherer:wander"}, srcmap = 80}
})

npc.proc.register_program("torcherer:wander", {
	{name = "npc:var:set", args = {key = "prev_dir", value = -1, storage_type = "local"}, srcmap = 87},
	{key = "@local._inline_npc:random0", name = "npc:random", args = {start = 1, ["end"] = 5}},
	{name = "npc:var:set", args = {key = "for_index", value = 1, storage_type = "local"}, srcmap = 88}, -- FOR start [3],
		{key = "@local.cardinal_dir", name = "npc:random", args = {start = 0, ["end"] = 7}, srcmap = 89},
			{key = "@local.cardinal_dir", name = "npc:random", args = {start = 0, ["end"] = 7}, srcmap = 91},
		{name = "npc:jump_if", args = {expr = {left = "@local.cardinal_dir", op = "==", right = "@local.prev_dir"}, negate = false, offset = true, pos = -2}, srcmap = 90}, -- WHILE end [3],
		{name = "npc:var:set", args = {key = "prev_dir", value = "@local.cardinal_dir", storage_type = "local"}, srcmap = 93},
		{name = "npc:move:walk", args = {cardinal_dir = "@local.cardinal_dir"}, srcmap = 94},
	{name = "npc:var:set", args = {key = "for_index", value = {left = "@local.for_index", op = "+", right = 1}, storage_type = "local"}, srcmap = 88},
	{name = "npc:jump_if", args = {expr = {left = "@local.for_index", op = "<", right = "@local._inline_npc:random0"}, negate = false, offset = true, pos = -7}, srcmap = 88}, -- FOR end [10],
	{name = "npc:move:stand", args = {}, srcmap = 96}
})

npc.proc.register_program("torcherer:sleep", {
	{key = "@local.target_node", name = "npc:env:node:store:get", args = {only_one = true, categories = "beds"}, srcmap = 100},
	{name = "npc:jump_if", args = {expr = {left = "@local.target_node", op = "~=", right = nil}, offset = true, negate = true, pos = 7}, srcmap = 101}, -- IF [2],
		{name = "npc:execute", args = {name = "npc:walk_to_pos", args = {pos = "@local.target_node.pos", force_accessing_node = true}, args = {pos = "@local.target_node.pos", force_accessing_node = true}}, srcmap = 102},
		{name = "npc:env:node:operate", args = {pos = "@local.target_node.pos"}, srcmap = 103},
			{key = "_prev_proc_int", name = "npc:get_proc_interval"},
			{name = "npc:set_proc_interval", args = {wait_time = 30, value = {left = 30, op = "-", right = "@local._prev_proc_int"}}},
			{name = "npc:set_proc_interval", args = {value = "@local._prev_proc_int"}},
		{name = "npc:jump_if", args = {expr = {left = {left = {left = "@time", op = ">", right = 20000}, op = "&&", right = {left = "@time", op = "<", right = 24000}}, op = "||", right = {left = "@time", op = "<", right = 6000}}, negate = false, offset = true, pos = -4}, srcmap = 104}, -- WHILE end [6],
		{name = "npc:var:set", args = {key = "hunger", value = 60, storage_type = "global"}, srcmap = 107}
})




------------------------------------------------------
-- Items
------------------------------------------------------
minetest.register_craftitem("anpc:torcherer_spawner", {
	description = "Torcherer Spawner",
	inventory_image = "default_torch_on_floor.png",
	on_use = function(itemstack, user, pointed_thing)
		local spawn_pos = minetest.pointed_thing_to_face_pos(user, pointed_thing)
		spawn_pos.y = spawn_pos.y
		local entity = minetest.add_entity(spawn_pos, "anpc:torcherer_npc")
		if entity then
            npc.proc.execute_program(entity:get_luaentity(), "torcherer:init")
            npc.proc.execute_program(entity:get_luaentity(), "torcherer:find_bed")
			npc.proc.set_state_process(entity:get_luaentity(), "torcherer:idle", {
				ack_nearby_objs = true,
				ack_nearby_objs_dist = 4,
				ack_nearby_objs_chance = 50
			})
		else
			minetest.remove_entity(entity)
		end
	end
})

minetest.register_entity("anpc:torcherer_npc", {
	hp_max = 1,
	visual = "mesh",
	mesh = "character_anpc.b3d",
	textures = {
		"default_male.png",
	},
	visual_size = {x = 1, y = 1, z = 1},
	collisionbox = {-0.20,0,-0.20, 0.20,1.8,0.20},
	stepheight = 0.6,
	physical = true,
	on_activate = npc.on_activate,
	get_staticdata = npc.get_staticdata,
	on_step = npc.do_step,
	on_rightclick = function(self, puncher)
		minetest.log(dump(self))
	end
})