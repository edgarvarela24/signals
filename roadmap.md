# Project North Star: The Roadmap

## Philosophy

Alright. We've talked, we've designed. The architecture is solid. Now it's time to build. This roadmap is about ruthless prioritization and momentum. We will build the simplest thing that works, validate it, and iterate. We build a specific application first, and the framework emerges from its needs. No premature optimization, no building for imaginary use cases. Let's get to work.

## Guiding Principles

1.  **PoC First, Framework Second**: We are not building a framework. We are building a *single, simple application* (a counter) that *forces* us to create the framework's core.
2.  **API is King**: The Developer Experience (DX) matters more than anything. If an API feels clunky or confusing, it's wrong. We fix it.
3.  **YAGNI (You Ain't Gonna Need It)**: Start with a `list` for hit detection. Don't build a Quadtree. Don't build a complex `Cmd` system for websockets. Solve the problem in front of you, not the one you imagine for tomorrow.
4.  **Embrace Zig**: We use Zig's strengths. Manual memory management is a feature. The `comptime` is our friend. Explicitness is our guide.

---

## Phase 0: The Foundation ("Hello, Terminal")

**Goal:** Prove we can control the terminal. This is the bedrock.

**Tasks:**
1.  **Project Setup**: Initialize a new Zig project with a build file.
2.  **Dependency**: Fetch and link `termbox2`.
3.  **Main Loop**: Write `main.zig`. It must:
    * Initialize `termbox2`.
    * Enter a loop that polls for events.
    * If the event is the key 'q', break the loop.
    * Properly de-initialize `termbox2` before exiting.

**Definition of Done:** You can run `zig build run` and see a blank terminal screen. Pressing 'q' exits the program cleanly.

## Phase 1: The Reactive Core ("It's Alive!")

**Goal:** Build a working, end-to-end prototype of the "Reactive TEA" data flow. This is the most critical phase.

**Tasks:**
1.  **Build the Signal Primitives**:
    * In a new file, `src/signal.zig`, create a minimal signal implementation.
    * You need `create_signal(value: T) -> Signal(T)` with `.get()` and `.set()` methods.
    * You need `create_effect(fn)`. `create_memo` can wait. Focus on the dependency tracking between `set` and `effect`.
2.  **Implement the TEA Loop**:
    * Define a `Model` struct with one field: `counter: Signal(u32)`.
    * Define a `Msg` tagged union with one variant: `increment`.
    * Define the `update(model, msg)` function that increments the counter signal when it receives the `.increment` msg.
3.  **Implement the View->Render Bridge**:
    * Define a placeholder `Node` union with just a `Text` variant.
    * Write a top-level `view(model)` function that returns a `Node.Text` with the counter's current value.
    * Write a dead-simple renderer that just knows how to print text to a fixed location on screen.
    * In `main`, wrap the `view -> render` call inside a `create_effect` to link everything.
4.  **Wire Input**: In the main loop from Phase 0, if the event is the key '+', dispatch the `increment` `Msg` to your `update` function.

**Definition of Done:** A number appears on the screen. When you press '+', the number increments. You have successfully validated the entire reactive data flow.

## Phase 2: The Layout & Render Engine ("Building Blocks")

**Goal:** Abstract the rendering and enable composition of components.

**Tasks:**
1.  **Flesh out Core Structs**:
    * Define the real `Style` struct.
    * Expand the `Node` union to include `FlexBox` and `Text`. The `FlexBox` node will contain a slice of child `Node`s.
2.  **Build the Layout Engine**:
    * Write a function that takes a `Node` tree and a bounding `Rect` (initially, the whole screen).
    * It should recursively traverse the tree, calculating and assigning a final `Rect` to every single `Node` based on FlexBox rules.
3.  **Build the Real Renderer**:
    * Implement the `Virtual Buffer` (a 2D grid of `Cell { char, style }`).
    * Change the layout engine's output to draw to the `Virtual Buffer` instead of the screen directly.
    * Implement the `diff` and `flush` logic that compares the current buffer to the previous one and generates `termbox2` calls.
4.  **Refactor the PoC**: Rebuild the counter app from Phase 1 using a `FlexBox` to layout two `Text` components (a title and the counter value).

**Definition of Done:** A styled "Counter App" title and the reactive counter number are on screen, positioned correctly by `FlexBox`. The rendering is now flicker-free.

## Phase 3 & Beyond: The Framework Emerges

With the foundation from Phases 0-2, you can now add features as needed. The path becomes about expansion.

* **Build More Core Components**: `Input` (this will require managing focus state in the `Model`), `List`, `ProgressBar`.
* **Implement Mouse Support**: Build the hit detection system (list of rects) and dispatch `Msg`s for mouse events.
* **Build the `Cmd` System**: Implement the runner for handling asynchronous operations. A great first `Cmd` would be one that waits for 1 second and then sends an `increment` `Msg`.
* **Documentation & Examples**: Start documenting the API and building more complex example apps to stress-test the framework.
