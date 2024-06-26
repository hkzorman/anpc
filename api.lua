-- The anpc API

local _npc = {
	dsl   = {},
	proc  = {},
	env   = {},
	obj	  = {},
	move  = {},
	model = {}
}

npc.model = _npc.model

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
local hl_task_table = {}
local node_table = {}
local node_group_name_map = {}
local group_to_pos_map = {}

-- Check if `anpc-dev` mod is enabled. If so, make the program table and instruction
-- table accessible from `npc.proc.*`. This enables debugging tools in `anpc_dev`
local mods = minetest.get_modnames()
local is_dev_mode = false
for i = 1, #mods do
	if mods[i] == "anpc_dev" then
		npc.proc.program_table = program_table
		npc.proc.instruction_table = instruction_table
		is_dev_mode = true
	end
end

local models = {}

-----------------------------------------------------------------------------------
-- DSL Functions
-----------------------------------------------------------------------------------

-- At least left and op are necessary
_npc.dsl.evaluate_boolean_expression = function(self, expr, args)
	--minetest.log("Got expr: "..dump(expr))
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
	elseif operator == "+" then
		return source + target
	elseif operator == "-" then
		return source - target
	elseif operator == "*" then
		return source * target
	elseif operator == "/" then
		return source / target
	elseif operator == "%" then
		return source % target
	elseif operator == "&&" then
		return source and target
	elseif operator == "||" then
		return source or target
	end
end

-- This function parses in-line arguments, mostly used to get/set variables
-- These expressions have to be evaluated at run time, so this function is called at run time only.
-- Supported operations:
--   - Get variables from:
--     - local: local program variables, e.g. @local.var_name
--     - global: global variables, to the NPC, e.g. @global.var_name
--     - args: access the arguments of the current program, e.g. @args.arg_name
--   - You can also access variable using another variable:
--     - @local.@local.var_name
--   - Supports tables
--     - Constant table element: @local.tbl_name["some_key_name"]
--     - Variable table element: @local.tbl_name[@local.for_index]
--     - Table length: @local.tbl_name.length
--   - Object expressions:
--     - @objs.all: returns a table with all objects nearby the NPC
--     - @objs.get[<tracking_id>]: returns object with tracking ID = <tracking_id>
--     - @objs.get[@local.for_index]: returns object with index or tracking ID @local.for_index
--	 - Time expression:
--     - @time: Returns minetest local time * 24000
_npc.dsl.evaluate_argument = function(self, expr, args, local_vars)
	--minetest.log("Got expr: "..dump(expr))
	if type(expr) == "string" then
		if expr:sub(1,1) == "@" then
			local expression_values = string.split(expr, ".")
			local storage_type = expression_values[1]
			local result = nil
			local second_arg = nil
			local third_arg = nil
			local orig_key = nil
			local key = nil

			local bracket_start = string.find(expr, "%[")
			local bracket_end = string.find(expr, "%]")
			if bracket_start ~= nil and bracket_end ~= nil then
				local point_start = string.find(expr, "%.")
				second_arg = expr:sub(point_start + 1, bracket_start - 1)
				orig_key = expr:sub(bracket_start + 1, bracket_end - 1)
				if orig_key:sub(1,1) == "@" then
					key = _npc.dsl.evaluate_argument(self, orig_key)
				else
					key = orig_key
				end
				
				-- Check if the key is a number - if so, we should use a key of type number
				if type(key) == "string" and string.find(key, "^%d+$") ~= nil and string.find(key, "^%d+$") > -1 then
					key = tonumber(key)
				end
			else
				if expression_values[2] then
					if expression_values[2]:sub(1,1) == "@" then
						second_arg = _npc.dsl.evaluate_argument(self, expression_values[2]..expression_values[3])
					else
						second_arg = expression_values[2]
					end
				end
			end
			
			-- Get third argument, `length` if provided
			-- Possible usecases:
			--   - @local.my_array.length
			if #expression_values > 2 then
				if #expression_values == 3 then
					third_arg = expression_values[3]
				elseif #expression_values == 4 then
					third_arg = expression_values[4]
				end
			end
				
			if storage_type == "@local" then
				if self.data.proc[self.process.current.id] then
					result = _npc.dsl.get_var(self, second_arg)
				end
			elseif storage_type == "@args" then
				result = self.process.current.args[second_arg]
			elseif storage_type == "@global" then
				result = self.data.global[second_arg]
			elseif storage_type == "@temp" then
				result = self.data.temp[second_arg]
			elseif storage_type == "@env" then
				result = self.data.env[second_arg]
			elseif storage_type == "@objs" then
				result = self.data.env.objects
				-- Supports passing in an index, a tracking ID, a tracking record, or "all"
				-- NOTE: This will only work if the NPC is within range of the object
				
				if second_arg == "all" then
					result = self.data.env.objects
				elseif second_arg == "get" then
					-- Return object by number index
					if type(key) == "number" then
						return self.data.env.objects[key]
					else
						local obj_key = _npc.dsl.evaluate_argument(self, key)

						-- Extract the tracking ID from the tracking record if
						-- the expression is a variable containing a tracking record
						if type(obj_key) == "table" and obj_key._is_tracking_record == true then
							obj_key = obj_key._id
						end

						for i = 1, #self.data.env.objects do
							local obj = self.data.env.objects[i]
							if obj then
								if obj:is_player() and obj:get_player_name() == obj_key then
									self.data.temp[obj_key] = obj
									return obj
								else
									local entity = obj:get_luaentity()
									if entity and entity.anpc_track_id == obj_key then
										self.data.temp[obj_key] = obj
										return obj
									end
								end
							end
						end

						-- Try on temp data storage
						local obj = self.data.temp[obj_key]
						if obj then return obj end
					end
				end
			elseif storage_type == "@time" then
				return 24000 * minetest.get_timeofday()
			-- This might be temporary
			elseif storage_type == "@self" then
				if expression_values[2] == "pos_rounded" then
					return vector.round(self.object:get_pos())
				elseif expression_values[2] == "pos" then
					return self.object:get_pos()
				elseif expression_values[2] == "dir" then
					return minetest.yaw_to_dir(self.object:get_yaw())
				elseif expression_values[2] == "yaw" then
					return self.object:get_yaw()
				end
			end
			
			-- Check if there's a third argument.
			-- Supported third argument:
			--   - `length`: if object is a table, returns length of table
			--minetest.log("[e] On third argument..."..dump(key))
			--minetest.log("[e] Storage type: "..dump(storage_type))
			--minetest.log("[e] Result: "..dump(_npc.dsl.get_var(self, second_arg)))
			--minetest.log("[e] Second arg: "..dump(second_arg))
			--minetest.log("[e] result="..dump(result))
			--if type(result) == "table" then minetest.log("[e] result[key]="..dump(result[key])) end
			if third_arg then
				if third_arg == "length" then
					if not result then return -1 end
					local count = 0
					for _ in pairs(result) do count = count + 1 end
					return count
				end
			end

			if key and type(result) == "table" then
				return result[key]
			else
				return result
			end
			--minetest.log("Expression: "..dump(expression_values))

		end
	elseif type(expr) == "table" and expr.left and expr.op then
		return _npc.dsl.evaluate_boolean_expression(self, expr, args)
	elseif type(expr) == "function" then
		return expr(self, args, local_vars)
	end
	return expr
end

-- TODO: Might not be needed
-- TODO: We probably want to remove this to discourage use of in-line Lua
--       on anpcscript programs
npc.eval = function(self, expr, args, local_vars)
	return _npc.dsl.evaluate_argument(self, expr, args, local_vars)
end

-- Nil-safe set variable function, plus handling of userdata variables
_npc.dsl.set_var = function(self, key, value, userdata_type, storage_type)
	local storage = nil
	local subkey = nil
	local orig_subkey = key
	
	--minetest.log("Got key: "..dump(key))
	--minetest.log("Got value: "..dump(value))
	
	if storage_type == nil and key and key:sub(1,1) == "@" then
		local index = string.find(key, "%.")
		storage_type = key:sub(2, index - 1)
		key = key:sub(index + 1, #key)
	elseif storage_type == nil then
		-- Assume local storage
		storage_type = "local"
	end
	
	--minetest.log("Selected storage: "..dump(storage_type))
	
	-- TODO: This doesn't work, I think
	-- Support assigning values to array elements
	local bracket_start = string.find(key, "%[")
	local bracket_end = string.find(key, "%]")
	if bracket_start ~= nil and bracket_end ~= nil then
		orig_subkey = key:sub(bracket_start + 1, bracket_end - 1)
		key = key:sub(1, bracket_start - 1)
		if orig_subkey:sub(1,1) == "@" then
			subkey = _npc.dsl.evaluate_argument(self, orig_subkey)
		else
			subkey = orig_subkey
		end
	end
	
	if storage_type == "global" then
		storage = self.data.global
	elseif storage_type == "temp" then
		storage = self.data.temp
	elseif storage_type == "args" then
		storage = self.process.current.args
	elseif storage_type == "local" then
		storage = self.data.proc[self.process.current.id]
		if storage == nil then
			self.data.proc[self.process.current.id] = {}
			storage = self.data.proc[self.process.current.id]
		end
	end
	
	-- TODO: Fix this hack. We need somehow to understand what kind of userdata
	-- value is being passed in. Probably the best idea is to have someway to 
	-- specify the userdata type in the anpcscript, and the interpreter add the 
	-- userdata_type argument
	-- TODO: Handle better objects at reload?
	if not userdata_type then userdata_type = "object" end
	
	if type(value) == "userdata" then
		if userdata_type then
			if userdata_type == "object" then
				local tracking_record = _npc.dsl.generate_tracking_record(self, value)

				if subkey and type(storage[key]) == "table" then
					storage[key][subkey] = tracking_record
				else
					storage[key] = tracking_record
				end
	
				-- Store actual object so that lookups are simpler
				self.data.temp[tracking_record._id] = value

				return
			else
				-- TODO: Handle other userdata types
				assert(value.to_table and value.from_table)
				value = {userdata_type=userdata_type, value=value.to_table}
			end
		end
	end

	-- Handle table with variables
	-- Currently, only first-level keys are checked for performance reasons
	if type(value) == "table" then

	end

	if subkey and type(storage[key]) == "table" then
		storage[key][subkey] = value
	else
		storage[key] = value
	end
end

_npc.dsl.get_var = function(self, key)
	--minetest.log("Data: "..dump(self.data.proc[self.process.current.id]))
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

_npc.dsl.generate_tracking_record = function(self, obj)
	--local obj = value
	if obj then
		-- Check if player
		if obj:is_player() then
			-- Store tracking record
			self.data.temp[obj:get_player_name()] = obj
			return {
				_is_tracking_record = true,
				_id = obj:get_player_name(),
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
			self.data.temp[id] = obj
			return {
				_is_tracking_record = true,
				_id = id,
				userdata_type = "object",
				obj_type = "object",
				obj_attr = {
					id = id,
					distance = vector.distance(self.object:get_pos(), obj:get_pos()) * 3
				}
			}
		end
	end
end
-----------------------------------------------------------------------------------
-- Scheduling functions
-----------------------------------------------------------------------------------
-- The scheduling functionality is as follows:
--   - A scheduled entry has the following parameters:
--     - earliest start time
--     - latest start time
--	   - recurrency type
--     - repeat interval
--     - end time (if repeat interval given, if not given, repeat always)
--     - dependent schedule entry ID
--   - A schedule entry is for a *single* job
--   - A scheduled job will be priority-enqueued (using npc.execute_program)
--     - If this job sets a state process, it needs to state how to do it (e.g.
--       future state vs. immediate state process)
-----------------------------------------------------------------------------------

-- TODO: Support weekly, monthly and yearly recurrencies
npc.schedule.recurrency_type = {
	["none"] = "none",
	["daily"] = "daily"
}

-- This function adds an entry (as defined above) to the NPC's schedule
-- data.
_npc.proc.schedule_add = function(self, args)

	self.data.schedule[#self.data.schedule + 1] = {
		program_name = args.program_name,
		earliest_start_time = args.earliest_start_time,
		latest_start_time = args.latest_start_time,
		repeat_interval = args.repeat_interval,
		end_time = args.end_time,
		dependent_entry_id = args.dependent_entry_id
	}

	return #self.data.schedule
end

_npc.proc.schedule_remove = function(self, args)
	if self.data.schedule[args.entry_id] ~= nil then
		self.data.schedule[args.entry_id] = nil
		return true
	else
		return false
	end
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

		-- TODO: Remove this as the interpreter now does this
		-- Process true instructions if available
		--[[
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
		]]--

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

		-- TODO: Remove this as the interpreter now does this
		--[[
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
		]]--

	elseif instruction.name == "npc:for" then

		-- TODO: Remove this as the interpreter now does this
		--[[
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
		minetest.log("On a for loop")
		minetest.log(dump(loop_start))
		minetest.log(dump(instruction_list))
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
		]]--

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
					local array = _npc.dsl.evaluate_argument(
						self, instruction.args.array, args, self.data.proc[self.process.current.id])
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
					local array = _npc.dsl.evaluate_argument(
						self, instruction.args.array, args, self.data.proc[self.process.current.id])
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

		-- TODO: Remove this as the interpreter now does this
		--[[
		-- This is not a busy wait, this modifies the interval in two instructions
		local wait_time = _npc.dsl.evaluate_argument(self, instruction.args.time, nil, nil)
		instruction_list[#instruction_list + 1] =
			{key="_prev_proc_int", name="npc:get_proc_interval"}
		instruction_list[#instruction_list + 1] =
			{name="npc:set_proc_interval", args={wait_time = wait_time, value = function(self, args)
				return args.wait_time - self.timers.proc_int
			end}}
		instruction_list[#instruction_list + 1] =
			{name="npc:set_proc_interval", args={value = "@local._prev_proc_int"}}
		]]--

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

npc.proc.register_program = function(name, raw_instruction_list, source_location)
	if program_table[name] ~= nil then
		assert("Program with name "..name.." already exists")
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
			--assert(raw_instruction_list[i].name ~= "npc:jump",
				--"Instruction 'npc:jump' is only for internal use and cannot be explicitly invoked from a program.")
			--assert(raw_instruction_list[i].name ~= "npc:jump_if",
				--"Instruction 'npc:jump_if' is only for internal use and cannot be explicitly invoked from a program.")
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
		
		minetest.log("Source location: "..dump(source_location))
		
		if source_location then
			program_table[name]["source_file"] = source_location
		end

		minetest.log("Registered program "..dump(name).." with initial instruction: "..dump(initial_instruction)..":")

		--minetest.log(dump(program_table[name]))
		return true
	end
end

npc.proc.register_instruction = function(name, instruction)
	if instruction_table[name] ~= nil then
		assert("Instruction \""..name.."\" already exists.")
		return false
	else
		instruction_table[name] = instruction
		return true
	end
end

npc.proc.register_low_latency_task = function(name, handler, timeout_handler)
	if hl_task_table[name] ~= nil then
		assert("Low-latency \""..name.."\" already exists.")
		return false
	else
		hl_task_table[name] = {
			handler = handler,
			timeout_handler = timeout_handler
		}
	end
end

-- Parameters:
-- name: Name of the node, same as when the node is registered with 'minetest.register_node'
-- categories: Array of tags or categories, that classifies nodes together
-- properties: An array of functions in the following format:
--   {
--		[property_name] = function(self, args)
--   }
-- operation: A function that is called when the instruction 'npc:env:node:operate' is executed
-- the function is given two parameters: 'self', and a table of arguments 'args'
npc.env.register_node = function(name, groups, properties, operation)
	if node_table[name] ~= nil then
		return false
	else
		node_table[name] = {
			groups = groups,
			properties = properties,
			operation = operation
		}
		return true
	end

	-- Insert into group_to_name_map - this is used when searching
	-- for nodes of a specific group
	for i = 1, #groups do
		-- Create group if it doesn't exists
		if not node_group_name_map[groups[i]] then
			node_group_name_map[groups[i]] = {}
		end
		node_group_name_map[groups[i]][#node_group_name_map[groups[i]] + 1] = name
	end
end

-- Parameters:
-- The "animation_name" parameter is the name of the animation
-- The object "animation_params" is like this:
-- {
--		start_frame: integer, required, the starting frame of the animation of the blender model
--		end_frame: integer, required, the ending frame of the animation of the blender model
--		speed: integer, required, the speed in which the animation will be played
--		blend: integer, optional, animation blend is broken, defaults to 0
--		loop: boolean, optional, default is true. If false, should specify "animation_after"
--		animation_after: string, optional, default is "stand". Name of animation that will be played
--   			  		  when this animation is over.
-- }
npc.model.register_animation = function(model_name, animation_name, animation_params)
	-- Initialize if not present
	if (not models[model_name]) then
		models[model_name] = {
			animations = {}
		}
	end

	models[model_name].animations[animation_name] = animation_params
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
	_npc.dsl.set_var(self, args.key, args.value, args.userdata_type, args.storage_type)
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
	if condition == true then
		if args.offset == true then
			self.process.current.instruction = self.process.current.instruction + args.pos
		else
			self.process.current.instruction = args.pos
		end
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

npc.proc.register_instruction("npc:get_proc_interval", function(self, args)
	return self.timers.proc_int
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
	local processed_args = {}
	if args.args then
		for arg_key,arg_value in pairs(args.args) do
			processed_args[arg_key] = _npc.dsl.evaluate_argument(
				self, arg_value, raw_args, self.data.proc[self.process.current.id])
		end
	end
	self.process.current.called_execute = true
	npc.proc.execute_program(self, args.name, processed_args)
    self.process.program_changed = true
end)

npc.proc.register_instruction("npc:set_default_program", function(self, args)
	npc.proc.set_state_process(self, args.name, args.args, true)
end)

-- Exits the current program
-- Arguments:
-- * return_value: value returned when program exits. Defaults to nil
npc.proc.register_instruction("npc:exit", function(self, args)
	-- This implementation will cause a new program to be picked up on the
	-- next entity step
	self.process.current.instruction =
		#program_table[self.process.current.name].instructions + 1
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
-- Utilities instructions
-----------------------------------------------------------------------------------
npc.proc.register_instruction("npc:debug", function(self, args)
	minetest.log("[npc:debug] "..dump(args.msg).." [val]="..dump(args.val))
end)

npc.proc.register_instruction("npc:random", function(self, args)
	if args.start and args["end"] then
		return math.random(args.start, args["end"])
	end
end)

npc.proc.register_instruction("npc:distance_to", function(self, args)
	if args.pos then
		local source = self.object:get_pos()
		local target = args.pos
		local result = vector.distance(source, target)
		if args.round then return vector.round(result) else return result end
	elseif args.object then
		local source = self.object:get_pos()
		local target = args.object:get_pos()
		local result = vector.distance(source, target)
		if args.round then return vector.round(result) else return result end
	end
end)

-- Arguments:
--   - x: must be a vector
--   - y: can be a vector or number. If vector, operation is applied component by component.
--        If number, then same number is added to all vector components
npc.proc.register_instruction("npc:util:vector:add", function(self, args)
	local x = args.x
	local y = args.y
	--minetest.log("x: "..dump(x)..", y: "..dump(y))
	return vector.add(x, y)
end)

npc.proc.register_instruction("npc:util:vector:subtract", function(self, args)
	local x = args.x
	local y = args.y
	return vector.subtract(x, y)
end)

npc.proc.register_instruction("npc:util:vector:multiply", function(self, args)
	local x = args.x
	local y = args.y
	return vector.multiply(x, y)
end)

npc.proc.register_instruction("npc:util:vector:divide", function(self, args)
	local x = args.x
	local y = args.y
	return vector.divide(x, y)
end)

-----------------------------------------------------------------------------------
-- Environment-related instructions
-----------------------------------------------------------------------------------
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

-- Checks for:
--   - Selected position is a non-walkable node
--   - There's vertical clearance for the NPC to fit
--   - There's a walkable node to stand in
--   - (optional) There's a x-node-radius horizontal clearance around the NPC (non-solid nodes)
_npc.env.node_can_stand_in = function(self, args)
	local node_pos = args.pos
	local node = minetest.get_node_or_nil(node_pos)
	local height = math.ceil(self.collisionbox[5] - self.collisionbox[2])
	if (node and node.name) then
	
		for y = node_pos.y - 1, node_pos.y + height do
			is_walkable = false
			if (y == node_pos.y - 1) then is_walkable = true end
			
			local next_node = minetest.get_node_or_nil({x=node_pos.x, y=y, z=node_pos.z}) 
			if (next_node 
				and next_node.name 
				and not minetest.registered_nodes[node.name].walkable == is_walkable) then
				return false
			end
		end
		
		if (args.horizontal_radius) then
			-- TODO: Implement
		end
		
		return true	 
	end
	
	return nil
end

-- Returns a position from where a NPC can approach or access another position.
-- Search methods:
--  - prefer_first
--  - prefer_closest
_npc.env.node_get_accessing_pos = function(self, args)
	minetest.log("Args: "..dump(args))
	minetest.log("The chosen node: "..minetest.pos_to_string(args.pos))
	minetest.log("Force an accessing node? "..dump(args.force))
	local search_method = args.search_method or "prefer_first"
	minetest.log("Search method: "..dump(search_method))

	-- Make a copy of the given pos
	local pos = {x=args.pos.x, y=args.pos.y, z=args.pos.z}

	-- Check vertical reach - NPCs should be able to walk to nodes even if
	-- they are not in the floor, as long as they are within their vertical reach.
	-- For the moment, the reach is defined as ceil(height) + ceil(height) / 2
	-- TODO: Seems like a relatively good assumption - except if the model
	--       has extra-long arms. We probably want to see how can we handle this.
	-- First, calculate NPC's collisionbox height
	local height = math.ceil(self.collisionbox[5] - self.collisionbox[2])
	local vertical_reach = height + (height / 2)
	-- Then check if the node is within the reach
	local self_pos = vector.round(self.object:get_pos())
	if (pos.y > self_pos.y and (pos.y - self_pos.y) > vertical_reach) then
		return args.pos
	else
		-- Adjust the position's y for the pathfinder
		pos.y = self_pos.y
	end

	local target_node = minetest.get_node_or_nil(pos)
	if (target_node) then
		if npc.pathfinder.is_good_node(target_node, {})
			== npc.pathfinder.node_types.non_walkable or args.force == true then

			-- First of all, if walking towards a node, try to see if the position
			-- in front of the node is walkable
			if (target_node.name
				and minetest.registered_nodes[target_node.name].paramtype2 == "facedir") then

				local front_pos = vector.add(pos, vector.multiply(minetest.facedir_to_dir(target_node.param2), -1))
				local front_node = minetest.get_node_or_nil(front_pos)
				if front_node then
					if npc.pathfinder.is_good_node(front_node, {})
						 == npc.pathfinder.node_types.walkable then
						 return front_pos
					end
				end
			-- If the position is not a node, then prefer accessible position
			-- that is on the same direction that the NPC is walking to
			end

			-- Search all surrounding nodes
			local min_distance = 10000 -- Just a big number
			local closest_pos = nil
			local count = 0
			while count < 4 do
				-- Create copy of pos
				local cpos = {
					x = pos.x,
					y = pos.y,
					z = pos.z
				}
				if count == 0 then
					cpos.x = cpos.x + 1
				elseif count == 1 then
					cpos.z = cpos.z + 1
				elseif count == 2 then
					cpos.x = cpos.x -1
				elseif count == 3 then
					cpos.z = cpos.z -1
				end

				local dist = vector.distance(self_pos, cpos)
				if (dist < min_distance) then
					min_distance = dist
					closest_pos = cpos
				end

				if search_method == "prefer_first" then
					local node = minetest.get_node(cpos)
					if node and node.name and minetest.registered_nodes[node.name].walkable == false then
						minetest.log("Returning this accessing pos: "..minetest.pos_to_string(cpos))
						return cpos
					end
				end
				count = count + 1
			end

			if search_method == "prefer_closest" then
				return closest_pos
			end
		else
			return pos
		end
	end

	-- If no accessible found, then just return the given position.
	-- The pathfinder should fail to find a path.
	return args.pos
end

-- This function is logically opposite to the 'walkable' parameter of a node.
-- In a node, if it is walkable, means that an entity can step *on* it. If not,
-- then an entity can step *through* it (like grass). This functon returns true
-- with nodes like air, grass and stairs.
_npc.env.node_is_walkable = function(self, args)
	local node = minetest.get_node_or_nil(args.pos)
	if (node and node.name
		and (
			minetest.registered_nodes[node.name].walkable == false
			or minetest.get_item_group(next_node_below.name, "stair") > 0
			or minetest.get_item_group(next_node_below.name, "slab") > 0
		)) then
		return true
	end
	return false
end

_npc.env.node_can_jump_to = function(self, args)
	local pos = args.pos
	if (vector.round(self.object:get_pos()).y + self.data.env.max_jump_height >= pos.y) then
		-- Can jump, let's see now if we have clearance to land
		if (args.check_clearance == true) then
			local height = math.ceil(self.collisionbox[5] - self.collisionbox[2])
			for i = 1, height do
				if (_npc.env.node_is_walkable(self, {pos = {x=pos.x, y=pos.y + i, z=pos.z}}) == false) then
					return false
				end
			end
			return true
		end
		return true
	end
	return false
end

-- TODO: Implement
_npc.env.node_can_drop_to = function(self, args)
	local pos = args.pos
	if (vector.round(self.object:get_pos()).y + self.data.env.max_jump_height >= pos.y) then
		-- Can jump, let's see now if we have clearance to land
		if (args.check_clearance == true) then
			local height = math.ceil(self.collisionbox[5] - self.collisionbox[2])
			for i = 1, height do
				if (_npc.env.node_is_walkable(self, {pos = {x=pos.x, y=pos.y + i, z=pos.z}}) == false) then
					return false
				end
			end
			return true
		end
		return true
	end
	return false
end

-- Find nodes with the following criteria:
--   - radius:  (required if `min_pos` and `max_pos` not given)
--   - min_pos: (required if `max_pos` given and `radius` not given)
--   - max_pos: (required if `min_pos` given and `radius` not given)
--   - nodenames: array of node names to find, required if `categories` not given
--   - categories: array of node category names to find, required if `nodenames` not given
--   - single_match: boolean, find only one node and return that node (optional, default `true`)
--   - owned_only: boolean, only return nodes that are owned by the NPC 
--                (optional, default `nil`, not checked)
--   - used_only: boolean, only find nodes that are used. If false, it will find only un-used
--               nodes (optional, default `nil`, not checked) 
_npc.env.node_find = function(self, args)

	local start_pos = args.pos or vector.round(self.object:get_pos())
	local radius = args.radius or self.data.env.view_range
	local min_pos = args.min_pos
	local max_pos = args.max_pos

	-- Calculate node names if categories are given
	local nodenames = args.nodenames or {}
	if (not args.nodenames and args.categories) then
		for i = 1, #args.categories do
			local category_nodenames = node_group_name_map[args.categories[i]]
			for j = 1, #category_nodenames do
				nodenames[#nodenames + 1] = category_nodenames[j]
			end
		end
	end
	-- If no nodenames then just return
	if (#nodenames == 0) then return nil end

	local nodes_found = {}
	if (not min_pos) and (not max_pos) and (args.single_match == true) then
		nodes_found = minetest.find_node_near(start_pos, radius, args.nodenames)
	end

	-- Calculate area if just radius given
	if (not min_pos) and (not max_pos) and (not args.single_match) then
		local y_radius = args.y_radius or radius
		local y_offset = args.y_offset or 0
		min_pos = {x=start_pos.x - radius, y=(start_pos.y + y_offset) - y_radius, z=start_pos.z - radius}
		max_pos = {x=start_pos.x + radius, y=(start_pos.y + y_offset) + y_radius, z=start_pos.z + radius}
	end

	nodes_found = minetest.find_nodes_in_area(min_pos, max_pos, nodenames)
	minetest.log("Found: "..dump(nodes_found))
	
	if #nodes_found == 0 then return nil end
	if (args.owned_only == nil and args.used_only == nil) then return nodes_found end
	
	-- Apply filters
	local result = {}
	for i = 1, #nodes_found do
		local meta = minetest.get_meta(nodes_found[i])
		local is_owner = meta:get_string("anpc:owner") == self.npc_id
		local is_user = meta:get_string("anpc:user") == self.npc_id
		
		if (args.owned_only == true and is_owner == true) then
			result[#result + 1] = nodes_found[i]
		elseif (args.owned_only == false) then
			result[#result + 1] = nodes_found[i]
		end
		
		if (args.used_only == true and is_user == true) then
			result[#result + 1] = nodes_found[i]
		elseif (args.used_only == false) then
			result[#result + 1] = nodes_found[i]
		end
	end
	
	return result
end

_npc.env.node_npc_is_owner = function(self, args)
	local meta = minetest.get_meta(args.pos)
	local owner = meta:get_string("anpc:owner")
	if owner == self.npc_id then
		return true
	elseif owner ~= "" then
		return false
	else
		return nil
	end
end

_npc.env.node_npc_is_user = function(self, args)
	local meta = minetest.get_meta(args.pos)
	local user = meta:get_string("anpc:user")
	if user == self.npc_id then
		return true
	elseif user ~= "" then
		return false
	else
		return nil
	end
end

-- This function will mark a specific node in the map as owned by
-- the NPC. This can be used to mark nodes such as beds as being
-- owned by a specific NPC and avoid multiple NPCs trying to own same
-- node. This will also add the node to the node store.
_npc.env.node_set_owned = function(self, args)
	local meta = minetest.get_meta(args.pos)
	if (meta) then
		local node = minetest.get_node_or_nil(args.pos)
		local owner = meta:get_string("anpc:owner")
		minetest.log("Owner: "..dump(owner))
		if (owner == self.npc_id) then
			if (args.value == true) then
				return true
			else
				-- Remove from node storage
				_npc.env.node_store_remove(self, {
					pos = args.pos,
					categories = args.categories or {[1] = "generic"}
				})
				-- Remove attribute, set as un-owned
				meta:set_string("anpc:owner", nil)
				return true
			end
		elseif (owner ~= "") then
			-- Unable to change ownership as NPC is not the owner
			return false
		else
			-- Add to node storage
			_npc.env.node_store_add(self, {
				name = node.name,
				label = args.label,
				pos = args.pos,
				categories = args.categories or {[1] = "generic"}
			})
			meta:set_string("anpc:owner", self.npc_id)
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
		elseif (user ~= "") then
			-- Unable to change user as NPC is not the user
			return false
		else
			meta:set_string("anpc:user", self.npc_id)
			return true
		end
	end
end

-- The following functions manages the NPC node store. This store
-- is used to keep track of nodes the NPC cares about.
_npc.env.node_store_add = function(self, args)
	-- Initialize storage
	if not self.data.env.nodes then self.data.env.nodes = {} end
	for i = 1, #args.categories do
		-- Initialize category
		if not self.data.env.nodes[args.categories[i]] then
			self.data.env.nodes[args.categories[i]] = {}
		end
		-- Add node
		local is_primary = args.is_primary
		if is_primary == nil then is_primary = false end
		self.data.env.nodes[args.categories[i]][#self.data.env.nodes[args.categories[i]] + 1] = {
			is_primary = is_primary,
			pos = args.pos,
			name = args.name,
			label = args.label
		}
	end
	minetest.log("Node storage: "..dump(self.data.env.nodes))
end

_npc.env.node_store_get = function(self, args)
	if not self.data.env.nodes then return nil end
	local result = {}
	
	for i = 1, #args.categories do
		if not self.data.env.nodes[args.categories[i]] then return nil end
		for j = 1, #self.data.env.nodes[args.categories[i]] do
			local current = self.data.env.nodes[args.categories[i]][j]
			local found = true
			
			if args.name then found = found and args.name == current.name end
			if args.label then found = found and args.label == current.label end
			if args.pos then found = found and vector.equals(args.pos, current.pos) end
			if args.is_primary then found = found and current.is_primary == true end
			
			if found == true then
				if args.only_one == true then
					return current
				else
					-- Returns a copy so that the originals are not modifiable
					result[#result + 1] = {
						name = current.name,
						label = current.label,
						pos = current.pos,
						is_primary = current.is_primary
					}
				end 
			end
		end
	end
	return result
end

_npc.env.node_store_remove = function(self, args)
	if not self.data.env.nodes then return false end
	
	local deleted_count = 0
	for i = 1, #args.categories do
		if self.data.env.nodes[args.categories[i]] then
			for j = 1, #self.data.env.nodes[args.categories[i]] do
				local current_pos = self.data.env.nodes[args.categories[i]][j].pos
				if vector.equals(current_pos, args.pos) then
					self.data.env.nodes[args.categories[i]][j] = nil
					deleted_count = deleted_count + 1
				end
			end
		end
	end
	
	return deleted_count > 0
end

_npc.env.node_place = function(self, args)
	local pos = args.pos
    local node = args.node
	local param1 = args.param1
	local param2 = args.param2
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
                _npc.model.set_animation(self, {name = "mine_once"})
                -- Place node
                minetest.set_node(pos, {name=node, param1=param1, param2=param2})
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
end

_npc.model.set_animation = function(self, args)

	assert(args.name or args.name == "", "Argument 'name' cannot be nil or empty.")
	local model = models[self.object:get_properties().mesh]
	if not model then return false end
	if not model.animations[args.name] then return false end

	local animation = model.animations[args.name]
	local loop = animation.loop
	local speed = args.speed or animation.speed or 30
	if (loop == nil) then loop = true end
	self.object:set_animation(
        {
            x = animation.start_frame,
            y = animation.end_frame
        },
        speed,
        animation.blend or 0,
        loop
    )

    if ((args.animation_after or animation.animation_after) and loop == false) then
    	minetest.after(
    		(animation.end_frame - animation.start_frame) / animation.speed,
    		_npc.model.set_animation,
    		self, {
    			name = args.animation_after or animation.animation_after
    		})
    end

    return true
end

npc.proc.register_instruction("npc:env:node:operate",
	_npc.env.node_operate)

npc.proc.register_instruction("npc:env:node:get_property",
	_npc.env.node_get_property)
	
npc.proc.register_instruction("npc:env:node:can_stand_in", 
	_npc.env.node_can_stand_in)

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
	
npc.proc.register_instruction("npc:env:node:store:add",
	_npc.env.node_store_add)

npc.proc.register_instruction("npc:env:node:store:get",
	_npc.env.node_store_get)

npc.proc.register_instruction("npc:env:node:store:remove",
	_npc.env.node_store_remove)

npc.proc.register_instruction("npc:env:node:place", 
	_npc.env.node_place)

npc.proc.register_instruction("npc:env:node:dig", function(self, args)
	local pos = args.pos
    if pos then
    	minetest.log("Digging at: "..minetest.pos_to_string(pos))
    	_npc.model.set_animation(self, {name = "mine_once"})
    	minetest.dig_node(pos)
   	end
end)

-- Use this when you need the NPC to do a `minetest.set_node`.
-- This will not check for protection, or check if the node is buildable, etc.
npc.proc.register_instruction("npc:env:node:set", function(self, args)
	local pos = args.pos
	local node = args.node
	local param1 = args.param1
	local param2 = args.param2
	if pos and node then
		minetest.log("NPC Replacing node at "..minetest.pos_to_string(pos))
		_npc.model.set_animation(self, {name = "mine_once"})
		minetest.set_node(pos, {name=node, param1=param1, param2=param2})
	end
end)

npc.proc.register_instruction("npc:env:node:set_metadata", function(self, args)
	local pos = args.pos
	if pos then
		local meta = minetest.get_meta(args.pos)
		meta:set_string("infotext", args.meta)
	end
end)

-- Gets the node at the given position
npc.proc.register_instruction("npc:env:node:get", function(self, args)
	local pos = args.pos
	if pos then
		return minetest.get_node_or_nil(pos)
	end
end)

npc.proc.register_instruction("npc:env:node:get_metadata", function(self, args)
	local pos = args.pos
	if pos then
		return minetest.get_meta(args.pos)
	end
end)

npc.proc.register_instruction("npc:chat:send_player", function(self, args)
	minetest.chat_send_player(args.player, args.message)
end)

npc.proc.register_instruction("npc:util:str:replace", function(self, args)
	local str = args.str
	local target = args.target
	local replacement = args.replacement
	if str then
		return string.gsub(str, target, replacement)
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

npc.proc.register_instruction("npc:model:set_animation", _npc.model.set_animation)

-----------------------------------------------------------------------------------
-- Object instructions
-----------------------------------------------------------------------------------
npc.proc.register_instruction("npc:obj:get_pos", function(self, args)
	local obj = args.object
	if obj and type(obj) == "userdata" then 
		if args.round then return vector.round(obj:get_pos()) else return obj:get_pos() end
	else
		return nil
	end
end)

npc.proc.register_instruction("npc:obj:get_yaw", function(self, args)
	local obj = args.object
	if obj and type(obj) == "userdata" then
		return obj:get_yaw()
	else
		return nil
	end
end)

npc.proc.register_instruction("npc:obj:get_dir", function(self, args)
	local obj = args.object
	if obj and type(obj) == "userdata" then
		if args.round then return vector.round(minetest.yaw_to_dir(obj:get_yaw())) else return minetest.yaw_to_dir(obj:get_yaw()) end		
	else
		return nil
	end
end)

npc.proc.register_instruction("npc:obj:get_velocity", function(self, args)
	local obj = args.object
	if obj and type(obj) == "userdata" then
		if args.round then return vector.round(obj:get_velocity()) else return obj:get_velocity() end
	else
		return nil
	end
end)

-- TODO: get_acceleration

-----------------------------------------------------------------------------------
-- Movement instructions
-----------------------------------------------------------------------------------

npc.proc.register_instruction("npc:move:stand", function(self, args)
	self.object:set_velocity({x=0, y=0, z=0})
	-- TODO: Check if animation is registered
	_npc.model.set_animation(self, {name = "stand"})
end)

npc.proc.register_instruction("npc:move:rotate", function(self, args)
	local pos = args.target_pos
	if not pos then return end
	local dir = vector.direction(self.object:get_pos(), args.target_pos)
	local yaw = minetest.dir_to_yaw(dir)
	self.object:set_yaw(yaw)
end)

npc.proc.register_instruction("npc:move:get_pos", function(self, args)
	local round = args.round
	if args.round then
		return vector.round(self.object:get_pos())
	else
		return self.object:get_pos()
	end
end)

npc.proc.register_instruction("npc:move:to_pos", function(self, args)
	self.object:move_to(args.pos, true)
end)

--
_npc.move.jump = function(self, args)

	local trgt_pos = args.target_pos
	--local yaw = args.yaw
	--local cardinal_dir = args.cardinal_dir
	local range = args.range or 1 -- horizontal distance the NPC will move on jump
	local speed = args.speed or 1

	local self_pos = vector.round(self.object:get_pos())
	local dir = vector.direction(self_pos, trgt_pos)

	-- Checks nodes in front to
	local next_pos_front = {x = self_pos.x + dir.x, y = self_pos.y, z = self_pos.z + dir.y}
	local next_pos_below = {x = self_pos.x + dir.x, y = self_pos.y - 1, z = self_pos.z + dir.z}
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

	local mid_point = (self.collisionbox[5] - self.collisionbox[2]) / 2

	-- Based on range, doesn't takes time into account
	local y_speed = math.sqrt ( (10 * range) / (math.sin(2 * (math.pi / 3))) ) + mid_point
	if (next_y_diff == -1) then y_speed = 0 end
--	local x_speed = 1
--	if (next_y_diff == -1) then
--		x_speed = 1 / (math.sqrt( (2 + mid_point) / (10) ))
--	end

	minetest.log("This is y_speed: "..dump(y_speed))

	self.object:set_pos(self_pos)
	local vel = {x=dir.x * speed, y=y_speed, z=dir.z * speed}
	self.object:set_velocity(vel)
	npc.proc.execute_ll_task(self, "npc:move:jump")

end

npc.proc.register_instruction("npc:move:jump", _npc.move.jump)

-- This instruction sets the NPC in motion towards a specific direction at
-- a specific speed. Notice that this instruction *doesn't* provides
-- pathfinding. Also, notice this doesn't stops the NPC once in motion.
-- The stop has to be done separately by using the instruction `npc:move:stand`.
-- These are the different ways to use it:
--   1. If a `target_pos` is provided, the NPC will rotate to that position
--      and will walk towards it.
--   2. If a `yaw` is provided, the NPC will rotate according to the yaw
--      and walk.
--   3. If a `cardinal_dir` is provided, the NPC will turn to that direction
--      and walk. The cardinal direction goes from 0-7, and represent north
--      to north-west in a clockwise fashion.

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

	-- TODO: The below is probably dealt with better in a program
	-- WARNING: The below is currently halted.
	-- 			It is possible this code will not be used anymore.
	-- 
	-- Obstacle avoidance: in order to use this instruction in a loop,
	-- some obstacle avoidance features can be enabled via arguments. In
	-- general, these are the possible obstacle avoidance:
	--   1. The NPC will jump over any jumpable-obstacle
	--   2. For unjumpable obstacles, the NPC will evade obstacles in a
	--      given distance by turning on any direction between -90 and
	--		90 degrees from the current direction.
	--   3. The NPC will not fall down a specified distance and will instead
	--      turn around in a -90 to 90 degrees. If that fails, the NPC will
	--      turn 180 degrees around.

--	if (args.avoid_obstacles) then
--		-- Check for solid obstacles
--		local obstacle_radius = args.obstacle_detection_radius or 3
--		local obstacle_pos = {}
--		for i = 2, obstacle_radius + 1 do
--			obstacle_pos.x = self_pos.x + (dir.x * obstacle_radius)
--			obstacle_pos.y = self_pos.y,
--			obstacle_pos.z = self_pos.z + (dir.z * obstacle_radius)
--			local obstacle_node = minetest.get_node_or_nil(obstacle_pos)

--		end
--
--		if (obstacle_node and obstacle_node.name
--			and minetest.registered_nodes[obstacle_node.name].walkable == true) then
--			-- Check nodes above, obstacle may be jumpable
--			if (args.enable_obstacle_jump) then
--				-- TODO: Check all nodes between this and up to NPC's height?
--				local node_above = minetest.get_node_or_nil({
--					x=obstacle_pos.x,
--					y=obstacle_pos.y + self.data.env.max_jump_height,
--					z=obstacle_pos.z})
--				if (node_above and node_above.name
--					and minetest.registered_nodes[node_above].walkable == false) then

--					minetest.log("Jumping to "..minetest.pos_to_string(node_above))
--					_npc.move.jump(self, {target_pos = node_above})
--				end
--			end

--		end

--	end

	-- TODO: Continue..
--	if (args.avoid_drops) then
--		-- Check for drops
--		local node_below = minetest.get_node_or_nil({x=trgt_pos.x, y=trgt_pos.y-1, z=trgt_pos.z})
--	end

	local yaw = args.yaw or minetest.dir_to_yaw(dir)
	if not velocity then velocity = vector.multiply(dir, speed) end

	self.object:set_yaw(yaw)
	self.object:set_velocity(velocity)
	_npc.model.set_animation(self, {name = "walk", speed = 30})
end)

-- Walk instruction using pathfinding
-- Supports position lag correction, climbing stairs/slabs, jumping and opening doors
npc.proc.register_instruction("npc:move:walk_to_pos", function(self, args)
	minetest.log("Arguments: "..dump(args))
	local result = false
	local u_self_pos = self.object:get_pos()
	local self_pos = vector.round(u_self_pos)
	local trgt_pos = args.target_pos
	local speed = args.speed or 2

	-- Calculate process timer interval
	self.data.proc[self.process.current.id]["_prev_proc_int"] = self.timers.proc_int
	self.timers.proc_int = (1/speed) / 2

	local prev_proc_timer_value = self.data.proc[self.process.current.id]["_prev_proc_int"]-- or 0.5

	-- Find path
	if args.check_end_pos_walkable == true then
		trgt_pos = _npc.env.node_get_accessing_pos(self, trgt_pos)
	end

	-- Correct self pos if NPC is lagging behind
	minetest.log("Before correction pos: "..minetest.pos_to_string(self.object:get_pos()))
	local prev_trgt_pos = self.data.proc[self.process.current.id]["_prev_trgt_pos"]
-- 	if (prev_trgt_pos ~= nil
-- 		and self.data.proc[self.process.current.id]["_do_correct_pos"] ~= false) then
-- 		local dist = vector.distance(prev_trgt_pos, u_self_pos)
-- 		if (dist > 0.25) then
-- 			-- Expensive(?) check to see that we are not going backwards
-- 			-- when correcting position... wonder if it's worth it.
-- 			-- This checks that the direction from the NPC's position to the
-- 			-- previous target (from last iteration) is not pointing backwards
-- 			-- (from the NPC perspective).
-- 			--
-- 			 local prev_dir = self.data.proc[self.process.current.id]["_prev_trgt_dir"]
-- 			 local prev_yaw = minetest.dir_to_yaw(prev_dir)
-- 			 local dir_to_prev_pos = vector.direction(u_self_pos, prev_trgt_pos)
-- 			 local yaw_to_prev_pos = minetest.dir_to_yaw(dir_to_prev_pos)
-- 			 local min_yaw = prev_yaw - math.pi/2
-- 			 local max_yaw = prev_yaw + math.pi/2

-- 			 if (min_yaw <= yaw_to_prev_pos and yaw_to_prev_pos <= max_yaw)
-- 			    or (prev_trgt_pos.x == trgt_pos.x and prev_trgt_pos.z == trgt_pos.z) then
-- 				  minetest.log("Corrected NPC pos from "..minetest.pos_to_string(self_pos).." to "..minetest.pos_to_string(prev_trgt_pos))
-- 				  -- This removes some annoying jumping
-- 				  local trgt_y = prev_trgt_pos.y
-- 				  if (math.abs(trgt_y - u_self_pos.y) < 1) then trgt_y = u_self_pos.y end
-- 				  self.object:move_to({x=prev_trgt_pos.x, y=trgt_y, z=prev_trgt_pos.z}, true)
-- 				  self_pos = prev_trgt_pos
-- 			 end

-- 			-- Simplified check for the same thing above. This checks that the direction
-- 			-- is not *exactly* the opposite as the current dir. This *will not* catch
-- 			-- every single instance of annoying back-jumps, but is a very simple check.
-- --			local prev_dir = self.data.proc[self.process.current.id]["_prev_trgt_dir"]
-- --			local dir_to_prev_pos = vector.direction(u_self_pos, prev_trgt_pos)
-- --
-- --			if (dir_to_prev_pos ~= vector.multiply(prev_dir, -1)) then
-- --				minetest.log("Corrected NPC pos from "..minetest.pos_to_string(u_self_pos).." to "..minetest.pos_to_string(prev_trgt_pos))
-- --				-- This removes some annoying jumping
-- --				local trgt_y = prev_trgt_pos.y
-- --				--if (math.abs(trgt_y - u_self_pos.y) < 1) then trgt_y = u_self_pos.y end
-- --				self.object:move_to({x=prev_trgt_pos.x, y=trgt_y, z=prev_trgt_pos.z}, true)
-- --				self_pos = prev_trgt_pos
-- --			end
-- 		end
-- 	else
-- 		-- Let correction work on next call
-- 		self.data.proc[self.process.current.id]["_do_correct_pos"] = nil
-- 	end

	-- Return if target pos is same as start pos
	if self_pos.x == trgt_pos.x
		and self_pos.z == trgt_pos.z
		and math.abs(trgt_pos.y - self_pos.y) < 0.5 then
		minetest.log("Same self pos and target pos")
		--minetest.log("Target pos: "..minetest.pos_to_string(trgt_pos))
		--minetest.log("The original target pos: "..minetest.pos_to_string(args.original_target_pos))
		-- Stop NPC
		self.object:set_velocity({x = 0, y = 0, z = 0})
		-- TODO: Check if animation exists?
		_npc.model.set_animation(self, {name = "stand"})
		if args.original_target_pos and
			(args.original_target_pos.x ~= trgt_pos.x or args.original_target_pos.z ~= trgt_pos.z) then
			self.object:set_yaw(minetest.dir_to_yaw(vector.direction(trgt_pos, args.original_target_pos)))
		end
		-- Restore process timer interval
		self.timers.proc_int = prev_proc_timer_value
		return true
	end

	-- For the purposes of the pathfinder - we assume stepheight = 1.
	-- TODO: make this configurable. What if we want more than just 1 because
	-- we have a bigger-than-two-nodes NPC?
	self.object:set_properties({stepheight = 1})
	local path = npc.pathfinder.find_path(self_pos, trgt_pos, self, true)
	self.object:set_properties({stepheight = 0.6})
	if not path then
		-- Restore process timer interval
		self.timers.proc_int = prev_proc_timer_value
		if args.force == true then
			self.object:move_to(trgt_pos, false)
		end
		return nil
	end

	minetest.log("Path: "..dump(path))

	-- Move towards position
	local next_node = path[1]
	if next_node.pos.x == self_pos.x and next_node.pos.z == self_pos.z and #path > 1 then
		next_node = path[2]
	end

	local next_pos = next_node.pos

	local dir = vector.direction(u_self_pos, next_pos)
	local yaw = minetest.dir_to_yaw(dir)

	-- Store next target pos for position correction
	self.data.proc[self.process.current.id]["_prev_trgt_pos"] = next_pos
	self.data.proc[self.process.current.id]["_prev_trgt_dir"] = dir

	-- Rotate towards next node
	self.object:set_yaw(yaw)

	-- Diagonal movement speed must be increased
	if (dir.x ~= 0 and dir.z ~= 0) then speed = speed * math.sqrt(2) end

	local next_node_below = minetest.get_node({x=next_pos.x, y=next_pos.y-1, z=next_pos.z})

	-- Small hack: avoid jumping if we are looking at stairs or slabs.
	-- TODO: Make it better. Maybe, from the NPC's stepheight, create
	-- a raycast in a 45 grade incline. If the raycast doesn't inersects
	-- anything, we can walk the incline. Otherwise, we jump.
	local is_incline = false
	local is_walkable_incline = false
	if (next_pos.y >= u_self_pos.y + 1) then
		is_incline = true
		if (minetest.get_item_group(next_node_below.name, "stair") > 0
			or minetest.get_item_group(next_node_below.name, "slab") > 0) then
			is_walkable_incline = true
		end
	end

	if (is_incline and not is_walkable_incline) then
		-- Jump
		minetest.log("Jumping to "..minetest.pos_to_string(next_pos))
		_npc.move.jump(self, {target_pos = next_pos})
	else
		local y_speed = -10
		if (is_walkable_incline == true) then
			self.data.proc[self.process.current.id]["_do_correct_pos"] = false
		end

		-- Walk
		local vel = vector.multiply({x=dir.x, y=y_speed, z=dir.z}, speed)

		self.object:set_velocity(vel)
		_npc.model.set_animation(self, {name = "walk", speed = 30})
	end

	-- If openable, check the state. If it's open, NPC will close. If it's closed,
	-- NPC will open and close.
	if next_node.type == npc.pathfinder.node_types.openable then

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
	assert(program_table[name] ~= nil, "Program with name '"..name.."' is not a registered program")
	-- Enqueue process - this is a priority enqueue
	local tail = self.process.queue_tail
	local head = self.process.queue_head
	if self.process.queue_tail < self.process.queue_head then
		tail = self.process.queue_head
		head = self.process.queue_tail
	end
	for i = tail + 1, head + 1, -1 do
		self.process.queue[i] = self.process.queue[i - 1]
	end

	-- Pre-process program arguments - userdata arguments cause crashes!
	if args then
		for key, value in pairs(args) do
			if type(value) == "userdata" then
				args[key] = _npc.dsl.generate_tracking_record(self, value)
			end
		end
	end

	self.process.queue_tail = self.process.queue_tail + 1
	self.process.queue[self.process.queue_head] = {
		id = self.process.key,
		name = name,
		args = args,
		instruction = 1--program_table[name].initial_instruction
	}

	-- TODO: Key is 100, but queue_head = 1. It happened.
	self.process.key = (self.process.key + 1) % 100

	self.process.current = self.process.queue[self.process.queue_head]
end

npc.proc.enqueue_program = function(self, name, args)

	self.process.queue_tail = self.process.queue_tail + 1
	self.process.queue[self.process.queue_tail] = {
		id = self.process.key,
		name = name,
		args = args,
		instruction = 1--program_table[name].initial_instruction
	}

	-- TODO: Key is 100, but queue_head = 1. It happened.
	self.process.key = (self.process.key + 1) % 100
end

_npc.proc.execute_instruction = function(self, name, raw_args, result_key)
	assert(instruction_table[name] ~= nil, "Unknown instruction: "..name)

	-- Un-comment to debug instructions that are crashing
	--minetest.log("["..dump(self.process.current.name).."]: ["..dump(self.process.current.instruction).."] "..dump(name))
	--minetest.log("[Raw arguments]: "..dump(raw_args))
	
	local processed_args = {}
	if raw_args then
		for arg_key,arg_value in pairs(raw_args) do
			processed_args[arg_key] = 
				_npc.dsl.evaluate_argument(self, arg_value, raw_args, self.data.proc[self.process.current.id])
		end
	end

	-- Increase the current instruction before execution of program - on re-entry,
	-- this will cause going to next instruction
	if (name == "npc:execute") then
		self.process.current.instruction = self.process.current.instruction + 1
	end

	local result = instruction_table[name](self, processed_args)
	if (result_key) then
		--minetest.log("Instruction returned: "..dump(result))
		--minetest.log("This is the result_key: "..dump(result_key))
		_npc.dsl.set_var(self, result_key, result)
	end

	local env_si, env_ei = string.find(name, "npc:env:")
	if name == "npc:jump"
		or name == "npc:jump_if"
		or name == "npc:break"
		or name == "npc:var:get"
		or name == "npc:var:set"
		or name == "npc:timer:instr:start"
		or name == "npc:timer:instr:stop"
		or name == "npc:get_proc_interval"
		or env_si ~= nil then

		-- Execute next instruction now if possible
		self.process.current.instruction = self.process.current.instruction + 1

		local instruction = program_table[self.process.current.name].instructions[self.process.current.instruction]
		--minetest.log("[exec_instr] "..dump(instruction))
		if instruction then
			-- Break at this point if breakpoint is found
			if instruction.pause == true and not instruction.override and is_dev_mode == true then
				self.debug.pause = true
				
				-- Update debug screen if being shown
				if self.debug and self.debug.show_debugger == true then
					npc_dev.show_debug_formspec(npc_dev.source, self.object)
				end
				return
			end
			
			-- Remove breakpoint override so that next time it hits the breakpoint again
			if instruction.override == true then
				instruction.override = false
			end

			_npc.proc.execute_instruction(self, instruction.name, instruction.args, instruction.key)
        end

	end
end

npc.proc.execute_ll_task = function(self, name, args)
	assert(hl_task_table[name] ~= nil, "Low-latency task '"..dump(name).."' doesn't exists.'")

	local task = hl_task_table[name]

	-- TODO: Decide whether pre-process and evaluate on execution or not.
	-- Currently wiping out is the solution - this should be fast, which is what ll tasks is about
	-- Pre-process arguments
	-- if args then
	-- 	for key, value in pairs(args) do
	-- 		if type(value) == "userdata" then
	-- 			args[key] = _npc.dsl.generate_tracking_record(self, value)
	-- 		end
	-- 	end
	-- end

	-- If we have a current LL task running, put it into the stack
	if self.process.low_latency_task.active == true then
		table.insert(self.process.low_latency_task_stack, 1, {name = self.process.low_latency_task.name, args = self.process.low_latency_task.args})
	end

	self.process.low_latency_task.name = name
	self.process.low_latency_task.args = args
	self.process.low_latency_task.handler = task.handler
	self.process.low_latency_task.timeout_handler = task.timeout_handler
	self.process.low_latency_task.active = true
	self.timers.hl_task_value = 0
end

npc.proc.enqueue_process = function(self, name, args)
	-- Enqueue process
	self.process.queue[self.process.queue_tail] = {
		id = self.process.key,
		name = name,
		args = args,
		instruction = program_table[name].initial_instruction
	}

	-- TODO: Key is 100, but queue_head = 1. It happened.
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

npc.proc.set_state_process = function(self, name, args, clear_queue)
	self.process.state.id = self.process.key
	self.process.state.name = name

	-- Pre-process program arguments - userdata arguments cause crashes!
	if args then
		for key, value in pairs(args) do
			if type(value) == "userdata" then
				args[key] = _npc.dsl.generate_tracking_record(self, value)
			end
		end
	end

	self.process.state.args = args

	if (clear_queue == true) then
		self.process.queue_head = 1
		self.process.queue_tail = 1
		self.process.queue = {}
		-- Clear current process, that way, state process should be picked
		self.process.current = {}
	end
	
	self.process.program_changed = true

	-- TODO: Key is 100, but queue_head = 1. It happened.
	-- This is probably fixed already by new queue logic
	self.process.key = (self.process.key + 1) % 100
end	

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Lua Entity Callbacks															 --
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
npc.do_step = function(self, dtime)
	
	-- Support for debug
	if self.debug and self.debug.pause then
		return
	end

	-------------------------------------------------------------------------------
	-- Timers
	-- Increment timers and gets basic environmental information
	-------------------------------------------------------------------------------
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

	-- TODO: Implement scheduled interrupts
	--       e.g. npc:event:schedule(time = 22000, name = "program_name")

	-------------------------------------------------------------------------------
	-- Low-latency tasks
	if self.process.low_latency_task.active == true then
		self.timers.hl_task_value = self.timers.hl_task_value + dtime
		--minetest.log("LL Task interval: "..dump(self.timers.hl_task_value))
		--minetest.log("Active LL task: "..dump(self.process.low_latency_task.name))
		local args = self.process.low_latency_task.args
		local is_finished = false
		-- Check timeout
		if (self.timers.hl_task_value >= self.timers.hl_task_int) then
			if (self.process.low_latency_task.timeout_handler) then
				self.process.low_latency_task.timeout_handler(self, dtime, args)
			end
			is_finished = true
		else
			if (self.process.low_latency_task.handler) then
				is_finished = self.process.low_latency_task.handler(self, dtime, args)
				--minetest.log("Is finished: "..dump(is_finished))
			else
				-- If no handler exists, cut it short
				is_finished = true
			end
		end

		if (is_finished == true) then
			-- Remove low latency task
			self.timers.hl_task_value = 0
			self.process.low_latency_task.active = false
			self.process.low_latency_task.args = nil
			self.process.low_latency_task.handler = nil
			
			-- Check if we have a low latency task on the stack
			-- and run it if we do
			minetest.log("This is the stack!"..dump(self.process.low_latency_task_stack))
			if #self.process.low_latency_task_stack > 0 then
				minetest.log("Before pop: "..dump(#self.process.low_latency_task_stack))
				local top = self.process.low_latency_task_stack[1]
				minetest.log("Now executing task: "..dump(name))
				npc.proc.execute_ll_task(self, top.name, top.args)
				table.remove(self.process.low_latency_task_stack)
				minetest.log("After pop: "..dump(#self.process.low_latency_task_stack))
				-- Avoid execution of the process queue
				return
			end
		else
			-- Avoid execution of the process queue
			return
		end

	end

	-------------------------------------------------------------------------------
	-- Process functionality
	-------------------------------------------------------------------------------
	if (self.timers.proc_value > self.timers.proc_int) then
		self.timers.proc_value = 0
		local current = self.process.current

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

		-------------------------------------------------------------------------------
		-- Process queue
		
		-- Check if there is a current process
		if self.process.current.name ~= nil then

			-- Step 1: Check if the program is done.
			-- If the program is done, check if it is a state process.
			-- If it is a state process, the process is restarted.
			-- If not, the process is dequeued.
			if self.process.current.instruction >
				#program_table[self.process.current.name].instructions then
				-- If process is state process, reset instruction counter
				-- and re-run the process
				if self.process.current.name == self.process.state.name then
					self.process.current.instruction =
						program_table[self.process.current.name].initial_instruction
				else
					-- No more instructions, dequeue process
					local next_head = (self.process.queue_head + 1) % 100
					if next_head == 0 then next_head = 1 end
					self.process.queue[self.process.queue_head] = nil
					self.process.current.name = nil
					self.process.current.instruction = -1
					self.process.queue_head = next_head
					-- Clear memory of the dequeued process
					self.data.proc[self.process.current.id] = nil
				end
				-- minetest.log("Condition: "..dump(self.process.queue_tail)..", "..dump(self.process.queue_head))
				-- minetest.log("Condition: "..dump(self.process.queue))
				-- minetest.log("Condition: "..dump(self.process.queue[self.process.queue_head]))
				
				-- Step 2: Check if there is another process in queue.
				-- If there is, execute that process.
				-- If there's not, then execute the default state process
				if self.process.queue[self.process.queue_head] == nil then
					-- If there's a process at the end of tail, execute that one
					if self.process.queue[self.process.queue_tail] ~= nil then
						self.process.current = self.process.queue[self.process.queue_tail]
						-- Reset head and tail
						self.process.queue_head = 1
						self.process.queue_tail = 1
					-- Else, just execute state process
					else
						-- Execute state process, if present
						if self.process.state.name ~= nil then
							self.process.current.id = self.process.state.id
							self.process.current.name = self.process.state.name
							self.process.current.args = self.process.state.args
							self.process.current.instruction =
								program_table[self.process.current.name].initial_instruction
							self.process.queue[self.process.queue_head] = self.process.current
						end
					end	
				end 
			end
		-- If there's no current process, then try to find one to execute
		else
			-- Check if there is a process in queue
			if (self.process.queue_tail > self.process.queue_head)
				or (self.process.queue[self.process.queue_head] ~= nil) then
				self.process.current = self.process.queue[self.process.queue_head]

			-- Check if there is a state process
			elseif self.process.state.name ~= nil then
				self.process.current.id = self.process.state.id
				self.process.current.name = self.process.state.name
				self.process.current.args = self.process.state.args
				self.process.current.instruction =
					program_table[self.process.current.name].initial_instruction
				self.process.queue[self.process.queue_head] = self.process.current
			end
		end

		--minetest.log("Process now: "..dump(self.process))

		-- Execute next instruction, if available
		if self.process.current.instruction > -1 then
			local instruction =
				program_table[self.process.current.name].instructions[self.process.current.instruction]
			-- Check if there are no more instructions. This happens usually when the last instruction
			-- of a program is "npc:execute".
			if instruction == nil then
				minetest.log("Process now: "..dump(self.process))
				return
			end
			
			-- Only perform this check if in dev mode
			-- Break at this point if "pause" is found
			if is_dev_mode == true then
				if instruction.pause == true and not instruction.override and is_dev_mode == true then
					self.debug.pause = true
					-- Update debug screen if being shown
					if self.debug and self.debug.show_debugger == true then
						npc_dev.show_debug_formspec(npc_dev.source, self.object)
					end
					return
				end
			end
			
			-- Remove breakpoint override so that next time it hits the breakpoint again
			if instruction.override == true then
				instruction.override = false
			end
			
			--minetest.log("[do_step] Current instruction: "..dump(instruction))
			_npc.proc.execute_instruction(self, instruction.name, instruction.args, instruction.key)
            --minetest.log("Next 2")
            if self.process.program_changed == false then
                self.process.current.instruction = self.process.current.instruction + 1
            else self.process.program_changed = false end
		end
		
		-- Update debug screen
		if self.debug and self.debug.show_debugger == true then
			npc_dev.show_debug_formspec(npc_dev.source, self.object)
		end
	end

end

npc.on_activate = function(self, staticdata)
	if staticdata ~= nil and staticdata ~= "" then
		local cols = string.split(staticdata, "|")
		self["npc_id"] = cols[1]
		self["timers"] = minetest.deserialize(cols[2])
		self["process"] = minetest.deserialize(cols[3])
		self["data"] = minetest.deserialize(cols[4])
		self["debug"] = minetest.deserialize(cols[5])
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
			proc_int = 0.5,
			hl_task_value = 0,
			hl_task_int = 0.1
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
			queue = {},
			low_latency_task_stack = {},
			low_latency_task = {
				handler = nil,
				timeout_handler = nil,
				args = {},
				active = false
			}
		}

		self.data = {
			env = {},
			global = {},
			proc = {},
			temp = {},
			schedule = {}
		}
		
		self.debug = {
			show_debugger = false,
			pause = false
		}

		-- These values should be customizable, but these are default
		self.data.env.view_range = 12
		local height = self.collisionbox[5] - self.collisionbox[2]
		self.data.env.max_jump_height = math.ceil(height / 2)
		self.data.env.max_drop_height = math.ceil(height / 2)

	end

	self.object:set_acceleration({x=0, y=-10, z=0})

end

npc.get_staticdata = function(self)

	local result = ""
	if self.npc_id then
		result = result..self.npc_id.."|"
	end

	if self.timers then
		result = result..minetest.serialize(self.timers).."|"
	end

	if self.process then
		self.process.low_latency_task_stack = {}
		self.process.low_latency_task = {}
		result = result..minetest.serialize(self.process).."|"
	end

	if self.data then
		self.data.env.objects = {}
		self.data.temp = {}
		result = result..minetest.serialize(self.data).."|"
	end
	
	if self.debug then
		result = result..minetest.serialize(self.debug).."|"
	end

	return result

end

npc.set_debug = function(self, is_debug)
	if not self.debug then
		self.debug = {}
	end
	
	if is_debug == false then
		self.timers.proc_int = 0.5
	else
		self.timers.proc_int = 1.5
	end
		
	self.debug.show_debugger = is_debug
end

-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
-- Built-in programs
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
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

-----------------------------------------------------------------------------------
-- Built-in low-latency tasks
-----------------------------------------------------------------------------------

npc.proc.register_low_latency_task("npc:move:jump", function(self, dtime, args)
	local vel = self.object:get_velocity()
	if (vel.y == 0) then
		self.object:set_velocity({x=0, y=0, z=0})
		-- Landed
		return true
	end
	-- Not landed yet
	return false
end)

-- TODO: This needs to be optimized as much as possible!
-- 1. Consider what is our target.
--    a. If node, calculate path once, then use it
--    b. If object, move toward it
-- 2. On both instances, always save our previous position
-- 3. If we have been stuck for 2-3 turns (configurable!), then use pathfinder
-- Walk instruction using pathfinding and low-latency tasks
-- This is a possibly expensive operation!
-- Supports climbing stairs/slabs, jumping and opening doors
npc.proc.register_low_latency_task("npc:move:walk_to", function(self, dtime, args)
	local result = false
	local u_self_pos = self.object:get_pos()
	local self_pos = vector.round(u_self_pos)

	--minetest.log("Args: "..dump(args))

	local u_trgt_pos = nil
	if args.target then
		u_trgt_pos = args.target:get_pos() 
	elseif args.target_pos then
		u_trgt_pos = args.target_pos
	else
		-- Cannot find a target to walk to
		return false
	end

	local trgt_pos = vector.round(u_trgt_pos)
	local speed = args.speed or 3
	local trgt_distance = args.target_distance or 1.5
	
	local look_at_trgt = args.look_at_target

	local path = self.data.temp["_npc_walk_to_ll_path"]
	local self_prev_pos = self.data.temp["_npc_walk_to_ll_self_prev_pos"]
	local trgt_prev_pos = self.data.temp["_npc_walk_to_ll_trgt_prev_pos"]
	local min_self_move_distance = args.min_self_move_distance or 0.25
	local min_trgt_move_distance = args.min_self_move_distance or 0.25

	if args.check_end_pos_walkable == true and not args.target then
		trgt_pos = _npc.env.node_get_accessing_pos(self, trgt_pos)
	end

	-- Check if we are done
	local distance = vector.distance(u_self_pos, u_trgt_pos)
	--minetest.log("Distance: "..dump(distance))
	if distance <= trgt_distance then
		self.object:set_velocity({x = 0, y = 0, z = 0})
		-- TODO: Check if animation exists?
		_npc.model.set_animation(self, {name = "stand"})
		return true
	end


	minetest.log("No path: "..dump(path == nil or #path == 0))

	if (path == nil or #path == 0)
		--or (self_prev_pos ~= nil and vector.distance(self_prev_pos, u_self_pos) < min_self_move_distance)
		or (trgt_prev_pos ~= nil and vector.distance(trgt_prev_pos, u_trgt_pos) > min_trgt_move_distance) then
			--minetest.log("Using pathfinder...")
			self.object:set_properties({stepheight = 1})
			path = npc.pathfinder.find_path(self_pos, trgt_pos, self, true)
			self.object:set_properties({stepheight = 0.6})
			if not path then
				if args.force == true then
					self.object:move_to(trgt_pos, false)
				end

				-- Stop NPC
				self.object:set_velocity({x = 0, y = 0, z = 0})
				-- TODO: Check if animation exists?
				_npc.model.set_animation(self, {name = "stand"})
				return true
			end	
		end

	-- Move towards position
	local next_node = path[1]
	if next_node.pos.x == self_pos.x and next_node.pos.z == self_pos.z and #path > 1 then
		next_node = path[2]
		table.remove(path)
	end

	table.remove(path)
	self.data.temp["_npc_walk_to_ll_path"] = path

	local next_pos = next_node.pos

	local dir = vector.direction(u_self_pos, next_pos)
	local yaw = 0
	if look_at_trgt then
		yaw = minetest.dir_to_yaw(vector.direction(u_self_pos, u_trgt_pos))
	else
		yaw = minetest.dir_to_yaw(dir)
	end

	-- Rotate towards next node
	self.object:set_yaw(yaw)

	-- Diagonal movement speed must be increased
	if (dir.x ~= 0 and dir.z ~= 0) then speed = speed * math.sqrt(2) end

	local next_node_below = minetest.get_node({x=next_pos.x, y=next_pos.y-1, z=next_pos.z})

	-- Small hack: avoid jumping if we are looking at stairs or slabs.
	-- TODO: Make it better. Maybe, from the NPC's stepheight, create
	-- a raycast in a 45 grade incline. If the raycast doesn't inersects
	-- anything, we can walk the incline. Otherwise, we jump.
	local is_incline = false
	local is_walkable_incline = false
	if (next_pos.y >= u_self_pos.y + 1) then
		is_incline = true
		if (minetest.get_item_group(next_node_below.name, "stair") > 0
			or minetest.get_item_group(next_node_below.name, "slab") > 0) then
			is_walkable_incline = true
		end
	end

	if (is_incline and not is_walkable_incline) then
		-- Jump
		--minetest.log("Jumping to "..minetest.pos_to_string(next_pos))
		_npc.move.jump(self, {target_pos = next_pos})
	else
		local y_speed = self.object:get_velocity().y
		--minetest.log("Walking to "..dump(minetest.pos_to_string(dir)))

		-- Walk
		local vel = vector.multiply({x=dir.x, y=y_speed, z=dir.z}, speed)

		self.object:set_velocity(vel)
		_npc.model.set_animation(self, {name = "walk", speed = 30})
	end

	-- If openable, check the state. If it's open, NPC will close. If it's closed,
	-- NPC will open and close.
	if next_node.type == npc.pathfinder.node_types.openable then

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

	self.data.temp["_npc_walk_to_ll_prev_self_pos"] = self.object:get_pos()
	if args.target then self.data.temp["_npc_walk_to_ll_prev_trgt_pos"] = args.target:get_pos() end

    return false

end)

npc.proc.register_instruction("npc:move:walk_to_pos_ll", function(self, args)
	self.timers.hl_task_int = 30
	npc.proc.execute_ll_task(self, "npc:move:walk_to", args)
end)

---------------------------------------------------------------------
-- WARNING: Below are stuff for testing. Remove from final version
-- 		    of mod
---------------------------------------------------------------------

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

-----------------------------------------------------------------------------------
-- Node registrations
-----------------------------------------------------------------------------------

npc.env.register_node("doors:door_wood_a", {"openable", "doors"},
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

npc.env.register_node("doors:door_wood_b", {"openable", "doors"},
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


