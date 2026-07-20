# Agent Instructions — ass_backend

Airsoft Schedule System 백엔드. **Supabase(Postgres)** 기반이며, 마이그레이션·RPC·Edge Function으로 구성된다.

> Firebase 구현(Cloud Functions)은 태그 `archive/firebase-v1`에 박제된 **참조 자산**이다. 폐기가 아니지만 신규 작업의 기준이 아니다.

## 시작 전에 읽을 것

1. `../ass_knowledge/architecture/project-status.md` — 현재 상태·다음 할 일
2. `../ass_knowledge/INDEX.md` — 문서 지도
3. 작업 웨이브의 지침 문서: `docs/supabase/00-master-plan.md` ~ `03-edge-functions-and-jobs.md`

## SoT 규칙

- `../ass_knowledge/decisions/` = 제품·아키텍처 결정의 최우선 기준 (충돌 시 승)
- `../ass_knowledge/api/` = FE-BE 계약 기준
- `../ass_knowledge/database/erd-v2.md` = 데이터 모델 **개념** 기준
  - ⚠️ **ERD와 실제 스키마가 어긋난 사례가 있다** (예: `participations.entry_pass_id`는 ERD에만 존재, 실제 테이블엔 없음 — 관계는 `entry_passes.participation_id` 단방향). **컬럼 확인은 `supabase/migrations/0003_tables.sql`을 직접 볼 것.**
- 구현이 계약·스키마를 바꾸면 **`../ass_knowledge`를 같은 웨이브에서 갱신**한다.

## 브랜치·검증

- 작업: `develop`에서 분기 → `feature/*` → **PR로 develop 머지**. `main` 직접 푸시 금지.
- CI(`.github/workflows/ci.yml`)가 PR에서 `db reset` + pgTAP을 돌린다 = 실질 게이트.
- 로컬 검증(필수):
  ```
  E:/Airsoft_Schedule_Workspace/.tools/supabase.exe db reset   # 무오류
  E:/Airsoft_Schedule_Workspace/.tools/supabase.exe test db    # 현재 182개 전량 PASS
  ```
- Supabase CLI는 **PATH에 없다.** 전체 경로로 호출. **`supabase init` 금지**(이미 구성됨).

## 마이그레이션 규칙

- **실배포 전이므로 in-place 편집 허용** — 새 번호 파일을 늘리지 말고 기존 파일을 고친다. (실배포 후 append-only 전환)
- enum 값 제거는 마이그레이션 리스크가 있으므로 **값은 남기고 미사용 처리**한다. (예: Gate B 이후 `paymentReview`는 DB enum에 남아 있으나 코드·문서에서 제거됨)
- RPC는 `security definer` + `set search_path = public`. 오류는 `app_error(code, message [, detail])`로 통일 — `hint`에 도메인 에러코드가 실린다.
- 다중 행 갱신 시 **부모(게임 세션) 로우를 먼저 락**한다(`for update`). 데드락 방지 규약.

## pgTAP 작성 시 함정

- **RLS가 검증을 가린다.** `notifications`·`participations` 등은 `select_self` 정책이 있어, **다른 사용자 소유 행을 세면 0이 나온다.** 남의 행을 확인할 땐 `reset role;` 후 검사하고 다시 롤을 설정한다. (거짓 통과·거짓 실패 모두 실제로 발생했음)
- **RLS UPDATE 거부는 예외가 아니라 0행**이다. `throws_ok` 대신 영향 행 수로 검증.
- `storage.objects`는 `supabase_storage_admin` 소유 — `alter table ... enable rls` 금지(42501). **정책만 생성.**

## 기타

- 시크릿·로컬 환경 파일은 커밋 금지. 로컬 스택 키는 demo 기본값이라 비밀이 아니다.
- `../ass_client`는 **최정환(HOAN) 소유** — 읽기만. 원격 푸시 금지.
- 백엔드 변경이 FE 호출에 영향을 주면 `../ass_knowledge/api/` 계약을 먼저(또는 함께) 갱신하고 FE에 통지한다.
