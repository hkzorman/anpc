

-- Sample programs for anpc

-- Stupid program that walks on a square
npc.proc.register_program("sample:silly_square", {
	{name = "npc:for", args = {
		initial_value = 0,
		step_increase = 2,
		expr = {left="@local.for_index", op="<=", right=6},
		loop_instructions = {
			{name = "npc:move:walk", args = {dir = "@local.for_index"}}
		}
	}}
})

npc.proc.register_program("sample:silly_initialization", {
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
							{name = "npc:env:node:set_owned", args = {
								pos = function(self, args)
									return self.data.proc[self.process.current.id].nodes[self.data.proc[self.process.current.id].for_index]
								end,
								value=true
							}},
							{name = "npc:break"}
						},
					}}
				}
			}}
		}
	}}
})

