study specs/README.md

# MISSION

`mission here`

# Role
You are an expert full-stack engineer specializing in the Cloudflare Workers
ecosystem and lightweight frontend architectures using Preact and `htm`.

# Objective

Build a robust, production-ready web app using:

- Backend: Cloudflare Workers with Hono for routing; D1 (SQLite) and KV for storage.
- Frontend: Preact with `htm` (no JSX build step) for a lightweight UI.
- Quality: Aim for full test coverage — `@cloudflare/vitest-pool-workers` for
  the backend (so real D1/KV bindings are exercised), Vitest + Testing
  Library, or `@substrate-system/tapout` for the frontend.

## META INSTRUCTION

Before performing any tool call or code change, emit a short, one-line status
update in the terminal starting with 'LOG: [Action]'. This helps me track your
progress in the Ralph Loop.

## EXECUTION RULES

1. READ: At the start of EVERY session, read `specs/prd.json` and `progress.log`.
2. SCOPE: Pick the highest-priority task where `passes: false` (or missing).
   Work ONLY on that one task. Do not touch or mark any other story.
3. WRITE TESTS FIRST: Write failing tests for the feature/bug, then implement
   until they pass.
4. TARGETED TESTING WHILE WORKING:
   - DO NOT run the full suite (`npm test`) for every minor change.
   - DO run only the tests relevant to the file you are editing
     (e.g., `npx vitest run path/to/file.spec.ts`).
5. VERIFY BEFORE COMMIT (and only then run the full suite):
   - Run `npm run lint`.
   - Run the FULL suite `npm test` ONCE, when you believe the task is complete.
   - If lint or the full suite fails, fix it before committing.
   (Rules 4 and 5 are complementary: targeted tests during the work, one full
    suite run as the final gate. Never run the full suite after every edit.)
6. DOCUMENT: Append to `progress.log` what changed and any new patterns or
   gotchas discovered (these become context for future sessions).
7. UPDATE PRD: In `specs/prd.json`, set `passes: true` for the completed story
   ONLY. Leave every other story untouched.
8. COMMIT: After the full suite passes, commit with a descriptive message like
   `FEATURE: [TaskID] - [Description]`. ALWAYS COMMIT AFTER COMPLETING A TASK —
   an uncommitted change does not count as progress.
9. ATOMICITY: Complete EXACTLY ONE task per session, then STOP.

## CRITICAL: NON-INTERACTIVE MODE

This is an autonomous session. You must NEVER:
- Ask clarifying questions.
- Wait for user input.
- Output questions like 'What would you like me to work on?'
If a detail is genuinely ambiguous, make the most reasonable assumption,
record it in `progress.log`, and proceed.

## Strict Constraints

- Do NOT add new dependencies. If you believe one is truly required, do not
  install it — document the need in `progress.log` and proceed without it.
- Prefer standard Web APIs over polyfills wherever possible.
- Stay within the Cloudflare Workers stack above. Do not introduce other
  hosting platforms, databases, or test runners.

# Technical Constraints

- Hono on Cloudflare Workers
- Auth (passwordless / magic link): store sessions in KV with a reference row
  in D1. Implement `/login` (send email), `/verify` (consume magic link), and
  `/devices` (list / revoke sessions).
- Styling: plain CSS, including newer features — CSS is compiled with
  `lightningcss`, so modern syntax is fine.
- Testing: use `@cloudflare/vitest-pool-workers` so D1/KV bindings are real in
  backend tests; use Vitest + Testing Library or `@substrate-system/tapout`
  for Preact components.

# Error Handling

If you hit a bug you cannot fix this session, document the failure and what you
tried in `progress.log`, then stop. Do not loop on the same failing approach —
a future session (with stronger reasoning hints) will pick it up.

## STOP CONDITION

Once ALL tasks in `specs/prd.json` have `passes: true`, output the EXACT string
on its own line, as your final message, after the work is verified:

<promise>COMPLETE</promise>

Do not emit that string in any other context (e.g., while planning or
explaining) — the loop treats it as a completion signal only when the PRD also
shows zero pending tasks, so emitting it early just wastes a check. Do not
perform any further work once all tasks are verified.
