# Agent Instructions

This repository contains the backend implementation for Airsoft Schedule System.

Before changing backend behavior, read the shared knowledge repository next to
this repo:

- `../ass_knowledge/INDEX.md`
- `../ass_knowledge/api/api-spec-v2.md`
- `../ass_knowledge/database/erd-v2.md`
- `../ass_knowledge/decisions/2026-05-25-backend-decision-v1.md`

Rules:

- Treat `../ass_knowledge/api/` as the source of truth for API contracts.
- Treat `../ass_knowledge/database/` as the source of truth for schema context.
- Treat `../ass_knowledge/decisions/` as the source of truth for accepted decisions.
- When backend changes affect frontend calls, inspect `../ass_client` before finalizing.
- Update shared docs in `../ass_knowledge` when implementation changes an API, schema, or decision.
- Keep generated secrets, local environment files, and private credentials out of git.

