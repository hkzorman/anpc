-- A sample NPC

-- Animations
npc.model.register_animation("character_anpc.b3d", "stand", {
	start_frame = 0,
	end_frame = 79,
	speed = 30,
	loop = true
})

npc.model.register_animation("character_anpc.b3d", "lay", {
	start_frame = 162,
	end_frame = 166,
	loop = true
})

npc.model.register_animation("character_anpc.b3d", "walk", {
	start_frame = 168,
	end_frame = 187,
	loop = true
})

npc.model.register_animation("character_anpc.b3d", "mine_once", {
	start_frame = 192,
	end_frame = 196,
	speed = 15,
	loop = false,
	animation_after = "stand"
})

-- Nodes
npc.env.register_node("beds:bed_bottom", 
	{"bed"},
	{},
	function(self, args)
		local pos = args.pos
		local node = minetest.get_node_or_nil(pos)
		if (not node) then return end
		local dir = minetest.facedir_to_dir(node.param2)
		-- Calculate bed_pos
		local bed_pos = {
			x = pos.x + dir.x / 2,
			y = pos.y,
			z = pos.z + dir.z / 2
		}
		-- Move to position
		self.object:move_to(bed_pos)
		self.object:set_yaw(minetest.dir_to_yaw(minetest.facedir_to_dir((node.param2 + 2) % 4)))
		-- Set animation
		npc.model.set_animation(self, {name = "lay"})
	end)

npc.proc.register_instruction("vegetarian:set_hunger", function(self, args)
    self.data.global.hunger = args.value
end)

npc.proc.register_instruction("vegetarian:get_hunger", function(self, args)
    return self.data.global.hunger
end)

-- npc.proc.register_instruction("vegetarian:check_can_ack_nearby_objs", function(self, args)
-- 	-- Random 50% chance
-- 	local chance = math.random(1, 100)
-- 	if chance < (100 - npc.eval(self, "@args.ack_nearby_objs_chance")) then
-- 		return false
-- 	end

-- 	local object = self.data.env.objects[self.data.proc[self.process.current.id].for_index]
-- 	if object then
-- 		local object_pos = object:get_pos()
-- 		local self_pos = self.object:get_pos()
-- 		return vector.distance(object_pos, self_pos) < npc.eval(self, "@args.ack_nearby_objs_dist")
-- 			and vector.distance(object_pos, self_pos) > 0
-- 	end
-- 	return false
-- end)

-- Generated programs
npc.proc.register_program("vegetarian:init", {
	{name = "npc:var:set", args = {key = "hunger", value = 0, storage_type = "global"}, srcmap = 3}
}, "/home/hfranqui/minetest/mods/anpc_dev/vegetarian.anpcscript")

npc.proc.register_program("vegetarian:idle", {
	{name = "npc:move:stand", args = {}, srcmap = 11},
	{name = "npc:var:set", args = {key = "hunger", value = {left = "@global.hunger", op = "+", right = 2}, storage_type = "global"}, srcmap = 12},
	{name = "npc:jump_if", args = {expr = {left = "@global.hunger", op = ">=", right = 60}, offset = true, negate = true, pos = 1}, srcmap = 14}, -- IF [3],
		{name = "npc:execute", args = {name = "vegetarian:feed"}, srcmap = 15},
	{name = "npc:jump_if", args = {expr = {left = "@time", op = ">=", right = 20000}, offset = true, negate = true, pos = 1}, srcmap = 19}, -- IF [5],
		{name = "npc:execute", args = {name = "vegetarian:sleep"}, srcmap = 20},
	{name = "npc:var:set", args = {key = "should_ack_obj", value = "false", storage_type = "local"}, srcmap = 23},
	{name = "npc:var:set", args = {key = "for_index", value = 1, storage_type = "local"}, srcmap = 24}, -- FOR start [8],
		{key = "@local._inline_npc:random0", name = "npc:random", args = {start = 1, ["end"] = 100}},
		{name = "npc:jump_if", args = {expr = {left = "@local._inline_npc:random0", op = ">=", right = {left = 100, op = "-", right = "@args.ack_nearby_objs_chance"}}, offset = true, negate = true, pos = 4}, srcmap = 25}, -- IF [2],
			{name = "npc:var:set", args = {key = "obj", value = "@objs.get[@local.for_index]", storage_type = "local"}, srcmap = 26},
			{name = "npc:jump_if", args = {expr = {left = "@local.obj", op = "~=", right = nil}, offset = true, negate = true, pos = 2}, srcmap = 27}, -- IF [2],
				{key = "@local.dist", name = "npc:distance_to", args = {object = "@local.obj"}, srcmap = 28},
				{name = "npc:var:set", args = {key = "should_ack_obj", value = {left = {left = "@local.dist", op = "<=", right = "@args.ack_nearby_objs_dist"}, op = "&&", right = {left = "@local.dist", op = ">", right = 0}}, storage_type = "local"}, srcmap = 29},
		{name = "npc:jump_if", args = {expr = {left = "@local.should_ack_obj", op = "==", right = true}, offset = true, negate = true, pos = 9}, srcmap = 33}, -- IF [7],
			{key = "@local.ack_times", name = "npc:random", args = {start = 15, ["end"] = 30}, srcmap = 34},
			{name = "npc:var:set", args = {key = "for_index", value = 1, storage_type = "local"}, srcmap = 35}, -- FOR start [2],
				{key = "@local.obj_pos", name = "npc:obj:get_pos", args = {object = "@local.obj"}, srcmap = 36},
				{name = "npc:move:rotate", args = {target_pos = "@local.obj_pos"}, srcmap = 37},
			{name = "npc:var:set", args = {key = "for_index", value = {left = "@local.for_index", op = "+", right = 1}, storage_type = "local"}, srcmap = 35},
			{name = "npc:jump_if", args = {expr = {left = "@local.for_index", op = "<=", right = "@local.ack_times"}, negate = false, offset = true, pos = -4}, srcmap = 35}, -- FOR end [6],
			{name = "npc:var:set", args = {key = "hunger", value = {left = "@global.hunger", op = "+", right = {left = "@local.ack_times", op = "*", right = 2}}, storage_type = "global"}, srcmap = 39},
			{name = "npc:break", srcmap = 40},
		{name = "npc:jump", args = {offset = true, pos = 3}, srcmap = 41}, -- ELSE [16],
			{key = "@local._inline_npc:random0", name = "npc:random", args = {start = 1, ["end"] = 10}},
			{name = "npc:jump_if", args = {expr = {left = "@local._inline_npc:random0", op = "<=", right = 5}, offset = true, negate = true, pos = 1}, srcmap = 42}, -- IF [2],
				{name = "npc:execute", args = {name = "vegetarian:wander"}, srcmap = 43},
	{name = "npc:var:set", args = {key = "for_index", value = {left = "@local.for_index", op = "+", right = 1}, storage_type = "local"}, srcmap = 24},
	{name = "npc:jump_if", args = {expr = {left = "@local.for_index", op = "<=", right = "@objs.all.length"}, negate = false, offset = true, pos = -21}, srcmap = 24}, -- FOR end [29]
}, "/home/hfranqui/minetest/mods/anpc_dev/vegetarian.anpcscript")

npc.proc.register_program("vegetarian:wander", {
	{name = "npc:var:set", args = {key = "prev_dir", value = -1, storage_type = "local"}, srcmap = 52},
	{key = "@local._inline_npc:random0", name = "npc:random", args = {start = 1, ["end"] = 5}},
	{name = "npc:var:set", args = {key = "for_index", value = 1, storage_type = "local"}, srcmap = 53}, -- FOR start [3],
		{key = "@local.cardinal_dir", name = "npc:random", args = {start = 0, ["end"] = 7}, srcmap = 54},
			{key = "@local.cardinal_dir", name = "npc:random", args = {start = 0, ["end"] = 7}, srcmap = 56},
		{name = "npc:jump_if", args = {expr = {left = "@local.cardinal_dir", op = "==", right = "@local.prev_dir"}, negate = false, offset = true, pos = -2}, srcmap = 55}, -- WHILE end [3],
		{name = "npc:var:set", args = {key = "prev_dir", value = "@local.cardinal_dir", storage_type = "local"}, srcmap = 58},
		{name = "npc:move:walk", args = {cardinal_dir = "@local.cardinal_dir"}, srcmap = 59},
	{name = "npc:var:set", args = {key = "for_index", value = {left = "@local.for_index", op = "+", right = 1}, storage_type = "local"}, srcmap = 53},
	{name = "npc:jump_if", args = {expr = {left = "@local.for_index", op = "<", right = "@local._inline_npc:random0"}, negate = false, offset = true, pos = -7}, srcmap = 53}, -- FOR end [10],
	{name = "npc:move:stand", args = {}, srcmap = 61}
}, "/home/hfranqui/minetest/mods/anpc_dev/vegetarian.anpcscript")

npc.proc.register_program("vegetarian:sleep", {
	{key = "@local.bed_pos", name = "npc:env:node:find", args = {matches = "single", radius = 35, nodenames = {"beds:bed_bottom"}, nodenames = {"beds:bed_bottom"}}, srcmap = 65},
	{name = "npc:jump_if", args = {expr = {left = "@local.bed_pos.length", op = ">", right = 0}, offset = true, negate = true, pos = 7}, srcmap = 66}, -- IF [2],
		{name = "npc:execute", args = {name = "npc:walk_to_pos", args = {pos = "@local.bed_pos[1]"}, args = {pos = "@local.bed_pos[1]"}}, srcmap = 67},
		{name = "npc:env:node:operate", args = {pos = "@local.bed_pos[1]"}, srcmap = 68},
			{key = "_prev_proc_int", name = "npc:get_proc_interval"},
			{name = "npc:set_proc_interval", args = {wait_time = 30, value = {left = 30, op = "-", right = "@local._prev_proc_int"}}},
			{name = "npc:set_proc_interval", args = {value = "@local._prev_proc_int"}},
		{name = "npc:jump_if", args = {expr = {left = {left = {left = "@time", op = ">", right = 20000}, op = "&&", right = {left = "@time", op = "<", right = 24000}}, op = "||", right = {left = "@time", op = "<", right = 6000}}, negate = false, offset = true, pos = -4}, srcmap = 69}, -- WHILE end [6],
		{name = "npc:var:set", args = {key = "hunger", value = 60, storage_type = "global"}, srcmap = 72}
}, "/home/hfranqui/minetest/mods/anpc_dev/vegetarian.anpcscript")

npc.proc.register_program("vegetarian:feed", {
		{name = "npc:jump_if", args = {expr = {left = {left = {left = "@time", op = ">", right = 20000}, op = "&&", right = {left = "@time", op = "<=", right = 24000}}, op = "||", right = {left = "@time", op = "<", right = 6000}}, offset = true, negate = true, pos = 1}, srcmap = 80}, -- IF [1],
			{name = "npc:exit"},
		{key = "@local.nodes", name = "npc:env:node:find", args = {radius = 5, nodenames = {"default:grass_1", "default:grass_2", "default:grass_3", "default:grass_4", "default:grass_5"}, nodenames = {"default:grass_1", "default:grass_2", "default:grass_3", "default:grass_4", "default:grass_5"}}, srcmap = 84},
		{name = "npc:jump_if", args = {expr = {left = "@local.nodes.length", op = ">", right = 0}, offset = true, negate = true, pos = 6}, srcmap = 85}, -- IF [4],
			{key = "@local.random_index", name = "npc:random", args = {start = 1, ["end"] = "@local.nodes.length"}, srcmap = 86},
			{name = "npc:var:set", args = {key = "chosen_node", value = "@local.nodes[@local.random_index]", storage_type = "local"}, srcmap = 87},
			{name = "npc:execute", args = {name = "npc:walk_to_pos", args = {pos = "@local.chosen_node", force_accessing_node = true}, args = {pos = "@local.chosen_node", force_accessing_node = true}}, srcmap = 88},
			{name = "npc:env:node:dig", args = {pos = "@local.chosen_node"}, srcmap = 89},
			{name = "npc:var:set", args = {key = "hunger", value = {left = "@global.hunger", op = "-", right = 10}, storage_type = "global"}, srcmap = 90},
		{name = "npc:jump", args = {offset = true, pos = 1}, srcmap = 91}, -- ELSE [10],
			{name = "npc:execute", args = {name = "vegetarian:wander"}, srcmap = 92},
	{name = "npc:jump_if", args = {expr = {left = "@global.hunger", op = ">=", right = 0}, negate = false, offset = true, pos = -12}, srcmap = 77}, -- WHILE end [12]
}, "/home/hfranqui/minetest/mods/anpc_dev/vegetarian.anpcscript")

-- npc.proc.register_program("vegetarian:own", {
-- 	{name = "npc:env:nodes:set_owned", args = {value = "@args.value", pos = "@args.pos", categories = "@args.categories"}, srcmap = 98}
-- }, "/home/hfranqui/minetest/mods/anpc_dev/vegetarian.anpcscript")

-- npc.proc.register_program("vegetarian:walk_to_owned", {
-- 	{key = "@local.target_node", name = "npc:env:node:store:get", args = {only_one = true, categories = "@args.categories"}, srcmap = 102},
-- 	{name = "npc:jump_if", args = {expr = {left = "@local.target_node", op = "~=", right = nil}, offset = true, negate = true, pos = 1}, srcmap = 103}, -- IF [2],
-- 		{name = "npc:execute", args = {name = "npc:walk_to_pos", args = {pos = "@local.target_node.pos", force_accessing_node = true}, args = {pos = "@local.target_node.pos", force_accessing_node = true}}, srcmap = 104}
-- }, "/home/hfranqui/minetest/mods/anpc_dev/vegetarian.anpcscript")



-- Wandering program
-- Try to do some smart wandering instead of just walking back and forth
-- The wandering have two approaches: 
--[[
npc.proc.register_program("vegetarian:wander", {
	{name = "npc:if", args = {
		expr = {
			left  = "@args.pattern",
			op    = "==",
			right = "MSL"
		},
		true_instructions = {
			-- Save the starting position
			{name = "npc:var:set", args = { key = "start_pos", value = "@self.pos_rounded" }},
			-- Save the starting direction
			{name = "npc:var:set", args = { key = "start_yaw", value = "@self.yaw" }},
			{name = "npc:var:set", args = { key = "found_next_pos", value = false }},
			{name = "npc:var:set", args = { key = "new_pos_tries", value = 0 }},
			{name = "npc:while", args = {
				expr = function(self, args)
					return self.data.proc[self.process.current.id].new_pos_tries < 5 
						and self.data.proc[self.process.current.id].found_next_pos == false
				end,
				loop_instructions = {
					-- Calculate a new direction
					{name = "npc:var:set", args = { key = "new_yaw", value = function(self, args)
						local dir = math.random(1, 3)
						local yaw_change = 0
						if dir == 1 then
							yaw_change = -1 * (math.pi / 4)
						elseif dir == 3 then
							yaw_change = math.pi / 4
						end
						return self.object:get_yaw() + yaw_change
					end}},
					-- Calculate new position
					{name="npc:var:set", args = { key = "new_pos", value = function(self, args)
						local new_dir = minetest.yaw_to_dir(self.data.proc[self.process.current.id].new_yaw)
						local distance = math.random(3, 7)
						local self_pos = vector.round(self.object:get_pos())
						return vector.round(vector.add(self_pos, vector.multiply(new_dir, distance)))
					end}},
					{name="npc:var:set", args = { key = "new_pos_tries", value = function(self, args)
						return self.data.proc[self.process.current.id].new_pos_tries + 1
					end}},
					-- Check that new position is valid
					{key = "found_next_pos", name = "npc:env:node:can_stand_in", args = {
						pos = "@local.new_pos"
					}}
				}
			}},
			{name = "npc:if", args = {
				expr = {
					left  = "@local.new_pos_tries",
					op    = "<=",
					right = 5
				},
				true_instructions = {
					-- Start walking on that direction
					{name = "npc:execute", args = {
						name = "builtin:walk_to_pos",
						args = {
							end_pos = "@local.new_pos",
						}
					}},
				}
			}}
		}
	}}
})
]]--

-- NPC
minetest.register_entity("anpc:vegetarian_npc", {
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

-- Spawner item
minetest.register_craftitem("anpc:vegetarian_npc_spawner", {
	description = "Vegetarian Spawner",
	inventory_image = "default_grass.png",
	on_use = function(itemstack, user, pointed_thing)
		local spawn_pos = minetest.pointed_thing_to_face_pos(user, pointed_thing)
		spawn_pos.y = spawn_pos.y
		local entity = minetest.add_entity(spawn_pos, "anpc:vegetarian_npc")
		if entity then
            npc.proc.execute_program(entity:get_luaentity(), "vegetarian:init")
			npc.proc.set_state_process(entity:get_luaentity(), "vegetarian:idle", {
				ack_nearby_objs = true,
				ack_nearby_objs_dist = 4,
				ack_nearby_objs_chance = 50
			})
		else
			minetest.remove_entity(entity)
		end
	end
})

minetest.register_craftitem("anpc:vegetarian_feed", {
	description = "Feeder",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			local target_pos = minetest.find_node_near(user:get_pos(), 25, {"default:grass_1", "default:grass_2", "default:grass_3", "default:grass_4", "default:grass_5"})
			npc.proc.execute_program(pointed_thing.ref:get_luaentity(), "builtin:walk_to_pos", {end_pos = target_pos})
			--minetest.log(dump(pointed_thing.ref:get_luaentity()))
		end
	end
})

minetest.register_entity("anpc:vegetarian_npc2", {
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
	on_step = function(self, dtime)
		if (self.is_jumping == true) then
			self.timer = self.timer + dtime
			local vel = self.object:get_velocity()
			if (vel.y == 0) then
				self.object:set_velocity({x=0, y=0, z=0})
				self.is_jumping = false
				minetest.log("Landed in: "..dump(self.timer))
			end
		end
		if (self.is_dropping == true) then
			local vel = self.object:get_velocity()
			if vel.y == 0 and self.is_falling == true then
				self.is_dropping = false
				self.object:set_velocity({x=0, y=0, z=0})
				minetest.log("Landed")
			elseif vel.y < 0 and self.is_falling == false then
				self.is_falling = true
				minetest.log("Started falling")
			end
		end
	end,
	on_rightclick = function(self, puncher)
		minetest.log(dump(self))
	end
})

-- Spawner item
minetest.register_craftitem("anpc:vegetarian_npc_spawner2", {
	description = "Vegetarian Spawner 2",
	inventory_image = "default_glass.png",
	on_use = function(itemstack, user, pointed_thing)
		local spawn_pos = minetest.pointed_thing_to_face_pos(user, pointed_thing)
		spawn_pos.y = spawn_pos.y
		local entity = minetest.add_entity(spawn_pos, "anpc:vegetarian_npc2")
		if entity then
            entity:set_acceleration({x=0, y=-10, z=0})
		else
			minetest.remove_entity(entity)
		end
	end
})

--- For testing purposes ---
-- Ownership program
npc.proc.register_program("vegetarian:own", {
	{name = "npc:env:node:set_owned", args = {
		value = "@args.value",
		pos = "@args.pos",
		categories = "@args.categories"
	}}
})

npc.proc.register_program("vegetarian:walk_to_owned", {
	{key = "target_node", name = "npc:env:node:store:get", args = {
		only_one = true,
		categories = {"sign"}
	}},
	{name = "npc:if", args = {
		expr = {
			left  = "@local.target_node",
			op    = "~=",
			right = nil
		},
		true_instructions = {
			{name = "npc:execute", args = {
				name = "builtin:walk_to_pos",
				args = {
					end_pos = function(self, args) 
						return self.data.proc[self.process.current.id]["target_node"].pos
					end,
					force_accessing_node = true
				}
			}}
		}
	}}
})

-- Owner item
minetest.register_craftitem("anpc:vegetarian_owner", {
	description = "Owner\nGives the NPC ownership of the last clicked node",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			local meta = user:get_meta()
			local pos = minetest.deserialize(meta:get_string("target_pos"))
			npc.proc.execute_program(pointed_thing.ref:get_luaentity(), "vegetarian:own", {
				value = true,
				pos = pos,
				-- Please notice that categories are arbitrary
				categories = {"sign"}
			})
			minetest.log("self.data.env.nodes: "..dump(pointed_thing.ref:get_luaentity().data))
		elseif pointed_thing.type == "node" then
			local meta = user:get_meta()
			minetest.log("Pointed thing: "..dump(pointed_thing))
			minetest.log("The pointed: "..dump(minetest.get_node(pointed_thing.under)))
			meta:set_string("target_pos", minetest.serialize(pointed_thing.under))
		end
	end
})

minetest.register_craftitem("anpc:vegetarian_walk_to_owned", {
	description = "Walk-to-owned\nWalk to an owned node",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			--local user_meta = user:get_meta()
			--local pos = minetest.deserialize(meta:get_string("target_pos"))
			minetest.log("self.data.env.nodes: "..dump(pointed_thing.ref:get_luaentity().data.env.nodes))
			npc.proc.execute_program(pointed_thing.ref:get_luaentity(), "vegetarian:walk_to_owned", {})
		end
	end
})

minetest.register_craftitem("anpc:vegetarian_follower", {
	description = "Follower\nMakes the NPC follow the player",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			local entity = pointed_thing.ref:get_luaentity()
			-- Toggle between follow and idle
			if entity.process.state.name == "npc:follow" then
				npc.proc.set_state_process(entity, "vegetarian:idle", {
					ack_nearby_objs = true,
					ack_nearby_objs_dist = 4,
					ack_nearby_objs_chance = 50
				}, true)
			else
				npc.proc.set_state_process(entity, "npc:follow", {object = user}, true)
			end
		end
	end
})

minetest.register_craftitem("anpc:vegetarian_jump", {
	description = "Jumper",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			local entity = pointed_thing.ref:get_luaentity()
			local dir = {x=1, y=0, z=0}
			local range = 1

			local self_pos = vector.round(entity.object:get_pos())
			local next_pos_front = {x = self_pos.x, y = self_pos.y, z = self_pos.z + 1}
			local next_pos_below = {x = self_pos.x, y = self_pos.y - 1, z = self_pos.z + 1}
			local next_y_diff = 0

			local next_nod = minetest.get_node(next_pos_front)
			if (next_nod.name ~= "air" and minetest.registered_nodes[next_nod.name].walkable == true) then
				next_y_diff = 1
				range = 2
			else
				next_nod = minetest.get_node(next_pos_below)
				if (next_nod.name == "air") then
					range = 0.5
					next_y_diff = -1
				end
			end

			local mid_point = (entity.collisionbox[5] - entity.collisionbox[2]) / 2

			-- Based on range, doesn't takes time into account
			local y_speed = math.sqrt ( (10 * range) / (math.sin(2 * (math.pi / 3))) ) + mid_point
			entity.is_jumping = true
			if (next_y_diff == -1) then y_speed = 0 end
			local x_speed = 1
			if (next_y_diff == -1) then
				x_speed = 1 / (math.sqrt( (2 + mid_point) / (10) ))
				entity.is_dropping = true
				entity.is_jumping = false
				entity.is_falling = false
			end
--			local initial_y = self_pos.y + mid_point
--			local target_y  = self_pos.y + mid_point + next_y_diff
--			local y_speed = target_y + 5 - initial_y

			minetest.log("This is y_speed: "..dump(y_speed))
			minetest.log("This is x speed: "..dump(x_speed))


			entity.object:set_pos(vector.round(entity.object:get_pos()))
			local vel = {x=0, y=y_speed, z=x_speed}
			entity.object:set_velocity(vel)
			entity.timer = 0

		end
	end
})
