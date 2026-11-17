# P2 — Behavior: events, priorities, utility, shared world, routines

Status: **not started** · Effort: ~8–12 days total (packages are independently shippable)
Order: P0 → P1 → **P2**. Within P2: P2.1 → P2.2 → P2.3 → P2.4 → P2.5 (each package can
land and be tested on its own; P2.3–P2.5 benefit from P2.2 but P2.1/P2.4 are usable
without it).
Dependencies: P2.2 assumes P1's `npc.proc.run_pass` (its pass loop and IP conventions);
P2.4's node-interest index benefits from P0's budget for lazy region scans. P2.1, P2.3,
P2.5 are technically startable earlier, but implement in the order listed.

## Goal

Make NPCs *smart* in the sense that matters at 100–300 NPCs: **reactive, interruptible,
and coordinated** — and give the framework the shared services that make that cheap:

1. **Events, not polling-only**: NPCs react to being punched, players approaching,
   node changes, and (future) LLM results — *while walking*, not after their current
   program ends. (The "scheduled interrupts" TODO at `api.lua` L4142.)
2. **Interruptible, prioritized tasks**: one running action at a time; higher-priority
   actions preempt; lower actions resume from exactly where they paused. Replaces the
   fragile modulo-100 queue + single state process.
3. **Utility layer**: a cheap (~1 Hz) scoring mechanism so "hunger > social > idle"
   blending is data, not imperative if-chains.
4. **Shared world services**: a node-interest index (beds/furnaces/chests/torches) and a
   1 Hz object snapshot — so 300 NPCs stop each doing their own 350k-node scans and
   radius queries.
5. **Daily routines**: finish the half-built schedule system (day/night programs).

## Non-goals (explicit)

- **No LLM code.** P2.1's event queue *is* the designed LLM seam (a future
  `llm:plan_ready` event lands here with zero scheduler changes), but no bridge,
  prompts, or model work in this plan.
- No central AI conductor / SoA batching (the P3 from the original analysis — out of
  scope at 100–300 NPCs; per-entity `on_step` keeps free dormancy).
- No behavior trees as a data structure — the utility layer + priority stack cover the
  needed expressiveness; a BT layer can be added later *on top of* tasks if ever wanted.

## Context recap (line refs at commit `f600b81`)

- While a low-latency task is active, the program pass is fully gated off
  (`npc.do_step` L4310) → an NPC mid-walk cannot react to anything except through the LL
  handler itself.
- Scheduling model today: one `current` process, a FIFO circular queue (modulo 100,
  `queue_head`/`queue_tail`), and one `state` process that restarts from
  `initial_instruction` on completion (L4240–L4246). `execute_program` is a head-insert
  (L3878–L3912); `set_state_process` optionally clears the queue (L4068–L4096). Process
  ids roll at 100 (L3909). `schedule_add`/`schedule_remove` exist (L462–L483) but are
  never driven from `do_step` (TODO at L4142).
- Perception is per-NPC polling: `get_objects_inside_radius(pos, 12)` every 1 s (L4137–
  L4423); `npc:env:node:find` does `minetest.find_nodes_in_area` up to radius 35
  (~350k node reads) on demand (L1531–L1591).
- Every NPC's entity registration duplicates the callback wiring
  (`on_step = npc.do_step` etc., e.g. `torcherer.lua` L120–L140) — P2 adds two more
  shared callbacks (`on_punch`, `on_deactivate`); the sample registrations get updated.

## New file

`behavior.lua`, dofile'd from `init.lua` after `api.lua` (contains P2.1, P2.3, P2.4,
P2.5; P2.2's scheduler lives in `api.lua` next to the existing process machinery).

---

## P2.1 — Event bus  (S–M)

Purely additive: no scheduler change yet.

### Data

```lua
-- per NPC (added in npc.on_activate's new-NPC branch):
self.data.events = {}   -- array of {name, args, priority, reactive, t}
-- capped at 32 entries; overflow drops the oldest lowest-priority entry
```

### API (in `behavior.lua`)

```lua
npc.event.register(name, handler)   -- handler(self, args, ev); global, all NPCs
npc.event.push(self, name, args, opts)
-- opts = {priority=50, reactive=false}
-- reactive=true events dispatch every tick (must be cheap: push a task, set a flag);
-- others dispatch at proc-pass cadence.
```

### Dispatch (in `npc.do_step`, new small section after the LL-task block, before the
proc gate)

```lua
local evs = self.data.events
if #evs > 0 then
  -- every tick: drain reactive events only (a single # check when empty ≈ free)
  -- proc pass: dispatch remaining events, highest priority first, then clear
end
```

Cost when idle: one `#` length check per tick.

### Built-in sources (v1)

| Event | Source | Reactive? | Priority |
|---|---|---|---|
| `punched` | new shared callback `npc.on_punch(self, puncher, tool, dir)` — mods add it to their entity registration (like `on_step`); pushes `{puncher, tool}` | yes | 100 |
| `player_near` / `player_far` | proc-pass proximity check with hysteresis (enter at radius R default 8, exit at 1.5R; flag in `self.data`); uses P2.4's snapshot when available, else the existing `env.objects` | no | 50 |
| `chat` | global `minetest.register_on_chat_receive` → push to NPCs whose region contains the speaker (P2.4) or within 16 m (fallback) | no | 50 |
| `node_changed` | from P2.4's interest-index updates, when the changed pos is within an NPC's view range | no | 30 |
| `llm:plan_ready` / `llm:chat_ready` | **documented seam only** — no code yet; the LLM layer will `npc.event.push` these | — | — |

### State-swap helper (bridge to existing scheduler)

Until P2.2, event handlers that want to change what the NPC is doing use the existing
`set_state_process` — provide the missing save/restore (today it's ad-hoc,
`data.follow_prev_state` in the follow test item, L4696–L4714):

```lua
npc.util.save_state(self)      -- stash {name, args} of process.state into self.data._state_prev
npc.util.restore_state(self)   -- re-apply the stashed state process
```

**Test**: mock harness — push a reactive `punched` event while a mock walk LL task is
active; assert the handler runs in the same tick (not after 0.5 s). Push 40 low-priority
events; assert cap + drop-oldest behavior.

---

## P2.2 — Priority task stack (scheduler v2)  (L — the core package)

Replaces the queue + state-process machinery with a small, serializable, preemptible
stack. This is what makes P2.1's events actually *change behavior mid-walk*.

### Data (replaces `self.process.queue`/`state`/`current`/`key`)

```lua
self.process.tasks = {}    -- array, sorted by priority desc; [1] = running
self.process.task_key = 0  -- monotonic id counter (no modulo — fixes the L3909 wrap)
-- task = {
--   id = int, name = program_name, args = table,
--   priority = int,          -- npc.task.priorities.*
--   persistent = bool,       -- true = restart on completion (the old "state process")
--   proc_int = seconds,      -- pass cadence for this task (default 0.5)
--   ll_task = name | nil,    -- LL task this task currently owns (for cancel)
-- }
-- program IP per task: self.data.proc[task.id].ip
```

```lua
npc.task.priorities = { react = 100, combat = 80, social = 50, task = 30, routine = 10, idle = 1 }
```

### API (drop-in mapping from today)

| Today | P2.2 |
|---|---|
| `npc.proc.set_state_process(self, name, args, clear_queue)` | sets the **routine** task (`priority = npc.task.priorities.routine`, `persistent = true`); `clear_queue` drops non-routine tasks. Signature unchanged → sample mods keep working. |
| `npc.proc.execute_program(self, name, args)` | pushes a one-shot task, `priority = npc.task.priorities.task`. New optional 3rd arg: `opts = {priority=…, persistent=…, proc_int=…}`. |
| `npc.proc.enqueue_program` | same push, appended at equal priority (no preemption). |
| (new) preempt | pushing a task with priority **strictly greater** than the running task's: suspend the running task first. |

### Suspension / resume

```lua
npc.proc.suspend(self, task)
-- 1. self.data.proc[task.id].ip = self.process.current.instruction
-- 2. if self.process.low_latency_task.active: task.ll_task = <name>; cancel it:
--    call ll_task_table[name].on_cancel(self, args) if present; clear active
-- 3. tasks[1] = <new task>; current = <new task's record>
```

- **Resume** = restore `ip` from `data.proc[task.id].ip` and let the pass re-execute the
  instruction at that IP. For a suspended walker, that re-issues the walk instruction →
  `npc.nav.start` re-arms with the same target (the existing `same_target` fast path in
  `npc.nav.start` makes this cheap; the nav session in `self.data.nav` survived
  suspension). No LL-task state needs persisting — re-arming is the resume.
- **`npc.proc.cancel_ll_task(self)`**: new public helper used by suspend and by
  `npc.nav.stop` callers.
- LL task registration gains an optional 4th function:
  `npc.proc.register_low_latency_task(name, handler, timeout_handler, on_cancel)`.
  The `npc:move:walk_to` task gets `on_cancel = function(self) npc.nav.stop(self) end`.

### Task completion

- One-shot task's IP passes the end → remove from stack; next task resumes (restore ip).
- Persistent task's IP passes the end → reset ip to the program's
  `initial_instruction` (today's state-restart semantics, L4240–L4246).
- The proc gate in `npc.do_step` uses the **running task's** `proc_int` (a task can set
  its own cadence — walkers 0.1 s, idle 0.5 s, matching today's per-instruction
  `proc_int` tweaks which now become task-level).

### Serialization & migration

- `get_staticdata` serializes `self.process` (now `tasks` + `task_key`) — plain tables,
  works as-is. `self.data.proc` already carries the per-task `ip`.
- `npc.on_activate` migration: if deserialized `process.tasks == nil` and the old fields
  (`queue`/`state`/`current`) exist → migrate: `state` → persistent routine task; each
  queued entry → one-shot task at priority `task`; `current` (if mid-run and not the
  state) → running task with its IP. Log once per migrated entity.

### Dev/debug compatibility

- `anpc-dev` reads the process structure — coordinate there (separate repo); keep task
  records carrying `name`/`args` so a minimal read works, and note in `anpc-dev`'s
  tracker that the queue display becomes a task-stack display.
- Keep `self.process.current` as a **live pointer to the running task's record** (the
  pass loop, LL handlers, and nav code all use `self.process.current.name/.args` — this
  keeps P1's `run_pass` and all `npc.nav` code untouched by P2.2; the task *record* plays
  the role `current` plays today: `{id, name, args, instruction}`).

**Tests** (mock harness):
1. Walker task running (nav session armed) → push `react` task → assert: walker's ip
   saved, LL task cancelled (`nav.active == false`, velocity zero), react task running.
   React completes → walker resumes at saved ip, walk re-armed, local vars intact
   (set a local before suspension, read after).
2. Equal-priority push → no preemption (queues behind).
3. Staticdata round-trip: serialize mid-walk with a queued task → new mock `self` from
   `on_activate` → assert task stack + ip + locals survive.
4. Old-save migration: hand-build a pre-P2.2 `process` blob → `on_activate` → assert
   mapped tasks.

---

## P2.3 — Utility layer  (S)

The cheap "smartness" layer: score candidate behaviors at ~1 Hz, run the best.

```lua
-- per NPC (code-registered; not DSL):
npc.util.add_utility(self, {
  name       = "feed",              -- task/program name to run when this wins
  args       = {},                  -- its args
  score      = function(self)       -- called ~1 Hz; must be µs-scale
    return self.data.global.hunger or 0
  end,
  min        = 60,                   -- only run if score >= min
  hysteresis = 15,                   -- keep current winner unless new score exceeds
                                     -- current score + hysteresis (anti-flap)
})
```

- Per-NPC utility timer: 1.0 s interval with a randomized phase (reuse
  `npc.util.stagger_offset` from P0.5) so 300 NPCs don't all score on the same tick.
- On tick: evaluate all score fns (a handful → microseconds), pick the argmax with
  `score >= min`. Winner ≠ current routine task **and** `winner_score > current_score +
  hysteresis` → `set_state_process(winner, args)` (P2.2: replace the routine task).
  No winner → leave the routine task running.
- **Demo**: refactor `vegetarian:idle`'s imperative if-chain (feed at hunger ≥ 60, sleep
  at night, wander otherwise, `vegetarian.lua` L103–L133) into three utilities — same
  behavior, less code. Keep the imperative version available as `vegetarian:old_idle`
  for A/B comparison.

**Test**: mock — set hunger 70 → next utility tick switches routine to feed; drop hunger
below min but keep another utility high with margin < hysteresis → no switch (flap
check).

---

## P2.4 — Shared world services  (M)

### 4a. Entity registry

```lua
npc.registry = {}      -- name -> luaentity
npc.on_activate  -> register (self.npc_id / entity name as key)
npc.on_deactivate -> unregister   -- NEW shared callback; sample entity registrations updated
```

- Sweep: every 60 s, drop entries whose `le.object:get_pos() == nil` (liveness idiom
  already used in the codebase, e.g. `api.lua` L1829–L1836) — covers entities that
  die/removed without a clean deactivate.

### 4b. Node-interest index

Interest set = union of groups from `npc.env.register_node` calls (the existing
`node_table`/`node_group_name_map`, L957–L978 — note: the group-map fill at L971–L978 is
*after* the `return` and is dead code today; move it inside the `else`).

```lua
npc.world = {
  regions = {},  -- region_key -> { category -> { [node_hash] = {name, pos} } }
  interest = {}, -- category -> nodenames (derived from node_table)
}
-- region = 32x32x32 block chunk; key = string "x/y/z" of floored chunk coords
npc.world.ensure_region(pos)          -- lazy: one find_nodes_in_area over that region,
                                      -- only for interest nodenames; budgeted to
                                      -- <= 2 scans/second globally (P0.3-style counter),
                                      -- excess deferred to next 1 s cycle
npc.world.node_changed(pos, new_name) -- direct update (add/remove from category buckets)
```

**Update layers** (all three, in order of trust):

1. **anpc's own writes**: `npc:env:node:place` / `node:dig` / `node:set` /
   `node:operate` (api.lua L1754–L1938) call `npc.world.node_changed` after the
   mutation (operate can toggle a door's state — for interest nodes, just re-read the
   node at pos).
2. **Node callback wrapping** (post-`minetest.register_on_mods_loaded`): walk
   `minetest.registered_nodes`; for every node whose name is in the interest set, wrap
   its `on_construct`/`on_destruct` in place (guarded, idempotent via a per-node flag)
   so player builds/digs also update the index.
3. **Periodic reconcile**: every 60 s, for each *active* region (contains ≥ 1 registered
   entity, or holds ≥ 1 interest entry), re-run `ensure_region` and diff — heals any
   changes that bypassed both layers (node-protector mods, mapgen, direct `set_node`).

**Consumer**: `npc:env:node:find` (L1531) — when the query's `categories` are interest
categories, answer from the index (touch only regions inside the query volume; apply the
existing owner/user filters and `single_match` semantics; return the same shape —
array of positions). Non-interest queries keep the legacy `find_nodes_in_area` path.
Result: `torcherer:find_bed` (radius 35) becomes a few region lookups instead of a
350k-node scan.

**Also**: `node_changed` for a pos within an NPC's view range pushes the P2.1
`node_changed` event (rate-limited: one event per NPC per pos per 5 s).

### 4c. Object snapshot (1 Hz)

```lua
-- one self-rescheduling loop: minetest.after(1, fn) started at server start
-- (or first on_activate); fn:
--   for each registry entry + minetest.get_players(): bucket by region
-- npc.world.objects = { region_key -> { {pos, is_player, name, ref}, … } }
```

- NPC env refresh (`do_step` L4137–L4140) reads its region's bucket + radius filter
  instead of calling `get_objects_inside_radius` itself; keep the old call as fallback
  when the snapshot isn't running (single-player edge cases, first second).
- Gives: O(1) access for `@objs.*`, the `player_near` event, the `chat` event radius
  check, and (future) LLM prompt context assembly.

**Tests**: place/dig a bed via the node:place instruction → index updated (query
`node:find` without scanning). Player digs a registered interest node → index updated
within one reconcile (or immediately via wrapped callback). Snapshot: 2 registered NPCs
in different regions → each sees only its region's objects. Region scan budget: 50
simultaneous fresh-region queries → ≤ 2 scans this second (counter assertion).

---

## P2.5 — Daily scheduler  (S)

Finish the TODO (L4142): drive `self.data.schedule` entries (already registered via
`schedule_add`/`schedule_remove`, L462–L483 — register the missing
`npc:schedule:add` / `npc:schedule:remove` instruction wrappers).

- Entry fields (existing): `program_name, earliest_start_time, latest_start_time,
  repeat_interval, end_time, dependent_entry_id`. Game time =
  `minetest.get_timeofday() * 24000` (the `@time` expression, L211).
- Bookkeeping per entry (added on fire, serialized with the entry): `last_run`
  (game-time), `ran_today` (flag; reset when game day rolls over — detect day change via
  floor(time/24000) on a per-day basis with wraparound care).
- Fire conditions (checked at a 1 s gate in the proc-pass cadence — not every pass):
  1. `now` inside `[earliest, latest]` — windows that cross midnight supported;
  2. `now - last_run >= repeat_interval` (or never run today);
  3. `now <= end_time` (if set, same cross-midnight semantics);
  4. if `dependent_entry_id`: that entry's `ran_today` is true.
- On fire: `npc.proc.execute_program(self, entry.program_name, {}, {priority =
  npc.task.priorities.routine})` and update bookkeeping.
- **Stagger**: `schedule_add` stores `offset = math.random() * (args.spread or 60)`
  (game-time seconds) added to `earliest_start_time` — mass "wake at 6:00" events spread
  naturally.
- **Demo**: torcherer gets a schedule entry (wake 8000, work window 8000–16000, sleep
  22000–6000, `repeat_interval` = one day) replacing the inline `@time` checks in
  `torcherer:idle` (L14–L45) — the imperative time-checks stay as a fallback until the
  demo validates.

**Test**: mock clock — set `@time` equivalents directly on the entry boundary cases
(window edges, midnight-crossing, dependency, repeat interval); assert fire/no-fire
matrix.

---

## Files touched

- New: `behavior.lua` (P2.1, P2.3, P2.4, P2.5).
- `api.lua` — P2.2 (process restructure in the "Process API" + `do_step` +
  `on_activate`/`get_staticdata`), P2.1 dispatch hook in `do_step`, LL task `on_cancel`
  support, `node_table` group-map fix, node-instruction index updates.
- `init.lua` — dofile `behavior.lua`.
- `torcherer.lua`, `vegetarian.lua` — add `on_punch`/`on_deactivate` callbacks; demo
  updates (P2.3 utilities, P2.5 schedule) — behavior-preserving, A/B-able.

## Cross-cutting invariants (check in review)

- **Dormancy still free**: everything above lives in entity callbacks + the 1 Hz/60 s
  global loops (which are O(active NPCs) and cheap); far NPCs still cost ~0.
- **Serialization**: every new per-NPC structure (`events`, `tasks`, `utility` state,
  `schedule` bookkeeping) is plain-table serializable — no function/ObjectRef stored
  per NPC (score fns are registered globally by name, referenced by string).
- **No tick hooks assumed**: P2.4's loops use self-rescheduling `minetest.after`; if the
  build has `minetest.set_interval`, it may be used instead — but the code must not
  *require* it.
- **Backpressure**: event queue capped (32); region scans budgeted (2/s); utility scoring
  staggered; schedule fires staggered. Nothing new is unbounded.

## Testing strategy

- Unit-level: the mock harness from P1.1 extended with a virtual clock (set
  `self.data.env.time` / stub `minetest.get_timeofday`) — every package ships its tests
  above before it's merged.
- Live scenario (the acceptance test for "smartness"):
  1. Spawn 20 vegetarians; walk up to one while it walks somewhere → it stops walking,
     turns (ack), and resumes the interrupted walk within 1 s (event + preemption +
     resume, end to end).
  2. Punch one mid-walk → `punched` event same tick; (v1 behavior: a registered handler
     that pushes a short react task) interrupts and resumes.
  3. Hunger crosses threshold mid-walk → utility switches the routine task *after* the
     walk (no mid-walk routine swap — utilities only replace the routine task; document
     this rule: **only ≥ combat-priority events preempt an active walk**).
  4. 100 idle NPCs: `node:find` for beds (all same village) → total scan cost ≈ village
     regions, not 100 × 350k reads.
  5. Nightfall: 30 villagers with sleep schedules → first walk starts spread over the
     stagger window; TPS flat (P0 budget + P2.5 stagger compose).

## Definition of done

- [ ] P2.1: reactive event dispatches same-tick while an LL task is active; queue cap holds.
- [ ] P2.2: preemption/resume tests pass; staticdata round-trip + old-save migration pass;
      sample mods unchanged behavior.
- [ ] P2.3: vegetarian demo parity (A/B behavior comparison) without the if-chain.
- [ ] P2.4: interest queries answer from the index; all three update layers verified;
      object snapshot in use by env refresh.
- [ ] P2.5: fire matrix passes; torcherer schedule demo runs unattended through a full
      game day (or accelerated time test).
- [ ] 100-NPC live scenario: TPS stable, no new per-tick allocations in the idle path
      (profile once; the per-tick cost should be the P2.1 `#events` check + P0's work).

## Risks & open questions

- **P2.2 is the risky one** (it restructures the core). Mitigations: the
  `self.process.current` live-pointer keeps every consumer (`run_pass`, `npc.nav`, LL
  handlers) untouched; migration keeps old saves working; and P2.1/P2.3–P2.5 ship
  *before* you'd want to break anything — if P2.2 stalls, P2.1+P2.4 already deliver most
  of the smartness with zero scheduler risk.
- **Node callback wrapping** (P2.4 layer 2) mutates other mods' node definitions in
  place — standard technique in the ecosystem but audit for mods that store callback
  references at register time (unlikely; verify against your modpack's mods).
- Open: should `punched` (react=100) auto-trigger combat *programs* in v1, or just be an
  event for mods to handle? Recommend v1 = event only (no built-in combat), matching the
  "library is not opinionated" stance.
- Open: `npc.task.priorities` defaults — tune during the live scenario; they're one
  table.
