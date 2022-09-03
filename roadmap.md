# Roadmap

This is a basic, non-strict roadmap that serves as a guide to the development
of this mod.

## Short term
### Version 1.0.0-alpha
For version 1.0.0-alpha to be ready for release, the following functionality
should be supported by the mod.

[x] Nodes
    [x] Place nodes
    [x] Dig nodes
    [x] Ability to operate nodes (e.g. open a door, put items on chest)
    [x] Own nodes and respect player-owned and other NPC-owned nodes
[ ] Movement
	[x] Walk to a specified position with pathfinding
	[ ] Follow a player or other entity
	[ ] Run-away from a player or other entity
	[ ] Attack a player or another entity
[x] Programming API
	[x] Implement interpreter for anpc-acript
		[x] Support variables and executing instructions
		[x] Support control instructions
[ ] Translate all built-in programs to anpc-script

### Version 1.0.0
[ ] Movement
	[ ] Support precision jumping
[ ] Programming API
	[ ] Support 'using' expression in interepter
## Long term
[ ] Nodes
	[ ] Place nodes like players and respect protection
	[ ] Dig nodes like players and respect protection
[ ] Movement patterns
	[ ] Float/Flight
	[ ] Pivot Points (PP): The idea is to calculate certain points around which the NPC will walk, and will keep a certain distance (radius) around them. These wandering mode is good for villages or forests, where obstacles are present. The NPC will always consider moves in a 180 degrees range.
    [ ] Mostly-Straight Line (MSL): The idea is to calculate a path which is mostly straight however it will bend normally 45 to -45 degrees and will bend up to 90 degrees ocassionaly, while trying to keep going in a certain direction. This wandering is ideal for long distance walking with a goal, when the desired position can't be immediately achieved.
[ ] Programming API
