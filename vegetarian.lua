-- A sample NPC

npc.proc.register_instruction("vegetarian:set_hunger", function(self, args)
    self.data.global.hunger = args.value
end)

npc.proc.register_instruction("vegetarian:get_hunger", function(self, args)
    return self.data.global.hunger
end)

npc.proc.register_instruction("vegetarian:dig", function(self, args)
    local pos = args.pos
    minetest.dig_node(pos)
end)

npc.proc.register_program("vegetarian:init", {
    {name = "vegetarian:set_hunger", args = {value = 0}}
})

npc.proc.register_program("vegetarian:idle", {
	{name = "npc:move:stand"},
    {name = "vegetarian:set_hunger", args = {
        value = function(self, args)
            return self.data.global.hunger + 1
        end
    }},
    {name = "npc:if", args = {
        expr = {
            left = "@global.hunger",
            op   = ">=",
            right = 180
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
					{name = "npc:while", args = {time = 5, loop_instructions = {
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
                    -- minetest.log("Nodes: ".dump(self.data.proc[self.process.current.id].nodes[index]))
                    -- minetest.log("Index: ")
					local index = math.random(1, #self.data.proc[self.process.current.id].nodes)
					local result = self.data.proc[self.process.current.id].nodes[index]
                    return result
                end
            }},
			{name = "npc:execute", args = {
				name = "builtin:walk_to_pos",
				args = {
					end_pos = "@local.chosen_node"
				}
			}},
            {name = "vegetarian:dig", args = {
                pos = "@local.chosen_node"
            }},
            {name = "vegetarian:set_hunger", args = {
                value = function(self, args)
                    return self.data.global.hunger - 32
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
        radius = 35,
        nodenames = {"beds:bed_bottom"}
    }},
    {name = "npc:if", args = {
        expr = function(self, args)
            minetest.log("Self: "..dump(self))
            return #self.data.proc[self.process.current.id].bed_pos > 0
        end,
        true_instructions = {
            {name = "npc:execute", args = {
                name = "builtin:walk_to_pos",
                args = {
                end_pos = function(self, args)
                        local index = math.random(1, #self.data.proc[self.process.current.id].bed_pos)
                        minetest.log("Walking to: "..dump(self.data.proc[self.process.current.id].bed_pos[index]))
                        return self.data.proc[self.process.current.id].bed_pos[index]
                    end
                }
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
            {name = "vegetarian:set_hunger", args = {value = 300}},
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
