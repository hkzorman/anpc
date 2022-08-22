import logging
import re
import sys

#logger = logging.getLogger("gunicorn.error")

test = """
    @local.pos0 = somegarbage(pos = @local.garb, avoid_g = true, donot_care = @local.garbage)
    @local.pos1 = "a"
    @local.pos2 = 1
    @local.pos3 = true
    if (@local.nonsense == "g") then
        executenonsense()
    end
"""

def generate_arguments_for_instruction(args_str):
    result = "{"
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

def parse_program(lines):
    result = []

    for i in range(len(lines)):
        line = lines[i]
        # Check for "variable assignment" line
        if re.search(r'[@a-z]*.[a-z_]*\s=\s.*', line, re.M|re.I):
            variable = re.search(r'@[a-z]*.[a-z_]*', line, re.I)
            if not variable:
                print(f"Error on line {i}: variable expected but not found")

            assignment = re.search(r'=\s.+', line, re.I)
            if not assignment:
                print(f"Error on line {i}: expected assignment to variable {variable.group(0)}")

            variable_name = variable.group(0)
            # Remove '= ' from assignment match
            assignment_expr = assignment.group(0)[2:]
            
            # Check if the assigned value is an instruction
            parenthesis_start = assignment_expr.find("(")
            parenthesis_end = assignment_expr.find(")")
            if parenthesis_start > -1 and parenthesis_end > -1 and parenthesis_end > parenthesis_start:
                instr_name = assignment_expr[:parenthesis_start]
                args_str = assignment_expr[parenthesis_start + 1:parenthesis_end]
                result.append(f'{{key = "{variable_name}", name = "{instr_name}", args = {generate_arguments_for_instruction(args_str)}}}')
            else:
                result.append(f'{{name = "npc:var:set", args = {{key = "{variable_name}", value = {assignment_expr}}}}}')
        # Check for control instruction line
        elif re.search(r'(while|for|if)\s\(.*\)\s(do|then)', line, re.M|re.I):
            print(re.search(r'(while|for|if)\s\(.*\)\s(do|then)', line, re.M|re.I))


    return result

def main():
    lines = test.splitlines()
    lua_code = parse_program(lines)

    for i in range(len(lua_code)):
        print(lua_code[i])

if __name__ == "__main__":
    main()