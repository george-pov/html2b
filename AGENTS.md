# AI Agent Instructions

## Read Before Acting

- Start with `README.md`, then read every durable document relevant to the
  requested area.
- Inspect the implementation, configuration, and runtime entry points before
  relying on documentation. When they disagree, report the mismatch and keep
  any authorized documentation change aligned with the implemented behavior.
- Discover solution, project, test, and command paths from the repository
  instead of assuming conventional names or locations.

## Documentation Ownership

- Keep `README.md` as a concise human-facing documentation index.
- Keep durable documents under `docs/` human-facing, present-tense, and limited
  to implemented behavior.
- Never place AI instructions in `README.md` or `docs/`.
- Never add a reference to `AGENTS.md` from `README.md` or `docs/`.
- Do not duplicate durable technical facts in this file. Point agents to the
  owning human document instead.
- Keep plans, roadmaps, feature phases, approval records, implementation
  history, review evidence, and validation evidence under `.work/`.
- Do not mention `.work/` in `README.md` or durable documents.

## Work Boundaries

- Follow the user's requested scope literally. A request for analysis, review,
  diagnosis, planning, or documentation does not authorize unrelated code or
  infrastructure changes.
- Preserve unrelated user changes and inspect overlapping edits before
  modifying a file.
- Do not perform live Azure mutations unless the user explicitly authorizes
  them.

## Local AI Workflows

- When `.work/agents/` exists, read the relevant workflow files before
  planning, implementation, review, validation, or release work.
- Treat `.work/` as local workflow state. Verify ignored records with direct
  path checks and readback rather than relying on Git status.

## Documentation Rules

- Describe the system as it operates now. Do not include proof-of-concept,
  transition, target-state, roadmap, feature-phase, or historical release
  language in `README.md` or `docs/`.
- Do not document unimplemented templates, assets, persistence, queues, user
  interfaces, or asynchronous jobs as available behavior.
- Keep the Azure deployment guide free of secrets and specific identifiers,
  hostnames, resource names, release hashes, image digest values,
  environment-specific values, and Bicep symbol names.
- Keep detailed setup, API, architecture, and deployment information in their
  owning durable documents rather than repeating it in `README.md`.

## Validation

- Validate in proportion to the change and use repository-defined commands
  where they exist.
- For documentation changes, verify internal Markdown links, scan for forbidden
  ownership and state-language terms, and run `git diff --check`.
- Report checks that were skipped or could not run.
