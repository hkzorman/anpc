-- The anpc API

local _npc = {
	dsl   = {},
	proc  = {},
	env   = {},
	obj	  = {},
	move  = {},
	model = {},
	follow_speed_logged = false
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
	end
	-- The accessing node must be at the same height as the target node; only
	-- if there is no node to stand at that height do we fall back to one block
	-- below or above the target. It must not be flattened to the NPC's own y,
	-- which put path targets at the NPC's level for goals above the current floor.
	local target_node = minetest.get_node_or_nil(pos)
	if (target_node == nil
		or npc.pathfinder.is_good_node(target_node, {}) == npc.pathfinder.node_types.walkable) then
		-- No node to stand at the target height: fall back to the closest
		-- level below or above the target within reach.
		local fallback_y = pos.y - 1
		while (fallback_y <= pos.y + 1) do
			local fallback_node = minetest.get_node_or_nil(
				{x = pos.x, y = fallback_y, z = pos.z})
			if (fallback_node ~= nil
				and npc.pathfinder.is_good_node(fallback_node, {}) == npc.pathfinder.node_types.walkable) then
				pos.y = fallback_y
				break
			end
			fallback_y = fallback_y + 1
		end
	end
	-- Re-resolve the target node at the (possibly fallback-adjusted) height.
	target_node = minetest.get_node_or_nil(pos)

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

				-- Only passable cells are usable access positions: the
				-- NPC walks to stand IN the cell, so a solid candidate can
				-- never be reached (and when the target level was flattened
				-- to the NPC's own ground, a solid target degenerates into
				-- a 1-node "path" to the NPC's own cell, which locks the
				-- walk instruction in a re-arm loop - see pathfinder.lua).
				local node = minetest.get_node(cpos)
				local passable = (node ~= nil and node.name ~= nil
					and minetest.registered_nodes[node.name] ~= nil
					and minetest.registered_nodes[node.name].walkable == false)
				if passable then
					local dist = vector.distance(self_pos, cpos)
					if (dist < min_distance) then
						min_distance = dist
						closest_pos = cpos
					end
				end

				if search_method == "prefer_first" then
					if passable then
						minetest.log("Returning this accessing pos: "..minetest.pos_to_string(cpos))
						return cpos
					end
				end
				count = count + 1
			end

			if search_method == "prefer_closest" then
				-- If no passable cell exists at the flattened level (the
				-- target sits on a platform above or below the NPC's own
				-- ground), retry the four neighbours at the target's own
				-- level: that is where a standable cell beside the target
				-- can be.
				if closest_pos == nil and pos.y ~= args.pos.y then
					local retry_count = 0
					while retry_count < 4 do
						local cpos2 = {
							x = pos.x,
							y = args.pos.y,
							z = pos.z
						}
						if retry_count == 0 then
							cpos2.x = cpos2.x + 1
						elseif retry_count == 1 then
							cpos2.z = cpos2.z + 1
						elseif retry_count == 2 then
							cpos2.x = cpos2.x - 1
						elseif retry_count == 3 then
							cpos2.z = cpos2.z - 1
						end
						local n2 = minetest.get_node(cpos2)
						if n2 ~= nil and n2.name ~= nil
							and minetest.registered_nodes[n2.name] ~= nil
							and minetest.registered_nodes[n2.name].walkable == false then
							local dist = vector.distance(self_pos, cpos2)
							if (dist < min_distance) then
								min_distance = dist
								closest_pos = cpos2
							end
						end
						retry_count = retry_count + 1
					end
				end
				if closest_pos ~= nil then
					return closest_pos
				end
				-- Nothing passable beside the target at either level: fall
				-- through to `return args.pos` below; the walk to the
				-- target itself then fails cleanly (the pathfinder reports
				-- nil) instead of returning an unreachable solid cell.
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
    	-- The entity may be gone by the time this fires (removed,
    	-- killed, or dormant). s.object is never nil - it stays a
    	-- userdata - and this build has no ObjectRef:is_gone() at
    	-- all, so calling it crashed the server (async error ->
    	-- shutdown). get_luaentity() never errors and returns nil
    	-- on a gone reference, so use it as the liveness check.
    	minetest.after(
    		(animation.end_frame - animation.start_frame) / animation.speed,
    		function(s)
    			if s.object ~= nil and s.object:get_luaentity() ~= nil then
    				_npc.model.set_animation(s, {
    					name = args.animation_after or animation.animation_after
    				})
    			end
    		end,
    		self)
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
	local middle = args.middle == true

	local u_self_pos = self.object:get_pos()
	local self_pos = vector.round(u_self_pos)
	-- Block-middle mode: jump to the middle of the target block. The
	-- target middle sits at the engine's rest height (cell y - 0.5).
	-- The arc's takeoff is the NPC's actual position (no x/z snap):
	-- the flight displacement is exactly (target middle - takeoff),
	-- so the landing hits the target middle by construction no matter
	-- where in the current cell the jump starts. That makes the jump
	-- self-healing: an offset from the block middle at takeoff is
	-- cancelled by the flight instead of being carried into the
	-- landing (where, e.g. in a 1-node-wide clearance, it would push
	-- the body into the side columns), and any lag/precision loss in
	-- the takeoff position is absorbed the same way.
	if middle then
		self_pos = {x = u_self_pos.x, y = u_self_pos.y, z = u_self_pos.z}
		trgt_pos = {x = trgt_pos.x, y = trgt_pos.y - 0.5, z = trgt_pos.z}
	end
	local dir = vector.normalize(vector.direction(self_pos, trgt_pos))

	-- Pick the arc from the vertical difference between the target
	-- and the NPC. The previous implementation sampled `self_pos + dir`
	-- (with dir the normalized 3D direction); whenever the target is
	-- above the NPC (dir.y > 0), the sampled y becomes fractional and
	-- get_node's truncation lands on the NPC's own level, so the step
	-- block is never seen - in particular for diagonal steps - and the
	-- default 0.58-peak arc is used, which can never clear a 1-block
	-- step.
	local next_y_diff = 0
	if (trgt_pos.y >= self_pos.y + 1) then
		next_y_diff = 1
		range = 2
	elseif (trgt_pos.y <= self_pos.y - 1) then
		next_y_diff = -1
		range = 0.5
	end

	-- Based on range, doesn't take time into account
	local y_speed = math.sqrt((10 * range) / (math.sin(2 * (math.pi / 3))))
	local travel = range
	if (next_y_diff == -1) then y_speed = 0 end
	if (next_y_diff == 1) then
		-- Minimal step-up jump: launch at the lowest speed that still
		-- clears the step. A ballistic arc launched at speed v under
		-- gravity g = 10 peaks at v^2 / (2 * g) above takeoff, so the
		-- minimum launch speed reaching a required rise h is
		-- v = sqrt(2 * g * h). The collision box bottom must rise one
		-- block plus the engine's 0.5-sunk rest offset to get above the
		-- step top, so the minimal jump speed for a step-up is
		-- v = sqrt(2 * 10 * rise) with rise = trgt_y - self_y + 0.5.
		-- This is the exact minimum jump for the step; the previous
		-- fixed arc (peak 1.6) overshot the required rise of ~1.5.
		local rise = trgt_pos.y - self_pos.y + 0.5
		y_speed = math.sqrt(2 * 10 * rise)
		-- Land exactly on the step top: travel the horizontal distance
		-- from takeoff to the target instead of a fixed overshoot, so
		-- the NPC lands on the intended block instead of the faced edge.
		local jump_dx = trgt_pos.x - self_pos.x
		local jump_dz = trgt_pos.z - self_pos.z
		travel = math.sqrt(jump_dx * jump_dx + jump_dz * jump_dz)
	end

	-- Horizontal speed such that the NPC actually crosses the travel
	-- distance during the expected airtime.
	local x_speed = speed
	if (y_speed > 0) then
		-- Symmetric full-flight airtime (launch and landing at the
		-- same height). Exact for same-level jumps.
		local airtime = 2 * y_speed / 10
		if (next_y_diff == 1 and middle == true) then
			-- Block-middle to block-middle: the minimal arc peaks at
			-- the target surface top (rise = dy + 0.5 puts the apex
			-- 0.5 above the landing rest height), so the flight is the
			-- climb to the apex plus a 0.5 m fall - shorter than the
			-- symmetric airtime, which lands the NPC short.
			airtime = y_speed / 10 + math.sqrt(2 * 0.5 / 10)
		end
		x_speed = travel / airtime
		-- Give the landing task a generous timeout so that a jump is
		-- never cut off mid-air.
		self.timers.hl_task_int = airtime * 2 + 0.5
	else
		self.timers.hl_task_int = 1.5
	end

	-- Stuck-jump escape: remember the horizontal spot the previous jump
	-- took off from. If the NPC keeps launching from (within one node of)
	-- the same spot - a jump that makes no x/z progress, as when the NPC
	-- takes off right up against the step face it must clear (x/z ~ +0.8
	-- into the cell) - the arc is raised after a few repeats so the body
	-- gets the height it needs to go over the face. Each repeated failure
	-- raises the arc one more step: +0.5, then +1.0, and so on, capped at
	-- +3.0. Only the vertical speed is boosted: a higher arc stays in the
	-- air longer, so the horizontal speed is re-derived from the longer
	-- flight time, which keeps the landing on the target (middle) instead
	-- of overshooting it. An additive horizontal boost is the wrong
	-- direction here: it reaches the face sooner and lower (less time in
	-- the air before the face), exactly when the takeoff is already
	-- offset toward it. The state lives in the nav session, so any real
	-- movement (and save/load) resets it.
	local stuck_limit = 3
	local stuck_boost_step = 0.5
	local stuck_boost_max = 3.0
	local nav = npc.nav.session(self)
	local moved = (nav.stuck_x ~= nil)
		and (math.abs(u_self_pos.x - nav.stuck_x) >= 1
			or math.abs(u_self_pos.z - nav.stuck_z) >= 1)
	if moved then
		nav.stuck_n = 0
	else
		nav.stuck_n = (nav.stuck_n or 0) + 1
	end
	nav.stuck_x = u_self_pos.x
	nav.stuck_z = u_self_pos.z
	if (nav.stuck_n >= stuck_limit) then
		local levels = nav.stuck_n - stuck_limit + 1
		local boost = math.min(levels * stuck_boost_step, stuck_boost_max)
		y_speed = y_speed + boost
		-- Re-aim the raised arc: solve the ballistic flight time to the
		-- target height (y(t) = dy, the later root, i.e. after the apex)
		-- so x_speed carries the body the exact horizontal travel in that
		-- time. Unboosted this equals the arc's existing airtime (the
		-- middle step-up's asymmetric 0.5 m fall included), so only
		-- boosted arcs change; the landing still hits the target middle
		-- despite the longer flight.
		local dy = trgt_pos.y - self_pos.y
		local disc = y_speed * y_speed - 20 * dy
		if (disc < 0) then disc = 0 end
		local airtime = (y_speed + math.sqrt(disc)) / 10
		x_speed = travel / airtime
		self.timers.hl_task_int = airtime * 2 + 0.5
		minetest.log(string.format(
			"[anpc] %s stuck-jump %d: no x/z progress, raising arc +%.1f (y=%.2f, x=%.2f)",
			tostring(self.npc_id), nav.stuck_n, boost, y_speed, x_speed))
	end
	-- `dir` is the normalized 3D direction, which carries a vertical
	-- component whenever the target sits above the NPC (always the case
	-- for a step-up). The horizontal speed must be applied along the pure
	-- horizontal direction, otherwise the vertical component dilutes it
	-- and the NPC undershoots the step top (e.g. an adjacent 1-block
	-- step gets ~29% less horizontal speed) and lands short of the jump.
	local horiz_len = math.sqrt(dir.x * dir.x + dir.z * dir.z)
	local horiz_x = (horiz_len > 0) and (dir.x / horiz_len) or 0
	local horiz_z = (horiz_len > 0) and (dir.z / horiz_len) or 0
	local vel = {x = horiz_x * x_speed, y = y_speed, z = horiz_z * x_speed}
	-- The engine resolves entity collision per axis: while the box's
	-- lower half still overlaps the step face (feet below the face top),
	-- any x/z motion against the face is pushed back and the velocity
	-- component of that axis is zeroed - leaving the arc purely
	-- vertical, a jump that clears the block's height but never crosses
	-- its face. Stash the horizontal launch so the landing task can
	-- re-assert it every tick until the body clears the face.
	self.jump_xvel = vel.x
	self.jump_zvel = vel.z
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

-----------------------------------------------------------------------------------
-- Navigation (npc.nav)
-----------------------------------------------------------------------------------
-- Unified path-based navigation backing the walk instructions.
--
-- A navigation session lives in self.data.nav and is owned by this
-- section: planning (npc.pathfinder), per-tick steering (node
-- advancement, aiming, stair/slab inclines, jumps, doors) and
-- arrival / stuck handling.
--
-- Entry points (thin wrappers around this section):
--   npc:move:walk_to_pos     proc, cell arrival, speed 2
--   npc:move:walk_to_pos_ll  proc -> ll task, distance arrival, speed 3
--   npc:move:walk_to_cell_ll proc -> ll task, cell arrival, speed 5,
--                            block-middle; for the npc:follow goal
--                            cell (re-tracked per tick by npc.nav:
--                            follow_track), the arrival rests the NPC
--                            on the goal cell middle
--
-- Block-middle walking (middle = true): the target, the per-tick aim
-- and the jump arc use the middle of each block (cell y - 0.5, the
-- engine's rest height), so the NPC moves from block middle to block
-- middle - on the ground, over 1-block steps and diagonals (at
-- constant speed). The pos entry points keep the legacy cell-corner
-- behavior by default (their callers track live coordinates, e.g. a
-- moving player); the cell ll entry point has middle on because its
-- goal is a static cell and the arrival must rest on the cell middle.
--
-- Door closing (door_close arg on the walk instructions): after the
-- NPC passes through an openable node (a door it opened, or one that
-- was already open) the door is closed according to the policy
-- (default "immediate"):
--   "immediate": the tick the NPC's center crosses into the next
--     cell - no timer, no backtracking.
--   "pause": the NPC walks on to the middle of the next cell, stops,
--     faces the door, closes it and holds for a short beat before
--     resuming the walk.
--   "none": the door is left open.
-- The pause is a plain tick counter (nav.door_hold) inside the
-- existing per-tick driver: no minetest.after timers and no liveness
-- guards to maintain.
--
-- Both entry points are driven per-tick by the low-latency task
-- "npc:move:walk_to" (npc.nav.step).
--
-- A session is (re)armed with npc.nav.start(). Re-arming with the
-- same target cell keeps the cached path and the stuck accumulators
-- (npc:follow re-arms every 0.05 s while the leader stands still and
-- must not reset the 1 s stuck window); a different target cell
-- resets them.

npc.nav = {}

-- Ensure the session table exists (staticdata from before this
-- section lacks it) and return it.
function npc.nav.session(self)
	if self.data.nav == nil then
		self.data.nav = {}
	end
	return self.data.nav
end

-- Plan a decorated path from the NPC's current cell to trgt_pos.
-- Returns the path, or nil.
function npc.nav._find_path(self, trgt_pos)
	-- For the purposes of the pathfinder - we assume stepheight = 1.
	-- TODO: make this configurable. What if we want more than just 1 because
	-- we have a bigger-than-two-nodes NPC?
	-- (Keep the original value so we don't hardcode the per-entity default.)
	local self_pos = vector.round(self.object:get_pos())
	local prev_stepheight = self.object:get_properties().stepheight or 0.6
	self.object:set_properties({stepheight = 1})
	local path = npc.pathfinder.find_path(self_pos, trgt_pos, self, true)
	self.object:set_properties({stepheight = prev_stepheight})
	return path
end

-- Axis-wise sign (-1, 0, 1); math.sign is not available here.
local function sign(v)
	if v < 0 then return -1 end
	if v > 0 then return 1 end
	return 0
end

-- Continuous follow (npc:follow): the goal cell is picked from the
-- live leader and re-tracked while the walk is active.
--
-- Goal = the first standable slot candidate (npc.nav._follow_slots)
-- for the leader's *predicted* cell: the live leader position plus a
-- predictive lead along the leader's velocity (npc.nav:
-- _follow_predict), so the goal anticipates the leader's next cell
-- instead of chasing the cell it just left. Slot order: the mode's
-- primary slot (behind/ahead per the leader's travel direction), the
-- opposite slot, then the four cardinal slots at the follow
-- distance. The leader's cell change and direction bookkeeping live
-- on the nav session (follow_prev_cell / follow_last_dir), so while
-- the leader stands still the goal is stable and the follower keeps
-- the slot it already occupies.
--
-- The leader is resolved by name (npc.nav.follow_leader): players
-- first (no range limit - the nearby-object set's view_range would
-- otherwise drop the leader), then the tracked nearby objects (an
-- NPC leader).
--
-- Per-tick tracking (npc.nav.follow_track, called from npc.nav.step
-- while the ll walk task is active): a leader position read and a
-- predicted-cell compare per tick; the slot node reads and the A*
-- run only when the leader's predicted cell actually changes (goal
-- cache: follow.pred_cell / follow.cached_goal, set in _follow_slot
-- and gated on in npc.nav.follow_goal / follow_next_leg). When the
-- goal cell changes: the remaining path is truncated if it already
-- passes the new cell (free), otherwise a full re-plan (the same
-- small A* the reached_head re-plan uses). If the goal cell is
-- unreachable, npc.nav.follow_fallback tries the remaining
-- slot-ladder candidates and, when every cell is unreachable, steers
-- the NPC directly at the goal cell (nav.steer). A steer that shoves
-- into a wall (or the leader) for a full second without moving drops
-- into the steer-stuck hold (nav.steer_stuck): the NPC stands still
-- while a rate-limited re-plan re-engages a path as soon as one
-- opens, and the hold lifts when the leader's predicted cell
-- changes. It never gives up on a live leader.
--
-- Cost: every follow plan site (follow_track, follow_fallback,
-- follow_next_leg, the steer retry and the steer-stuck hold in
-- npc.nav.step) plans through npc.nav._follow_plan, which shares one
-- 0.5 s failure cooldown, so an unreachable goal costs at most one
-- real A* per 0.5 s (a failed A* expands up to the pathfinder's
-- 2000-node cap); under an active cooldown the plans skip for free
-- and the steer retry keeps the NPC moving toward the goal (the
-- steer-stuck hold keeps it standing still).
--
-- Legs chain at arrival (npc.nav.follow_next_leg): when the NPC
-- reaches a goal cell's middle, the next leg starts on the same tick
-- if the goal moved, so there is no dead time between legs. A stale
-- follow session (the state process swapped away from npc:follow
-- mid-leg, e.g. the follow item toggled off) is dropped by
-- follow_track so a later walk is not hijacked.
--
-- The follow session (nav.follow) holds the leader ref, the mode,
-- the distance, the lead time, the derived default and catch-up
-- speeds (the leader's walk speed minus/plus 0.25 m/s, from the
-- engine setting movement_speed_walk), the catch-up distance
-- (default 2 x the follow distance, the gap band the follower uses
-- to resume walks and to switch between the two speeds, see
-- npc.nav.follow_speed) and the predicted-cell cache.
-- get_staticdata drops the whole nav session (it holds a live object
-- ref), so the session re-initializes from the program args on the
-- next pass after dormancy.

-- Engine walk-speed probe (settings): the follow default speed is
-- derived from `movement_speed_walk` at follow start; log the
-- effective base value once at load so it is visible in the server
-- log without a field test (there is no per-player walk-speed
-- getter in this API - the setting plus the per-player physics
-- overrides are the source of truth).
do
	local ws
	if minetest.settings ~= nil and minetest.settings.get ~= nil then
		ws = minetest.settings:get("movement_speed_walk")
	end
	minetest.log(string.format(
		"[anpc] engine movement_speed_walk = %s", tostring(ws)))
end

-- Resolve the follow leader by name. Players first (no range limit),
-- then the tracked nearby objects (an NPC leader). Returns an
-- ObjectRef or nil.
function npc.nav.follow_leader(self, name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local leader = minetest.get_player_by_name(name)
	if leader ~= nil and leader:get_pos() ~= nil then
		return leader
	end
	local objects = self.data.env.objects
	for i = 1, #objects do
		local o = objects[i]
		if o ~= nil and o.get_name ~= nil and o:get_name() == name then
			return o
		end
	end
	return nil
end

-- The leader's predicted position: live position plus a predictive
-- lead along the leader's velocity (follow.lead seconds, default
-- 0), so a positive lead makes the goal cell anticipate where the
-- leader is going. Zero lead (or a missing velocity) returns the
-- live position.
function npc.nav._follow_predict(self, leader_pos)
	local nav = npc.nav.session(self)
	local follow = nav.follow
	local lead = follow.lead or 0
	if lead <= 0 then
		return leader_pos
	end
	local vel = follow.leader ~= nil and follow.leader:get_velocity() or nil
	if vel == nil then
		return leader_pos
	end
	return {x = leader_pos.x + vel.x * lead, y = leader_pos.y + vel.y * lead,
		z = leader_pos.z + vel.z * lead}
end

-- Rate-limited follow A*: every follow plan site (npc.nav:
-- follow_track, follow_fallback, follow_next_leg, the steer retry in
-- npc.nav.step) shares one failure cooldown (nav.follow_fail_cd, a
-- per-tick countdown decremented by npc.nav.follow_track - this
-- build has no wall clock API), so an unreachable goal costs at most
-- one real A* per 0.5 s (a failed A* expands up to the pathfinder's
-- 2000-node cap). Returns the path (a plan ran and succeeded),
-- "skip" (too soon after a failed plan: the caller treats it as a
-- failure without planning) or nil (a plan ran and failed - the
-- cooldown is re-armed).
function npc.nav._follow_plan(self, trgt_pos)
	local nav = npc.nav.session(self)
	if (nav.follow_fail_cd or 0) > 0 then
		return "skip"
	end
	local path = npc.nav._find_path(self, trgt_pos)
	if path == nil then
		nav.follow_fail_cd = 0.5
	end
	return path
end

-- The ordered follow slot candidates for a leader cell (see the
-- section header): the mode's primary slot, the opposite slot, and
-- the four cardinal slots at the follow distance. `d` is the
-- leader's travel direction; when `seed` is true (first follow, no
-- direction on record) d is the follower's side of the leader and
-- the primary is the follower's own side whatever the mode.
-- Unstandable cells are dropped (a dropped primary falls through to
-- the next candidate), so entry 1 is always a cell the NPC can rest
-- in. Standable: the body cell must be walkable (air, not a wall or
-- door) and the node below must be solid ground (not the edge of a
-- pit); the body-cell test comes first so the common wall case
-- short-circuits without a second node read.
function npc.nav._follow_slots(self, leader_cell, d, seed)
	local nav = npc.nav.session(self)
	local follow = nav.follow
	local n = follow.distance
	if type(n) ~= "number" or n < 1 then
		n = 1
	end
	local ahead = (follow.mode == "ahead")
	local px = (ahead or seed) and 1 or -1
	local cells = {}
	local function add(c)
		for i = 1, #cells do
			if cells[i].x == c.x and cells[i].y == c.y
					and cells[i].z == c.z then
				return
			end
		end
		-- Ungenerated positions read as nil nodes: not standable.
		local body = minetest.get_node(c)
		local below = minetest.get_node({x = c.x, y = c.y - 1, z = c.z})
		if body ~= nil and below ~= nil
			and npc.pathfinder.is_good_node(body, {})
					== npc.pathfinder.node_types.walkable
			and npc.pathfinder.is_good_node(below, {})
					~= npc.pathfinder.node_types.walkable then
			table.insert(cells, c)
		end
	end
	add({x = leader_cell.x + d.x * n * px, y = leader_cell.y + d.y * n * px,
		z = leader_cell.z + d.z * n * px})
	add({x = leader_cell.x - d.x * n * px, y = leader_cell.y - d.y * n * px,
		z = leader_cell.z - d.z * n * px})
	add({x = leader_cell.x + n, y = leader_cell.y, z = leader_cell.z})
	add({x = leader_cell.x - n, y = leader_cell.y, z = leader_cell.z})
	add({x = leader_cell.x, y = leader_cell.y, z = leader_cell.z + n})
	add({x = leader_cell.x, y = leader_cell.y, z = leader_cell.z - n})
	return cells
end

-- Pick the follow goal cell for a live leader position (see the
-- section header): the predictive lead is applied here so the goal
-- anticipates the leader's next cell. Direction bookkeeping (the
-- leader's cell change records the travel direction; the last
-- direction is kept while the leader stands still; the seed pass
-- uses the follower's own side and is deliberately not stored) lives
-- on the nav session. Returns the goal cell (the first standable
-- slot candidate), or nil when the leader is in the follower's own
-- cell with no direction on record yet.
function npc.nav._follow_slot(self, leader_pos)
	local nav = npc.nav.session(self)
	local follow = nav.follow
	local pred = npc.nav._follow_predict(self, leader_pos)
	local leader_cell = vector.round(pred)
	local follower_cell = vector.round(self.object:get_pos())

	local d
	local seed = false
	if nav.follow_prev_cell ~= nil
			and (nav.follow_prev_cell.x ~= leader_cell.x
				or nav.follow_prev_cell.z ~= leader_cell.z) then
		-- The leader moved: the axis-wise sign of its last move.
		d = {
			x = sign(leader_cell.x - nav.follow_prev_cell.x),
			y = sign(leader_cell.y - nav.follow_prev_cell.y),
			z = sign(leader_cell.z - nav.follow_prev_cell.z),
		}
		nav.follow_last_dir = d
	else
		-- The leader stands still (or this is the first pass): keep the
		-- last recorded travel direction so the goal stays stable and
		-- the follower holds the slot on its side of the leader.
		if nav.follow_last_dir ~= nil then
			d = nav.follow_last_dir
		else
			if leader_cell.x == follower_cell.x
					and leader_cell.z == follower_cell.z then
				-- Same cell and no direction on record: nothing to
				-- follow yet - the program stands down until the leader
				-- moves (or the follower leaves the cell).
				nav.follow_prev_cell = leader_cell
				follow.pred_cell = leader_cell
				follow.cached_goal = nil
				return nil
			end
			-- First pass, leader stationary: there is no travel direction
			-- yet. Use the follower's own side of the leader so both
			-- behind and ahead keep the slot the follower already
			-- occupies until the leader moves.
			d = {
				x = sign(follower_cell.x - leader_cell.x),
				y = 0,
				z = sign(follower_cell.z - leader_cell.z),
			}
			seed = true
		end
	end

	nav.follow_prev_cell = leader_cell
	-- Predicted-cell goal cache: while the leader's predicted cell is
	-- unchanged the goal cell cannot change. npc.nav.follow_goal and
	-- npc.nav.follow_next_leg gate on it to skip the slot node reads.
	follow.pred_cell = leader_cell
	local cells = npc.nav._follow_slots(self, leader_cell, d, seed)
	if #cells == 0 then
		follow.cached_goal = nil
		return nil -- no standable slot: nothing to aim at
	end
	follow.cached_goal = cells[1]
	nav.follow_goal = cells[1]
	return cells[1]
end

-- Program entry for the npc:follow goal cell: resolve the leader,
-- (re)initialize the follow session, and pick the goal cell.
-- Returns the goal cell (the program stores it in a local), or nil
-- when the leader cannot be resolved (the program then stands down).
function npc.nav.follow_goal(self, args)
	local leader = npc.nav.follow_leader(self, args.name)
	if leader == nil and args.object ~= nil and type(args.object) == "userdata" then
		leader = args.object
	end
	if leader == nil or leader:get_pos() == nil then
		return nil
	end
	local nav = npc.nav.session(self)
	local follow = nav.follow
	if follow == nil or (args.name ~= nil and follow.name ~= args.name) then
		follow = {name = args.name}
		nav.follow = follow
		-- A new leader: drop the direction bookkeeping (it belongs to
		-- the previous leader).
		nav.follow_prev_cell = nil
		nav.follow_last_dir = nil
	end
	follow.leader = leader
	follow.mode = args.mode
	-- Default 2 cells (with the zero-lead default below the goal is
	-- always at least 2 cells behind the leader's live cell, so the
	-- NPC cannot bump into a walking leader).
	follow.distance = (type(args.distance) == "number" and args.distance >= 1)
		and args.distance or 2
	-- Default zero lead: the goal aims at the leader's current cell.
	-- A positive lead can push the goal onto the leader's own cell at
	-- small distances and make the NPC bump into a walking leader.
	follow.lead = (type(args.lead) == "number" and args.lead >= 0) and args.lead or 0
	-- Catch-up distance (cells, see npc.nav.follow_speed): the
	-- follower only resumes a walk - and only switches to the
	-- catch-up speed - once the gap to the leader reaches this
	-- distance, and it stays in the catch-up speed until the gap
	-- closes back to the follow distance. Default 2 x the follow
	-- distance; clamped to at least the follow distance (a catch-up
	-- zone inside the slot would fight the arrival).
	follow.catch_up = (type(args.catch_up) == "number" and args.catch_up >= 1)
		and math.floor(args.catch_up) or (follow.distance * 2)
	if follow.catch_up < follow.distance then
		follow.catch_up = follow.distance
	end
	-- Default follow speed: the leader's walk speed minus 0.25 m/s,
	-- so the follower stays just under the leader's pace; the
	-- catch-up speed is the walk speed plus 0.25 m/s (see
	-- npc.nav.follow_speed for the gap band between the two). The
	-- base walk speed is the engine setting `movement_speed_walk`
	-- (engine default 4.0, nodes/s) - read from the engine, not a
	-- Minetest-Game constant, so a game that sets a different base
	-- value keeps the follower at the leader's pace - scaled by any
	-- per-player physics override (the actual walk speed is the
	-- product of the `speed` and `speed_walk` multipliers, see
	-- set_physics_override). An explicit `speed` argument on the
	-- program wins (the entry resolves args over defaults); when the
	-- setting is unreadable the entry default (5 m/s) applies.
	local base_walk_speed
	if minetest.settings ~= nil and minetest.settings.get ~= nil then
		local ws = minetest.settings:get("movement_speed_walk")
		if type(ws) == "number" then
			base_walk_speed = ws
		elseif type(ws) == "string" then
			base_walk_speed = tonumber(ws)
		end
	end
	if base_walk_speed ~= nil and base_walk_speed > 0.5 then
		local leader_walk_speed = base_walk_speed
		if leader.get_physics_override ~= nil then
			local po = leader:get_physics_override()
			if type(po) == "table" then
				leader_walk_speed = leader_walk_speed
					* (type(po.speed) == "number" and po.speed or 1)
					* (type(po.speed_walk) == "number" and po.speed_walk or 1)
			end
		end
		-- Normal speed: just under the leader's pace; catch-up
		-- speed: just over it (npc.nav.follow_speed switches
		-- between the two on the gap band).
		follow.speed = leader_walk_speed - 0.25
		follow.speed_catchup = leader_walk_speed + 0.25
	end
	if _npc.follow_speed_logged == false then
		_npc.follow_speed_logged = true
		if follow.speed ~= nil then
			minetest.log(string.format(
				"[anpc] follow default speed: %.2f m/s (walk %.2f - 0.25, catch-up %.2f)",
				follow.speed, follow.speed + 0.25, follow.speed + 0.5))
		else
			minetest.log("[anpc] follow default speed: "
				.. "movement_speed_walk unreadable, using the 5 m/s "
				.. "entry default")
		end
	end
	-- Goal cache: while the leader's predicted cell is unchanged the
	-- goal cell cannot change - return the cached goal without the
	-- slot node reads (the common case while the leader stands still).
	local pred_cell = vector.round(npc.nav._follow_predict(self, leader:get_pos()))
	if follow.cached_goal ~= nil
			and follow.pred_cell ~= nil
			and pred_cell.x == follow.pred_cell.x
			and pred_cell.y == follow.pred_cell.y
			and pred_cell.z == follow.pred_cell.z then
		return follow.cached_goal
	end
	return npc.nav._follow_slot(self, leader:get_pos())
end

-- Speed selection for continuous follow, resolved at every walk
-- (re)arm (the npc:follow program pass, 0.05 s). An explicit `speed`
-- argument on the program wins for the normal speed; otherwise the
-- derived default (the leader's walk speed minus 0.25 m/s, see
-- npc.nav.follow_goal). The catch-up speed is 0.5 m/s above the
-- normal speed (the leader's walk speed plus 0.25 m/s on the
-- default). Hysteresis on the gap to the leader: the catch-up speed
-- engages when the gap reaches `catch_up` (default 2 x the follow
-- distance) and stays engaged until the gap closes back to the
-- follow distance - so a straight walk at the slower default speed
-- necessarily falls behind, the follower bursts to close the gap,
-- and the gap oscillates inside the band. The same band is the
-- resume gate: an idle follower only starts walking at all when the
-- gap reaches `catch_up` (enforced by the walk_to_cell_ll entry).
function npc.nav.follow_speed(self, args)
	local nav = npc.nav.session(self)
	local follow = nav.follow
	if follow == nil then
		return args.speed or 5
	end
	local normal = args.speed or follow.speed or 5
	local catchup
	if type(args.speed) == "number" then
		-- Explicit program speed: the catch-up burst is 0.5 m/s
		-- above the requested speed.
		catchup = args.speed + 0.5
	elseif follow.speed_catchup ~= nil then
		catchup = follow.speed_catchup
	else
		catchup = normal + 0.5
	end
	local leader_pos = follow.leader ~= nil and follow.leader:get_pos() or nil
	if leader_pos == nil then
		return normal
	end
	local gap = vector.distance(self.object:get_pos(), leader_pos)
	if follow.catch_mode == true then
		if gap <= follow.distance then
			follow.catch_mode = false -- the slot is reached again
		end
	else
		if gap >= follow.catch_up then
			follow.catch_mode = true -- fell behind: catch up
		end
	end
	return (follow.catch_mode == true) and catchup or normal
end

-- Per-tick continuous-follow update (see the section header). Called
-- from npc.nav.step while the ll walk task is active.
function npc.nav.follow_track(self, dtime)
	local nav = npc.nav.session(self)
	local follow = nav.follow
	if follow == nil then
		return
	end
	-- Stale follow session (the state process is no longer
	-- npc:follow - e.g. the follow item toggled off while a leg was
	-- in flight): drop it so the current walk is not hijacked.
	if self.process.state.name ~= "npc:follow" then
		nav.follow = nil
		nav.steer = false
		nav.steer_stuck = nil
		nav.follow_fail_cd = nil
		return
	end
	-- Failure-cooldown countdown (npc.nav._follow_plan): 0.5 s
	-- between real follow A* failures, stepped by the tick.
	if (nav.follow_fail_cd or 0) > 0 then
		nav.follow_fail_cd = nav.follow_fail_cd - dtime
		if nav.follow_fail_cd < 0 then
			nav.follow_fail_cd = 0
		end
	end
	-- Validate the cached leader ref (stale after dormancy or
	-- removal); re-resolve by name.
	local leader_pos = follow.leader:get_pos()
	if leader_pos == nil then
		local leader = npc.nav.follow_leader(self, follow.name)
		if leader == nil then
			-- Leader gone: keep walking to the last goal; the program
			-- stands down on the next pass.
			return
		end
		follow.leader = leader
		leader_pos = leader:get_pos()
		if leader_pos == nil then
			return
		end
	end
	local pred = npc.nav._follow_predict(self, leader_pos)
	local pred_cell = vector.round(pred)
	if follow.pred_cell ~= nil and pred_cell.x == follow.pred_cell.x
			and pred_cell.y == follow.pred_cell.y
			and pred_cell.z == follow.pred_cell.z then
		return -- goal cell unchanged: nothing to do this tick
	end
	follow.pred_cell = pred_cell
	-- The predicted cell changed: any steer-stuck hold belonged to
	-- the old goal - lift it so the NPC re-engages.
	nav.steer_stuck = nil
	local goal = npc.nav._follow_slot(self, leader_pos)
	if goal == nil then
		return -- nothing to follow yet (leader in our cell, no
		-- direction): keep the current walk
	end
	if nav.trgt_pos ~= nil and goal.x == nav.trgt_pos.x
			and goal.y == nav.trgt_pos.y and goal.z == nav.trgt_pos.z then
		nav.u_trgt_pos = {x = goal.x, y = goal.y, z = goal.z}
		nav.prev_u_trgt_pos = nav.u_trgt_pos
		return -- the path already heads there
	end
	-- Continuation test: the remaining path already passes through
	-- the new goal cell - truncate instead of re-planning.
	local path = nav.path
	if path ~= nil then
		for i = 1, #path do
			if path[i].pos.x == goal.x and path[i].pos.y == goal.y
					and path[i].pos.z == goal.z then
				for j = #path, i + 1, -1 do
					path[j] = nil
				end
				nav.trgt_pos = goal
				nav.u_trgt_pos = {x = goal.x, y = goal.y, z = goal.z}
				nav.prev_u_trgt_pos = nav.u_trgt_pos
				return
			end
		end
	end
	-- Rate-limited full re-plan (the same small A* the reached_head
	-- re-plan uses).
	local new_path = npc.nav._follow_plan(self, goal)
	if type(new_path) == "table" then
		nav.path = new_path
		nav.trgt_pos = goal
		nav.u_trgt_pos = {x = goal.x, y = goal.y, z = goal.z}
		nav.prev_u_trgt_pos = nav.u_trgt_pos
		nav.steer = false
		return
	end
	-- Unreachable (or a plan skipped by the failure cooldown): slot
	-- ladder, then direct steering (see the section header).
	npc.nav.follow_fallback(self, goal)
end

-- The follow fallback (see the section header): the goal cell is
-- unreachable (or a plan was skipped by the failure cooldown). Try
-- the remaining slot-ladder candidates (2 = the opposite slot, 3-6 =
-- the cardinal slots; the primary is the goal itself, which the
-- caller already planned) with the rate-limited plan - under an
-- active cooldown every candidate skips for free. When every
-- candidate is unreachable (or skipped) steer the NPC directly at
-- the goal cell. Returns "path" (a candidate reached -
-- nav.path/trgt_pos updated), "steer" (steering at the goal cell) or
-- nil (the leader is gone).
function npc.nav.follow_fallback(self, goal)
	local nav = npc.nav.session(self)
	local follow = nav.follow
	if follow == nil or follow.leader == nil then
		return nil
	end
	local leader_pos = follow.leader:get_pos()
	if leader_pos == nil then
		local leader = npc.nav.follow_leader(self, follow.name)
		if leader == nil then
			return nil
		end
		follow.leader = leader
		leader_pos = leader:get_pos()
		if leader_pos == nil then
			return nil
		end
	end
	local pred_cell = vector.round(npc.nav._follow_predict(self, leader_pos))
	local d = nav.follow_last_dir
	local cells = npc.nav._follow_slots(self, pred_cell,
		d ~= nil and d or {x = 0, y = 0, z = 0}, d == nil)
	for i = 2, #cells do
		local cand = cells[i]
		local path = npc.nav._follow_plan(self, cand)
		if type(path) == "table" then
			nav.path = path
			nav.trgt_pos = cand
			nav.u_trgt_pos = {x = cand.x, y = cand.y, z = cand.z}
			nav.prev_u_trgt_pos = nav.u_trgt_pos
			nav.prev_self_pos = self.object:get_pos()
			nav.steer = false
			nav.stuck_time = 0
			nav.stuck_acc = 0
			nav.active = true
			nav.last_status = "moving"
			return "path"
		end
	end
	-- Every candidate unreachable (or the plan skipped by the
	-- cooldown): steer directly at the goal cell; the rate-limited
	-- search retry in npc.nav.step's re-plan branch picks up a path
	-- as soon as one opens.
	nav.trgt_pos = goal
	nav.u_trgt_pos = {x = goal.x, y = goal.y, z = goal.z}
	nav.prev_u_trgt_pos = nav.u_trgt_pos
	nav.steer = true
	nav.path = {}
	nav.active = true
	nav.last_status = "moving"
	nav.stuck_time = 0
	nav.stuck_acc = 0
	return "steer"
end

-- Continuous-follow leg chaining (see the section header): called
-- from the cell-arrival branch of npc.nav.step. If the goal cell
-- moved while the NPC walked to the old one, start the next leg on
-- this tick (no dead time between legs); otherwise return false and
-- the normal arrival (stand down) happens.
function npc.nav.follow_next_leg(self, dtime, u_self_pos)
	local nav = npc.nav.session(self)
	local follow = nav.follow
	if follow == nil then
		return false
	end
	local leader_pos = follow.leader:get_pos()
	if leader_pos == nil then
		local leader = npc.nav.follow_leader(self, follow.name)
		if leader == nil then
			return false -- leader gone: stand down
		end
		follow.leader = leader
		leader_pos = leader:get_pos()
		if leader_pos == nil then
			return false
		end
	end
	-- Goal cache gate (see the section header): while the leader's
	-- predicted cell is unchanged the goal cell cannot change - use
	-- the cached goal without the slot node reads.
	local goal
	local pred_cell = vector.round(npc.nav._follow_predict(self, leader_pos))
	if follow.cached_goal ~= nil
			and follow.pred_cell ~= nil
			and pred_cell.x == follow.pred_cell.x
			and pred_cell.y == follow.pred_cell.y
			and pred_cell.z == follow.pred_cell.z then
		goal = follow.cached_goal
	else
		goal = npc.nav._follow_slot(self, leader_pos)
	end
	if goal == nil then
		return false
	end
	local self_cell = vector.round(u_self_pos)
	if goal.x == self_cell.x and goal.y == self_cell.y
			and goal.z == self_cell.z then
		return false -- the NPC is in the slot: stand down
	end
	nav.path = nil
	nav.stuck_time = 0
	nav.stuck_acc = 0
	local path = npc.nav._follow_plan(self, goal)
	if type(path) == "table" then
		nav.path = path
		nav.trgt_pos = goal
		nav.u_trgt_pos = {x = goal.x, y = goal.y, z = goal.z}
		nav.prev_u_trgt_pos = nav.u_trgt_pos
		nav.prev_self_pos = u_self_pos
		nav.steer = false
		nav.last_status = "moving"
		return true
	end
	-- Unreachable (or a plan skipped by the failure cooldown): slot
	-- ladder, then direct steering (see the section header).
	local outcome = npc.nav.follow_fallback(self, goal)
	if outcome == "path" or outcome == "steer" then
		return true
	end
	return false
end

-- Shared stand-down: zero the velocity, play the stand animation, and
-- (when look_at_pos is given) face the original target if it is a
-- different cell than the accessed one.
function npc.nav._stand(self, look_at_pos)
	self.object:set_velocity({x = 0, y = 0, z = 0})
	-- TODO: Check if animation exists?
	_npc.model.set_animation(self, {name = "stand"})
	local nav = self.data.nav
	if look_at_pos ~= nil and nav.original_target_pos ~= nil
		and (nav.original_target_pos.x ~= look_at_pos.x
			or nav.original_target_pos.z ~= look_at_pos.z) then
		self.object:set_yaw(minetest.dir_to_yaw(vector.direction(look_at_pos, nav.original_target_pos)))
	end
end

-- Start (or re-arm) a navigation session.
-- args: target | target_pos, speed, target_distance, look_at_target,
--       original_target_pos, check_end_pos_walkable, force,
--       min_self_move_distance, min_trgt_move_distance, middle,
--       door_close
-- defaults: per-entry-point values (speed, arrive_rule, target_distance,
--           middle)
-- Returns "arrived" | "failed" | "moving".
function npc.nav.start(self, args, defaults)
	local nav = npc.nav.session(self)

	local speed = args.speed or (defaults ~= nil and defaults.speed) or 2
	local arrive_rule = (defaults ~= nil and defaults.arrive_rule) or "distance"
	local target_distance = args.target_distance or (defaults ~= nil and defaults.target_distance) or 1.5
	-- Block-middle walking (see the section header): args win over the
	-- entry point's default; off unless requested.
	local middle
	if args.middle ~= nil then
		middle = args.middle
	elseif defaults ~= nil and defaults.middle ~= nil then
		middle = defaults.middle
	else
		middle = false
	end

	-- Door-close policy for openable nodes (doors) the NPC passes
	-- through (see the section header): "immediate" (default), "pause"
	-- or "none". A re-arm keeps the policy unless args override it.
	local door_close = args.door_close
		or (defaults ~= nil and defaults.door_close)
		or nav.door_close
		or "immediate"

	-- Resolve the target
	local trgt = args.target
	local u_trgt_pos
	if trgt ~= nil then
		u_trgt_pos = trgt:get_pos()
	elseif args.target_pos ~= nil then
		u_trgt_pos = args.target_pos
	end
	if u_trgt_pos == nil then
		-- Cannot find a target to walk to
		nav.active = false
		nav.last_status = "failed"
		return "failed"
	end

	local trgt_pos = vector.round(u_trgt_pos)
	if args.check_end_pos_walkable == true and trgt == nil then
		trgt_pos = _npc.env.node_get_accessing_pos(self, trgt_pos)
	end

	-- A re-arm with the same target cell keeps the cached path and the
	-- stuck accumulators; a different target cell starts fresh.
	local same_target = (nav.active == true)
		and (nav.u_trgt_pos ~= nil)
		and (vector.round(nav.u_trgt_pos).x == trgt_pos.x
			and vector.round(nav.u_trgt_pos).z == trgt_pos.z
			and math.abs(vector.round(nav.u_trgt_pos).y - trgt_pos.y) < 0.5)
	if not same_target then
		nav.path = nil
		nav.stuck_time = 0
		nav.stuck_acc = 0
		nav.prev_self_pos = nil
		nav.prev_u_trgt_pos = nil
		-- Drop any in-flight door-close pause (it belonged to the old
		-- walk; the new walk's door passages re-arm it themselves).
		nav.door_close_cell = nil
		nav.door_pause_cell = nil
		nav.door_hold = 0
	end

	nav.active = true
	nav.target = trgt
	nav.u_trgt_pos = u_trgt_pos
	nav.trgt_pos = trgt_pos
	nav.speed = speed
	nav.arrive_rule = arrive_rule
	nav.target_distance = target_distance
	nav.middle = middle
	nav.door_close = door_close
	nav.look_at_target = args.look_at_target
	nav.original_target_pos = args.original_target_pos
	nav.force = args.force
	-- Steering is a follow-only fallback mid-walk: every (re)arm
	-- starts fresh.
	nav.steer = false
	nav.min_self_move_distance = args.min_self_move_distance or 0.25
	nav.min_trgt_move_distance = args.min_trgt_move_distance or 0.25

	-- Check if we are done (before any planning)
	local u_self_pos = self.object:get_pos()
	if arrive_rule == "cell" then
		if middle == true then
			-- Block-middle arrival: at the rest height on the target
			-- cell middle (x/z within 0.25, y within 0.5 of cell y -
			-- 0.5).
			if math.abs(u_self_pos.x - trgt_pos.x) <= 0.25
				and math.abs(u_self_pos.z - trgt_pos.z) <= 0.25
				and math.abs(u_self_pos.y - (trgt_pos.y - 0.5)) <= 0.5 then
				nav.active = false
				nav.path = nil
				npc.nav._stand(self, trgt_pos)
				nav.last_status = "arrived"
				return "arrived"
			end
		else
			local self_pos = vector.round(u_self_pos)
			if self_pos.x == trgt_pos.x
				and self_pos.z == trgt_pos.z
				and math.abs(trgt_pos.y - self_pos.y) < 0.5 then
				nav.active = false
				nav.path = nil
				npc.nav._stand(self, trgt_pos)
				nav.last_status = "arrived"
				return "arrived"
			end
		end
	elseif vector.distance(u_self_pos, u_trgt_pos) <= target_distance then
		nav.active = false
		nav.path = nil
		npc.nav._stand(self, trgt_pos)
		nav.last_status = "arrived"
		return "arrived"
	end

	-- First plan (a re-arm with a usable cached path keeps it).
	-- Block-middle: if we are already in the target cell, a same-cell
	-- path search returns nil and would fail the walk. Leave the path
	-- empty; nav.step steers straight at the cell middle instead.
	if nav.path == nil or #nav.path == 0 then
		local self_cell = vector.round(u_self_pos)
		if middle == true and self_cell.x == trgt_pos.x
				and self_cell.y == trgt_pos.y and self_cell.z == trgt_pos.z then
			nav.path = {}
		else
			nav.path = npc.nav._find_path(self, trgt_pos)
			if nav.path == nil then
				if nav.force == true then
					self.object:move_to(trgt_pos, false)
				end
				nav.active = false
				nav.path = nil
				npc.nav._stand(self, nil)
				nav.last_status = "failed"
				return "failed"
			end
		end
	end

	nav.last_status = "moving"
	return "moving"
end

-- Per-tick driver, called by the low-latency task "npc:move:walk_to".
-- Returns "arrived" | "failed" | "moving".
function npc.nav.step(self, dtime)
	local nav = npc.nav.session(self)
	if nav.active ~= true or nav.trgt_pos == nil then
		return "moving"
	end

	-- Refresh a live target's position
	if nav.target ~= nil then
		local p = nav.target:get_pos()
		if p ~= nil then
			nav.u_trgt_pos = p
		end
	end

	local u_self_pos = self.object:get_pos()
	local self_pos = vector.round(u_self_pos)

	-- Continuous follow (npc:follow): re-track the live leader's
	-- goal cell for the active leg (see the section header). A no-op
	-- without a follow session.
	npc.nav.follow_track(self, dtime)

	-- Door-close pause hold (door_close = "pause"): after the NPC
	-- stopped, faced the door and closed it (trigger below), stand
	-- still for a short beat before the walk resumes. A plain tick
	-- counter in this driver - nothing to schedule or guard.
	if (nav.door_hold or 0) > 0 then
		nav.door_hold = nav.door_hold - 1
		local y_speed = self.object:get_velocity().y
		self.object:set_velocity({x = 0, y = y_speed, z = 0})
		_npc.model.set_animation(self, {name = "stand"})
		nav.prev_self_pos = u_self_pos
		nav.prev_u_trgt_pos = nav.u_trgt_pos
		nav.last_status = "moving"
		return "moving"
	end

	-- Openable-passage tracking: remember the openable node (e.g. a
	-- door) the NPC is currently standing in. When the NPC leaves that
	-- cell (its center crosses into the next cell), the door_close
	-- policy (see the section header) takes over:
	--   "immediate": close the door now
	--   "pause": remember the door; the close happens once the NPC
	--            reaches the middle of the cell it just stepped into
	--   "none": leave the door open
	local cur_is_open = _npc.env.node_get_property(self, {property="is_open", pos=self_pos})
	if cur_is_open ~= nil then
		nav.in_openable_pos = {x=self_pos.x, y=self_pos.y, z=self_pos.z}
	elseif nav.in_openable_pos ~= nil then
		local openable_pos = nav.in_openable_pos
		nav.in_openable_pos = nil
		if nav.door_close == "immediate" then
			-- Close it now: only if the node is still there and still
			-- open (it may have been closed or removed in the
			-- meantime). The NPC's center is already in the next
			-- cell, so the solid door cannot trap it.
			if _npc.env.node_get_property(self, {property="is_open", pos=openable_pos}) == true then
				_npc.env.node_operate(self, {pos=openable_pos})
			end
		elseif nav.door_close == "pause" then
			-- The NPC just stepped into self_pos; pause there.
			nav.door_close_cell = openable_pos
			nav.door_pause_cell = {x=self_pos.x, y=self_pos.y, z=self_pos.z}
		end
	end

	-- Door-close pause trigger (door_close = "pause"): the NPC has
	-- reached the middle of the cell it stepped into after the door.
	-- Stop, face the door, close it; the hold at the top of this
	-- function keeps the beat before the walk resumes.
	local pause_cell = nav.door_pause_cell
	if pause_cell ~= nil then
		local at_pause_cell
		if nav.middle == true then
			at_pause_cell = math.abs(u_self_pos.x - pause_cell.x) <= 0.25
				and math.abs(u_self_pos.z - pause_cell.z) <= 0.25
		else
			at_pause_cell = (self_pos.x == pause_cell.x
				and self_pos.z == pause_cell.z)
		end
		if at_pause_cell then
			nav.door_pause_cell = nil
			local door_cell = nav.door_close_cell
			nav.door_close_cell = nil
			-- Face the middle of the door (its rest height), then
			-- close it (only if it is still there and still open).
			self.object:set_yaw(minetest.dir_to_yaw(vector.direction(u_self_pos,
				{x = door_cell.x, y = door_cell.y - 0.5, z = door_cell.z})))
			if _npc.env.node_get_property(self, {property="is_open", pos=door_cell}) == true then
				_npc.env.node_operate(self, {pos=door_cell})
			end
			nav.door_hold = 10
			local y_speed = self.object:get_velocity().y
			self.object:set_velocity({x = 0, y = y_speed, z = 0})
			nav.prev_self_pos = u_self_pos
			nav.prev_u_trgt_pos = nav.u_trgt_pos
			nav.last_status = "moving"
			return "moving"
		end
	end

	-- Steer-stuck hold (armed in the steer retry below): the last
	-- steer attempt shoved the NPC into something for a full second
	-- without moving. Stand still; the rate-limited re-plan (at most
	-- one real A* per 0.5 s while holding) re-engages a path as soon
	-- as one opens, and follow_track lifts the hold when the leader's
	-- predicted cell changes.
	if nav.steer_stuck == true then
		local self_cell = vector.round(u_self_pos)
		if nav.path ~= nil and #nav.path > 0 then
			-- A path is back (follow_track re-planned this tick):
			-- resume normal path walking.
			nav.steer_stuck = nil
		elseif self_cell.x == nav.trgt_pos.x
				and self_cell.y == nav.trgt_pos.y
				and self_cell.z == nav.trgt_pos.z then
			-- In the goal cell: fall through so the arrival check can
			-- end the walk (a held ll task would otherwise never
			-- notice the arrival).
			nav.steer_stuck = nil
			nav.path = {}
		else
			local path = npc.nav._follow_plan(self, nav.trgt_pos)
			if type(path) == "table" and #path > 0 then
				nav.path = path
				nav.steer_stuck = nil
			else
				local y_speed = self.object:get_velocity().y
				self.object:set_velocity({x = 0, y = y_speed, z = 0})
				_npc.model.set_animation(self, {name = "stand"})
				nav.prev_self_pos = u_self_pos
				nav.prev_u_trgt_pos = nav.u_trgt_pos
				nav.last_status = "moving"
				return "moving"
			end
		end
	end

	-- Check if we are done
	if nav.arrive_rule == "cell" then
		if nav.middle == true then
			-- Block-middle arrival: at the rest height on the target
			-- cell middle (x/z within 0.25, y within 0.5 of cell y -
			-- 0.5).
			if math.abs(u_self_pos.x - nav.trgt_pos.x) <= 0.25
				and math.abs(u_self_pos.z - nav.trgt_pos.z) <= 0.25
				and math.abs(u_self_pos.y - (nav.trgt_pos.y - 0.5)) <= 0.5 then
				-- Continuous follow: chain the next leg on this tick
				-- (no dead time between legs).
				if npc.nav.follow_next_leg(self, dtime, u_self_pos) then
					return "moving"
				end
				nav.active = false
				nav.path = nil
				npc.nav._stand(self, nav.trgt_pos)
				nav.last_status = "arrived"
				return "arrived"
			end
		elseif self_pos.x == nav.trgt_pos.x
			and self_pos.z == nav.trgt_pos.z
			and math.abs(nav.trgt_pos.y - self_pos.y) < 0.5 then
			-- Continuous follow: chain the next leg on this tick.
			if npc.nav.follow_next_leg(self, dtime, u_self_pos) then
				return "moving"
			end
			nav.active = false
			nav.path = nil
			npc.nav._stand(self, nav.trgt_pos)
			nav.last_status = "arrived"
			return "arrived"
		end
	elseif vector.distance(u_self_pos, nav.u_trgt_pos) <= nav.target_distance then
		-- Continuous follow: chain the next leg on this tick.
		if npc.nav.follow_next_leg(self, dtime, u_self_pos) then
			return "moving"
		end
		nav.active = false
		nav.path = nil
		npc.nav._stand(self, nav.trgt_pos)
		nav.last_status = "arrived"
		return "arrived"
	end

	-- Stuck detection: accumulate how far we moved during the last
	-- second. If we barely moved while we were supposed to be walking,
	-- the cached path is considered stale and we re-plan.
	local is_stuck = false
	if nav.prev_self_pos ~= nil then
		local acc_time = (nav.stuck_time or 0) + dtime
		local acc_moved = (nav.stuck_acc or 0)
			+ vector.distance(nav.prev_self_pos, u_self_pos)
		if (acc_time >= 1) then
			is_stuck = (acc_moved < nav.min_self_move_distance)
			acc_time = 0
			acc_moved = 0
		end
		nav.stuck_time = acc_time
		nav.stuck_acc = acc_moved
	end

	-- Re-plan if the path is gone, we are stuck, the target moved, or
	-- we reached the first node of the path: the head node is consumed
	-- by re-planning from the current cell, so the aim is always a step
	-- ahead of the NPC.
	local trgt_moved = (nav.prev_u_trgt_pos ~= nil)
		and (vector.distance(nav.prev_u_trgt_pos, nav.u_trgt_pos) > nav.min_trgt_move_distance)
	local reached_head = (nav.path ~= nil and #nav.path >= 1)
		and (nav.path[1].pos.x == self_pos.x and nav.path[1].pos.z == self_pos.z)
	-- Block-middle: if we are already in the target cell, a same-cell
	-- path search returns nil (and would fail the walk). Skip the
	-- search and steer straight at the cell middle below instead; the
	-- arrival check above ends the session once we are on it.
	local middle_same_cell = (nav.middle == true)
		and (self_pos.x == nav.trgt_pos.x and self_pos.y == nav.trgt_pos.y
			and self_pos.z == nav.trgt_pos.z)
	if (nav.path == nil or #nav.path == 0)
		or (is_stuck == true)
		or (trgt_moved == true)
		or (reached_head == true) then
		if nav.steer == true then
			-- Blocked while steering (pushed into a wall or the
			-- leader for a full second without moving): enter the
			-- steer-stuck hold instead of shoving forever; the hold's
			-- rate-limited re-plan picks a path up as soon as one
			-- opens.
			if is_stuck == true then
				nav.steer = false
				nav.steer_stuck = true
				nav.path = {}
				local y_speed = self.object:get_velocity().y
				self.object:set_velocity({x = 0, y = y_speed, z = 0})
				_npc.model.set_animation(self, {name = "stand"})
				nav.prev_self_pos = self.object:get_pos()
				nav.prev_u_trgt_pos = nav.u_trgt_pos
				nav.last_status = "moving"
				return "moving"
			end
			-- Direct steering (the follow fallback): retry a
			-- rate-limited search at the goal cell; a path resumes
			-- normal path walking, otherwise keep steering (the
			-- steering section below).
			local path = npc.nav._follow_plan(self, nav.trgt_pos)
			if type(path) == "table" and #path > 0 then
				nav.path = path
				nav.steer = false
			else
				nav.path = {}
			end
		elseif middle_same_cell == true then
			nav.path = {}
		else
			local path = npc.nav._find_path(self, nav.trgt_pos)
			if path == nil then
				if nav.force == true then
					self.object:move_to(nav.trgt_pos, false)
				end
				nav.active = false
				nav.path = nil
				npc.nav._stand(self, nil)
				nav.last_status = "failed"
				return "failed"
			end
			nav.path = path
		end
	end

	-- No path ahead: aim directly at the target cell middle (its
	-- rest height) - block-middle same-cell, or direct steering
	-- (the follow fallback at its goal cell).
	if middle_same_cell == true or nav.steer == true then
		local aim_pos = {x = nav.trgt_pos.x, y = nav.trgt_pos.y - 0.5,
			z = nav.trgt_pos.z}
		local dir = vector.normalize(vector.direction(u_self_pos, aim_pos))
		local yaw
		if nav.look_at_target then
			yaw = minetest.dir_to_yaw(vector.direction(u_self_pos, nav.u_trgt_pos))
		else
			yaw = minetest.dir_to_yaw(dir)
		end
		self.object:set_yaw(yaw)
		-- Leave the vertical movement to the physics (gravity and
		-- stepheight).
		local y_speed = self.object:get_velocity().y
		local vel = vector.multiply({x=dir.x, y=y_speed, z=dir.z}, nav.speed)
		self.object:set_velocity(vel)
		_npc.model.set_animation(self, {name = "walk", speed = 30})
		nav.prev_self_pos = self.object:get_pos()
		nav.prev_u_trgt_pos = nav.u_trgt_pos
		nav.last_status = "moving"
		return "moving"
	end

	-- Move towards position.
	-- Legacy advancement semantics (kept verbatim for now): the tail of
	-- the path is consumed every tick and the re-plans above refresh
	-- the head. Proper head advancement replaces this in the next step.
	local next_node = nav.path[1]
	if next_node.pos.x == self_pos.x and next_node.pos.z == self_pos.z and #nav.path > 1 then
		next_node = nav.path[2]
		table.remove(nav.path)
	end

	table.remove(nav.path)

	local next_pos = next_node.pos

	-- Block-middle steering: aim at the middle of the next block (its
	-- rest height) instead of the cell coordinates.
	local aim_pos = next_pos
	if nav.middle == true then
		aim_pos = {x = next_pos.x, y = next_pos.y - 0.5, z = next_pos.z}
	end

	local dir = vector.normalize(vector.direction(u_self_pos, aim_pos))
	local yaw = 0
	if nav.look_at_target then
		yaw = minetest.dir_to_yaw(vector.direction(u_self_pos, nav.u_trgt_pos))
	else
		yaw = minetest.dir_to_yaw(dir)
	end

	-- Rotate towards next node
	self.object:set_yaw(yaw)

	-- Direction is already normalized, so speed is constant on any axis

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
		_npc.move.jump(self, {target_pos = next_pos, middle = (nav.middle == true)})
	else
		-- Leave the vertical movement to the physics (gravity and
		-- stepheight). A large negative y speed made the NPC dive and
		-- could cancel stair/slab climbing.
		local y_speed = self.object:get_velocity().y
		local vel = vector.multiply({x=dir.x, y=y_speed, z=dir.z}, nav.speed)
		self.object:set_velocity(vel)
		_npc.model.set_animation(self, {name = "walk", speed = 30})
	end

	-- If the next node in the path is openable (e.g. a door), open
	-- it if it's closed. Closing is handled when the NPC leaves the
	-- door cell (passage tracking at the top of npc.nav.step), so
	-- this only opens - the door is left open until the NPC is
	-- through it.
	if next_node.type == npc.pathfinder.node_types.openable then
		local is_open = _npc.env.node_get_property(self, {property="is_open", pos=next_pos})
		if is_open == false then
			_npc.env.node_operate(self, {pos=next_pos})
		end
	end

	nav.prev_self_pos = self.object:get_pos()
	nav.prev_u_trgt_pos = nav.u_trgt_pos

	nav.last_status = "moving"
	return "moving"
end

-- Stop an active navigation session (the NPC stands down).
function npc.nav.stop(self)
	local nav = npc.nav.session(self)
	if nav.active == true then
		self.object:set_velocity({x = 0, y = 0, z = 0})
		_npc.model.set_animation(self, {name = "stand"})
	end
	nav.active = false
	nav.path = nil
end

-- Current session status: "moving" while the session is active,
-- otherwise the last terminal status ("arrived" | "failed") or nil.
function npc.nav.status(self)
	local nav = npc.nav.session(self)
	if nav.active == true then
		return "moving"
	end
	return nav.last_status
end

-- Walk instruction using pathfinding
-- Supports climbing stairs/slabs, jumping and opening doors (the
-- per-tick work lives in the npc.nav section above).
-- Walks block-middle to block-middle by default (middle = true): the
-- target, the per-tick aim and the jump arc all use the middle of each
-- block (cell y - 0.5). Pass middle = false to keep the legacy
-- cell-corner behavior.
-- args.door_close: "immediate" (default) | "pause" | "none" - how the
-- door is closed after the NPC passes through it (npc.nav section
-- header).
npc.proc.register_instruction("npc:move:walk_to_pos", function(self, args)
	local speed = args.speed or 2

	-- Calculate process timer interval: re-arm more frequently while
	-- the NPC is moving. Restored when the walk finishes or fails.
	local prev_proc_int = self.timers.proc_int
	self.timers.proc_int = (1/speed) / 2

	local status = npc.nav.start(self, args, {speed = speed, arrive_rule = "cell", middle = true})
	if status == "moving" then
		-- The low-latency task drives the per-tick movement
		self.timers.hl_task_int = 30
		npc.proc.execute_ll_task(self, "npc:move:walk_to", args)
		return false
	end

	-- Restore process timer interval
	self.timers.proc_int = prev_proc_int
	if status == "arrived" then
		return true
	end

	return nil
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

	local next_tail = (self.process.queue_tail + 1) % 100
	if next_tail == 0 then next_tail = 1 end
	self.process.queue_tail = next_tail
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
		if self.process.low_latency_task.name == name then
			-- Re-arming an already active task: refresh its arguments in
			-- place (e.g. npc:follow updating the target) and restart the
			-- timeout countdown.
			self.process.low_latency_task.args = args
			self.timers.hl_task_value = 0
			return
		end

		-- Avoid stacking a task that is already waiting on the stack
		local is_on_stack = false
		for i = 1, #self.process.low_latency_task_stack do
			if self.process.low_latency_task_stack[i].name == name then
				is_on_stack = true
				break
			end
		end
		if not is_on_stack then
			table.insert(self.process.low_latency_task_stack, 1, {name = self.process.low_latency_task.name, args = self.process.low_latency_task.args})
		end
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
npc.do_step = function(self, dtime, moveresult)
	-- Keep the latest moveresult around so that low-latency tasks (e.g. the
	-- jump landing check) can inspect the collision info of this step.
	self.moveresult = moveresult
	
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
	if (self.timers.node_below_value > self.timers.node_below_int) then
		self.timers.node_below_value = 0
		local current_pos = self.object:get_pos()
		-- The supporting node is the row containing the NPC's feet:
		-- this engine build rests min.y=0 collision boxes 0.5 sunk
		-- into their supporting node, so the feet y already floors
		-- to that node row (no -1 offset).
		self.data.env.node_on = minetest.get_node_or_nil({x=current_pos.x, y=current_pos.y, z=current_pos.z})
	end

	-- Get objects around NPC on radius
	if (self.timers.objects_value > self.timers.objects_int) then
		self.timers.objects_value = 0
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
			if #self.process.low_latency_task_stack > 0 then
				local top = self.process.low_latency_task_stack[1]
				npc.proc.execute_ll_task(self, top.name, top.args)
				table.remove(self.process.low_latency_task_stack)
				-- Avoid execution of the process queue
				return
			end
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

		-- Execute next instruction, if available. While a low-latency
		-- task is still active (e.g. the jump landing wait), do not run
		-- the next instruction: the NPC must land before the program
		-- proceeds to the following instruction.
		if self.process.current.instruction > -1 and self.process.low_latency_task.active ~= true then
			local instruction =
				program_table[self.process.current.name].instructions[self.process.current.instruction]
			-- Check if there are no more instructions. This happens usually when the last instruction
			-- of a program is "npc:execute".
			if instruction == nil then
				--minetest.log("Process now: "..dump(self.process))
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
			nav = {},
			schedule = {}
		}
		-- Prime the object table: the first refresh runs 1 s later, but
		-- a program may resolve @objs arguments on its very first pass.
		self.data.env.objects = {}
		
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
		self.process.low_latency_task = {
			handler = nil,
			timeout_handler = nil,
			args = {},
			active = false
		}
		result = result..minetest.serialize(self.process).."|"
	end

	if self.data then
		self.data.env.objects = {}
		self.data.temp = {}
		-- The navigation session holds live object references (and a
		-- cached path), which are not serializable - drop it.
		self.data.nav = {}
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
	-- Landed if we collided with the ground on this step (moveresult is
	-- only true on the tick where the collision happens), or if the
	-- collision handling has already zeroed the y velocity.
	local landed = (self.moveresult ~= nil and self.moveresult.touching_ground == true)
	if landed == false and self.object:get_velocity().y == 0 then
		landed = true
	end
	if landed then
		self.object:set_velocity({x=0, y=0, z=0})
		return true
	end
	-- Not landed yet: re-assert the horizontal launch velocity. The
	-- per-axis collision resolution zeroes the velocity of any axis
	-- that presses into a face, so without this the step-up arc loses
	-- its x/z component the moment the box's lower half touches the
	-- step face and the jump degenerates into a vertical hop in place.
	-- Keep the engine-managed y (gravity, ceiling handling). In free
	-- air this is a no-op: the launch velocity is constant, which is
	-- exactly the ballistic arc the takeoff set.
	if (self.jump_xvel ~= nil or self.jump_zvel ~= nil) then
		local vel = self.object:get_velocity()
		self.object:set_velocity({x = self.jump_xvel or 0, y = vel.y, z = self.jump_zvel or 0})
	end
	return false
end)

-- Walk instruction using pathfinding and low-latency tasks
-- This is a possibly expensive operation!
-- Supports climbing stairs/slabs, jumping and opening doors
-- The per-tick work (planning, node advancement, aiming, stairs,
-- jumps, doors, arrival and stuck handling) lives in the shared
-- navigation session - see the npc.nav section above.
-- Distance arrival on live coordinates stays on for this entry
-- point: its callers walk to moving objects or exact positions where
-- the live coordinates matter more than the block middle.
npc.proc.register_low_latency_task("npc:move:walk_to", function(self, dtime, args)
	return npc.nav.step(self, dtime) ~= "moving"
end)

npc.proc.register_instruction("npc:move:walk_to_pos_ll", function(self, args)
	local status = npc.nav.start(self, args, {speed = 3, arrive_rule = "distance", target_distance = 1.5})
	if status == "moving" then
		self.timers.hl_task_int = 30
		npc.proc.execute_ll_task(self, "npc:move:walk_to", args)
	end
end)

-- Cell-arrival ll entry point for the npc:follow goal cell:
-- block-middle walking, cell arrival, so the NPC rests at the middle
-- of the goal cell. The goal is re-tracked per tick by npc.nav:
-- follow_track while the ll task is active (see the section header).
-- A failed initial plan does not freeze the follow: the follow
-- fallback (slot ladder, then direct steering) takes over instead.
npc.proc.register_instruction("npc:move:walk_to_cell_ll", function(self, args)
	local nav = npc.nav.session(self)
	-- Resume gate (continuous follow, see npc.nav.follow_speed): an
	-- idle follower (no active walk) only starts walking again when
	-- the leader is at least `catch_up` cells away (default 2 x the
	-- follow distance); a leader moving a couple of steps around a
	-- place does not drag the NPC.
	local follow = nav.follow
	if follow ~= nil and nav.active == false then
		local leader_pos = follow.leader ~= nil and follow.leader:get_pos() or nil
		if leader_pos ~= nil then
			local gap = vector.distance(self.object:get_pos(), leader_pos)
			if gap < follow.catch_up then
				npc.nav._stand(self, nil)
				return -- stand down (no walk this pass)
			end
		end
	end
	-- Speed: the derived follow speed with the catch-up hysteresis
	-- (npc.nav.follow_speed); an explicit speed argument on the
	-- program wins for the normal speed.
	local speed = npc.nav.follow_speed(self, args)
	local status = npc.nav.start(self, args, {speed = speed, arrive_rule = "cell", middle = true})
	if status == "failed" and npc.nav.session(self).follow ~= nil
			and args.target_pos ~= nil then
		-- The initial goal cell was unreachable: fall back to the
		-- slot ladder / direct steering instead of freezing the
		-- follow session.
		local outcome = npc.nav.follow_fallback(self, vector.round(args.target_pos))
		if outcome == "path" or outcome == "steer" then
			status = "moving"
		end
	end
	if status == "moving" then
		self.timers.hl_task_int = 30
		npc.proc.execute_ll_task(self, "npc:move:walk_to", args)
	end
end)

-- Compute the npc:follow goal cell (behind/ahead of the tracked
-- leader); the program stores the result in a local variable.
npc.proc.register_instruction("npc:nav:follow_goal", function(self, args)
	return npc.nav.follow_goal(self, args)
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

-- Follow test item: left-click an anpc NPC with it to make that NPC
-- follow the clicking player (runs the "npc:follow" state process,
-- block-middle walking, 2 cells behind, walking speed = the
-- player's walk speed minus 0.25 m/s with catch-up at 4 cells,
-- immediate door closing).
-- Left-click the same NPC with it again to stop following and
-- restore the NPC's previous state process. Only works on engine
-- NPCs (the pointed object must have the proc machinery).
minetest.register_craftitem("anpc:follow_item", {
	description = "Follow (test)",
	inventory_image = "default_footprint.png",
	on_use = function(itemstack, user, pointed_thing)
		if user == nil or pointed_thing == nil
			or pointed_thing.type ~= "object" then
			return itemstack
		end
		local npc_ent = pointed_thing.ref:get_luaentity()
		-- Only engine NPCs: they have the data/process tables set up
		-- in npc.on_activate.
		if npc_ent == nil or npc_ent.data == nil
			or npc_ent.process == nil or npc_ent.process.state == nil then
			return itemstack
		end
		local state = npc_ent.process.state
		if state.name == "npc:follow" then
			-- Stop following: restore the previous state process.
			local prev = npc_ent.data.follow_prev_state
			npc_ent.data.follow_prev_state = nil
			if prev ~= nil and prev.name ~= nil then
				npc.proc.set_state_process(npc_ent, prev.name, prev.args, true)
			end
		else
			-- Start following the clicking player. The leader is
			-- resolved by player name each pass (@objs.get in the
			-- npc:follow program), so the NPC tracks the player even
			-- while the goal cell stays static for one walk.
			npc_ent.data.follow_prev_state = {
				name = state.name,
				args = state.args,
			}
			npc.proc.set_state_process(npc_ent, "npc:follow", {
				object = user:get_player_name(),
				follow_mode = "behind",
				follow_distance = 2,
			}, true)
		end
		return itemstack
	end
})

-- Node registrations live in the per-game files under nodes/
-- (e.g. nodes/minetest_game.lua), loaded by init.lua. The engine
-- itself only operates on nodes registered there by category
-- (e.g. "openable"), so it stays game-agnostic.


