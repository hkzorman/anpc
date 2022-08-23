# Very inflexible, rudimentary and basic interpreter for anpc-script
# (C) by Zorman2000

import logging
import re
import sys

logging.basicConfig(level=logging.DEBUG)
#logger = logging.getLogger("gunicorn.error")

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
                    lua_code_lines = parse_instructions(program_lines)
                    for k in range(len(lua_code_lines)):
                        result.append(f'\t{lua_code_lines[k]}{"," if k < len(lua_code_lines) - 1 else ""}')
                    result.append("})")

                    print(i, j)
                    logging.info(f'Successfully parsed program "{program_name}" ({j-i-1} lines of code)')
                    i = i + j
                   
                    
                    break
                else:
                    program_lines.append(lines[j])

    return result
    
def parse_instructions(lines):
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
        elif re.search(r'^\s+(while|for|if)\s\(.*\)\s(do|then)$', line, re.M|re.I):
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
            parenthesis_end = line.find(")")
            if parenthesis_start > -1 and parenthesis_end > -1 and parenthesis_end > parenthesis_start:
                bool_expr_str = line[parenthesis_start+1:parenthesis_end-1]
                
            # Find all instructions that are part of the control
            # For 'if', we need to search for an else as well.
            for j in range(i + 1, len(lines), 1):
                sub_line = lines[j]
                else_instr = re.search(r'\s*else\s*', sub_line, re.M|re.I)
                if else_instr:
                    last_control = control_stack.pop()
                    if last_control != "if":
                        logging.error(f'Found "else" keyword without corresponding "if" (line {i+j+1})')
                        sys.exit(1)
                    control_stack.append("else")
                
    return result

## Helper ##
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

def generate_boolean_expression(bool_expr):
    result = "{"


def main():
    lines = []
    name = "vegetarian.anpcscript"
    logging.info(f'Starting parsing file "{name}"')
    file = open(name, "r")
    for line in file:
        lines.append(line)

    lua_code = parse_file(lines)

    for i in range(len(lua_code)):
        print(lua_code[i])

if __name__ == "__main__":
    main()
