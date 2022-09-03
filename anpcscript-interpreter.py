# Very inflexible, rudimentary and basic interpreter for anpc-script
# (C) by Zorman2000
#
# Please don't use this as an example of good Python code :)

import logging
import re
import sys

logging.basicConfig(level=logging.INFO)

###################################################################
## Helper functions
###################################################################
def generate_arguments_for_instruction(args_str):
	result = "{"
	if not args_str.strip():
		return "{}"

	keyvalue_pairs = args_str.split(",")
	pairs_count = len(keyvalue_pairs)
	for i in range(pairs_count):
		key_value = keyvalue_pairs[i].split("=")
		key = key_value[0].strip()
		value = key_value[1].strip()

		if value[0] == "@":
			value = f'"{value}"'

		result = result + key + " = " + value
		if i < pairs_count - 1:
			result = result + ", "
		
	return result + "}"

def generate_boolean_expression(bool_expr):
	if bool_expr[:4] == "lua:":
		return bool_expr[4:]
		
	result = '{left = "'
	expr_parts = re.split(r'(==|<|>|<=|>=|~=)', bool_expr)
	if len(expr_parts) != 3:
		logging.error(f'Malformed boolean expression: {bool_expr}')
		return

	result += expr_parts[0].strip()
	result += '", op = "'
	result += expr_parts[1].strip()
	result += '", right = '
	result += expr_parts[2].strip()
	result += '}'
	return result


###################################################################
## Single-line parsers
###################################################################
# This function parses a line where a variable assignment is contained
def parse_variable_assignment(line, line_number, nesting, result):
	variable = re.search(r'@[a-z]*.[a-z_]*', line, re.I)
	if not variable:
		logging.error(f"Error on line {line_number}: variable expected but not found")

	assignment = re.search(r'=\s.+', line, re.I)
	if not assignment:
		logging.error(f"Error on line {line_number}: expected assignment to variable {variable.group(0)}")

	variable_name = variable.group(0)
	# Remove '= ' from assignment match
	assignment_expr = assignment.group(0)[2:]
	
	# Check if the assigned value is an instruction
	parenthesis_start = assignment_expr.find("(")
	parenthesis_end = assignment_expr.find(")")
	if parenthesis_start > -1 and parenthesis_end > -1 and parenthesis_end > parenthesis_start:
		instr_name = assignment_expr[:parenthesis_start]
		args_str = assignment_expr[parenthesis_start + 1:parenthesis_end]
		result.append((nesting*"\t") + f'{{key = "{variable_name}", name = "{instr_name}", args = {generate_arguments_for_instruction(args_str)}}}')
	else:
		result.append((nesting*"\t") + f'{{name = "npc:var:set", args = {{key = "{variable_name}", value = {assignment_expr}}}}}')

# This function parses a line where a single instruction is contained
def parse_instruction(line, nesting, result):
	parenthesis_start = line.find("(")
	parenthesis_end = line.find(")")
	if parenthesis_start > -1 and parenthesis_end > -1 and parenthesis_end > parenthesis_start:
		instr_name = line[:parenthesis_start]
		args_str = line[parenthesis_start + 1:parenthesis_end]
				
		result.append((nesting*"\t") + f'{{name = "{instr_name}", args = {generate_arguments_for_instruction(args_str)}}}')


###################################################################
## File parsers
###################################################################
def parse_file(lines):
	result = []
	program_names = []

	for i in range(len(lines)):
		if re.search(r'^(define program).*$', lines[i], re.M|re.I):
			# Found a program definition, now collect all lines inside the program
			program_name = lines[i].split("define program")[1].strip()
			logging.info(f'Found program "{program_name}" definition starting at line {i+1}')
			if program_name in program_names:
				logging.error(f'Parsing error: Program with name "{program_name}" is already defined.')
				sys.exit(1)
			
			program_names.append(program_name)
			program_lines = []

			for j in range(i + 1, len(lines), 1):
				if re.search(r'^end$', lines[j], re.M|re.I):
					# Found definition end, parse this program and continue
					result.append(f'npc.proc.register_program("{program_name}", {{')
					lua_code_lines = parse_instructions(program_lines, 1)
					for k in range(len(lua_code_lines)):
						result.append(f'{lua_code_lines[k]}{"," if k < len(lua_code_lines) - 1 else ""}')
					result.append("})\n")

					logging.info(f'Successfully parsed program "{program_name}" ({j-i-1} lines of code)')
					i = i + j
					break
				else:
					program_lines.append(lines[j])

	return result

def parse_instructions(lines, nesting):
	logging.debug('Executing "parse_instructions" with lines:\n' + "".join(lines))
	result = []

	lines_count = len(lines)
	i = 0
	while (i < lines_count):
		line = lines[i].strip()
		logging.debug(f'Line: {lines[i]}, {i}')

		###################################################################
		# Check for "variable assignment" line
		if re.search(r'^\s*@[a-z]*.[a-z_0-9A-Z]*\s=\s.*$', line, re.M|re.I):
			parse_variable_assignment(line, i, nesting, result)
		
		###################################################################
		# Check for control instruction line
		elif re.search(r'^\s*(while|for|if)\s\(.*\)\s(do|then)$', line, re.M|re.I):
			control_stack = []
					
			# Find the control instruction
			control_instr = re.search(r'(while|for|if)', line, re.M|re.I) \
			.group(0) \
			.strip()
			control_stack.append(control_instr)
			# Find the start for the control instruction
			control_start_instr = re.search(r'(do|then)', line, re.M|re.I).group(0).strip()
			# Find the boolean expression
			bool_expr_str = ""
			parenthesis_start = line.find("(")
			parenthesis_end = re.search(r'\)\s*(do|then)$', line, re.M|re.I).span()[0]
			if parenthesis_start > -1 and parenthesis_end > -1 and parenthesis_end > parenthesis_start:
				bool_expr_str = line[parenthesis_start+1:parenthesis_end]
				bool_expr_str = generate_boolean_expression(bool_expr_str)
				
			# Find all instructions that are part of the control
			# For 'if', we need to search for an else as well.
			loop_instructions = []
			false_instructions = []
			else_index = -1
			for j in range(i + 1, len(lines), 1):
				sub_line = lines[j].strip()
				logging.debug("subline: " + sub_line)
				
				else_instr = re.search(r'\s*else\s*', sub_line, re.M|re.I)
				if else_instr:
					last_control = control_stack.pop()
					if last_control != "if":
						logging.error(f'Found "else" keyword without corresponding "if" at: line {i+j+1}')
						sys.exit(1)
					control_stack.append("else")
					else_index = j
					# These are the true_instructions
					loop_instructions = lines[i+1:j+1]
					continue
				end_instr = re.search(r'\s*end\s*', sub_line, re.M|re.I)
				if end_instr:
					last_control = control_stack.pop()
					if last_control == "else":
						# These are the false instructions
						false_instructions = lines[else_index+1:j+1]
					else:
						# These are the true/loop instructions
						loop_instructions = lines[i+1:j+1]
					# Increase counter to avoid processing lines which are inside controls
					logging.debug(f"Old i: {i}")
					i = j
					logging.debug(f"New i: {i}")
					break
			# Now, process all the instructions that we found
			if not loop_instructions:
				logging.warning(f'Found control structure "{control_instr}" without any instructions at: line {j+1}')
			processed_loop_instrs = parse_instructions(loop_instructions, nesting + 1)
			processed_false_instrs = parse_instructions(false_instructions, nesting + 1)
			
			instructions_name = "true_instructions" if control_instr == "if" else "loop_instructions"
			loop_instr = (nesting*"\t") + '{name = "npc:' + control_instr \
			+ '", args = {expr = ' + bool_expr_str + ', ' + instructions_name \
			+ ' = {\n' + ",\n".join(processed_loop_instrs) + '\n' + (nesting*"\t") + '}'
			
			if processed_false_instrs:
				loop_instr = loop_instr + ',\n' + (nesting*"\t") + 'false_instructions = {\n' \
				+ ",\n".join(processed_false_instrs) + '\n' + (nesting*"\t") + '}'
			
			result.append(loop_instr)
			
			logging.debug(f'loop: {processed_loop_instrs}')
			logging.debug(f'false: {processed_false_instrs}')
		
		###################################################################
		# Check for single-line instructions
		elif re.search(r'^(?!.*(\sif\s|\swhile\s|\sfor\s|.*=.*\(.*\))).*\(.*\)$', line, re.M|re.I):
			parse_instruction(line, nesting, result)
		
		###################################################################
		# Check for break instruction
		elif re.search(r'^\s*break\s*$', line, re.M|re.I):
			result.append((nesting*"\t") + f'{{name = "npc:break"}}')

		i = i + 1

	logging.debug("Returning Lua code lines:\n" + "\n".join(result))
	return result


###################################################################
## Main
###################################################################
def main():
	if len(sys.argv) != 3:
		print("anpcscript-interpreter.py v1.0")
		print("This python script converts a anpc-script file into Lua code")
		print("understandable by the anpc Minetest mod\n")
		print('Usage: "python3 anpcscript-interpreter.py <input-file> <output-file>"\n')
		sys.exit(0)

	lines = []
	input_name = sys.argv[1]
	output_name = sys.argv[2]
	logging.info(f'Starting parsing file "{input_name}"')
	with open(input_name, "r") as file:
		for line in file:
			lines.append(line)

	logging.info(f'Successfully parsed file "{input_name}" generating {len(lines)} lines of Lua code')

	lua_code = parse_file(lines)
	logging.info(f'Writing Lua file at "{output_name}"')
	with open(output_name, "w") as file:
		for i in range(len(lua_code)):
			file.write(lua_code[i] + "\n")

	logging.info(f'Successfully writed Lua source code file "{output_name}"')
	return

if __name__ == "__main__":
	main()
