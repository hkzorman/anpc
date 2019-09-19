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

npc.proc.register_program("vegetarian:init", {
    {name = "vegetarian:set_hunger", args = {value = 0}}
})

npc.proc.register_program("vegetarian:idle", {
	{name = "npc:move:stand"},
    {name = "vegetarian:set_hunger", args = {
        value = function(self, args)
            return self.data.global.hunger + 2
        end
    }},
    {name = "npc:if", args = {
        expr = {
            left = "@global.hunger",
            op   = ">=",
            right = 60
        },
        true_instructions = {
            {name = "npc:set_state_process", args = {
                name = "vegetarian:feed", args = {}
            }}
        }
    }},
    {name = "npc:if", args = {
        expr = function(self, args)
            return 24000 * minetest.get_timeofday() >= 20000
        end,
        true_instructions = {
            {name = "npc:execute", args = {
                name = "vegetarian:sleep", args = {}
            }}
        }
    }},
	{name = "npc:for", args = {
		initial_value = 1,
		step_increase = 1,
		expr = {
			left = "@local.for_index",
			op = "<=",
			right = function(self)
				return #self.data.env.objects
			end
		},
		loop_instructions = {
			{name = "npc:if", args = {
				expr = function(self, args)
					-- Random 50% chance
					local chance = math.random(1, 100)
					if chance < (100 - npc.eval(self, "@args.ack_nearby_objs_chance")) then
						return false
					end

					local object = self.data.env.objects[self.data.proc[self.process.current.id].for_index]
					if object then
						local object_pos = object:get_pos()
						local self_pos = self.object:get_pos()
						return vector.distance(object_pos, self_pos) < npc.eval(self, "@args.ack_nearby_objs_dist")
							and vector.distance(object_pos, self_pos) > 0
					end
					return false
				end,
				true_instructions = {
					{name = "npc:while", args = {time = "@random.15.30", loop_instructions = {
						{name = "npc:move:rotate", args={
							target_pos = function(self, args)
								local object = self.data.env.objects[self.data.proc[self.process.current.id].for_index]
								if object then
									return object:get_pos()
								end
							end
						}},
					}},
					{name = "npc:break"}}
				},
				false_instructions = {
					{name = "npc:if", args = {
						expr = {
							left  = "@random.1.10",
							op    = "<=",
							right = 2
						},
						true_instructions = {
							{name = "npc:move:walk", args = {
								cardinal_dir = "@random.1.7"
							}},
							{name = "npc:move:stand"}
						}
					}}
				}}}
		}}}
})

-- Eating program
npc.proc.register_program("vegetarian:feed", {
	{key = "nodes", name = "npc:env:node:find", args = {
		radius = 5,
		nodenames = {"default:grass_1", "default:grass_2", "default:grass_3", "default:grass_4", "default:grass_5"}
	}},
	{name = "npc:if", args = {
		expr = function(self, args)
			return #self.data.proc[self.process.current.id].nodes > 0
		end,
		true_instructions = {
            {name = "npc:var:set", args = {
                key = "chosen_node",
                value = function(self, args)
					-- Choose a random pos
					local index = math.random(1, #self.data.proc[self.process.current.id].nodes)
					local result = self.data.proc[self.process.current.id].nodes[index]
                    return result
                end
            }},
			{name = "npc:execute", args = {
				name = "builtin:walk_to_pos",
				args = {
					end_pos = "@local.chosen_node",
					force_accessing_node = true
				}
			}},
            {name = "npc:env:node:dig", args = {
                pos = "@local.chosen_node"
            }},
            {name = "vegetarian:set_hunger", args = {
                value = function(self, args)
                    return self.data.global.hunger - 10
                end
            }},
            {name = "npc:if", args = {
                expr = {
                    left = "@global.hunger",
                    op   = "<=",
                    right = 0
                },
                true_instructions = {
                    {name = "npc:set_state_process", args = {
                        name = "vegetarian:idle",
                        args = {
                            ack_nearby_objs = true,
            				ack_nearby_objs_dist = 4,
            				ack_nearby_objs_chance = 50
                        }
                    }}
                }
            }}
		},
		false_instructions = {
			-- Move in a random direction
			{name = "npc:move:walk", args = {
				cardinal_dir = function(self, args) return math.random(1,7) end
			}},
			{name = "npc:move:stand"}
		}
	}}
})

-- Sleep program
npc.proc.register_program("vegetarian:sleep", {
    {key = "bed_pos", name = "npc:env:node:find", args = {
        matches = "single",
        radius = 35,
        nodenames = {"beds:bed_bottom"}
    }},
    {name = "npc:if", args = {
        expr = {
        	left  = "@local.bed_pos",
        	op    = "~=",
        	right = nil
        },
        true_instructions = {
            {name = "npc:execute", args = {
                name = "builtin:walk_to_pos",
                args = {
                	end_pos = "@local.bed_pos"
                }
            }},
            {name = "npc:env:node:operate", args = {
            	pos = "@local.bed_pos"
            }},
            {name = "npc:while", args = {
                expr = function(self, args)
                    local time = 24000 * minetest.get_timeofday()
                    return (time > 20000 and time < 24000) or (time < 6000)
                end,
                loop_instructions = {
                    {name = "npc:wait", args = {time = 30}}
                }
            }},
            {name = "vegetarian:set_hunger", args = {value = 60}},
            {name = "npc:set_state_process", args = {
                name = "vegetarian:idle",
                args = {
                    ack_nearby_objs = true,
    				ack_nearby_objs_dist = 4,
    				ack_nearby_objs_chance = 50
                }}
            }
        }
    }}
})

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
	--collisionbox = {-0.6,-0.6,-0.6, 0.6,0.6,0.6},
	physical = true,
	on_activate = npc.on_activate,
	get_staticdata = function(self)

		local result = ""
		if self.npc_id then
			result = result..self.npc_id.."|"
		end

		if self.timers then
			result = result..minetest.serialize(self.timers).."|"
		end

		if self.process then
			result = result..minetest.serialize(self.process).."|"
		end

		if self.data then
			self.data.env.objects = {}
			self.data.temp = {}
			--minetest.log("User data: "..dump(self.data))
			result = result..minetest.serialize(self.data).."|"
		end

        minetest.log("Self: "..dump(self))

		return result

	end,
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
