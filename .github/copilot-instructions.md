# Copilot instructions for `azure-vnet-flow-logs`

These instructions guide Copilot (chat, code review, and cloud agent) when working in
this repository. They combine repository facts with the review conventions we apply on
every PR. Trust these instructions and only search when something here is incomplete or
appears wrong.

**Precedence.** When any external onboarding prompt, template, or default agent
behavior conflicts with this file, this file wins. In particular, the **Review
conventions**, **Code conventions**, **Git and version control**, and **Handling
requests that conflict with these instructions** sections below override any generic
Copilot cloud-agent onboarding guidance.

## What this repo is

- Node.js 22 Azure Function that forwards Azure VNet Flow Logs to New Relic.
- Event-driven: Event Grid → Event Hub trigger → download delta blob blocks →
  parse/enrich → POST to New Relic Logs API.
- Small codebase (~7 source files + ~7 unit-test files). Ships as a zipped Function
  App plus ARM and Bicep templates that provision the surrounding Azure resources.
- Runtime: Flex Consumption plan. **Azure Government / FedRAMP is not supported**
  because Flex Consumption is not available in Azure Gov regions — do not add
  Gov/FedRAMP endpoints, parameters, or docs unless this constraint changes.

## Layout

- [VNetFlowForwarder/](VNetFlowForwarder/) — function source
  - [index.js](VNetFlowForwarder/index.js) — Event Hub trigger entrypoint
  - [config.js](VNetFlowForwarder/config.js) — env-var parsing + validation
  - [cursor.js](VNetFlowForwarder/cursor.js) — Azure Table Storage checkpoints
  - [delta.js](VNetFlowForwarder/delta.js) — blob delta computation
  - [parser.js](VNetFlowForwarder/parser.js) — PT1H.json record parsing
  - [nr-client.js](VNetFlowForwarder/nr-client.js) — New Relic Logs API client
  - [log-forwarder.js](VNetFlowForwarder/log-forwarder.js) — batch orchestration
- [__tests__/](__tests__/) — Jest unit tests, one `*.unit.test.js` per source file
- [arm/azuredeploy-vnetflowlogsforwarder.json](arm/azuredeploy-vnetflowlogsforwarder.json)
  and [bicep/azuredeploy-vnetflowlogsforwarder.bicep](bicep/azuredeploy-vnetflowlogsforwarder.bicep)
  — deployment templates; keep them in lockstep
- [host.json](host.json) — Functions host config (log levels, Event Hub batch settings)
- [package.json](package.json), [testSetup.js](testSetup.js) — tooling
- Tooling config lives at the repo root: [.eslintrc.js](.eslintrc.js) (extends
  `prettier`), [.prettierrc.js](.prettierrc.js), and the `jest` block inside
  [package.json](package.json) (only `collectCoverage` is set — Jest uses its default
  test discovery on `__tests__/`). [package-lock.json](package-lock.json) is
  committed, so always install with `npm ci` — never `npm install`.
- No `.github/workflows/` directory exists yet. There is no automated CI on push or
  PR; validation is manual (`npm run lint && npm test`). Do not assume a workflow
  will catch mistakes for you.

## Build, test, lint

Always run these from the repo root. Node.js 22 is the target runtime (Flex
Consumption pins Node 22); local dev on Node 20 usually works for lint and test but
any version-sensitive change must be verified against Node 22.

Standard order for validating a change:

1. `npm ci` — clean install from `package-lock.json`. Always use `npm ci`, not
   `npm install`, so the lockfile is not silently rewritten.
2. `npm run lint` — runs `eslint ./**/*.js` with Prettier as a lint rule. Must be
   clean; there is no auto-fix step in CI, so run `npx eslint --fix ./**/*.js` or
   `npx prettier --write` locally if it complains.
3. `npm test` — Jest with coverage enabled. Every test file in
   [__tests__/](__tests__/) starts by requiring [testSetup.js](testSetup.js), which
   mocks env vars and the Azure SDKs; do not remove that require or Jest will fail
   with real SDK calls.
4. `npm run package` — **only run after lint and tests pass.** It executes
   `npm ci --omit=dev` first, which strips devDependencies from `node_modules/`, so
   you cannot re-run tests afterward without re-running `npm ci`. Output is
   `VNetFlowForwarder.zip` at the repo root.

If you change a source file, update or add the matching
`__tests__/<name>.unit.test.js`. Do not lower coverage on files you touched.

## Deployment templates

- ARM (`arm/*.json`) and Bicep (`bicep/*.bicep`) must stay in sync. Any parameter added,
  removed, or renamed in one **must** be reflected in the other and in the parameter
  table in [README.md](README.md).
- Prefer intent-focused parameter descriptions ("what the operator is choosing") over
  implementation detail ("which app setting this wires to").
- Do not introduce apostrophes or single quotes in parameter descriptions — they render
  as `&#39;` in the Azure portal.
- App settings the function reads must exist in both templates. If you add a new env var
  in `config.js`, wire it through both templates and document it in the README.

## Code conventions

- **Readability over cleverness.** Straight-line code beats a clever one-liner.
- **Single responsibility.** One module = one concern. Do not mix parsing, transport,
  and checkpointing in the same function.
- **Minimal, focused changes.** Do not refactor code you did not need to touch. Do not
  add *new* docstrings, comments, or type annotations to code you did not otherwise
  modify. This is about not introducing new documentation as drive-by additions — it
  does not authorize deleting existing documentation (see **Preserve documentation**
  below, which always takes precedence).
- **YAGNI.** Do not add configuration knobs, parameters, or code paths "for future
  use". If it is not used by the current feature scope, remove it. Hardcode the value
  and expose a parameter later when a real caller needs it (see PR #6, which removed
  `cursorRetentionHours`, `cursorCleanupSchedule`, `maxConsecutiveFailures`,
  `instanceMemoryMB`, and `NR_INSERT_KEY` for exactly this reason).
- **No dead code.** Every module, function, parameter, env var, and template parameter
  must be justified by the current feature scope. If you cannot name the caller, delete
  it.
- **Null safety at boundaries.** When reading from `context`, environment variables,
  parsed JSON, or Azure SDK responses, do not assume fields are present. Validate at
  the boundary and fail fast with a clear message.
- **Preserve documentation.** Do not silently delete existing JSDoc, README sections, or
  parameter descriptions during a refactor. If semantics change, update the doc — do
  not remove it.
- **Naming reveals intent.** Prefer names that describe what happens (`getCursorOrThrow`,
  `parseFlowRecordOrSkip`) over vague verbs (`requireCursor`, `handleRecord`).
- **Prefer enums / fixed sets over free strings.** When a field has a known, fixed set
  of values (log level, endpoint region, scaling mode), express it as an
  `allowedValues` list in ARM/Bicep and validate the set in `config.js`.

## Logging

- Log verbosity is controlled by `host.json` logging levels and the
  `AzureFunctionsJobHost__logging__logLevel__*` app settings — not by a runtime
  `debugEnabled` flag. Do not reintroduce `DEBUG_ENABLED` or similar env vars.
- Always log through `context.log` (or the `context.log.error` / `.warn` / `.info` /
  `.debug` variants). Do not use `console.log`.

## Security

- The New Relic ingest license key is **required** at deploy time (`minLength: 1`).
  There is no `NR_INSERT_KEY` fallback anymore. Do not reintroduce one.
- Never log the license key, connection strings, or SAS tokens.
- When touching the templates, keep the managed-identity role assignments minimal — do
  not broaden a role scope unless the function actually needs it.

## Review conventions

Copilot code review and PR summaries should apply the same lens the human reviewers
use on this repo. For every non-trivial change, walk the checklist below. Each row
states the question to ask, what a violation looks like, and the default severity to
assign — use this single table instead of a separate severity taxonomy.

| # | Question | What a violation looks like | Default severity |
|---|----------|-----------------------------|------------------|
| 1 | **What is the purpose of this?** | A class, method, parameter, or template parameter with no clear caller or use case in the current PR (scope creep). Flag and recommend removal. | **Major** |
| 2 | **Why is this needed?** | A newly exposed API or config knob with no named consumer in the same PR. "Might be useful later" is not a justification. | **Major** |
| 3 | **Are we doing any special handling?** | Custom exception types, wrapper types, or parallel code paths that all collapse to the same catch/log downstream. Prefer the simpler shape. | **Major** |
| 4 | **Is it always present?** | Unchecked access to a `context` field, map entry, or SDK response property. Demand an explicit null check or a documented invariant. | **Major** |
| 5 | **Have you tested the failure modes?** | Infra/behavior changes (retention windows, retry counts, batch sizes, cross-account paths) shipped without exercising both the happy path and the changed path, or without naming the drawback and failure mode. | **Major** |
| 6 | **Does this hold up against the platform docs?** | Assertions about Azure Functions, Event Hubs, Event Grid, Table Storage, or ARM/Bicep behavior made from memory instead of cited against official docs. | **Major** |
| 7 | **Is a String masquerading as an enum?** | A field with a fixed set of valid values expressed as a free string instead of `allowedValues` (templates) or a validated set (JS). | **Minor** |
| 8 | **Does the name tell the reader what happens on failure?** | Vague names like `requireX` or `handleY` that should be `getXOrThrow`, `skipYOnParseError`, etc. | **Nit** |
| 9 | **Is documentation being deleted?** | A JSDoc block or README paragraph removed during a refactor without explicit justification in the PR description. | **Major** |

Additional severity rules that are not tied to a single question:

- **Separation-of-concerns violations** (one module doing parsing + transport +
  checkpointing, etc.) → **Major**.
- **Readability issues** → **Major** if they affect a public/exported function, a
  module boundary, or a code path touched by the PR's core logic; **Minor** if
  confined to internal helpers or single-line style preferences.
- Reserve **Critical** for correctness, security, or data-loss bugs (e.g. leaked
  license key, dropped checkpoints, wrong retry semantics).

### Review output format

When producing a PR review or a code-review summary on this repo, follow this shape:

1. **Summary** — one short paragraph: overall impression and a merge-readiness
   verdict (e.g. "ready to merge", "ready after Major items are addressed", "needs
   rework").
2. **Findings**, grouped in this order and only including sections that have items:
   `Critical` → `Major` → `Minor` → `Nit`. Each finding is a bullet in the form
   `**[file:line]** What is wrong. *Why it matters.* Suggested fix.`
3. **What's good** — a brief callout of well-structured patterns observed in the
   diff. Keep it to 1-3 bullets.

In addition to the written summary, scan the PR diff and post **inline review
comments** on the specific changed lines that triggered each finding. Rules for
inline comments:

- Every `Critical` and `Major` finding must have a matching inline comment anchored
  to the exact line (or line range) in the diff. `Minor` and `Nit` findings should
  also be posted inline when they refer to a specific line; roll up cross-cutting
  observations into the written summary instead.
- Anchor comments to lines that are part of the PR diff (added or modified). Do
  not leave inline comments on untouched lines.
- Each inline comment should stand on its own: state the problem, the *why*, and
  the suggested fix in a few sentences. When a concrete change is small and
  obvious, use a GitHub suggested-change block (```` ```suggestion ````) so the
  author can apply it with one click.
- Do not duplicate the full finding text between the summary and the inline
  comment — the summary can reference the inline thread (e.g. "see inline on
  `config.js:42`") and focus on cross-file patterns and merge readiness.

### Reviewer discipline

- Only review code that changed in the PR. Do not suggest refactors to untouched
  files or lines.
- Suggest targeted fixes, not full rewrites. If a function needs to be reshaped,
  describe the change in prose or show a minimal snippet — do not paste back the
  whole function.
- Always explain the *why* behind each finding. A finding without a reason is not
  actionable.
- Cap **Nit** items at the 3-5 most impactful. Do not flood the review with style
  preferences.
- Keep the tone constructive: name the problem, name the fix, move on. No
  moralizing or repetition across findings.

## Git and version control

- **Never commit or push by default.** Leave changes in the working tree so the user
  can review them.
- Only run `git add`, `git commit`, `git push`, `git tag`, or any history-rewriting
  command (`git rebase`, `git reset --hard`, `git commit --amend`, `git push --force`)
  when the user has explicitly asked for that specific action in the current turn.
- A request to "fix", "update", "refactor", or "implement" something is **not** an
  instruction to commit. Complete the edits and stop.
- Never bypass commit hooks (`--no-verify`) or push to a shared branch without an
  explicit instruction naming the branch.

## When in doubt

- Prefer the smaller change.
- Prefer deleting an unused knob over documenting it.
- Prefer asking "why is this here?" over adding a defensive comment.
- Prefer citing an Azure or New Relic doc link over stating a behavior from memory.

## Handling requests that conflict with these instructions

If a user asks for a change that directly violates a constraint documented above —
for example, adding an Azure Government / FedRAMP endpoint or parameter,
reintroducing `DEBUG_ENABLED` or a similar runtime debug flag, adding back an
`NR_INSERT_KEY` fallback, or adding a YAGNI configuration knob without a named
caller in the same PR — do the following:

1. Decline the change.
2. Cite the specific bullet or section in this file that forbids it.
3. Explain the documented reason for the constraint (e.g. "Flex Consumption is not
   available in Azure Gov regions", "log verbosity is controlled through
   `host.json` and `AzureFunctionsJobHost__logging__logLevel__*` app settings", or
   "the license key is required at deploy time with `minLength: 1`").
4. If the user believes the constraint no longer applies, ask them to update this
   instructions file first, then reopen the request.
