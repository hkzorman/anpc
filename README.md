# anpc - Advanced NPCs for minetest
## What is `anpc`?
`anpc`, short for advanced NPCs or non-playable-character, is a Minetest mod that allows you to create animals, enemies (so-called mobs) and any other kind of computer-controlled character. `anpc` is the spiritual successor to my other mod, `advanced_npc`. `anpc` inherits the "computer-like" structure of entities in `advanced_npc`, but takes it to a whole new level.

**NOTE** `anpc` is still on development. This is not even an alpha version - but close. The mod is very stable, but functionality is missing. This mod also doesn't contain any *real* playable content: you can fiddle around with the included `vegetarian.lua` NPC, which will be taken out of the release version of the mod.

For more information about how to use `anpc`, please see (anpc_dev)[https://github.com/hkzorman/anpc-dev]

## How does it works?
The main concept behind `anpc` is that each NPC is an independent, programmable computer. 

### The NPC programming model
Each NPC has a "CPU" and a memory space. The "CPU" runs instructions inside a program. The instructions are Lua functions, while programs are collections of instructions. The CPU also supports timers, interruptions and low-latency tasks.

Instructions, as said before, are Lua functions. This is the lowest level of operation in `anpc`. Each instruction is condered "atomic", and therefore should run on one entity step.

Programs are collections of instructions, implemented as a Lua array. Each element in the array contains the name of the instruction and the arguments of it. This is useful for the "CPU" (think binary code), but it is very annoying to use for a human. Therefore, a special script-kind of language was developed, `anpc-script`, which can be used by humans to code and it is translated to the Lua-array format by menas of a interpreter.

`anpc` comes built-in with instructions and programs that supports:
* Environment interactions (e.g. place node, dig node, use node)
* Movement (e.g. walk to a certain position, rotate)

**NOTE**: More documentation on the programming model coming soon.

Each NPC also has a memory space, which can be local to its program or global, shared among programs.

To make a Minetest entity use `anpc`, simply set the following functions in your entity registration:
* `on_step`: `npc.do_step`
* `on_activate`: `npc.on_activate`
* `get_staticdata`: `npc.get_staticdata`

And that's it! You can then execute a program by doing:
```lua
npc.proc.execute_program(entity:get_luaentity(), "vegetarian:init")
```

Replacing `vegetarian:init` with whatever name your program actually has.


## Why `anpc`?
`anpc` is different from many other "mobs mods" in Minetest. The #1 difference is that in `anpc` each NPC is essentially an independent, programmable computer. Each NPC has a CPU that supports timers and interrupts, and have its own memory. Other differences are:
* `anpc` is strictly an API mod - no NPCs are defined
* `anpc` is not opinionated about what features and entity should have
	* `anpc` does include pre-built programs that are considered basic, e.g. follow something, attack. However these are *not* defined in your entity - you use them if you need them
* `anpc` is very lightweight: you add features to the entities as you need

And you may be asking again, why? Why build NPCs like a CPU? The idea of a programmable NPC API came first with the previous mod, `advanced_npc`, and my attempt to create smart NPCs that could roam around villages, use chests, furnaces, beds, and trade with players. At that time I understood that a minimal, generic-enough mobs mod for Minetest would essentially support the infrastructure to perform certain actions, without forcing them on the entities. That's why everything is programmable, from how your NPC walks to how it attacks if(!) it does.


## How to use `anpc`
If you are user and don't want to create any NPC and just play Minetest, you should use a mod that uses `anpc` to implement its mobs. Currently there are no mods that do that, but I will be developing one soon.


## OK, I actually want to create a NPC. What should I do?
Go to `anpc`'s helper mod, `anpc-dev`, in order to get started to create NPCs. `anpc-dev` contains development tools and documentation to help you get started and create NPCs with `anpc`.
