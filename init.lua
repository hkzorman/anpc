npc = {
	proc = {}
}

local _npc = {
	dsl = {},
	proc = {},
	env = {},
	move = {}
}

local path = minetest.get_modpath("anpc")
dofile(path .. "/pathfinder.lua")

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
local node_table = {}
local animation_table = {}

local programs = {}
local instructions = {}

-- At least left and op are necessary
_npc.dsl.evaluate_boolean_expression = function(self, expr, args)
	local operator = expr.op
	local source = _npc.dsl.evaluate_argument(self, expr.left, args)
	local target = _npc.dsl.evaluate_argument(self, expr.right, args)
	
	--minetest.log("Boolean expression: "..dump(expr))
	
	--minetest.log("Source: "..dump(source))
	--minetest.log("Target: "..dump(target))
	
	if operator == "==" then
		return source == target
	elseif operator == ">=" then
		return source >= target
	elseif operator == "<=" then
		return source <= target
	elseif operator == "~=" then
		--minetest.log("Bool expression eval: "..dump(source ~= target))
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
			--minetest.log("Expression values length: "..dump(#expression_values))
			--minetest.log("Expression: "..dump(expression_values))
			if storage_type == "@local" then
				if self.data.proc[self.process.current.id] then
					result = _npc.dsl.get_var(self, expression_values[2])
				end
			elseif storage_type == "@args" then
				result = self.process.current.args[expression_values[2]]
			elseif storage_type == "@global" then
				result = self.data.global[expression_values[2]]
			elseif storage_type == "@env" then
				result = self.data.env[expression_values[2]]
			elseif storage_type == "@random" then
				return math.random(expression_values[2], expression_values[3])
			end
			if #expression_values > 2 then
				--minetest.log("Returning: "..dump(result[tonumber(expression_values[3])]))
				return result[tonumber(expression_values[3])]
			else
				return result
			end
			--minetest.log("Expression: "..dump(expression_values))

		end
	elseif type(expr) == "table" and expr.left and expr.op then
		return _npc.dsl.evaluate_boolean_expression(self, expr, args)
	elseif type(expr) == "function" then
		return expr(self, args)
	end
	return expr
end

-- TODO: Might not be needed
npc.eval = function(self, expr, args)
	return _npc.dsl.evaluate_argument(self, expr, args)
end

-- Nil-safe set variable function, plus handling of userdata variables
_npc.dsl.set_var = function(self, key, value, userdata_type)
	if self.data.proc[self.process.current.id] == nil then
		self.data.proc[self.process.current.id] = {}
	end
	
	if type(value) == "userdata" then
		if userdata_type then
			if userdata_type == "object" then
				local obj = value
				if obj then
					-- Check if player
					if obj:is_player() then
					
						-- Store tracking record
						self.data.proc[self.process.current.id][key] = {
							userdata_type = "object",
							obj_type = "player",
							obj_attr = obj:get_player_name()
						}
						
					elseif obj:get_luaentity() then
						-- Generate a tracking ID for entities
						local id = "anpc:track:id:"..tostring(math.random(1000, 9999))
						if obj:get_luaentity().anpc_track_id then
							id = obj:get_luaentity().anpc_track_id
						end
						
						obj:get_luaentity().anpc_track_id = id
						-- Store tracking record
						self.data.proc[self.process.current.id][key] = {
							userdata_type = "object",
							obj_type = "object",
							obj_attr = {
								id = id,
								distance = vector.distance(self.object:get_pos(), obj:get_pos()) * 3
							}
						}
						
						-- Store actual object so that lookups are simpler
						self.data.temp[id] = obj
					end
				end
				return
			else
				-- TODO: Handle other userdata types
				assert(value.to_table and value.from_table)
				value = {userdata_type=userdata_type, value=value.to_table}
			end
		end
	end
	
	--minetest.log("Keys: "..dump(self.process.current.id)..", "..dump(key))
	self.data.proc[self.process.current.id][key] = value
end

_npc.dsl.get_var = function(self, key)
	if self.data.proc[self.process.current.id] == nil then return nil end
	local result = self.data.proc[self.process.current.id][key]
	
	-- TODO: Add handling for other types of userdata
	if type(result) == "table" and result.userdata_type == "object" then
		if result.obj_type == "player" then
			result = minetest.get_player_by_name(result.obj_attr)
		elseif result.obj_type == "object" then
			-- Check if object is in temp storage
			if self.data.temp[result.obj_attr.id] then
				return self.data.temp[result.obj_attr.id]
			end
			-- Check if object is in the current objects
			for i = 1, #self.data.env.objects do
				if self.data.env.objects[i]
					and self.data.env.objects[i]:get_luaentity() 
					and self.data.env.objects[i]:get_luaentity().anpc_track_id
					and self.data.env.objects[i]:get_luaentity().anpc_track_id == result.obj_attr.id then
					return self.data.env.objects[i]
				end
			end
			-- Try to search object
			local nearby_objs = minetest.get_objects_inside_radius(self.object:get_pos(), result.obj_attr.distance)
			for i = 1, #nearby_objs do
				if nearby_objs[i] 
					and nearby_objs[i]:get_luaentity() 
					and nearby_objs[i]:get_luaentity().anpc_track_id
					and nearby_objs[i]:get_luaentity().anpc_track_id == result.obj_attr.id then
					result = nearby_objs[i]
					break
				end
			end
			-- Not found, return nil
			result = nil
		end
	end
	--minetest.log("Actual: "..dump(self.data.proc[self.process.current.id][key]))
	--minetest.log("Returning: "..dump(result))
	return result
end

_npc.env.node_operate = function(self, args)
	local node_pos = args.pos
	local node = minetest.get_node_or_nil(node_pos)
	if (node) then
		if (node_table[node.name] == nil) then return end
	
		local result = node_table[node.name].operation(self, args)
		return result
	end
	return nil
end

_npc.env.node_get_property = function(self, args)
	local node_pos = args.pos
	local node = minetest.get_node_or_nil(node_pos)
	if (node) then
		if (node_table[node.name] == nil) then return end
	
		local result = node_table[node.name].properties[args.property](self, args)
		return result
	end
	return nil
end

_npc.env.node_get_accessing_pos = function(_, args)

	local target_node = minetest.get_node_or_nil(args.pos)
	if (target_node) then
		if npc.pathfinder.is_good_node(target_node, {}) 
			== npc.pathfinder.node_types.non_walkable then
			
			-- First of all, try to see if the position in front of the node is walkable
			if (target_node.name 
				and minetest.registered_nodes[target_node.name].paramtype2 == "facedir") then
				
				local front_pos = vector.add(args.pos, vector.multiply(minetest.facedir_to_dir(target_node.param2), -1))
				local front_node = minetest.get_node_or_nil(front_pos)
				if front_node then
					if npc.pathfinder.is_good_node(front_node, {})
						 == npc.pathfinder.node_types.walkable then
						 return front_pos
					end
				end
			end
			
			-- Search all surrounding nodes
			local count = 0
			while count < 4 do
				local pos = args.pos
				if count == 0 then
					pos.x = pos.x + 1
				elseif count == 1 then
					pos.z = pos.z + 1
				elseif count == 2 then
					pos.x = pos.x -1
				elseif count == 3 then
					pos.z = pos.z -1
				end
				
				local node = minetest.get_node(pos)
				if node and node.name and minetest.registered_nodes[node.name].walkable == false then 
					return pos
				end
				count = count + 1
			end
		else
			return args.pos
		end
	end
	
	return nil
end

_npc.env.node_find = function(self, args)
	
	local start_pos = args.pos or vector.round(self.object:get_pos())
	local radius = args.radius or self.data.env.view_range
	local min_pos = args.min_pos
	local max_pos = args.max_pos
	
	-- Calculate area if just radius given
	if (not min_pos) and (not max_pos) then
		local y_radius = args.y_radius or radius
		local y_offset = args.y_offset or 0
		min_pos = {x=start_pos.x - radius, y=(start_pos.y + y_offset) - y_radius, z=start_pos.z - radius}
		max_pos = {x=start_pos.x + radius, y=(start_pos.y + y_offset) + y_radius, z=start_pos.z + radius}
	end
	
	--minetest.log("Searching for "..dump(args.nodenames).."\nin area: "..minetest.pos_to_string(min_pos)..", "..minetest.pos_to_string(max_pos))
	
	local result = minetest.find_nodes_in_area(min_pos, max_pos, args.nodenames)
	--minetest.log("Found: "..dump(result))
	return result
end

_npc.env.node_npc_is_owner = function(self, args)
	local meta = minetest.get_meta(args.pos)
	if (meta) then
		local owner = meta:get_string("anpc:owner")
		if owner == self.npc_id then
			return true
		else
			return false
		end
	end
	return nil
end

_npc.env.node_npc_is_user = function(self, args)
	local meta = minetest.get_meta(args.pos)
	if (meta) then
		local user = meta:get_string("anpc:user")
		if user == self.npc_id then
			return true
		else
			return false
		end
	end
	return nil
end

_npc.env.node_set_owned = function(self, args)
	local meta = minetest.get_meta(args.pos)
	if (meta) then
		local owner = meta:get_string("anpc:owner")
		if (owner == self.npc_id) then
			if (args.value == true) then
				return true
			else
				-- Remove attribute, set as un-owned
				meta:set_string("anpc:owner", nil)
				return true
			end
		elseif (owner ~= nil) then
			-- Unable to change ownership as NPC is not the owner
			return false
		else
			meta:set_string("anpc:owner", self.npc_id)
			meta:set_string("infotext", "Owned by NPC: "..dump(self.npc_id))
			return true
		end
	end
end

_npc.env.node_set_used = function(self, args)
	local meta = minetest.get_meta(args.pos)
	if (meta) then
		local user = meta:get_string("anpc:user")
		if (user == self.npc_id) then
			if (args.value == true) then
				return true
			else
				-- Remove attribute, set as unused
				meta:set_string("anpc:user", nil)
				return true
			end
		elseif (user ~= nil) then
			-- Unable to change user as NPC is not the user
			return false
		else
			meta:set_string("anpc:user", self.npc_id)
			return true
		end
	end
end

_npc.env.node_store_add = function(self, args)

end

_npc.env.node_store_get = function(self, args)

end

_npc.env.node_store_remove = function(self, args)

end


-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Program and Instruction Registration
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Returns an array of instructions
_npc.proc.process_instruction = function(instruction, original_list_size, function_index_map)
	local instruction_list = {}
	local is_function = false
	
	if instruction.name == "npc:if" then
		
		-- Process true instructions if available
		local true_instrs = {}
		for i = 1, #instruction.args.true_instructions do
			assert(not instruction.args.true_instructions[i].declare, 
				"Function declaration cannot be done inside another instruction.")
			local instrs = _npc.proc.process_instruction(instruction.args.true_instructions[i], 
				#true_instrs + original_list_size + 1)
			for j = 1, #instrs do
				true_instrs[#true_instrs + 1] = instrs[j]
			end
		end
		
		-- Insert jump to skip true instructions if expr is false
		local offset = 0
		if instruction.args.false_instructions then offset = 1 end
		
		instruction_list[#instruction_list + 1] = {
			name = "npc:jump_if", 
			args = {
				expr = instruction.args.expr,
				pos =  #true_instrs + offset,
				negate = true,
				offset = true
			}
		}
		
		-- Insert all true_instructions into result
		for j = 1, #true_instrs do
			instruction_list[#instruction_list + 1] = true_instrs[j]
		end
		
		-- False instructions
		if instruction.args.false_instructions then
		
			-- Process false instructions if available
			local false_instrs = {}
			for i = 1, #instruction.args.false_instructions do
				assert(not instruction.args.false_instructions[i].declare, 
					"Function declaration cannot be done inside another instruction.")
				local instrs = _npc.proc.process_instruction(instruction.args.false_instructions[i], 
					#false_instrs + #instruction_list + original_list_size + 1)
				for j = 1, #instrs do
					false_instrs[#false_instrs + 1] = instrs[j]
				end
			end
			
			-- Insert jump to skip false instructions if expr is true
			instruction_list[#instruction_list + 1] = {
				name = "npc:jump", 
				args = {
					pos = #false_instrs,
					offset = true 
				}
			}
			
			-- Insert all false_instructions
			for j = 1, #false_instrs do
				instruction_list[#instruction_list + 1] = false_instrs[j]
			end
			
		end
		
	elseif instruction.name == "npc:switch" then
	
		for i = 1, #instruction.args.cases do
			
			-- Process each case instructions
			local case_instrs = {}
			for j = 1, #instruction.args.cases[i].instructions do
				assert(not instruction.args.cases[i].instructions[j].declare, 
					"Function declaration cannot be done inside another instruction.")
				local instrs = _npc.proc.process_instruction(instruction.args.cases[i].instructions[j], 
					#case_instrs + original_list_size + 1)
				for k = 1, #instrs do
					case_instrs[#case_instrs + 1] = instrs[k]
				end
			end
			
			instruction_list[#instruction_list + 1] = {
				name = "npc:jump_if", 
				args = {
					expr = instruction.args.cases[i].case,
					pos =  #case_instrs,
					negate = true,
					offset = true
				}
			}
			
			-- Insert all case instructions
			for j = 1, #case_instrs do
				instruction_list[#instruction_list + 1] = case_instrs[j]
			end
			
		end
		
	elseif instruction.name == "npc:while" then
	
		-- Support time-based while loop.
		-- The loop will execute as many times as possible within the given time.
		-- The given time is in seconds, no smaller resolution supported.
		if instruction.args.time then
			-- Add instruction to start instruction timer
			instruction_list[#instruction_list + 1] = {name = "npc:timer:instr:start"}
			-- Modify expression
			instruction.args.expr = {
				left = function(self) return self.timers.instr_timer end,
				op = "<=",
				right = instruction.args.time
			}
		end
	
		-- The below will actually set the jump to the instruction previous
		-- to the relevant one - this is done because after the jump
		-- instruction is executed, the instruction counter will be increased
		local loop_start = #instruction_list + original_list_size
		-- Insert all loop instructions
		for i = 1, #instruction.args.loop_instructions do
			assert(not instruction.args.loop_instructions[i].declare, 
				"Function declaration cannot be done inside another instruction.")
			local instrs = _npc.proc.process_instruction(instruction.args.loop_instructions[i], 
				loop_start)
			for j = 1, #instrs do
				instruction_list[#instruction_list + 1] = instrs[j]
			end
		end
		
		-- Insert conditional to loop back if expr is true
		instruction_list[#instruction_list + 1] = {
			name = "npc:jump_if", 
			args = {
				expr = instruction.args.expr, 
				pos = loop_start - 1, 
				negate = false
			},
			loop_end = true
		}
		
		-- Add instruction to stop timer
		if instruction.args.time then
			instruction_list[#instruction_list + 1] = {name = "npc:timer:instr:stop"}
		end
		
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
		local loop_start = #instruction_list + original_list_size
		-- Insert all loop instructions
		for i = 1, #instruction.args.loop_instructions do
			assert(not instruction.args.loop_instructions[i].declare, 
				"Function declaration cannot be done inside another instruction.")
			local instrs = _npc.proc.process_instruction(instruction.args.loop_instructions[i], 
				loop_start)
			for j = 1, #instrs do
				instruction_list[#instruction_list + 1] = instrs[j]
			end
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
				pos = loop_start - 1, 
				negate = false
			},
			loop_end = true
		}
	
	-- TODO: Remove for each?
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
				value = function(self, args)
					local array = _npc.dsl.evaluate_argument(instruction.args.array)
					return array[1]
				end
			}
		}
	
		-- The below will actually set the jump to the instruction previous
		-- to the relevant one - this is done because after the jump
		-- instruction is executed, the instruction counter will be increased
		local loop_start = #instruction_list + original_list_size
		-- Insert all loop instructions
		for i = 1, #instruction.args.loop_instructions do
			assert(not instruction.args.loop_instructions[i].declare, 
				"Function declaration cannot be done inside another instruction.")
			local instrs = _npc.proc.process_instruction(instruction.args.loop_instructions[i], 
				loop_start)
			for j = 1, #instrs do
				instruction_list[#instruction_list + 1] = instrs[j]
			end
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
					local array = _npc.dsl.evaluate_argument(instruction.args.array)
					return array[self.data.proc[self.process.current.id].for_index]
				end
			}
		}
		
		-- Insert conditional to loop back if expr is true
		instruction_list[#instruction_list + 1] = {
			name = "npc:jump_if", 
			args = {
				expr = {
					left = "@local.for_index", 
					op = "<=", 
					right = function(self, args)
						return #self.data.proc[self.process.current.id].for_array
					end
				},
				pos = loop_start - 1, 
				negate = false
			},
			loop_end = true
		}
		
		-- Remove the array and the for-value variables
		instruction_list[#instruction_list + 1] = 
			{name = "npc:var:set", args = {key="for_value", value=nil}}
	
	elseif instruction.name == "npc:wait" then
	
		-- This is not a busy wait, this modifies the interval in two instructions
		local wait_time = _npc.dsl.evaluate_argument(self, instruction.args.time, nil) - 1
		instruction_list[#instruction_list + 1] = 
			{name="npc:set_proc_interval", args={value = wait_time}}
		instruction_list[#instruction_list + 1] =
			{name="npc:set_proc_interval", args={value = 1}}
	
	elseif not instruction.name and instruction.declare then
	
		-- Store function index in map
		local func_index = #instruction_list + original_list_size
		function_index_map[instruction.declare] = func_index
	
		minetest.log("Function declaration: "..dump(instruction))
	
		-- Process all instructions
		for i = 1, #instruction.instructions do
			local instrs = _npc.proc.process_instruction(instruction.instructions[i], 
				func_index)
			for j = 1, #instrs do
				instruction_list[#instruction_list + 1] = instrs[j]
			end
		end
		
		is_function = true
		
	elseif not instruction.name and instruction.call then
		
		-- Validate we are calling an existing instruction
		local index = function_index_map[instruction.call]
		assert(index, "Function "..instruction.call.." not found")
		
		instruction_list[#instruction_list + 1] = 
			{name="npc:call", args = {name = instruction.call, index = index, key = instruction.key}}
		
	elseif instruction.name == "npc:timer:register" then
	
		-- Validations
		assert(instruction.args.name, "Timer needs a name")
		local timer_name = "_timer:"..instruction.args.name
		
		-- Add a return instruction
		local timer_func_instr = instruction.args.instructions
		timer_func_instr[#timer_func_instr + 1] = {name="npc:return"}
		
		-- Process all instructions, and register function
		local all_instructions, timer_func_index = _npc.proc.process_instruction({
			declare = timer_name, 
			instructions = instruction.args.instructions
		}, original_list_size, function_index_map)
		
		-- Add all instructions
		for i = 1, #all_instructions do
			instruction_list[#instruction_list + 1] = all_instructions[i]
		end
		
		instruction_list[#instruction_list + 1] = {name="npc:timer:register", args = {
			name = instruction.args.name,
			interval = instruction.args.interval,
			initial_value = instruction.args.initial_value,
			times_to_run = instruction.args.times_to_run,
			function_index = original_list_size
		}}
	
		is_function = true
	else
		-- Insert the instruction
		instruction_list[#instruction_list + 1] = instruction
	end
	
	return instruction_list, is_function
end

npc.proc.register_program = function(name, raw_instruction_list)
	if program_table[name] ~= nil then
		return false
	else
		-- Interpret program queue
		-- Convert if, for and while to index-jump instructions
		local instruction_list = {}
		local function_table = {}
		-- This is zero-based as the initial instruction is always initial_instruction - 1
		-- TODO: Really?
		-- TODO: Seems like
		local initial_instruction = 0
		for i = 1, #raw_instruction_list do
			-- The following instructions are only for internal use
			assert(raw_instruction_list[i].name ~= "npc:jump", 
				"Instruction 'npc:jump' is only for internal use and cannot be explicitly invoked from a program.")
			assert(raw_instruction_list[i].name ~= "npc:jump_if", 
				"Instruction 'npc:jump_if' is only for internal use and cannot be explicitly invoked from a program.")
			assert(raw_instruction_list[i].name ~= "npc:set_process_interval", 
				"Instruction 'npc:set_process_interval' is only for internal use and cannot be explicitly invoked from a program.")
			assert(raw_instruction_list[i].name ~= "npc:timer:instr:start", 
				"Instruction 'npc:timer:instr:start' is only for internal use and cannot be explicitly invoked from a program.")
			assert(raw_instruction_list[i].name ~= "npc:timer:instr:stop", 
				"Instruction 'npc:timer:instr:stop' is only for internal use and cannot be explicitly invoked from a program.")
			
			local instructions, is_function = _npc.proc.process_instruction(raw_instruction_list[i], 
				#instruction_list + 1, function_table)
			for j = 1, #instructions do
				instruction_list[#instruction_list + 1] = instructions[j]
			end
			
			if is_function then
				-- Count the number of instructions inside function
				initial_instruction = initial_instruction + #instructions
			end
		end
		
		if initial_instruction == 0 then initial_instruction = 1 end
	
		program_table[name] = {
			function_table = function_table,
			initial_instruction = initial_instruction,
			instructions = instruction_list
		}
		
		minetest.log("Registered and compiled program '"..dump(name).."':")
		for i = 1, #instruction_list do
			minetest.log("["..dump(i).."] = "..dump(instruction_list[i]))
		end
		
		--minetest.log(dump(program_table))
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

npc.proc.register_operable_node = function(name, categories, properties, operation)
	if node_table[name] ~= nil then
		return false
	else
		node_table[name] = {
			categories = categories,
			properties = properties,
			operation = operation
		}
		return true
	end
end

--TODO: Implement
npc.register_model_animation = function(name, animation_table)
	--if animation_table[name] ~=
end


-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Core Instructions
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Variable instructions
npc.proc.register_instruction("npc:var:get", function(self, args)
	_npc.dsl.get_var(self, args.key)
end)

npc.proc.register_instruction("npc:var:set", function(self, args)
	_npc.dsl.set_var(self, args.key, args.value, args.userdata_type)
end)

-- Control instructions
npc.proc.register_instruction("npc:jump", function(self, args)
	if args.offset == true then
		self.process.current.instruction = self.process.current.instruction + args.pos
	else
		self.process.current.instruction = args.pos
	end
	
	minetest.log("Jumping to instruction: "..dump(program_table[self.process.current.name][self.process.current.instruction]))
end)

npc.proc.register_instruction("npc:jump_if", function(self, args)
	local condition = args.expr
	if args.negate == true then condition = not condition end
	--minetest.log("Jump-If: Expression: "..dump(args.expr))
	--minetest.log("Jump-If: Condition: "..dump(condition))
	if condition == true then
		if args.offset == true then
			self.process.current.instruction = self.process.current.instruction + args.pos
		else
			self.process.current.instruction = args.pos
		end
	
		--minetest.log("Jumping to instruction: "..dump(program_table[self.process.current.name][self.process.current.instruction]))
	end

end)

npc.proc.register_instruction("npc:break", function(self, args)
	for i = self.process.current.instruction + 1, #program_table[self.process.current.name].instructions do
		if program_table[self.process.current.name].instructions[i].loop_end then
			minetest.log("Found last instruction of loop to be: "..dump(program_table[self.process.current.name].instructions[i]))
			minetest.log("At pos: "..dump(i))
			self.process.current.instruction = i
			break
		end
	end
end)

npc.proc.register_instruction("npc:set_proc_interval", function(self, args)
	self.timers.proc_int = args.value
end)

-- Function instructions
npc.proc.register_instruction("npc:call", function(self, args)

	-- Insert entry into call stack
	if not self.data.proc[self.process.current.id]["_call_stack"] then
		self.data.proc[self.process.current.id]["_call_stack"] = {}
	end
	
	local top = #self.data.proc[self.process.current.id]["_call_stack"] + 1
	self.data.proc[self.process.current.id]["_call_stack"][top] = {
		key = args.key,
		index = args.index
	}
	
	self.process.current.instruction = args.index

end)

npc.proc.register_instruction("npc:return", function(self, args)

	local top = #self.data.proc[self.process.current.id]["_call_stack"]
	local stack_entry = self.data.proc[self.process.current.id]["_call_stack"][top]
	
	-- Set the variable, if needed
	if args.value and stack_entry.key then
		_npc.dsl.set_var(self, stack_entry.key, args.value)
	end
	
	-- Change current instruction pointer
	self.process.current.instruction = stack_entry.index
	
	-- Remove from stack
	self.data.proc[self.process.current.id]["_call_stack"][top] = nil

end)

npc.proc.register_instruction("npc:execute", function(self, args)
	npc.proc.execute_program(self, args.name, args.args)
end)

-- Timer instructions
npc.proc.register_instruction("npc:timer:register", function(self, args)
	if self.data.proc[self.process.current.id] == nil then
		self.data.proc[self.process.current.id] = {}
	end
	
	if self.data.proc[self.process.current.id]["_timers"] == nil then
		self.data.proc[self.process.current.id]["_timers"] = {}
	end
	
	self.data.proc[self.process.current.id]["_timers"][args.name] = {
		interval = args.interval,
		value = args.initial_value or 0,
		is_running = false,
		execution_count = 0,
		max_execution_count = args.times_to_run,
		function_index = args.timer_func_index
	}
end)

npc.proc.register_instruction("npc:timer:start", function(self, args)
	assert(args.name, "No timer name provided")
	self.data.proc[self.process.current.id]["_timers"][args.name].is_running = true
end)

npc.proc.register_instruction("npc:timer:stop", function(self, args)
	assert(args.name, "No timer name provided")
	self.data.proc[self.process.current.id]["_timers"][args.name].is_running = false
end)

npc.proc.register_instruction("npc:timer:instr:start", function(self, args)
	self.timers.instr_timer = 0
end)

npc.proc.register_instruction("npc:timer:instr:stop", function(self, args)
	self.timers.instr_timer = nil
end)

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Built-in instructions
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------

-----------------------------------------------------------------------------------
-- Environment-related instructions
-----------------------------------------------------------------------------------

npc.proc.register_instruction("npc:env:node:operate", 
	_npc.env.node_operate)

npc.proc.register_instruction("npc:env:node:get_property", 
	_npc.env.node_get_property)
	
npc.proc.register_instruction("npc:env:node:get_accessing_pos",
	_npc.env.node_get_accessing_pos)

npc.proc.register_instruction("npc:env:node:find", 
	_npc.env.node_find)
	
npc.proc.register_instruction("npc:env:node:is_owner", 
	_npc.env.node_npc_is_owner)
	
npc.proc.register_instruction("npc:env:node:is_user", 
	_npc.env.node_npc_is_user)

npc.proc.register_instruction("npc:env:node:set_owned", 
	_npc.env.node_set_owned)
	
npc.proc.register_instruction("npc:env:node:set_used", 
	_npc.env.node_set_used)

npc.proc.register_instruction("npc:env:node:place", function(self, args)
	local pos = args.pos
    local node = args.node
    local source = args.source or "forced"
    local bypass_protection = args.bypass_protection
    if bypass_protection == nil then bypass_protection = false end
    local play_sound = args.play_sound or true
    local node_at_pos = minetest.get_node_or_nil(pos)
    -- Check if position is empty or has a node that can be built to
    if node_at_pos and
    	(node_at_pos.name == "air" or minetest.registered_nodes[node_at_pos.name].buildable_to == true) then
        -- Check protection
        if (not bypass_protection and not minetest.is_protected(pos, self.npc_id))
                or bypass_protection == true then
            -- Take from inventory if necessary
            local place_item = false
            if source == "take" then
--                if npc.take_item_from_inventory(self, node, 1) then
--                    place_item = true
--                end
            elseif source == "take_or_forced" then
                --npc.take_item_from_inventory(self, node, 1)
                place_item = true
            elseif source == "forced" then
                place_item = true
            end
            -- Place node
            if place_item == true then
                -- Set mine animation
                self.object:set_animation({
                    x = npc.ANIMATION_MINE_START,
                    y = npc.ANIMATION_MINE_END},
                    self.animation.speed_normal, 0)
                -- Place node
                minetest.set_node(pos, {name=node})
                -- Play place sound
                if play_sound == true then
                    if minetest.registered_nodes[node].sounds then
                        minetest.sound_play(
                            minetest.registered_nodes[node].sounds.place,
                            {
                                max_hear_distance = 10,
                                object = self.object
                            }
                        )
                    end
                end
            end
        end
    end
end)

--TODO: Add calculation for surrounding air nodes if node is walkable
npc.proc.register_instruction("npc:env:find_path", function(self, args)

	local end_pos = args.end_pos
	local start_pos = args.start_pos or vector.round(self.object:get_pos())
	
	--minetest.log("Start pos: "..dump(start_pos))
	
	local path = npc.pathfinder.find_path(start_pos, end_pos, self, args.decorate)
	--minetest.log("Path found: "..dump(path))
	self.data.proc[self.process.current.id].current_path = path

end)

-- TODO: Finish implementation
-- This instruction prioritizes a certain object in the self.data.env.objects
-- array depending on the given criteria. The prioritized item will be swapped
-- with the first item in the array.
npc.proc.register_instruction("npc:env:prioritize", function(self, args)

	if (#self.data.env.objects < 1) then return end

	local distance = args.distance 		 -- Supported values: "min", "max", an integer number
	local entity_type = args.entity_type -- Supported values: "player", "npc", "monster"
	
	local self_pos = self.object:get_pos()
	local min_dist = vector.distance(self_pos, self.data.env.objects[1]:get_pos())
	local max_dist = vector.distance(self_pos, self.data.env.objects[1]:get_pos())
	
	for i = 1, #self.data.env.objects do
		if self.data.env.objects[i]
			and self.data.env.objects[i]:get_luaentity() then
			local pos = self.data.env.objects[i]:get_pos()
			local is_player = self.data.env.objects[i]:is_player()
			local distance = vector.distance(self_pos, pos)
			
			if (type(distance) == "string") then
				if distance == "min" then
					if distance < min_dist then
					
					end
				elseif (distance == "max") then
					
				end
			elseif (type(distance) == "number") then
				
			end
		end
	end
end)

-----------------------------------------------------------------------------------
-- Movement instructions
-----------------------------------------------------------------------------------

_npc.move.set_animation = function(self, args)
	--local animation_name = 
end

npc.proc.register_instruction("npc:move:set_animation", 
	_npc.move.set_animation)

npc.proc.register_instruction("npc:move:stand", function(self, args)
	self.object:set_velocity({x=0, y=0, z=0})
	self.object:set_animation({
        x = npc.ANIMATION_STAND_START,
        y = npc.ANIMATION_STAND_END},
        30, 0)
end)

npc.proc.register_instruction("npc:move:rotate", function(self, args)
	local dir = vector.direction(self.object:get_pos(), args.target_pos)
	local yaw = minetest.dir_to_yaw(dir)
	self.object:set_yaw(yaw)
end)

npc.proc.register_instruction("npc:move:move_to", function(self, args)
	self.object:move_to(args.pos, true)
end)

-- This instruction sets the NPC in motion towards a specific direction at
-- a specific speed. Notice that this instruction *doesn't* provides 
-- pathfinding. Also, notice this doesn't stops the NPC once in motion.
-- The stop has to be done separately by using the instruction `npc:move:stand`.
-- There are two different ways to use it:
--   1. If a `target_pos` is provided, the NPC will rotate to that position
--      and will walk towards it.
--   2. If a `yaw` is provided, the NPC will rotate according to the yaw
--      and walk
-- TODO: Allow random yaw to be generated by instruction

npc.proc.register_instruction("npc:move:walk", function(self, args)
	local speed = args.speed or 2
	local cardinal_dir = args.cardinal_dir
	local velocity = nil
	local self_pos = args.start_pos or vector.round(self.object:get_pos())
	local trgt_pos = args.target_pos
	
	if (cardinal_dir) then
		if cardinal_dir == 0 then
        	velocity = {x=0, y=0, z=1}
		elseif cardinal_dir == 1 then
		    velocity = {x=1, y=0, z=1}
		elseif cardinal_dir == 2 then
		    velocity = {x=1, y=0, z=0}
		elseif cardinal_dir == 3 then
		    velocity = {x=1, y=0, z=-1}
		elseif cardinal_dir == 4 then
		    velocity = {x=0, y=0, z=-1}
		elseif cardinal_dir == 5 then
		    velocity = {x=-1, y=0, z=-1}
		elseif cardinal_dir == 6 then
		    velocity = {x=-1, y=0, z=0}
		elseif cardinal_dir == 7 then
		    velocity = {x=-1, y=0, z=1}
		end
		
		trgt_pos = vector.add(self_pos, velocity)
		velocity = vector.multiply(velocity, speed)
	end

	local dir = vector.direction(self_pos, trgt_pos)
	local yaw = args.yaw or minetest.dir_to_yaw(dir)
	if not velocity then velocity = vector.multiply(dir, speed) end
	
	self.object:set_yaw(yaw)
	self.object:set_velocity(velocity)
	self.object:set_animation({
        x = npc.ANIMATION_WALK_START,
        y = npc.ANIMATION_WALK_END},
        30, 0)
end)

npc.proc.register_instruction("npc:move:walk_to_pos", function(self, args)
	local result = false
	local self_pos = vector.round(self.object:get_pos())
	local trgt_pos = args.target_pos
	local speed = args.speed or 2
	
	-- Calculate process timer interval
	if (speed ~= 2) then
		self.data.proc[self.process.current.id]["_prev_proc_timer_value"] = self.timers.proc_int
		self.timers.proc_int = 1/speed
	end
	
	local prev_proc_timer_value = self.data.proc[self.process.current.id]["_prev_proc_timer_value"] or 0.5
	
	-- Return if target pos is same as start pos
	if self_pos.x == trgt_pos.x
		and self_pos.z == trgt_pos.z then 
		minetest.log("Same self pos and target pos")
		-- Stop NPC
		self.object:set_velocity({x = 0, y = 0, z = 0})
		-- TODO: Change for a registered animation
		self.object:set_animation({
		    x = npc.ANIMATION_STAND_START,
		    y = npc.ANIMATION_STAND_END},
		    30, 0)
		if args.original_target_pos and 
			(args.original_target_pos.x ~= trgt_pos.x or args.original_target_pos.z ~= trgt_pos.z) then
			self.object:set_yaw(minetest.dir_to_yaw(vector.direction(trgt_pos, args.original_target_pos)))
		end
		-- Restore process timer interval
		self.timers.proc_int = prev_proc_timer_value
		return true 
	end
	
	-- Find path
	if args.check_end_pos_walkable == true then
		trgt_pos = _npc.env.node_get_accessing_pos(trgt_pos)
	end
	
	-- Correct self pos if NPC is lagging behind
	local prev_trgt_pos = self.data.proc[self.process.current.id]["_prev_trgt_pos"]
	if prev_trgt_pos ~= nil then
		local dist = vector.distance(prev_trgt_pos, self_pos) 
		if (dist > 0.25) then
			-- TODO Check that we are not going backwards?
			self.object:move_to({x=prev_trgt_pos.x, y=prev_trgt_pos.y, z=prev_trgt_pos.z}, true)
			self_pos = prev_trgt_pos
		end
	end
	
	local path = npc.pathfinder.find_path(self_pos, trgt_pos, self, true)
	if not path then 
		-- Restore process timer interval
		self.timers.proc_int = prev_proc_timer_value
		if args.force == true then
			self.object:move_to(trgt_pos, false)
		end
		return nil
	end
	
	-- Move towards position
	local next_node = path[1]
	if next_node.pos.x == self_pos.x and next_node.pos.z == self_pos.z then
		next_node = path[2]
	end
	
	local next_pos = next_node.pos
	
	local dir = vector.direction(self_pos, next_pos)
	local yaw = minetest.dir_to_yaw(dir)
	
	-- Store next target pos for position correction
	self.data.proc[self.process.current.id]["_prev_trgt_pos"] = next_pos
	
	-- Rotate towards next node
	self.object:set_yaw(yaw)
	
	-- Check the type of the next position
	-- If walkable, just walk
	if next_node.type == npc.pathfinder.node_types.walkable then
		-- Diagonal movement speed must be increased
		if (dir.x ~= 0 and dir.z ~= 0) then speed = speed * math.sqrt(2) end
		local vel = vector.multiply({x=dir.x, y=0, z=dir.z}, speed)
		
		self.object:set_velocity(vel)
		self.object:set_animation({
		    x = npc.ANIMATION_WALK_START,
		    y = npc.ANIMATION_WALK_END},
		    30, 0)
	
	-- If openable, check the state. If it's open, NPC will close. If it's closed,
	-- NPC will open and close.
	elseif next_node.type == npc.pathfinder.node_types.openable then
	
		local is_open = _npc.env.node_get_property(self, {property="is_open", pos=next_pos})
		if (is_open ~= nil) then
			if (is_open == true) then
				minetest.after(1, _npc.env.node_operate, self, {pos=next_pos})
			elseif (is_open == false) then
				_npc.env.node_operate(self, {pos=next_pos})
				minetest.after(1, _npc.env.node_operate, self, {pos=next_pos})
			end
		end
		
	end
        
    return false
	
end)

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Process API
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
npc.proc.execute_program = function(self, name, args)
	-- Enqueue process
	self.process.queue[#self.process.queue + 1] = {
		id = self.process.key,
		name = name,
		args = args,
		instruction = program_table[name].initial_instruction
	}

	self.process.key = (self.process.key + 1) % 100

	self.process.current = self.process.queue[#self.process.queue]
end

_npc.proc.execute_instruction = function(self, name, raw_args, result_key)
	assert(instruction_table[name] ~= nil)
	local args = {}
	if raw_args then
		for key,value in pairs(raw_args) do
			args[key] = _npc.dsl.evaluate_argument(self, value, raw_args)
		end
	end
	minetest.log("Executing instruction: ["..dump(self.process.current.instruction).."] "..dump(name))
	
	local result = instruction_table[name](self, args)
	if (result_key) then
		minetest.log("Instruction returned: "..dump(result))
		_npc.dsl.set_var(self, result_key, result)
		--self.data.proc[self.process.current.id][result_key] = result
	end
	
	local env_si, env_ei = string.find(name, "npc:env:")
	if name == "npc:jump" 
		or name == "npc:jump_if"
		or name == "npc:break" 
		or name == "npc:var:get" 
		or name == "npc:var:set"
		or name == "npc:timer:instr:start"
		or name == "npc:timer:instr:stop"
		or env_si ~= nil then
		
		-- Execute next instruction now if possible
		self.process.current.instruction = self.process.current.instruction + 1
		
		local instruction = program_table[self.process.current.name].instructions[self.process.current.instruction]
		if instruction then
			_npc.proc.execute_instruction(self, instruction.name, instruction.args, instruction.key)
		end
	end
end

npc.proc.enqueue_process = function(self, name, args)
	-- Enqueue process
	self.process.queue[self.process.queue_tail] = {
		id = self.process.key,
		name = name,
		args = args,
		instruction = program_table[name].initial_instruction
	}

	self.process.key = (self.process.key + 1) % 100

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
-- Built-in programs
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------

-- Stupid program that walks on a square
npc.proc.register_program("sample:stupid", {
	{name = "npc:for", args = {
		initial_value = 0,
		step_increase = 2,
		expr = {left="@local.for_index", op="<=", right=6},
		loop_instructions = {
			{name = "npc:move:walk", args = {dir = "@local.for_index"}}
		}
	}}
})

npc.proc.register_program("builtin:idle", {
	{name = "npc:move:stand"},
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
								return object:get_pos()
							end
						}},
					}},
					{name = "npc:break"}}
				}}}
		}}}
})

npc.proc.register_program("builtin:walk_to_pos", {
	{name = "npc:var:set", args = {
		key = "has_reached_pos",
		value = false
	}},
	{key = "end_pos", name = "npc:env:node:get_accessing_pos", args = {
		pos = "@args.end_pos"
	}},
	{name = "npc:while", args = {
		expr = {
			left = "@local.has_reached_pos",
			op   = "==",
			right = false
		},
		loop_instructions = {
			{key = "has_reached_pos", name = "npc:move:walk_to_pos", args = {
				target_pos = "@local.end_pos",
				original_target_pos = "@args.end_pos",
				check_end_pos_walkable = false
			}},
			{name = "npc:if", args = {
				expr = {
					left = "@local.has_reached_pos",
					op   = "==",
					right = nil
				},
				true_instructions = {
					{name = "npc:break"}
				}
			}}
		}
	}}
})

npc.proc.register_program("sample:stupid_init", {
	{key = "nodes", name = "npc:env:node:find", args = {
		radius = "@args.radius",
		nodenames = "@args.nodes"
	}},
	{name = "npc:if", args = {
		expr = function(self, args)
			return #self.data.proc[self.process.current.id].nodes > 0
		end,
		true_instructions = {
			{name = "npc:for", args = {
				initial_value = 1,
				step_increase = 1,
				expr = {
					left = "@local.for_index",
					op   = "<",
					right = function(self, args)
						return #self.data.proc[self.process.current.id].nodes
					end
				},
				loop_instructions = {
					{key = "is_owned", name = "npc:env:node:is_owner", args = {
						pos = function(self, args)
							return self.data.proc[self.process.current.id].nodes[self.data.proc[self.process.current.id].for_index]
						end
					}},
					{name = "npc:if", args = {
						expr = {
							left = "@local.is_owned",
							op   = "==",
							right = nil
						},
						true_instructions = {
							{name = "npc:env:node:set_owned", args = {value=true}},
							{name = "npc:break"}
						},
					}}
				}
			}}
		}
	}}
})


npc.proc.register_program("builtin:node_query", {
	{key = "nodes", name = "npc:env:node:find", args = {
		radius = "@args.radius",
		nodenames = "@args.nodes"
	}},
	{name = "npc:if", args = {
		expr = function(self, args)
			return #self.data.proc[self.process.current.id].nodes > 0 
		end,
		true_instructions = {
			{name = "npc:execute", args = {
				name = "builtin:walk_to_pos",
				args = function(self, args)
					-- Choose a random pos
					local index = math.random(1, #self.data.proc[self.process.current.id].nodes)
					local result = self.data.proc[self.process.current.id].nodes[index]
					
					return {
						end_pos = result
					}
				end
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

-----------------------------------------------------------------------------------
-- Node registrations
-----------------------------------------------------------------------------------

npc.proc.register_operable_node("doors:door_wood_a", {"openable", "doors"},
	{["is_open"] = function(self, args)
		return false
	end},
	function(self, args)
		local node = minetest.get_node(args.pos)
		local clicker = self
		clicker.is_player = function() return true end
    	clicker.get_player_name = function(self) return "npc" end
		minetest.registered_nodes["doors:door_wood_a"].on_rightclick(args.pos, node, clicker, nil, nil)
	end)

npc.proc.register_operable_node("doors:door_wood_b", {"openable", "doors"},
	{["is_open"] = function(self, args)
		return true
	end},
	function(self, args)
		local node = minetest.get_node(args.pos)
		local clicker = self
		clicker.is_player = function() return true end
    	clicker.get_player_name = function(self) return "npc" end
		minetest.registered_nodes["doors:door_wood_b"].on_rightclick(args.pos, node, clicker, nil, nil)
	end)

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
		
		-- Increase instruction timer if available
		if (self.timers.instr_timer) then
			self.timers.instr_timer = self.timers.instr_timer + 1
		end
		
		-- Run timers
		if (self.data.proc[self.process.current.id]) then
			local timers = self.data.proc[self.process.current.id]["_timers"]
			if timers then
				for i = 1, #timers do
					if timers[i].is_running == true then
						timers[i].value = timers[i].value + 1
						if timers[i].value >= timers[i].interval then
							-- Set timer values
							timers[i].value = 0
							timers[i].execution_count = timers[i].execution_count + 1
							-- Insert call stack entry to be able to return to the same instruction
							local top = #self.data.proc[self.process.current.id]["_call_stack"] + 1
							self.data.proc[self.process.current.id]["_call_stack"][top] = {
								index = self.process.current.instruction
							}
							-- Jump to the instruction
							self.process.current.instruction = timers[i].function_index
							-- Stop timer if max execution count is reached
							if timers[i].execution_count >= timers[i].max_execution_count then
								timers[i].is_running = false
							end
						end
					end
				end
			end
		end
		--minetest.log("Process: "..dump(self.process))

		-- Check if there is a current process
		if self.process.current.name ~= nil then

			-- Check if there is a next instruction
			if self.process.current.instruction > #program_table[self.process.current.name].instructions then
				-- If process is state process, reset instruction counter
				if self.process.current.name == self.process.state.name then
					self.process.current.instruction = 
						program_table[self.process.current.name].initial_instruction
				else
					-- No more instructions, deque process
					local next_head = (self.process.queue_head + 1) % 100
					if next_head == 0 then next_head = 1 end
					self.process.queue[self.process.queue_head] = nil
					self.process.current.name = nil
					self.process.current.instruction = -1
					-- Check if there's a next process
					if self.process.queue[next_head] ~= nil then
						self.process.queue_head = next_head
					end
				end
				-- Check if no more processes in queue
				if (self.process.queue_tail - self.process.queue_head) == 0 then
					-- Execute state process, if present
					if self.process.state.name ~= nil then
						self.process.current.id = self.process.state.id
						self.process.current.name = self.process.state.name
						self.process.current.args = self.process.state.args
						self.process.current.instruction = 
							program_table[self.process.current.name].initial_instruction
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
				self.process.current.instruction = 
					program_table[self.process.current.name].initial_instruction
			end
		end
		
		--minetest.log("Process now: "..dump(process))

		-- Execute next instruction, if available
		if self.process.current.instruction > -1 then
			local instruction = 
				program_table[self.process.current.name].instructions[self.process.current.instruction]
			_npc.proc.execute_instruction(self, instruction.name, instruction.args, instruction.key)
			self.process.current.instruction = self.process.current.instruction + 1
		end
	end

end

local on_activate = function(self, staticdata)
	if staticdata ~= nil and staticdata ~= "" then
		local cols = string.split(staticdata, "|")
		self["timers"] = minetest.deserialize(cols[1])
		self["process"] = minetest.deserialize(cols[2])
		self["data"] = minetest.deserialize(cols[3])
		-- Restore objects
		self.data.env.objects = minetest.get_objects_inside_radius(self.object:get_pos(), self.data.env.view_range)
		--minetest.log("Data: "..dump(self))
	else

		self.npc_id = "anpc:"..dump(math.random(1000, 9999))

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
			proc = {},
			temp = {}
		}

		self.data.env.view_range = 12

		self.schedule = {}

		self.state = {
			walk = {
				target_pos = {}
			},
			track = {
				object = {}
			}
		}
	end
	
	self.object:set_acceleration({x=0, y=-10, z=0})
end

minetest.register_entity("anpc:npc", {
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
	on_activate = on_activate,
	get_staticdata = function(self)

		local result = ""
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
		spawn_pos.y = spawn_pos.y
		local entity = minetest.add_entity(spawn_pos, "anpc:npc")
		if entity then
			npc.proc.set_state_process(entity:get_luaentity(), "builtin:idle", {
				ack_nearby_objs = true,
				ack_nearby_objs_dist = 4,
				ack_nearby_objs_chance = 50
			})
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
			local target_pos = minetest.find_node_near(user:get_pos(), 25, {"default:chest"})
			npc.proc.execute_program(pointed_thing.ref:get_luaentity(), "builtin:walk_to_pos", {end_pos = target_pos})
		end
	end
})

minetest.register_craftitem("anpc:npc_querier", {
	description = "Querier",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			--local target_pos = minetest.find_node_near(user:get_pos(), 25, {"default:chest"})
			npc.proc.set_state_process(pointed_thing.ref:get_luaentity(), "builtin:node_query", {
				radius = 5,
				nodes = {
					"default:chest"
				}
			})
			minetest.log(dump(pointed_thing.ref:get_luaentity()))
		end
	end
})

minetest.register_craftitem("anpc:npc_owner", {
	description = "Owner",
	inventory_image = "default_apple.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing.type == "object" then
			--local target_pos = minetest.find_node_near(user:get_pos(), 25, {"default:chest"})
			npc.proc.execute_program(pointed_thing.ref:get_luaentity(), "sample:stupid_init", {
				radius = 5,
				nodes = {
					"default:chest"
				}
			})
		end
	end
})
