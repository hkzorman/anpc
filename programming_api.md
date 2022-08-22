ANPC programming language

The language will resemble the syntax of assembly language in order to make it simple to parse.

Here's an example program:
```
npc.proc.register_program("vegetarian:sleep", {
    {key = "bed_pos", name = "npc:env:node:find", args = {
        matches = "single",
        radius = 35,
        nodenames = {"beds:bed_bottom"}
    }},
    {name = "npc:if", args = {
        expr = {
        	left  = "@local.bed_pos",
        	op    = "~=",
        	right = nil
        },
        true_instructions = {
            {name = "npc:execute", args = {
                name = "builtin:walk_to_pos",
                args = {
                	end_pos = "@local.bed_pos"
                }
            }},
            {name = "npc:env:node:operate", args = {
            	pos = "@local.bed_pos"
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
            {name = "vegetarian:set_hunger", args = {value = 60}},
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
```

Here's how the program would like if we wrote it in ANPC-assembly:
```
@local.bed_pos = npc:env:node:find -matches="single" -radius=35 -nodenames="beds:bed_bottom"
if @local.bed_pos ~= nil then
	npc:execute -name="builtin:walk_to_pos" -args="end_pos=@local.bed_pos"
	npc:env:node:operate -pos=@local.bed_pos
	using expresson = "function(self, args); local time = 24000 * minetest.get_timeofday(); return (time > 20000 and time < 24000) or (time < 6000); end"
	while expression do
		npc:wait -time=30
	end
	
	vegetarian:set_hunger -value=60
	npc:set_state_process -name="vegetarian:idle" -args="ack_nearby_objs=true, ack_nearby_objs_dist=4, ack_nearby_objs_chance=50"
end	
```

local.bed_pos = env:node:find("single", 35, "beds:bed_bottom")
if local.bed_pos ~= nil then
	execute("builtin:walk_to_pos", 



Programs are made of three basic concepts:
1. Instructions
2. Program control
3. Variables

Instructions
------------
Instructions are the basic building block of programs. They are made of Lua code. Their name is usually of the syntax <namespace>:<instruction name>, but after "namespace" there could be more names which actually represent grouping. These are marely conventions are not really needed - the name is just the name. Instructions can receive an arbitrary number of parameters. Some instructions are built-in (and these are named always with "npc" as the namespace) while others can be registered locally.
