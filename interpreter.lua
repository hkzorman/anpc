-- This is the anpc's interpreter code. It changes the 

npc.parser = {}

local _parser = {}

npc.proc.register_program("builtin:walk_to_pos", {
	{name = "npc:var:set", args = {
		key = "has_reached_pos",
		value = false
	}},
	{key = "end_pos", name = "npc:env:node:get_accessing_pos", args = {
		pos = "@args.end_pos",
		force = "@args.force_accessing_node"
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


local builtin_walktopos = [[
	@local.has_reached_pos = false;
	@local.end_pos = npc:env:node:get_accessing_pos(@args.end_pos, @args.force_accessing_node);
	while (@local.has_reached_pos == false) do
		@local.has_reached_pos = npc:move:walk_to_pos(@local.end_pos, @args.end_pos, false);
		if (@local.has_reached_pos == nil) then;
			break;
		end
	end
]]

-- Variable assignment line: /[@a-z]*.[a-z_]*\s=\s.*/gm
-- Control line: /(while|for|if)\s\(.*\)\s(do|then)/gm
-- Control end line: /\b(end|break)\b/gm
-- Statement line: /^(?!.*(\sif\s|\swhile\s|\sfor\s|.*=.*\(.*\))).*\(.*\)$/gm
-- Using line: /using.*=\s".*"/gm

-- Extremely rudimentary code parser
npc.parser.parse = function(program_code)
	local result = {}
	
	local lines = string.split(program_code, "\n")
	for i = 1, #lines do
		-- For each line, split into spaces
		local tokens = string.split(lines[i], " ")
		
		-- Check if no tokens - this might be an empty line, so we skip it
		if #tokens == 0 then goto continue end
		
		local instruction = {}
		
		-- Identify the type of line that we have. In anpc-script, the first token is either:
		--  - a variable, so it starts with '@'
		--  - an instruction, so it will at some point have an opening parenthesis '('
		--  - a control instruction, which is either 'for', 'if' or 'while'
		local first_token = tokens[1]
		
		
		
		-- Check if token is a variable. If the first token is a variable, there are
		-- two ways to translate this. The first one is a "npc:var:set" instruction, or
		-- assigning the return value of an instruction to the specified variable
		-- The way to know this is what is at the other side of the "="
		if string.sub(first_token, 1, 2) == "@" then
			
		end
		
		for j = 1, #tokens do
			local token = tokens[j]
			-- Check if token is a variable.
			if string.sub(token, 1, 2) == "@" then
				
			
		end
		
		::continue::
	end
end

_parser.check_line_type = function(line)
	
	if (string.find(line, ""))
	
	end

end

_parser.parse_variable_assignment_line = function(tokens)

end
