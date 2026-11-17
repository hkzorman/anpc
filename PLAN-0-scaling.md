# P0 — Scaling: pathfinding, budgeting, walk lifecycle

Status: **not started** · Effort: ~3–5 focused days
Order: implement **P0 → P1 → P2** (see `PLAN-1-interpreter.md`, `PLAN-2-behavior.md`)
Dependencies: none. P0 touches only `pathfinder.lua` and the `npc.nav` / movement sections of `api.lua`.

## Goal

Remove the three scaling cliffs that break a single-threaded server at 100–300 NPCs on
low-budget hardware:

1. **A\* is quadratically slow** (linear open-set scan, ~60 node reads per expansion) and can
   take 20–60 ms in a *single tick*.
2. **The walker re-plans a full A\* every ~1–3 s of walking** (per-cell re-plan + per-tick
   tail consumption), and blocked NPCs re-plan a *capped* search every second.
3. **Nothing bounds aggregate work per tick** — 20 NPCs starting walks in the same tick
   (e.g. nightfall) produce a 0.5–3 s hitch in one 100 ms frame.

Also fixed in P0 (all walk/path-adjacent): the 30 s walk timeout that abandons long walks,
unowned velocity after walk end, tick-count (not time-based) constants, and two latent
crashes.

## Non-goals (explicit)

- No hierarchical pathfinding (HPA\*), no flow fields — re-evaluate after P0 measurements.
- No scheduler / behavior changes (that is P2).
- No changes to the DSL/interpreter (that is P1).
- No new dependencies, no C modules, no global on-tick hook (the budget below is
  deliberately hook-free).

## Context recap (line refs are at commit `f600b81`; match on function names — they drift)

- `pathfinder.find_path` (`pathfinder.lua` L219–L410): A\* with `pairs()` linear min-scan
  (L240–L252, O(V²)), 2000-expansion cap (L392), ~60 `minetest.get_node` reads per expansion
  (L284–L344), dead `check_clearance` (L181–L191), `minetest.log` on every failed search
  (L85).
- `npc.nav.step` (`api.lua` L3442–L3814): per-tick tail consumption `table.remove(nav.path)`
  (L3744, "legacy advancement"), full A\* re-plan on `reached_head` (L3646–L3706) → one
  complete A\* per ~1–3 s of walking, forever.
- `npc:move:walk_to_pos` / `_ll` / `walk_to_cell_ll` set `self.timers.hl_task_int = 30`
  (L3858, L4585, L4635): walks longer than ~150 m are abandoned mid-route with velocity
  left unowned (NPC slides forever).
- `nav.door_hold = 10` (L3533): tick-count based (1 s at 10 TPS, 0.16 s at 60 TPS).
- `_npc.env.node_is_walkable` (L1470–L1481): references undefined `next_node_below` →
  nil-index crash when evaluated on stair/slab nodes.
- `npc.nav._find_path` (L2568–L2579): toggles the entity's `stepheight` property before/after
  each search — the pathfinder never reads `stepheight` (it uses `collisionbox`,
  `fear_height`, `jump_height`), so this is pure overhead plus a misleading comment.

## Configuration

New table at the top of `pathfinder.lua` (all values tunable without code changes):

```lua
npc.pathfinder.config = {
  max_expansions = 2000,            -- per-search hard cap (existing behavior)
  budget_window = 0.1,              -- seconds, sliding window for global budget
  max_searches_per_window = 3,      -- global: A* searches started per window
  max_expansions_per_window = 4000, -- global: expansions consumed per window
  replan_hysteresis = 0.5,          -- seconds between goal-moved re-plans (matches follow code)
  invalidate_lookahead = 3,         -- path cells watched for node change each tick
}
```

## Work packages

### P0.1 — A\* with binary heap + pooled scratch + node-name memo  (M)

Rewrite the search core of `pathfinder.find_path`:

- **Binary min-heap** over `(fCost, hCost, seq)`. `seq` = insertion order → deterministic
  tie-breaks (the current `pairs()` iteration makes path choice nondeterministic;
  deterministic paths also make tests meaningful).
- **Pooled scratch tables** at module level: `heap` (array), `gmap` (hash → best g),
  `closed` (hash set), `name_memo` (node name → walkable/openable result). Reuse across
  searches; clear per search (simple `for k in pairs` wipe is fine; generation-stamp
  optimization only if profiling says so). No per-search table allocation.
- **Per-search node-name memo**: `walkable(node)` and `is_good_node(node)` results cached by
  node *name* (both checks are name-based only, so this is safe; door open/closed state is
  not part of these results).
- Keep the neighbor generation, corner-cutting rules, ground-level climb, and clearance
  logic **semantically identical** — extract neighbor generation into a helper only if it
  keeps the exact same index/ordering behavior (the corner-cut code at L349–L369 depends on
  the 1..9 neighbor ordering from the `z`-outer/`x`-inner loop; do not reorder).
- Remove dead `check_clearance` (L181–L191).
- Failure logging: `npc.pathfinder.find_path` stops logging on every failure; it returns
  `(path, reason)` where reason ∈ `nil | "budget" | "unreachable"` (see P0.3). Callers log
  with throttling (per-NPC: at most one log per 5 s while repeatedly failing — store the
  timestamp in the nav session).
- `npc.nav._find_path`: delete the `stepheight` `set_properties` dance (L2568–L2579); pass
  nothing new (the search already uses `jump_height`/`fear_height` from the entity table).

**Verify**: on a fixed static map, old vs new pathfinder produce paths with equal cost
(allow different routes; assert cost identical and length within 15%). Run with a stubbed
`minetest.get_node` in the dev bench (see "Testing").

### P0.2 — Head-pointer path following; re-plan only on invalidation/failure  (M, the big win)

Replace the legacy advancement in `npc.nav.step` (L3734–L3744) and the `reached_head`
re-plan trigger (L3660) with:

- **Nav session fields** (in `npc.nav.start` / session init):
  - `nav.path_i` — 1-based head pointer into `nav.path` (the path array is never mutated
    after planning; no more `table.remove` churn → no GC pressure, O(1) advance).
  - `nav.wants_replan` — set by budget denial (P0.3); consumed by the re-plan branch.
  - `nav.replan_cd` — hysteresis countdown for goal-moved re-plans.
  - `nav.path_sig` — cached node names of the next `invalidate_lookahead` path cells.

- **Advancement** (each tick, before aiming): if `nav.path[nav.path_i]` exists and the NPC's
  rounded cell matches it (x/z equal, |dy| < 0.5) → `nav.path_i = nav.path_i + 1`. If
  `nav.path_i > #nav.path` → the path is consumed: goal reached ⇒ arrival rules apply
  (existing arrival checks already cover this); otherwise set `wants_replan`.
- **Aiming**: aim at `nav.path[nav.path_i]` (block-middle variant: cell middle, as today).
  Substitute every `nav.path[1]` reference (incline/stair check L3776–L3807, door-open check
  L3802–L3807) with `nav.path[nav.path_i]`.
- **Re-plan triggers** (all gated by the P0.3 budget):
  | Trigger | Note |
  |---|---|
  | `nav.path == nil` or path consumed (goal not reached) | as above |
  | `is_stuck` (existing 1 s / 0.25 m) | unchanged |
  | `trgt_moved` **and** `nav.replan_cd <= 0` | hysteresis = `replan_hysteresis`; reset `replan_cd` on a successful plan |
  | **path invalidated**: node name at any of the next `invalidate_lookahead` path cells differs from `nav.path_sig` (check each tick — 3 node reads) | new; recompute `path_sig` after every successful plan |
  | `nav.wants_replan` | from budget denial; clear on attempt |
  | ~~`reached_head`~~ | **removed** |
- **Steer mode** (`nav.steer`, block-middle same-cell): behavior unchanged — it bypasses
  path following; just ensure the re-plan branch doesn't fire while `nav.steer == true`
  (current code order already does this — keep the order).
- **Follow path**: `npc.nav.follow_track` / `follow_next_leg` keep their truncation +
  cooldown logic (it's already correct); they also route re-plans through the shared
  budget gate (P0.3 unifies `_follow_plan`'s cooldown with it).

**Expected behavior delta** (document in the commit message): walks no longer re-plan per
cell; a 30-cell walk does ~1 A\* (initial) + re-plans only on block/move/invalidation.
Aim target changes from "cell after head" to "head cell" — verify the step-up jump cases
still work (the incline check reads the aimed cell, which is now the cell being entered).

### P0.3 — Global time-window pathfinding budget  (S)

No global tick hook needed — a sliding time window keyed on `minetest.get_server_time()`:

```lua
-- pathfinder.lua
local pb = { t0 = 0, searches = 0, expansions = 0 }
function npc.pathfinder.budget_tick()          -- call before each search
  local now = minetest.get_server_time()
  if now - pb.t0 >= cfg.budget_window then
    pb.t0, pb.searches, pb.expansions = now, 0, 0
  end
end
function npc.pathfinder.budget_allow_search()  -- true + consume; false = denied this tick
  npc.pathfinder.budget_tick()
  if pb.searches >= cfg.max_searches_per_window then return false end
  pb.searches = pb.searches + 1
  return true
end
function npc.pathfinder.budget_consume_expansions(n)
  pb.expansions = pb.expansions + n
end
function npc.pathfinder.budget_exhausted()
  npc.pathfinder.budget_tick()
  return pb.expansions >= cfg.max_expansions_per_window
end
```

Integration:

- `npc.nav._find_path`: before searching, `if not budget_allow_search() then return nil, "budget" end`.
  Inside the search main loop (P0.1's heap loop), every 64 expansions call
  `budget_consume_expansions(64)` and if `budget_exhausted()` → abort the search, return
  `nil, "budget"` (protects the worst case *within* one search too).
- Denial semantics in `npc.nav.start` / `npc.nav.step`:
  - `nil, "budget"` ≠ `nil, "unreachable"`. Budget denial: **keep the walk active**, keep
    the existing path if one exists (continue following it), set `nav.wants_replan = true`,
    and **do not** treat as failure (no `force` `move_to`, no `last_status = "failed"`).
    The NPC simply retries the re-plan on the next tick (the re-plan conditions fire
    naturally). If there is no path at all (denied at first plan), the NPC stands in place
    (velocity zero) but stays active.
  - `nil, "unreachable"`: existing failure semantics.
- `npc.nav._follow_plan`: its existing 0.5 s failure cooldown stays; add the same
  `budget_allow_search()` gate (denied → return the existing `"skip"` result so the
  steer fallback keeps the NPC moving cheaply).

**Invariant to test**: no matter how many NPCs walk/get stuck, total A\* work per 100 ms
window never exceeds `max_searches_per_window` searches / `max_expansions_per_window`
expansions.

### P0.4 — Resumable walks + velocity ownership  (S)

- `npc.nav.start` records `nav.ll_owner = self.process.current.name` (the program that
  started the walk).
- The `npc:move:walk_to` LL task gets a **timeout handler** (4th behavior of
  `register_low_latency_task` — it already supports `timeout_handler`):
  ```lua
  -- on timeout (currently 30 s):
  if self.process.current.name == nav.ll_owner and nav.active then
      npc.nav.start(self, nav.walk_args, nav.walk_defaults)  -- re-arm; walk continues
      return false   -- keep the task alive
  end
  npc.nav.stop(self)  -- walk abandoned by program switch: stand down, velocity zero
  return true
  ```
  Store `nav.walk_args` / `nav.walk_defaults` at start time (speed, arrive_rule,
  target_distance, middle, door_close — the same values each entry point passes).
  Keep the 30 s interval; it now just re-arms.
- The `npc:move:jump` LL task gets a timeout handler: zero the velocity (a stuck jump ends
  cleanly instead of leaving the NPC with a stale launch velocity).
- Audit: every walk terminal path (arrived / failed / timeout-cancel / P2 future cancel)
  goes through `npc.nav._stand` (velocity zero + stand anim). Add a comment stating the
  velocity-ownership invariant: *an NPC never keeps horizontal velocity after its walk ends*.

### P0.5 — Time-based constants, desync, staggering helper  (S)

- `nav.door_hold = 10` → `nav.door_hold_time = 1.0` (seconds), decremented by `dtime`,
  gated on `> 0`. Audit the rest of `npc.nav` for tick-count assumptions (stuck detection
  and `follow_fail_cd` are already dtime-based — confirm, don't change).
- **Desynchronize NPC phases at activation** (`npc.on_activate`, new-NPC branch only):
  initialize `timers.proc_value`, `timers.objects_value`, `timers.node_below_value` to
  `math.random() * <their interval>` so 300 NPCs don't all refresh objects / run passes
  on the same tick forever.
- **Staggering helper** (framework mechanism; mods opt in):
  ```lua
  -- Returns a memoized per-NPC random offset in [0, spread] seconds for the named event.
  npc.util.stagger_offset(self, event_name, spread_s)
  ```
  Stored in `self.data.global["_stagger_" .. event_name]` (serializes fine). Demo usage:
  update the sample `torcherer:sleep` / `vegetarian:sleep` programs to offset the
  walk-to-bed by `stagger_offset(self, "sleep", 30)` seconds (e.g. via a small wait
  before the walk instruction) so mass sleep events spread over 30 s.

## Files touched

- `pathfinder.lua` — P0.1, P0.3 (search rewrite, config, budget, wrapper logging).
- `api.lua` — P0.2 (nav session fields, step re-plan/advance), P0.4 (LL timeout handlers,
  `npc.nav.start` bookkeeping), P0.5 (door_hold, on_activate phases, `npc.util.stagger_offset`,
  `node_is_walkable` fix).
- `torcherer.lua`, `vegetarian.lua` — demo stagger usage only (optional, last).
- New: none.

## Testing & verification

**Dev-gated benchmark** (new file `bench.lua`, dofile'd from `init.lua` only when the
`anpc-dev` mod is present — reuse the existing `is_dev_mode` check; see P1's P1.1 for the
mock-entity harness spec, build the minimum needed here: a stubbed `minetest.get_node`
over a synthetic 128×128×8 map, wrap-and-restore the global).

1. **A\* micro-bench**: ms for 10 m / 50 m / 200 m straight, plus an obstacle field, old vs
   new. Target: ≥ 3× faster at 50 m+.
2. **Path-equivalence regression**: identical static map, old vs new pathfinder — same
   cost, length within 15%.
3. **Spike simulation**: 50 synthetic walkers start a 30 m walk in the same "tick" — assert
   per-window expansion/search counters never exceed budget, and measure max single-tick
   wall time (should be bounded by ~1 search's cost, not 50 searches').
4. **Live in-game checklist** (before/after comparison):
   - Walk 50 cells on flat ground (count A\* runs in log — should be ~1, not ~20).
   - 1-block step-up; stair climb; slab climb.
   - Door: open on approach + close for all three `door_close` policies.
   - Blocked by a standing player: stuck → re-plan → path around; while blocked, A\* runs
     at most once per `replan_hysteresis`/stuck period (log-throttled).
   - `npc:follow` unchanged (re-track, leg chaining, slot ladder, steer fallback).
   - A 200+ m walk: no abandonment at 30 s (re-arm works), velocity zero at arrival.
   - 100 idle NPCs + 20 simultaneous walkers: watch TPS with `/tps`-style timing;
     confirm no multi-second hitches.

## Definition of done

- [ ] Budget invariant holds under the spike simulation (counter assertion).
- [ ] Live checklist passes with no behavior regressions vs pre-P0.
- [ ] Walks of any length complete; velocity-ownership invariant holds on every terminal.
- [ ] A\* ≥ 3× faster at distance; per-walk re-plan count drops from O(cells) to O(1+events).
- [ ] `node_is_walkable` fixed and covered by one bench unit case.
- [ ] All new tunables in `npc.pathfinder.config`; defaults logged once at load.

## Risks & open questions

- **Budget defaults are guesses until measured** on a real low-end box. The config table +
  one periodic (60 s) log line of window stats (searches used / denials) exists precisely
  so you can tune from the server log. Decide later whether to expose them as minetest
  settings (out of scope here).
- The pathfinder rewrite is the riskiest package (correctness-sensitive neighbor logic).
  Mitigation: keep the neighbor/corner-cut code structurally intact, validate with the
  path-equivalence regression before integrating the heap.
- Open: is `max_searches_per_window = 3` right at 10 TPS? One search per 33 ms feels
  balanced for 100–300 NPCs, but verify with the spike sim and real worlds; it's a number
  in one table.
