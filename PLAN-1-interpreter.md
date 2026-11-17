# P1 — Interpreter: compile at registration, iterative pass

Status: **not started** · Effort: ~3–5 focused days
Order: P0 → **P1** → P2. P1 is independent of P0 (different files: `api.lua` only) but
should come after P0 so the P0 live checklist gives a clean baseline.
Dependencies: none. P0 recommended first (not required).

## Goal

Make per-NPC instruction execution ~5–20× cheaper by doing the work **once at
registration** instead of **every execution**:

1. The DSL currently **parses `@…` argument strings with `string.split`/`string.find` on
   every single execution** (`_npc.dsl.evaluate_argument`, `api.lua` L108–L257) — the
   dominant per-pass cost.
2. Expression trees `{left, op, right}` are re-walked recursively on every execution
   (L54–L87).
3. The "fast instruction" fast path is **recursive** (`execute_instruction` calling itself,
   L3958–L3994) — one C-stack frame per instruction; fine today, a latent bomb for a
   library API that third-party mods will write longer programs with.
4. Every execution re-looks-up the instruction function in `instruction_table` (L3951)
   and re-evaluates *all* args even when they are constants.

After P1, one pass over a 40-instruction program costs a few microseconds with **zero
string operations**, and programs get validated at load (typos in instruction names or
expressions become load-time errors instead of runtime surprises).

## Non-goals (explicit)

- No new programming language features (no new expression forms; the parser must handle
  *exactly* what `evaluate_argument` handles today, nothing more).
- No scheduler changes (P2), no pathfinding (P0).
- `anpcscript` codegen (lives in the `anpc-dev` mod) is untouched — generated programs
  keep working unchanged; that is the regression gate.
- The public API (`npc.proc.register_program`, `register_instruction`, `npc.eval`) keeps
  the same signatures.

## Context recap (line refs at commit `f600b81`)

- Hot path: `npc.do_step` (L4103) → proc gate → `execute_instruction` (L3930) →
  `evaluate_argument` per arg (L3938–L3943) → `instruction_table[name](self, args)` (L3951)
  → fast-instruction recursion (L3958–L3994) → back in `do_step` the IP increments once
  (L4341–L4343) unless `program_changed`.
- Instruction shapes: `{name, args, key}` in `program_table[name].instructions`;
  control instructions `npc:jump`/`jump_if`/`break` mutate `current.instruction` directly;
  `npc:execute` pre-increments the IP and swaps `current` (L1111–L1122, L3947–L3949);
  `npc:call`/`npc:return` mutate the IP via `_call_stack` (L1076–L1109).
- `register_program` (L867) flattens via `process_instruction` (L491) — the only live
  branches are `npc:for_each`, `declare`, `call`, `npc:timer:register`; the big commented
  blocks (if/while/for preprocessing, L495–L799) are dead.
- Latent bugs found during analysis (fixed in P1, see P1.5):
  - `npc:execute` passes the *global* `raw_args` (nil) to `evaluate_argument` (L1116) →
    `@args.*` inside nested execute args silently mis-resolves.
  - `assert("Program with name … already exists")` (L869) and the two `assert("…")` at
    L928/L938 are **no-ops** (assert on a truthy string never fails) → duplicate
    registrations are silently ignored instead of erroring.
  - `npc:call`/`npc:return` off-by-one: `call` sets IP to the function entry, then
    `do_step` increments → first body instruction skipped; `return` sets IP to the stored
    function entry instead of the caller's resume point. The feature is unused by shipped
    programs, so it's latent — fix it test-driven (P1.5).
  - Process id `self.process.key = (key + 1) % 100` (L3909 etc.) wraps → local-variable
    tables (`self.data.proc[id]`) collide after ~100 enqueues.

## Work packages

### P1.1 — Benchmark harness first (build before optimizing)  (M)

New file `bench.lua`, dofile'd from `init.lua` only when `anpc-dev` is present (reuse the
existing `is_dev_mode` detection in `api.lua`).

- **Mock entity harness**: `npc.bench.make_self()` builds a minimal `self` table:
  stub `object` (`get_pos`, `get_yaw`, `get_velocity`, `set_velocity`, `set_yaw`,
  `get_luaentity` → nil, …), plus real `timers`, `process`, `data` shapes copied from
  `npc.on_activate`'s new-NPC branch. The mock needs no live server and no entity.
- **Pass runner**: `npc.bench.run_pass(self)` calls the *same* internal function that
  `npc.do_step` uses (after P1.4 that is `npc.proc.run_pass`; before, the current inline
  code path — factor the pass out of `do_step` into this function as step 0 of P1.4).
- **Measurements** (using `os.clock()`, N=10 000 passes, log results with
  `minetest.log`):
  - **B1**: one full pass of `torcherer:idle` (the realistic ~45-instruction program).
  - **B2**: a synthetic 20-instruction straight-line program (var:set / jump_if /
    distance_to mix) — isolates interpreter overhead.
  - **B3**: a program that executes `npc:env:node:get` + `npc:distance_to` 10 times
    (the "heavy instruction" boundary).
  - **B4**: string-op counter: in dev mode, wrap `string.split`/`string.find` with
    counters; record calls-per-pass (baseline: dozens; target: **zero**).
- Record baseline numbers in the first commit message (or `bench-notes.md`) before any
  optimization lands. Each later package re-runs B1–B4 and must show non-regression.

### P1.2 — Refactor the DSL: parser out, runtime in  (M)

Split `_npc.dsl.evaluate_argument` (L108–L257) and `_npc.dsl.set_var` (L267–L355) into
**pure parsing** (no `self`, no `minetest`, no string ops at runtime) + **runtime
dispatch**:

- `npc.dsl.parse_ref(str) -> ref_table` — parses one `@…` string once. `ref_table`
  captures everything the current code extracts: `storage` (`local|global|args|temp|env|
  objs|time|self`), `key`, optional bracket `subkey` (literal string **or** nested ref),
  optional third segment (`length`), and the dotted/dynamic-key forms. Must handle exactly
  the existing forms (mirror L108–L223 case by case):
  - `@local.k`, `@global.k`, `@args.k`, `@temp.k`, `@env.k`
  - `@local.k[lit]`, `@local.k[@local.i]` (variable table element, L99–L100)
  - `@local.@local.var` (variable-as-key, L97; current code joins segments 2..3 — keep
    the same limitation, document it)
  - `@local.tbl.length` (L101)
  - `@objs.all`, `@objs.get[n]`, `@objs.get[@local.i]` (L103–L105; includes the
    tracking-record `_id` extraction, L183–L187)
  - `@time`, `@self.pos`, `@self.pos_rounded`, `@self.dir`, `@self.yaw` (L110–L222)
- `npc.dsl.read(self, ref, pargs, locals) -> value` — table-dispatched runtime lookup
  (one `if/elseif` on `ref.storage`, or a small dispatch table). No string operations.
  `@objs.get[…]` keeps the existing linear-scan + temp-storage behavior verbatim.
- `npc.dsl.write(self, ref, value, userdata_type)` — runtime half of `set_var`
  (L267–L355): storage resolution, bracket-subkey handling, the userdata
  tracking-record path (L321–L342) unchanged.
- `npc.dsl.compile_value(v) -> v|resolver`:
  - plain number/boolean/nil/constant-table/string (non-`@`) → returned unchanged;
  - `@…` string → closure `function(self, pargs, locals) return npc.dsl.read(self, REF, pargs, locals) end`
    with the parsed `REF` upvalue (and a `_npcr = true` marker field on the closure);
  - `{left, op, right}` table → recursive compile: `function(self, pargs, locals)
    return OP[ref.op](L(self,pargs,locals), R(self,pargs,locals)) end`, where `OP` is a
    table binding the operator strings to bound functions (move the op list from
    `evaluate_boolean_expression`, L54–L87, into `OP`);
  - plain functions → returned unchanged (legacy dynamic value-functions, called with
    `(self, args, local_vars)` — preserved exactly).
- **Compatibility shim**: keep `_npc.dsl.evaluate_argument` as a thin legacy entry (parse-if-
  string + dispatch) for direct callers (`npc.eval`, L262, and any anpc-dev usage), and
  keep it delegating to the same `read`/`OP` implementations so there is one source of
  truth.
- **Unit tests** (dev-gated file, run at load under `anpc-dev`): a table of
  `{expression, fixture_self, expected}` covering every form in the list above, including
  the edge cases (`.length` on nil, `@objs.get` miss, dynamic key, nested expression
  inside bracket). These run before P1.3 lands (against the legacy evaluator) so they
  pin current behavior, then keep passing after the rewrite.

### P1.3 — Compile programs at registration  (M)

Extend `npc.proc.register_program` (L867): after the existing `process_instruction`
flattening, run a compile pass over every instruction:

```lua
-- per instruction record (original fields kept for debugging):
{
  name     = "...",              -- kept (anpc-dev displays, logs)
  args     = <original args>,    -- kept for debug display only
  cargs    = <table> | nil,      -- all-constant args, frozen (see below)
  resolve  = fn(self, pargs, locals) -> args | nil,   -- when any arg/key is dynamic
  fn       = instruction_table[name],   -- bound now
  key_ref  = compiled key | literal key | nil,
  fast     = FAST_SET[name] == true,    -- the existing fast list (L3959–L3967)
  self_ip  = SELFIP_SET[name] == true,  -- names that set current.instruction themselves
}
```

- `FAST_SET` = today's fast list: `npc:jump`, `npc:jump_if`, `npc:break`, `npc:var:get`,
  `npc:var:set`, `npc:timer:instr:start`, `npc:timer:instr:stop`, `npc:get_proc_interval`,
  and any name matching `^npc:env:`.
- `SELFIP_SET` = `npc:jump`, `npc:jump_if`, `npc:break`, `npc:call`, `npc:return`,
  `npc:execute` (everything that writes `self.process.current.instruction` itself).
- `cargs`: when every arg value and the key compile to non-functions, store the
  constant args table as-is (`resolve = nil`). **Convention (document in the header
  comment of the api.lua instructions section): instruction handlers must not mutate
  their args table** — they receive shared constant tables. (Today a fresh
  `processed_args` table is built per execution, which made accidental mutation safe;
  audit the shipped instructions for arg mutation — none found at analysis time, but
  add a dev-mode sanity check: verify constant arg tables are unchanged after a pass.)
- Registration-time validation: `assert(instruction_table[name])` becomes a real
  `error("Unknown instruction …")` — typos in mod programs now fail at load.
- `npc.proc.register_instruction` unchanged (already stores functions).
- `program_table[name].instructions` keeps the same field name and now carries the
  compiled records; `anpc-dev` reads `.name`/`.args` — both still present.

### P1.4 — Iterative pass loop  (M)

Replace the recursion in `execute_instruction` (L3930–L3995) and the inline execution in
`npc.do_step` (L4306–L4344) with one function, **owned by the pass loop, not the
instructions**:

```lua
-- Run one deliberative pass over the current process. Returns when a non-fast
-- instruction executed, the program changed, or the program finished.
npc.proc.run_pass = function(self)
  local current = self.process.current
  local prog = program_table[current.name]
  local instructions = prog.instructions
  local n = #instructions
  local locals = self.data.proc[current.id]
  local pargs = current.args
  local ip = current.instruction
  while ip >= 1 and ip <= n do
    local inst = instructions[ip]
    -- dev-mode breakpoint handling (preserve current behavior, L3976–L3989 / L4322–L4331)
    local args = inst.resolve and inst.resolve(self, pargs, locals) or inst.cargs
    local r = inst.fn(self, args)
    if inst.key_ref then npc.dsl.write(self, inst.key_ref, r, args) end
    if inst.self_ip then
      ip = current.instruction           -- instruction moved the IP itself
      if self.process.current ~= current then break end   -- npc:execute swapped process
    else
      ip = ip + 1
    end
    if not inst.fast then break end
  end
  current.instruction = ip
end
```

Semantics preserved (verify each against current code):

- A run of consecutive fast instructions executes within one pass, exactly as the
  recursion does today; the first non-fast instruction executes and **ends the pass**
  after itself (its own IP increment already applied, or `ip+1` applied by the loop).
- `npc:jump`/`jump_if`/`break`: set `current.instruction` directly; the loop picks the
  new IP up on the next iteration (a jump target that is itself fast continues the
  chain — same as today's recursion).
- `npc:execute`: pre-increments IP, swaps `current`, sets `program_changed`; loop breaks
  on `self.process.current ~= current`. The `program_changed` flag remains as the
  belt-and-braces guard for the dequeuing logic in `do_step`.
- `npc:call`/`npc:return`: `self_ip`, pass ends (same as today — they are not in the fast
  list).
- Dev-mode `pause`/`override` breakpoints: keep the exact checks (in-loop, before
  executing the instruction), and the `npc_dev.show_debug_formspec` call.
- `npc.do_step` then just calls `npc.proc.run_pass(self)` under the existing guards
  (`current.instruction > -1` and no active LL task). Delete `execute_instruction`
  (or keep a one-line deprecated wrapper calling `run_pass` for one release).

### P1.5 — Bug fixes & dead-code cleanup  (S)

- **`npc:execute` `raw_args` global** (L1116): the compiled resolver receives `pargs`
  properly, so nested `@args.*` inside execute args now resolve — covered by a unit
  test (`npc:execute` with nested `@args` reference). If any code path still calls the
  legacy `evaluate_argument` with the nil third arg, fix it.
- **No-op asserts** → real errors: L869 `assert("Program …")` → `error(...)`; same for
  L928 (`register_instruction`) and L938 (`register_low_latency_task`).
- **`npc:call`/`npc:return` off-by-one** — test-driven fix:
  1. Write a bench/dev test: a program declaring a function that sets
     `@local.r = 7` twice with a `npc:call` between; assert final value 14 and that
     execution resumes at the instruction *after* the call.
  2. Fix: `npc:call` pushes `{key = args.key, index = self.process.current.instruction + 1}`
     (the *resume point*) and sets IP to the function entry (`args.index`); `npc:return`
     sets IP to `stack_entry.index` (resume point). With `self_ip` semantics there is no
     double increment. Adjust `process_instruction`'s call-arg emission if the stored
     index meaning changes.
- **Process id wrap**: `self.process.key` becomes a plain monotonic integer (no `% 100`)
  in every place it increments (L3909, L3927, L4055, L4095). `self.data.proc` keys stay
  unique forever; prune on dequeue as today (L4256).
- **Dead code removal**:
  - `npc:env:prioritize` (L1986–L2017): broken WIP (compares a number to `"min"`, empty
    branches) — remove the registration and the function; if the intent is wanted later
    it belongs in P2's perception work.
  - The commented-out preprocessing blocks in `process_instruction` (L495–L799, ~300
    lines) — remove; git history preserves them.
  - `npc.get_staticdata`'s `low_latency_task` reset (L4446–L4452) stays — still correct.
- Keep: `npc.eval` (public), `builtin:idle` (works unchanged — regression), all test
  items at the bottom of `api.lua`.

## Files touched

- `api.lua` — P1.2 (dsl section), P1.3 (register_program), P1.4 (run_pass, do_step),
  P1.5 (fixes + cleanup).
- New: `bench.lua` (dev-gated), `devtests.lua` or similar (dev-gated unit tests).
- `anpc-dev` mod (separate repo): still reads `program_table[…].instructions[…].name/.args`
  — no change needed; if it ever calls `execute_instruction`, it must move to
  `npc.proc.run_pass` (flag in that repo's notes).

## Compatibility

- **Saved games / staticdata**: unchanged — P1 touches only `program_table`
  (never serialized) and in-memory execution; `process`/`data` shapes are identical.
- **Sample programs** (`torcherer.lua`, `vegetarian.lua`, `builtin.lua`): unchanged; they
  are the regression gate (the full live checklist from P0 must re-run and pass).
- **Public API**: unchanged signatures; `npc.proc.execute_program`, `set_state_process`,
  `enqueue_program` work as before (they set `process.current` / queue entries, which the
  new pass loop consumes exactly as before).

## Verification targets (from P1.1 harness)

| Metric | Baseline (measure first) | Target |
|---|---|---|
| B1: `torcherer:idle` pass | µs | ≤ 1/5 of baseline |
| B2: synthetic 20-instr pass | µs | ≤ 1/5 of baseline |
| B4: `string.split`/`string.find` calls per pass | dozens | **0** |
| Load-time validation | — | unknown instruction name errors at load |
| Unit tests (all expression forms) | — | all pass, before and after |

Plus: the P0 live checklist re-run (behavior identity), and the dev-mode constant-args
mutation check.

## Definition of done

- [ ] B1–B4 targets met, recorded in the commit message alongside baseline.
- [ ] All DSL unit tests pass; the legacy `evaluate_argument` shim delegates (one code path).
- [ ] `npc:call`/`npc:return` test passes; duplicate-registration errors fire.
- [ ] Sample mods + P0 live checklist: identical behavior.
- [ ] `anpc-dev` debugger still renders programs (name/args preserved).
- [ ] No string parsing remains on the execution path (verifiable via B4 counter = 0).

## Risks & open questions

- **P1.2 parser is the correctness risk**: it must reproduce *every* quirk of the current
  parser (including the limited 2-segment dynamic-key form and the number-key coercion at
  L133). The unit-test table pinned *before* the rewrite is the safety net — do not skip
  it.
- **Constant-args sharing**: if any future instruction handler mutates `args`, it will
  corrupt other NPC instances sharing the same program. Mitigations: the dev-mode
  mutation check (P1.3) + the documented convention. If the convention proves too risky,
  fallback is per-execution copy for programs whose `args` contain tables (tables only —
  scalars are cheaply shared).
- Open: keep `process_instruction`'s `npc:for_each` desugaring as-is (it emits
  `npc:var:set`/`npc:jump_if` instructions that get compiled normally) — yes, no change
  needed. Confirm during P1.3 that timer-registered function bodies (L829–L858) compile
  through the same pass (they do: same `process_instruction` path).
