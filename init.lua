npc = {
	proc = {}
}

local _npc = {
	dsl = {},
	proc = {}
}

npc.ANIMATION_STAND_START = 0
npc.ANIMATION_STAND_END = 79
npc.ANIMATION_SIT_START = 81
npc.ANIMATION_SIT_END = 160
npc.ANIMATION_LAY_START = 162
npc.ANIMATION_LAY_END = 166
npc.ANIMATION_WALK_START = 168
npc.ANIMATION_WALK_END = 187
npc.ANIMATION_MINE_START = 189
npc.ANIMATION_MINE_END =198

local program_table = {}
local instruction_table = {}

local programs = {}
local instructions = {}

_npc.dsl.evaluate_boolean_expression = function(self, expr, args)
	local operator = expr.op
	local source = _npc.dsl.evaluate_argument(self, expr.left, args)
	local target = _npc.dsl.evaluate_argument(self, expr.right, args)

	if operator == "==" then
		return source == target
	elseif operator == ">=" then
		return source >= target
	elseif operator == "<=" then
		return source <= target
	elseif operator == "~=" then
		return source ~= target
	elseif operator == "<" then
		return source < target
	elseif operator == ">" then
		return source > target
	end
end

_npc.dsl.evaluate_argument = function(self, expr, args)
	if type(expr) == "string" then
		if expr:sub(1,1) == "@" then
			local expression_values = string.split(expr, ".")
			local storage_type = expression_values[1]
			local result = nil
			if storage_type == "@local" then
				--minetest.log("Data: "..dump(self.data))
				result = self.data.proc[#self.process.queue][expression_values[2]]
			elseif storage_type == "@global" then
				result = self.data.global[expression_values[2]]
			elseif storage_type == "@env" then
				result = self.data.env[expression_values[2]]
			end
			if #expression_values > 2 then
				-- The third element is an array index
				return result[expression_values[3]]
			else
				return result
			end
			--minetest.log("Expression: "..dump(expression_values))

		end
	elseif type(expr) == "table" and expr.left and expr.right and expr.op then
		return _npc.dsl.evaluate_boolean_expression(self, expr, args)
	elseif type(expr) == "function" then
		return expr(self, args)
	end
	return expr
end

-- Nil-safe set variable function
_npc.dsl.set_var = function(self, key, value)
	if self.data.proc[self.process.current.id] == nil then
		self.data.proc[self.process.current.id] = {}
	end

	self.data.proc[self.process.current.id][key] = value
end

_npc.dsl.get_var = function(self, key)
	if self.data.proc[self.process.current.id] == nil then return nil end
	return self.data.proc[self.process.current.id][key]
end

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Program and Instruction Registration
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
npc.proc.register_program = function(name, raw_instruction_list)
	if program_table[name] ~= nil then
		return false
	else
		-- Interpret program queue
		-- Convert if, for and while to index-jump instructions
		local instruction_list = {}
		for _,instruction in ipairs(raw_instruction_list) do

			if instruction.name == "npc:if" then
				-- Insert jump to skip true instructions if expr is false
				instruction_list[#instruction_list + 1] = {
					name = "npc:jump_if",
					args = {
						expr = instruction.args.expr,
						pos = #instruction_list + 1 + #instruction.args.true_instructions + 1,
						negate = true
					}
				}

				-- Insert all true_instructions
				for _,instr in ipairs(instruction.args.true_instructions) do
					instruction_list[#instruction_list + 1] = instr
				end

				-- Insert jump to skip false instructions if expr is true
				instruction_list[#instruction_list + 1] = {
					name = "npc:jump",
					args = {
						pos = #instruction_list + 1 + #instruction.args.false_instructions + 1,
					}
				}

				-- Insert all false_instructions
				for _,instr in ipairs(instruction.args.false_instructions) do
					instruction_list[#instruction_list + 1] = instr
				end

			elseif instruction.name == "npc:while" then

				-- The below will actually set the jump to the instruction previous
				-- to the relevant one - this is done because after the jump
				-- instruction is executed, the instruction counter will be increased
				local loop_start = #instruction_list
				-- Insert all loop instructions
				for _,instr in ipairs(instruction.args.loop_instructions) do
					instruction_list[#instruction_list + 1] = instr
				end

				-- Insert conditional to loop back if expr is true
				instruction_list[#instruction_list + 1] = {
					name = "npc:jump_if",
					args = {
						expr = instruction.args.expr,
						pos = loop_start,
						negate = false
					}
				}

			elseif instruction.name == "npc:for" then

				-- Initialize loop variable
				instruction_list[#instruction_list + 1] = {
					name = "npc:var:set",
					args = {
						key = "for_index",
						value = instruction.args.initial_value
					}
				}

				-- The below will actually set the jump to the instruction previous
				-- to the relevant one - this is done because after the jump
				-- instruction is executed, the instruction counter will be increased
				local loop_start = #instruction_list
				-- Insert all loop instructions
				for _,instr in ipairs(instruction.args.loop_instructions) do
					instruction_list[#instruction_list + 1] = instr
				end

				-- Insert loop variable increase instruction
				instruction_list[#instruction_list + 1] = {
					name = "npc:var:set",
					args = {
						key = "for_index",
						value = function(self, args)
							return self.data.proc[self.process.current.id]["for_index"]
								+ instruction.args.step_increase
						end
					}
				}

				-- Insert conditional to loop back if expr is true
				instruction_list[#instruction_list + 1] = {
					name = "npc:jump_if",
					args = {
						expr = instruction.args.expr,
						pos = loop_start,
						negate = false
					}
				}

			elseif instruction.name == "npc:for_each" then

				--assert(type(instruction.args.array) == "table")

				-- Initialize loop variables
				instruction_list[#instruction_list + 1] = {
					name = "npc:var:set",
					args = {
						key = "for_index",
						value = 1
					}
				}

				instruction_list[#instruction_list + 1] = {
					name = "npc:var:set",
					args = {
						key = "for_value",
						value = instruction.args.array..".1"
					}
				}

				-- The below will actually set the jump to the instruction previous
				-- to the relevant one - this is done because after the jump
				-- instruction is executed, the instruction counter will be increased
				local loop_start = #instruction_list
				-- Insert all loop instructions
				for _,instr in ipairs(instruction.args.loop_instructions) do
					instruction_list[#instruction_list + 1] = instr
				end

				-- Insert loop variable increase instruction
				instruction_list[#instruction_list + 1] = {
					name = "npc:var:set",
					args = {
						key = "for_index",
						value = function(self, args)
							return self.data.proc[self.process.current.id]["for_index"] + 1
						end
					}
				}

				instruction_list[#instruction_list + 1] = {
					name = "npc:var:set",
					args = {
						key = "for_value",
						value = function(self, args)
							return instruction.args.array.."."..self.data.proc[self.process.current.id].for_index
						end
					}
				}

				-- Insert conditional to loop back if expr is true
				instruction_list[#instruction_list + 1] = {
					name = "npc:jump_if",
					args = {
						expr = instruction.args.expr,
						pos = loop_start,
						negate = false
					}
				}

			else
				-- Insert the instruction
				instruction_list[#instruction_list + 1] = instruction
			end
		end

		program_table[name] = instruction_list
		minetest.log(dump(program_table))
		return true
	end
end

npc.proc.register_instruction = function(name, instruction)
	if instruction_table[name] ~= nil then
		return false
	else
		instruction_table[name] = instruction
		return true
	end
end

-----------------------------------------------------------------------------------
-- DSL Instructions
-----------------------------------------------------------------------------------
-- Variable instructions
npc.proc.register_instruction("npc:var:get", function(self, args)
	_npc.dsl.get_var(self, args.key)
end)

npc.proc.register_instruction("npc:var:set", function(self, args)
	_npc.dsl.set_var(self, args.key, args.value)
end)

-- Control instructions
npc.proc.register_instruction("npc:if", function(self, args) end)
npc.proc.register_instruction("npc:while", function(self, args) end)
npc.proc.register_instruction("npc:for", function(self, args) end)
npc.proc.register_instruction("npc:for_each", function(self, args) end)

npc.proc.register_instruction("npc:jump", function(self, args)
	self.process.current.instruction = args.pos
end)

npc.proc.register_instruction("npc:jump_if", function(self, args)
	local condition = args.expr
	if args.negate then condition = not condition end
	if condition then
		--minetest.log("Target instruction: "..dump(program_table[self.process.current.name][args.pos]))
		self.process.current.instruction = args.pos
	end
end)

npc.proc.register_instruction("npc:move:rotate", function(self, args)
	local dir = vector.dir(self.object:get_pos(), args.target_pos)
	local yaw = minetest.dir_to_yaw(dir)
	self.object:set_yaw(yaw)
end)

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Process API
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
npc.proc.execute_program = function(self, name, args)
	-- Enqueue process
	self.process.queue[#self.process.queue + 1] = {
		name = name,
		args = args,
		instruction = 1
	}

	self.process.current.key = (self.process.current.key + 1) % 100

	self.process.current = self.process.queue[#self.process.queue]
end

_npc.proc.execute_instruction = function(self, name, raw_args)
	assert(instruction_table[name] ~= nil)
	local args = {}
	if raw_args then
		for key,value in pairs(raw_args) do
			args[key] = _npc.dsl.evaluate_argument(self, value, raw_args)
		end
	end

	minetest.log("Instruction name: "..dump(name))
	minetest.log("Instruction args: "..dump(args))

	instruction_table[name](self, args)
	if name == "npc:jump"
		or name == "npc:jump_if"
		or name == "npc:var:get"
		or name == "npc:var:set" then
		-- Execute next instruction now if possible
		self.process.current.instruction = self.process.current.instruction + 1
		local instruction = program_table[self.process.current.name][self.process.current.instruction]
		if instruction then
			_npc.proc.execute_instruction(self, instruction.name, instruction.args)
		end
	end
end

npc.proc.enqueue_process = function(self, name, args)
	-- Enqueue process
	self.process.queue[self.process.queue_tail] = {
		id = self.process.key,
		name = name,
		args = args,
		instruction = 1
	}

	self.process.current.key = (self.process.current.key + 1) % 100

	local next_tail = (self.process.queue_tail + 1) % 100
	if next_tail == 0 then next_tail = 1 end
	self.process.queue_tail = next_tail

	-- If current process is state process, execute the new process immediately
	-- TODO: Check if this actually works
	if self.process.current.name == self.process.state.name then
		self.process.current = self.process.queue[self.process.queue_head]
	end
end

npc.proc.set_state_process = function(self, name, args)
	self.process.state.id = self.process.key
	self.process.state.name = name
	self.process.state.args = args
end

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Built-in instructions
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------

-- Stupid program that walks on a square
npc.proc.register_program("sample:stupid", {
	{name = "npc:for", args = {
		initial_value = 0,
		step_increase = 2,
		expr = {left="@local.for_index", op="<=", right=6},
		loop_instructions = {
			{name = "builtin:walk_step", args = {dir = "@local.for_index"}}
		}
	}}
})


-- Sample state program
npc.proc.register_program("builtin:idle", {
	{name = "builtin:stand"},
	{name = "npc:for_each", args = {
			array = "@env.objects",
			loop_instructions = {
				{name = "npc:if", args = {
					expr = function(self)
						minetest.log("Self data: "..dump(self.data))
						local object = self.data.proc[self.process.current.id].for_value
						if object then
							local object_pos = object:get_pos()
							local self_pos = self.object:get_pos()
							return vector.distance(object_pos, self_pos) < 4
						end
						return false
					end,
					true_instructions = {
						{name = "npc:move:rotate", args={target_pos="@local.for_value"}}
					}}
				}
			}
		}
	}
})

-- Sample walk program
npc.proc.register_instruction("builtin:stand", function(self, args)
	self.object:set_velocity({x=0, y=0, z=0})
	self.object:set_animation({
        x = npc.ANIMATION_STAND_START,
        y = npc.ANIMATION_STAND_END},
        30, 0)
end)

npc.proc.register_instruction("builtin:walk_step", function(self, args)

	local speed = 1
	local vel = {}
	local dir = args.dir
	minetest.log("dir: "..dump(dir))
	if dir == 0 then
        vel = {x=0, y=0, z=speed}
    elseif dir == 1 then
        vel = {x=speed, y=0, z=speed}
    elseif dir == 2 then
        vel = {x=speed, y=0, z=0}
    elseif dir == 3 then
        vel = {x=speed, y=0, z=-speed}
    elseif dir == 4 then
        vel = {x=0, y=0, z=-speed}
    elseif dir == 5 then
        vel = {x=-speed, y=0, z=-speed}
    elseif dir == 6 then
        vel = {x=-speed, y=0, z=0}
    elseif dir == 7 then
        vel = {x=-speed, y=0, z=speed }
    end


	local yaw = minetest.dir_to_yaw(vector.direction(self.object:get_pos(), vector.add(self.object:get_pos(), vel)))
	self.object:set_yaw(yaw)
	self.object:set_velocity(vel)
	self.object:set_animation({
        x = npc.ANIMATION_WALK_START,
        y = npc.ANIMATION_WALK_END},
        30, 0)
end)

npc.proc.register_program("builtin:walk_example", {
	{name = "builtin:walk_step", args = {dir = 0}},
	{name = "builtin:walk_step", args = {dir = 0}},
	{name = "builtin:walk_step", args = {dir = 0}},
	{name = "builtin:walk_step", args = {dir = 2}},
	{name = "builtin:stand"}
})

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Lua Entity Callbacks															 --
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
local do_step = function(self, dtime)

	self.timers.node_below_value = self.timers.node_below_value + dtime
	self.timers.objects_value = self.timers.objects_value + dtime
	self.timers.proc_value = self.timers.proc_value + dtime
	-- Check node below NPC
	if (self.timers.node_below_value > self.timers.node_below_value) then
		local current_pos = self.object:get_pos()
		self.data.env.node_on = minetest.get_node_or_nil({x=current_pos.x, y=current_pos.y-1, z=current_pos.z})
	end

	-- Get objects around NPC on radius
	if (self.timers.objects_value > self.timers.objects_int) then
		self.data.env.objects = minetest.get_objects_inside_radius(self.object:get_pos(), self.data.env.view_range)
	end

	-- Process queue
	if (self.timers.proc_value > self.timers.proc_int) then
		self.timers.proc_value = 0
		--minetest.log("Process: "..dump(self.process))

		-- Check if there is a current process
		if self.process.current.name ~= nil then

			-- Check if there is a next instruction
			if self.process.current.instruction > #program_table[self.process.current.name] then
				-- If process is state process, reset instruction counter
				if self.process.current.name == self.process.state.name then
					self.process.current.instruction = 1
				else
					-- No more instructions, deque process
					local next_head = (self.process.queue_head + 1) % 100
					if next_head == 0 then next_head = 1 end
					self.process.queue[self.process.queue_head] = nil
					self.process.queue_head = next_head
					self.process.current.name = nil
					self.process.current.instruction = -1
				end
				-- Check if no more processes in queue
				if self.process.queue_tail - self.process.queue_head == 0 then
					-- Execute state process, if present
					if self.process.state.name ~= nil then
						self.process.current.id = self.process.state.id
						self.process.current.name = self.process.state.name
						self.process.current.args = self.process.state.args
						self.process.current.instruction = 1
					end
				else
					-- Execute next process in queue
					-- The deque should reduce the #self.process.queue
					self.process.current = self.process.queue[self.process.queue_head]
				end
			end
		else
			-- Check if there is a process in queue
			if self.process.queue_tail - self.process.queue_head ~= 0 then
				self.process.current = self.process.queue[self.process.queue_head]

			-- Check if there is a state process
			elseif self.process.state.name ~= nil then
				self.process.current.id = self.process.state.id
				self.process.current.name = self.process.state.name
				self.process.current.args = self.process.state.args
				self.process.current.instruction = 1
			end
		end

		-- Execute next instruction, if available
		if self.process.current.instruction > -1 then
			local instruction =
				program_table[self.process.current.name][self.process.current.instruction]
			_npc.proc.execute_instruction(self, instruction.name, instruction.args)
			self.process.current.instruction = self.process.current.instruction + 1
		end
	end

end

minetest.register_entity("anpc:npc", {
	hp_max = 1,
	visual = "mesh",
	mesh = "character.b3d",
	textures = {
		"default_male.png",
	},
	visual_size = {x = 1, y = 1, z = 1},
	collisionbox = {-0.6,-0.6,-0.6, 0.6,0.6,0.6},
	physical = true,
	on_activate = function(self, staticdata)

		minetest.log("Data: "..staticdata)

		if staticdata ~= nil and staticdata ~= "" then
			local cols = string.split(staticdata, "|")
			self["timers"] = minetest.deserialize(cols[1])
			self["process"] = minetest.deserialize(cols[2])
			self["data"] = minetest.deserialize(cols[3])
		else

			self.timers = {
				node_below_value = 0,
				node_below_int = 0.5,
				objects_value = 0,
				objects_int = 1,
				proc_value = 0,
				proc_int = 0.5
			}

			self.process = {
				key = 0,
				current = {
					id = -1,
					name = nil,
					args = {},
					instruction = -1
				},
				state = {
					id = -1,
					name = nil,
					args = {}
				},
				queue_head = 1,
				queue_tail = 1,
				queue = {}
			}

			self.data = {
				env = {},
				global = {},
				proc = {}
			}

			self.data.env.view_range = 12

			self.schedule = {}

			self.state = {
				walk = {
					target_pos = {}
				}
			}
		end

	end,
	get_staticdata = function(self)

		local result = ""
		if self.timers then
			result = result..minetest.serialize(self.timers).."|"
		end

		if self.process then
			result = result..minetest.serialize(self.process).."|"
		end

		if self.data then
			self.data.env.objects = nil
			result = result..minetest.serialize(self.data).."|"
		end

		return result

	end,
	on_step = do_step,
	on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
		minetest.log(dump(self))
	end
})

minetest.register_craftitem("anpc:npc_spawner", {
	description = "Spawner",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		local spawn_pos = minetest.pointed_thing_to_face_pos(user, pointed_thing)
		spawn_pos.y = spawn_pos.y + 1
		local entity = minetest.add_entity(spawn_pos, "anpc:npc")
		if entity then
			npc.proc.set_state_process(entity:get_luaentity(), "builtin:idle")
		else
			minetest.remove_entity(entity)
		end
	end
})

minetest.register_craftitem("anpc:npc_walker", {
	description = "Walker",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			npc.proc.enqueue_process(pointed_thing.ref:get_luaentity(), "sample:stupid", {})
		end
	end
})
