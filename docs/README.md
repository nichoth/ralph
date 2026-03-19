# Notes

> Do not under any circumstances put the words "Proof of Concept" in the design
> docs of something you're gonna build with AI

> You want the key words "production grade"

## Iterations

Use a Ralph loop for multiple iterations.

## Models

### Codex CLI

* `gpt-5.3-codex` for Ralph loops in general 
* `gpt-5.1-codex-max` (option 7) for complex tasks
  (e.g., migrating an entire library to a new framework version)

#### "reasoning level"

For **Ralph loops**, the choice of reasoning level is a trade-off
between **iteration speed** and **convergence reliability**. Because Ralph
loops rely on "persistence over perfection," your choice depends on whether
you want the model to think more *within* one turn or rely on the
*loop harness* (tests/linters) to correct it.

Here is the strategic breakdown for setting the reasoning level in your CLI:

### 1. **`High` (The "Goldilocks" Baseline)**

For most Ralph loops—especially those involving feature implementation or
refactoring—**High** is the recommended setting.

* **Why:** In autonomous loops, the biggest "token burner" is the model
  hallucinating a completion tag (like `<promise>COMPLETE</promise>`)
  before the task is actually done. **High** reasoning ensures the model
  properly validates its own work against your `PLAN.md` and tests before
  trying to exit.
* **Use Case:** Building out complex decentralized logic, PDS synchronization,
  or multi-file architectural changes.

### 2. **Extra High (The "Stalemate" Breaker)**

Reserve **Extra High** for specific, high-stakes iterations rather than the
entire loop.

* **Why:** This level uses a massive internal "thought" budget.
  It is significantly slower and more expensive. However, if your loop
  has hit a **stalemate** (e.g., it has attempted to fix the same failing test
  3 times without success), bumping it to **Extra High** for a single run can
  often "think" its way out of the logic trap.
* **Use Case:** Deep debugging of cryptographic edge cases or complex state
  management in Durable Objects.

### 3. **Medium (The "Mechanical Grind")**

Use the default **Medium** only for low-complexity, high-volume tasks.
* **Why:** If the task is purely mechanical and has 100% test coverage,
  you want the loop to move as fast as possible. Medium is faster but "lazier,"
  which is fine if the feedback from your compiler or linter is clear enough
  to guide the model back on track in the next iteration.
* **Use Case:** Adding JSDoc comments, bulk CSS updates, or straightforward
  boilerplate generation.

---

### Comparison for Autonomous Workflows

| Reasoning Level | Ralph Loop Strategy | Impact on the Loop |
| :--- | :--- | :--- |
| **Medium** | **The Speed Run.** Best for simple CRUD or linting. | High risk of "looping forever" on subtle logic bugs. |
| **High** | **The Standard.** Best for daily feature work. | Highest reliability; usually converges in 2–4 iterations. |
| **Extra High** | **The Specialist.** Best for architectural hurdles. | Very slow; use only when the agent is "stuck." |

### Implementation Tip

If you are using the `codex` CLI in a bash script for your loop, you can
override the reasoning level dynamically. If you notice a stalemate in your logs,
you can trigger a "High Reasoning" pass:

```bash
# Example override for a thorny task
codex --config model_reasoning_effort='"high"'
```

**Would you like me to help you draft a specific `PLAN.md` or a loop script**
**that auto-escalates reasoning levels if it detects a stalemate?**
