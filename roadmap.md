# Production Signals: The Real Roadmap

## Current State Assessment
We have: working Signal/Effect/Memo, basic dependency tracking via observer stack, type inference.  
We lack: glitch-free updates, dependency cleanup, batching, equality checks, proper teardown.

## The Critical Path (in order, each task ~2-4 hours)

### Week 1: Fix the Foundations

**Day 1: Dynamic Dependency Cleanup**
```zig
// Add to Effect struct:
sources: std.BoundedArray(*anyopaque, 8)  // inline storage for dependencies

// Modify Effect.run():
// 1. Clear sources array
// 2. Run user function (which calls Signal.get)
// 3. Signal.get adds itself to sources
// 4. Before next run, unsubscribe from old sources
```

**Understanding Phase:**
- [ ] Analyze current Effect/Signal bidirectional relationship bug
- [ ] Write failing test: conditional dependency (if/else changes what signals are read)
- [ ] Write failing test: signal subscriber count verification 
- [ ] Write failing test: memory leak detection with DebugAllocator
- [ ] Document the mental model: newsletter subscription cleanup analogy

**Implementation Phase:**
- [ ] Add `sources: std.BoundedArray(*anyopaque, 8)` field to Effect struct
- [ ] Implement bidirectional unsubscribe in Signal: remove effect from subscribers
- [ ] Implement cleanup in Effect: clear sources array before re-run  
- [ ] Modify Effect.run() lifecycle: clear → execute → populate sources
- [ ] Handle Signal.get() adding itself to current effect's sources array

**Verification Phase:**
- [ ] Ensure conditional dependency test passes (old signals stop triggering)
- [ ] Ensure subscriber count test passes (lists shrink when deps change)
- [ ] Ensure memory leak test passes with DebugAllocator
- [ ] Run full existing test suite to verify no regressions
- [ ] Test edge cases: nested effects, mid-run dependency changes

**Day 2: Fix the Iterator Corruption Bug**
```zig
// Current bug: Signal.set modifies subscribers while iterating
// Solution: snapshot or defer
```
- [ ] Change Signal.set to clone subscriber list before iterating
- [ ] Alternative: accumulate effects to run, then run after iteration
- [ ] Test: effect that adds new effect during run
- [ ] Test: effect that removes itself during run

**Day 3: Add Equality Checking**
```zig
// Add to Signal:
eql: ?*const fn (a: T, b: T) bool
```
- [ ] Add equality field to Signal
- [ ] Modify Signal.set to check equality before propagating
- [ ] Default: use std.meta.eql for simple types
- [ ] Test: repeated sets with same value don't trigger effects

**Day 4: Implement Basic Queue (No Glitches)**
```zig
// Add to Scope:
dirty_queue: std.ArrayList(*Effect)
is_flushing: bool
```
- [ ] Change Signal.set to enqueue effects instead of running immediately
- [ ] Add flush() that processes queue once
- [ ] Auto-flush at end of outermost set() if not already flushing
- [ ] Test: diamond dependency (A→B,C→D) - D runs once, not twice

**Day 5: Add batch() Primitive**
```zig
pub fn batch(scope: *Scope, comptime f: fn() void) void {
    const was_batching = scope.is_batching;
    scope.is_batching = true;
    defer if (!was_batching) scope.flush();
    f();
}
```
- [ ] Implement batch that defers flush
- [ ] Handle nested batches correctly
- [ ] Test: 10 sets in batch = 1 effect run
- [ ] Test: nested batches work correctly

### Week 2: Memory Safety & Core Control

**Day 6: String Ownership Policy**
```zig
// Make it explicit:
ownership: enum { owned, borrowed }
```
- [ ] Add ownership field to Signal options
- [ ] Implement copy-on-set for owned strings
- [ ] Implement free-on-overwrite for owned strings
- [ ] Test with DebugAllocator: no leaks in string signal lifecycle

**Day 7: createRoot for Bulk Ownership**
```zig
pub const Root = struct {
    allocator: Allocator,
    signals: ArrayList(*anyopaque),
    effects: ArrayList(*Effect),
    
    pub fn deinit(self: *Root) void {
        // Cleanup everything in reverse order
    }
};
```
- [ ] Implement createRoot that tracks all created nodes
- [ ] Root.deinit cancels queued work, runs cleanups, frees everything
- [ ] Test: create 100 signals/effects in root, deinit = zero leaks
- [ ] Keep existing direct creation as "advanced" API

**Day 8: untrack() Primitive**
```zig
pub fn untrack(scope: *Scope, comptime f: fn() T) T {
    const saved = scope.observer_stack.items.len;
    defer scope.observer_stack.shrinkRetainingCapacity(saved);
    return f();
}
```
- [ ] Implement untrack that temporarily clears observer
- [ ] Test: reading signal in untrack doesn't create subscription
- [ ] Use case test: logging that doesn't create deps

**Day 9: onCleanup() Hook**
```zig
// Add to Effect:
cleanups: std.BoundedArray(fn() void, 4)
```
- [ ] Add cleanup storage to Effect
- [ ] Expose onCleanup() function during effect run
- [ ] Run cleanups before re-run and on dispose
- [ ] Test: cleanup for timer, cleanup for nested resource

**Day 10: Error Handling**
```zig
// Add to Scope:
error_handler: ?*const fn(err: anyerror) void
```
- [ ] Wrap effect.run in catch that routes to handler
- [ ] Default: log and continue (don't corrupt graph)
- [ ] Test: throwing effect doesn't break other effects
- [ ] Test: error handler receives all errors

### Week 3: Correctness & Testing

**Day 11: The Big Three Tests**
- [ ] **Diamond Test**: A→{B,C}→D, verify D runs once per update
- [ ] **Cycle Test**: Effect sets signal it reads, verify no infinite loop
- [ ] **Cleanup Test**: Effect with conditional deps, verify cleanup fires

**Day 12: Memory Audit**
- [ ] Run entire test suite under DebugAllocator
- [ ] Fix any leaks found
- [ ] Add leak detection to CI
- [ ] Document memory ownership rules

**Day 13: Benchmark Baseline**
```zig
// Simple benchmarks to prevent regression:
// - Create 1000 signals
// - Linear chain of 100 effects  
// - Fan-out 1→100
// - 1000 updates with/without batching
```
- [ ] Implement basic benchmark harness
- [ ] Record baseline numbers
- [ ] Add to CI with regression detection

**Day 14: Documentation & Examples**
- [ ] Write one-page "How Updates Work" 
- [ ] Write one-page "Memory & Ownership"
- [ ] Counter example
- [ ] Computed fullname example
- [ ] Resource cleanup example

**Day 15: Polish & Ship v0.1**
- [ ] Review all TODO comments
- [ ] Ensure all tests pass
- [ ] Tag v0.1.0
- [ ] Write announcement post with examples

---

## What We're NOT Doing (Yet)

These are explicitly **out of scope** for MVP:
- ❌ createStore (deep reactivity) - too complex, wait for v0.2
- ❌ createResource (async) - needs more design thought  
- ❌ Thread safety - single-threaded is fine for now
- ❌ Memory pools - ArenaAllocator is good enough
- ❌ Comptime optimizations - correctness first
- ❌ Debug visualizations - nice to have, not essential
- ❌ Time-travel debugging - way later

---

## Success Criteria

You have production-ready v0.1 when:
1. ✅ Diamond dependencies work without glitches
2. ✅ Effects clean up their old dependencies  
3. ✅ No memory leaks under DebugAllocator
4. ✅ batch() actually batches updates
5. ✅ Clear ownership model for strings
6. ✅ Errors don't corrupt the graph
7. ✅ You can build a non-trivial app without fighting the library

---