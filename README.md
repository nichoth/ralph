# Ralph

So how do you use this Ralph thing?

See

* [The Ralph Playbook](https://github.com/ghuntley/how-to-ralph-wiggum).
* [The Ralph Playbook 2](https://claytonfarr.github.io/ralph-playbook/)
* [everything is a ralph loop](https://ghuntley.com/loop/)
* [repomirror/repomirror.md](https://github.com/repomirrorhq/repomirror/blob/main/repomirror.md)
* [The Ralph Video](https://youtu.be/4Nna09dG_c0)
* ["starts with a conversation"](https://youtu.be/4Nna09dG_c0)
* ["It's a dance, folks. This is how you build your specifications."](https://youtu.be/4Nna09dG_c0)

<details><summary><h2>Contents</h2></summary>

<!-- toc -->

  * [Need to do these things:](#need-to-do-these-things)
    + [3. Start Ralph in a loop of 5 iterations](#3-start-ralph-in-a-loop-of-5-iterations)
  * [The Ralph Script](#the-ralph-script)
    + [Make executable](#make-executable)
    + [do one thing per loop](#do-one-thing-per-loop)
    + [Claude](#claude)
    + [`PROMPT.md`](#promptmd)
  * [How To](#how-to)
    + [Phase 1. Define Requirements (LLM conversation)](#phase-1-define-requirements-llm-conversation)
    + [Phase 2 / 3 -- Run Ralph Loop (two modes, swap `PROMPT.md` as needed)](#phase-2--3----run-ralph-loop-two-modes-swap-promptmd-as-needed)
- [Build Mode](#build-mode)
  * [Memory](#memory)
    + [PRD (Product Requirements Document [`JSON`])](#prd-product-requirements-document-json)
    + [Loop](#loop)
  * [See Also](#see-also)

<!-- tocstop -->

</details>

## Need to do these things:

1. Define requirements -- see [`./specs/prd.json`](./specs/prd.json).
2. Create a `PROMPT.md` file &mdash; can copy + paste [PROMPT.md](./PROMPT.md).
   The `PROMPT.md` file defines a stopping condition that will be printed on
   success. The stop text is watched for the the [./ralph.sh script](./ralph.sh).

### 3. Start Ralph in a loop of 5 iterations

```sh
./ralph.sh 5
```

---

## The Ralph Script

See [./ralph.sh](./ralph.sh).

Context loaded each iteration: `PROMPT.md` + `AGENTS.md`.

The prompts you start with won't be the prompts you end with -- they evolve
through observed failure patterns. Observe and adjust reactively. When Ralph
fails a specific way, add a sign to help him next time.

### Make executable

```sh
chmod +x ralph.sh
```

### do one thing per loop

It's about keeping the context window small.


### Claude

```sh
claude --dangerously-skip-permissions
```

### `PROMPT.md`

The file that it reads every time before starting.

#### Example of a Prompt

```md
# Ralph Agent Instructions

## Your Task

1. Read `scripts/ralph/prd.json`
2. Read `scripts/ralph/progress.log`
   (check Codebase Patterns first)
3. Check you're on the correct branch
4. Pick highest priority story 
   where `passes: false`
5. Implement that ONE story
6. Run typecheck and tests
7. Update AGENTS.md files with learnings
8. Commit: `feat: [ID] - [Title]`
9. Update prd.json: `passes: true`
10. Append learnings to progress.log

## Progress Format

APPEND to progress.log:

## [Date] - [Story ID]
- What was implemented
- Files changed
- **Learnings:**
  - Patterns discovered
  - Gotchas encountered
---

## Codebase Patterns

Add reusable patterns to the TOP of progress.log:

## Codebase Patterns
- Migrations: Use IF NOT EXISTS
- React: useRef<Timeout | null>(null)

## Stop Condition

If ALL stories pass, reply:
<promise>COMPLETE</promise>

Otherwise end normally.
```


## How To

Ralph isn't just "a loop that codes." It's a funnel with 3 Phases, 2 Prompts,
and 1 Loop.

### Phase 1. Define Requirements (LLM conversation)

1. Discuss project ideas, identify JTBD (jobs to be done)
2. Break individual JTBD info topics of concern
3. Use subagents to load info from URLs into context
4. subagent writes specs/FILENAME.md for each topic

### Phase 2 / 3 -- Run Ralph Loop (two modes, swap `PROMPT.md` as needed)

Same loop mechanism, different prompts.

#### Plan Mode

If no plan exists, or plan is stale/wrong. Generate/update
`IMPLEMENTATION_PLAN.md` only.


# Build Mode

'BUILDING' prompt assumes plan exists, picks tasks from it, implements,
runs tests (backpressure), commits.




## Memory

Treat files and git as memory. Do not put memories in the model context.
State persists in `.ralph/`.

### PRD (Product Requirements Document [`JSON`])

Defines stories, gates, and status

### Loop

Execute one story per iteration




----------

<!-- the image from https://github.com/iannuttall/ralph -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 520" role="img" aria-label="Ralph architecture diagram" data-ab-filters-channel="b372d42b-d586-4fd6-948d-95c09eecace3">
  <style>
    .bg { fill: #0f1218; }
    .box { fill: #141a23; stroke: #e6e6e6; stroke-width: 1.5; }
    .line { stroke: #e6e6e6; stroke-width: 1.5; }
    .text { fill: #f3f3f3; font-family: Menlo, Consolas, Monaco, monospace; font-size: 16px; }
    .small { font-size: 13px; opacity: 0.9; }
    .muted { opacity: 0.7; }
  </style>

  <rect class="bg" x="0" y="0" width="1000" height="520" rx="0"/>

  <!-- Top boxes -->
  <rect class="box" x="390" y="30" width="220" height="44" rx="0"/>
  <text class="text" x="500" y="58" text-anchor="middle">ralph CLI</text>

  <rect class="box" x="240" y="114" width="520" height="48" rx="0"/>
  <text class="text small muted" x="500" y="144" text-anchor="middle">agent CLI: codex | claude | droid</text>

  <!-- Arrow from top to agent (gap matches lower arrows) -->
  <line class="line" x1="500" y1="74" x2="500" y2="96"/>
  <polygon points="496,96 500,104 504,96" fill="#e6e6e6"/>

  <!-- Branch lines (gap for heads) -->
  <line class="line" x1="500" y1="162" x2="500" y2="200"/>
  <line class="line" x1="500" y1="200" x2="280" y2="200"/>
  <line class="line" x1="500" y1="200" x2="720" y2="200"/>
  <line class="line" x1="280" y1="200" x2="280" y2="214"/>
  <line class="line" x1="720" y1="200" x2="720" y2="214"/>
  <polygon points="276,214 280,222 284,214" fill="#e6e6e6"/>
  <polygon points="716,214 720,222 724,214" fill="#e6e6e6"/>

  <!-- Bottom boxes -->
  <rect class="box" x="90" y="226" width="380" height="230" rx="0"/>
  <text class="text" x="110" y="256">.agents/ralph/</text>
  <text class="text small muted" x="110" y="278">local overrides (optional)</text>
  <text class="text small" x="110" y="306">loop.sh</text>
  <text class="text small" x="110" y="328">PROMPT_build.md</text>
  <text class="text small" x="110" y="350">references/</text>
  <text class="text small" x="110" y="372">log-activity.sh</text>
  <text class="text small" x="110" y="394">config.sh (optional)</text>

  <rect class="box" x="530" y="226" width="380" height="230" rx="0"/>
  <text class="text" x="550" y="256">.ralph/</text>
  <text class="text small muted" x="550" y="278">state + logs</text>
  <text class="text small" x="550" y="306">errors.log</text>
  <text class="text small" x="550" y="328">progress.md</text>
  <text class="text small" x="550" y="350">guardrails.md</text>
  <text class="text small" x="550" y="372">activity.log</text>
  <text class="text small" x="550" y="394">runs/</text>

  <text class="text small muted" x="500" y="500" text-anchor="middle">
    Local templates override bundled defaults. State persists between runs.
  </text>
</svg>


---


## See Also

* [zeroshot](https://github.com/covibes/zeroshot)
* [reddit](https://www.reddit.com/r/ClaudeAI/comments/1pxc31u/a_quick_guide_to_ralph_wiggum/)
  "A quick guide to Ralph Wiggum"
* [awesomeclaude.ai/ralph-wiggum](https://awesomeclaude.ai/ralph-wiggum)
* [github.com/anthropics/claude-code/ralph-wiggum](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum)
  -- the official Ralph plugin
* [Ship Features in Your Sleep with Ralph Loops](https://www.geocod.io/code-and-coordinates/2026-01-27-ralph-loops/)
* [Verification-Driven Development (VDD)](https://gist.github.com/dollspace-gay/45c95ebfb5a3a3bae84d8bebd662cc25)
