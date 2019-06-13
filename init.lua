npc = {
	proc = {}
}

local _npc = {
	dsl = {},
	proc = {}
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

local programs = {}
local instructions = {}

-- At least left and op are necessary
_npc.dsl.evaluate_boolean_expression = function(self, expr, args)
	local operator = expr.op
	local source = _npc.dsl.evaluate_argument(self, expr.left, args)
	local target = _npc.dsl.evaluate_argument(self, expr.right, args)
	
	minetest.log("Boolean expression: "..dump(expr))
	
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
	
	minetest.log("Keys: "..dump(self.process.current.id)..", "..dump(key))
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

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Program and Instruction Registration
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Returns an array of instructions
_npc.proc.process_instruction = function(instruction, original_list_size, function_index_map, nesting_level)
	local instruction_list = {}
	local is_function = false
	
	minetest.log("Current list size: "..dump(original_list_size))
	minetest.log("Processing instruction: "..dump(instruction))
	
	if instruction.name == "npc:if" then	
		---minetest.log("The greatest jump if: "..dump(instruction))
		
		-- Process true instructions if available
		local true_instrs = {}
		for i = 1, #instruction.args.true_instructions do
			assert(not instruction.args.true_instructions[i].declare, 
				"Function declaration cannot be done inside another instruction.")
			local instrs = _npc.proc.process_instruction(instruction.args.true_instructions[i], 
				#true_instrs + original_list_size + 1, {}, nesting_level + 1)
			minetest.log("Processing inner instruction: "..dump(instruction.args.true_instructions[i]))
			minetest.log("Yielded "..dump(#instrs).." instructions")
			for j = 1, #instrs do
				true_instrs[#true_instrs + 1] = instrs[j]
			end
		end
		
		--original_list_size = original_list_size + 1
		
		minetest.log("Original list: "..dump(original_list_size))
		minetest.log("#true instr: "..dump(#true_instrs))
		
		-- Insert jump to skip true instructions if expr is false
		local offset = 1
		if nesting_level > 1 then offset = 0 end
		instruction_list[#instruction_list + 1] = {
			name = "npc:jump_if", 
			args = {
				expr = instruction.args.expr,
				pos =  #true_instrs + offset + nesting_level, 
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
					#false_instrs + #instruction_list + original_list_size + 1, {}, nesting_level + 1)
				for j = 1, #instrs do
					false_instrs[#false_instrs + 1] = instrs[j]
				end
			end
			
			minetest.log("Components: instr_list: "..dump(#instruction_list)..", false: "..dump(#false_instrs)..", org: "..dump(original_list_size))
			
			offset = 1
			if nesting_level < 2 then offset = 0 end
			
			-- Insert jump to skip false instructions if expr is true
			instruction_list[#instruction_list + 1] = {
				name = "npc:jump", 
				args = {
					pos = #false_instrs + nesting_level + offset,
					offset = true 
				}
			}
			
			-- Insert all false_instructions
			for j = 1, #false_instrs do
				instruction_list[#instruction_list + 1] = false_instrs[j]
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
				loop_start, {}, nesting_level + 1)
			for j = 1, #instrs do
				instruction_list[#instruction_list + 1] = instrs[j]
			end
		end
		
		-- Insert conditional to loop back if expr is true
		instruction_list[#instruction_list + 1] = {
			name = "npc:jump_if", 
			args = {
				expr = instruction.args.expr, 
				pos = loop_start, 
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
				loop_start, {}, nesting_level + 1)
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
				pos = loop_start, 
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
				loop_start, {}, nesting_level + 1)
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
				pos = loop_start, 
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
				func_index, {}, nesting_level + 1)
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
		}, original_list_size, function_index_map, nesting_level + 1)
		
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
				#instruction_list + 1, function_table, 0)
			minetest.log("Raw instruction name: "..dump(raw_instruction_list[i].name))
			minetest.log("Yielded "..dump(#instructions).." instructions")
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

-----------------------------------------------------------------------------------
-- DSL Instructions
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
	minetest.log("Jump-If: Expression: "..dump(args.expr))
	minetest.log("Jump-If: Condition: "..dump(condition))
	if condition == true then
		if args.offset == true then
			self.process.current.instruction = self.process.current.instruction + args.pos
		else
			self.process.current.instruction = args.pos
		end
	
		minetest.log("Jumping to instruction: "..dump(program_table[self.process.current.name][self.process.current.instruction]))
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

-- Movement instructions
npc.proc.register_instruction("npc:move:rotate", function(self, args)
	local dir = vector.direction(self.object:get_pos(), args.target_pos)
	local yaw = minetest.dir_to_yaw(dir)
	self.object:set_yaw(yaw)
end)

npc.proc.register_instruction("npc:move:stand", function(self, args)
	self.object:set_velocity({x=0, y=0, z=0})
	self.object:set_animation({
        x = npc.ANIMATION_STAND_START,
        y = npc.ANIMATION_STAND_END},
        30, 0)
end)

--TODO: Add calculation for surrounding air nodes if node is walkable
npc.proc.register_instruction("npc:move:find_path", function(self, args)

	local end_pos = args.end_pos
	local start_pos = args.start_pos or vector.round(self.object:get_pos())
	
	if npc.pathfinder.is_good_node(minetest.get_node(args.end_pos), {}) == npc.pathfinder.node_types.non_walkable then
		
		local count = 0
		while count < 4 do
			local pos = end_pos
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
			if node and node.name == "air" then 
				end_pos = pos
				break 
			end
			count = count + 1
		end
		
	end 
	
	minetest.log("Start pos: "..dump(start_pos))
	
	local path = npc.pathfinder.find_path(start_pos, end_pos, self, args.decorate)
	minetest.log("Path found: "..dump(path))
	self.data.proc[self.process.current.id].current_path = path

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
--	if (args.cardinal_dir) then
--		if dir == 0 then
--        	vel = {x=0, y=0, z=speed}
--		elseif dir == 1 then
--		    vel = {x=speed, y=0, z=speed}
--		elseif dir == 2 then
--		    vel = {x=speed, y=0, z=0}
--		elseif dir == 3 then
--		    vel = {x=speed, y=0, z=-speed}
--		elseif dir == 4 then
--		    vel = {x=0, y=0, z=-speed}
--		elseif dir == 5 then
--		    vel = {x=-speed, y=0, z=-speed}
--		elseif dir == 6 then
--		    vel = {x=-speed, y=0, z=0}
--		elseif dir == 7 then
--		    vel = {x=-speed, y=0, z=speed }
--		end
--	end

	local dir = vector.direction(self.object:get_pos(), args.target_pos or {x=0,y=0,z=0})
	local yaw = args.yaw or minetest.dir_to_yaw(dir)
	local speed = args.speed or 1
	
	self.object:set_yaw(yaw)
	minetest.log("This is unit vector: "..dump({x=(dir.x/dir.x), y=0, z=(dir.z/dir.z)}))
	minetest.log("This is the dir: "..dump(dir))
	self.object:set_velocity(vector.multiply({x=(dir.x/math.abs(dir.x)), y=0, z=(dir.z/math.abs(dir.z))}, speed))
	self.object:set_animation({
        x = npc.ANIMATION_WALK_START,
        y = npc.ANIMATION_WALK_END},
        30, 0)
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

_npc.proc.execute_instruction = function(self, name, raw_args)
	assert(instruction_table[name] ~= nil)
	local args = {}
	if raw_args then
		for key,value in pairs(raw_args) do
			args[key] = _npc.dsl.evaluate_argument(self, value, raw_args)
		end
	end
	minetest.log("Executing instruction: ["..dump(self.process.current.instruction).."] "..dump(name))
	
	instruction_table[name](self, args)
	
	if name == "npc:jump" 
		or name == "npc:jump_if"
		or name == "npc:break" 
		or name == "npc:var:get" 
		or name == "npc:var:set"
		or name == "npc:timer:instr:start"
		or name == "npc:timer:instr:stop" then
		
		-- Execute next instruction now if possible
		if name ~= "npc:jump" and name ~= "npc:jump_if" and name ~= "npc:break" then 
			-- The above instructions set the instruction counter, making it unnecessary
			-- to increase it.
			self.process.current.instruction = self.process.current.instruction + 1
		end
		
		local instruction = program_table[self.process.current.name].instructions[self.process.current.instruction]
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
					minetest.log("")
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



-- Sample state program
--npc.proc.register_program("builtin:idle", {
--	{name = "npc:timer:register", args = {
--		name = "idle_stop_acknowledge",
--		interval = 5,
--		instructions = {
--			{name="npc:var:set", args={key="@local.idle_current_obj", value=nil}}
--		}
--	}},
--	{name = "npc:move:stand"},
--	{name = "npc:if", args = {
--		expr = {
--			left = "@local.idle_current_obj",
--			op   = "~=",
--			right = nil
--		},
--		true_instructions = {
--			{name = "npc:move:rotate", args={
--				target_pos = function(self, args)
--					local object = npc.eval(self, "@local.idle_current_obj")
--					return object:get_pos()
--				end
--			}}
--		},
--		false_instructions = {
--			{name = "npc:timer:stop", args = {name = "idle_stop_acknowledge"}},
--			{name = "npc:for", args = {
--				initial_value = 1,
--				step_increase = 1,
--				expr = {
--					left = "@local.for_index",
--					op = "<=",
--					right = function(self)
--						return #self.data.env.objects
--					end
--				},
--				loop_instructions = {
--					{name = "npc:if", args = {
--						expr = function(self, args)
--							 Random 50% chance
--							local chance = math.random(1, 100)
--							if chance < (100 - npc.eval(self, "@args.ack_nearby_objs_chance")) then 
--								return false 
--							end
--							
--							local object = self.data.env.objects[self.data.proc[self.process.current.id].for_index]
--							if object then
--								local object_pos = object:get_pos()
--								local self_pos = self.object:get_pos()
--								return vector.distance(object_pos, self_pos) < npc.eval(self, "@args.ack_nearby_objs_dist")
--									and vector.distance(object_pos, self_pos) > 0
--							end
--							return false
--						end, 
--						true_instructions = {
--							{name = "npc:timer:start", args = {name = "idle_stop_acknowledge"}},
--							{name = "npc:var:set", args = {
--								key = "idle_current_obj", 
--								value = function(self, args)
--									return self.data.env.objects[self.data.proc[self.process.current.id].for_index]
--								end,
--								userdata_type = "object"
--							}},
--							{name = "npc:move:rotate", args={
--									target_pos = function(self, args)
--										local object = self.data.env.objects[self.data.proc[self.process.current.id].for_index]
--										return object:get_pos()
--									end
--							}},
--							{name = "npc:wait", args = {time = "@random.1.3"}},
--							{name = "npc:break"}
--						}
--					}}
--				}
--			}}
--		}
--	}}
--})

npc.proc.register_program("builtin:walk_to_pos", {
	{name = "npc:var:set", args = {
		key = "has_reached_pos",
		value = false
	}},
	{name = "npc:while", args = {
		expr = {
			left = "@local.has_reached_pos",
			op   = "~=",
			right = true
		},
		loop_instructions = {
			{name = "npc:move:find_path", args = {
				end_pos = "@args.end_pos"
			}},
			{name = "npc:if", args = {
				expr = {
					left = "@local.current_path",
					op   = "~=",
					right = nil
				},
				true_instructions = {
					{name = "npc:if", args = {
						expr = function(self, args)
							minetest.log("Data: "..dump(self.data))
							minetest.log("# path: "..dump(#self.data.proc[self.process.current.id].current_path))
							return #self.data.proc[self.process.current.id].current_path < 1
						end,
						true_instructions = {
							{name = "npc:break"}
						},
						false_instructions = {
							{name = "npc:move:walk", args = {
								target_pos = "@local.current_path.1"
							}}
						}
					}}	
				},
				false_instructions = {
					
					{name = "npc:break"}
				}
			}}
		}
	}}

})

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
			_npc.proc.execute_instruction(self, instruction.name, instruction.args)
			self.process.current.instruction = self.process.current.instruction + 1
		end
	end

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
	on_activate = function(self, staticdata)

		if staticdata ~= nil and staticdata ~= "" then
			local cols = string.split(staticdata, "|")
			self["timers"] = minetest.deserialize(cols[1])
			self["process"] = minetest.deserialize(cols[2])
			self["data"] = minetest.deserialize(cols[3])
			-- Restore objects
			self.data.env.objects = minetest.get_objects_inside_radius(self.object:get_pos(), self.data.env.view_range)
			--minetest.log("Data: "..dump(self))
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
			local target_pos = minetest.find_node_near(user:get_pos(), 25, {"default:dry_shrub"})
			npc.proc.execute_program(pointed_thing.ref:get_luaentity(), "builtin:walk_to_pos", {end_pos = target_pos})
		end
	end
})
