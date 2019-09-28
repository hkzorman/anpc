# Roadmap

This is a basic, non-strict roadmap that serves as a guide to the development
of this mod.

## Short term
### Version 1.0.0-alpha
For version 1.0.0-alpha to be ready for release, the following functionality
should be supported by the mod.

[ ] Nodes
    [ ] Place nodes with same effects as a player
    [ ] Dig nodes with same effects as a player
    [x] Operate nodes (e.g. open a door, put items on chest)
    [x] Own nodes and respect player-owned and other NPC-owned nodes
[x] Walk to a specified position with pathfinding
[ ] Follow a player or other entity
[ ] Run-away from a player or other entity
[ ] Movement patterns
	[ ] Pivot Points (PP): The idea is to calculate certain points around which the NPC will walk, and will keep a certain distance (radius) around them. These wandering mode is good for villages or forests, where obstacles are present. The NPC will always consider moves in a 180 degrees range.
    [ ] Mostly-Straight Line (MSL): The idea is to calculate a path which is mostly straight however it will bend normally 45 to -45 degrees and will bend up to 90 degrees ocassionaly, while trying to keep going in a certain direction. This wandering is ideal for long distance walking with a goal, when the desired position can't be immediately achieved.
[ ] Attack a player or another entity


## Long term
[ ] Movement patterns
	[ ] Float/Flight
