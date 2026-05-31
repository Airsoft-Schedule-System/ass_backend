# ass_backend

Backend repository for Airsoft Schedule System.

## Project Context

Shared product, API, database, and decision documents live in the sibling
repository:

```text
../ass_knowledge
```

Start with:

- `../ass_knowledge/INDEX.md`
- `../ass_knowledge/api/api-spec-v2.md`
- `../ass_knowledge/database/erd-v2.md`
- `../ass_knowledge/decisions/2026-05-25-backend-decision-v1.md`
- `../ass_knowledge/architecture/project-status.md` (전체 진행 현황)

## Getting Started

```bash
cd functions
npm install
npm run build   # tsc -p tsconfig.json
npm test        # vitest (unit tests, 24)
npm run lint    # eslint
```

- Node 20. 실제 Firebase project id는 `.firebaserc`의 placeholder를 교체.
- 시크릿(.env, serviceAccount* 등)은 `.gitignore`로 제외 — 커밋 금지.

## Structure

```text
firebase.json · firestore.rules · firestore.indexes.json · storage.rules
functions/src/
  config/runtime.ts     region(asia-northeast3) · secrets · admin init · db
  lib/                  permissions(B3-1) · guards(B1-1/B1-2) · validation(B1-6) · status · seams · errors · collections
  types/                common · status · entities · functions · events  (api-spec/ERD 전사)
  triggers/onUserCreate.ts
  functions/{session,participation,payment}/   콜러블 6
  __tests__/            permissions · guards · validation · status  (24)
```

## Status

- 설계·검증·후속 TODO: [docs/green-scope-implementation-plan.md](docs/green-scope-implementation-plan.md)
- 현재 GREEN(B1-1·B1-2·B1-5·B1-6·B3-1·B3-3) 완료(`green-backend` 브랜치, Codex 교차검증).
- 나머지 콜러블/트리거는 기획 결정(A1–A8) 의존 — `src/index.ts` 하단 TODO 참고.
