# Supabase 전환 마스터플랜 (MVP 전 범위 골격)

| 항목 | 내용 |
|------|------|
| 작성 | Claude (설계) · 문준수 검토 |
| 작성일 | 2026-07-04 |
| 상태 | **구현 지침 확정본 — 구현 미착수.** 위임 시 본 문서 세트만으로 착수 가능해야 함 |
| 선행 | 팀 합의: DB=Supabase(Postgres) 전환 / 클라=PWA 유지 / 푸시=FCM 유지 (2026-07-04 메신저, HOAN 동의. `decisions/` 승격은 공식 확정 후) |
| 문서 세트 | 본 문서(전략·수단·위임 절차) → `01-schema-and-rls.md`(DDL·RLS) → `02-rpc-functions.md`(콜러블→RPC 15종) → `03-edge-functions-and-jobs.md`(Edge·cron·푸시) → `../../ass_knowledge/api/fe-be-contract-v3-supabase.md`(FE 계약) |

## 0. 전환 결정의 근거 (요약 — decisions 승격 예정)

1. 도메인이 본질적으로 관계형: 정원(capacity), 1유저 1참가(unique), 세션↔참가↔결제↔환불↔입장권 FK 체인 → SQL 제약이 자연스러움.
2. 금전 거래(입금·환불): 변경 로그·감사가 Postgres에서 저렴.
3. 프로덕션 데이터 0인 **지금이 전환 최저비용 시점**. "출시 후 리팩터링"은 배제.
4. Supabase에는 푸시가 없으므로 **FCM 유지**. 실시간은 필요한 곳만 Supabase Realtime.
5. 클라이언트는 PWA 유지(Expo는 v2) — 펀더멘털 교체 슬롯은 한 번에 하나.

## 1. 스택 매핑 (Firebase → Supabase)

| Firebase (기존 green-backend) | Supabase (타깃) | 지침 위치 |
|---|---|---|
| Firebase Auth + onUserCreate 트리거 | Supabase Auth + `auth.users` INSERT 트리거 → `public.users` 생성 | 01 §5 |
| Firestore 9컬렉션 | Postgres 테이블 10개(+enum 7종). 정원·중복 불변식을 CHECK/UNIQUE로 DB 보장 | 01 |
| firestore.rules | RLS 정책. **SQL 조인이 가능해져 Firebase에서 불가능했던 규칙(운영자가 신청자 프로필/송금증 열람)이 정책으로 해결** → `getSessionParticipantProfiles`·`getReceiptUrl` 콜러블 신설 계획 **폐기** | 01 §4 |
| 콜러블 15종 | **Postgres RPC(SECURITY DEFINER, 단일 트랜잭션)** 15종 — 상태전이·정합 전부 DB 안에서 | 02 |
| onParticipationConfirmed 트리거 | **폐기** — `approve_payment` RPC가 같은 트랜잭션에서 EntryPass 발급(인라인). A7 join_as_operator는 미발급 유지 | 02 §3.10 |
| QR HMAC (Secret Manager) | pgcrypto `hmac()` + **Supabase Vault** 시크릿 — RPC 내부에서 서명·검증 | 02 §3.13 |
| 환불계좌 AES-256-GCM | pgcrypto `pgp_sym_encrypt` + Vault 키 | 02 §3.12 |
| FCM 발신 (FcmNotifier) | RPC가 `notifications` INSERT(영속화) → **Database Webhook** → Edge Function `send-push`가 FCM HTTP v1 호출 | 03 |
| Cloud Scheduler 2종 | **pg_cron**: 상태전이는 순수 SQL 함수, 리마인더는 SQL(마킹+알림 INSERT)→웹훅 경유 푸시 | 03 §3 |
| Firebase Storage + 경로검증 | Supabase Storage `receipts` 버킷 + **storage.objects RLS**(업로더 본인 + 세션 운영자 SELECT) → 클라가 `createSignedUrl` 직접 호출 | 01 §4.11 / 03 §4 |

**기존 자산 재사용률**: 도메인 규칙·상태머신(8/5states)·가드 로직·에러 정책·테스트 시나리오 54건 = 전부 이식(로직 기준). 코드 형태만 TS→SQL/Deno 재작성. `green-backend` 브랜치는 참조 자산으로 보존.

## 2. 네이밍·계약 규칙 (중요 — FE 합의사항)

- **DB 컬럼/테이블/RPC = snake_case** (Postgres 생태계 표준. quoted camelCase 금지).
- **enum 값 문자열 = camelCase 유지** (`'pendingApproval'`, `'inProgress'` 등) — fe-be-contract-v2의 정식 상태값을 **그대로 보존**해 FE statusView·화면 로직 무변경.
- FE 도메인 모델은 camelCase 유지, **snake↔camel 매핑은 supabaseRepository 내부**에서(contract-v3 참조).
- 에러: RPC는 `RAISE EXCEPTION ... USING ERRCODE`. 코드 체계는 02 §2 표(기존 HttpsError 코드와 1:1 매핑).

## 3. 저장소 구조 (구현 시 생성할 트리)

```
ass_backend/ (branch: supabase-backend)
  supabase/
    config.toml                 # supabase init 산출
    migrations/
      0001_extensions.sql       # pgcrypto, pg_cron, pg_net (+ vault는 대시보드 활성화)
      0002_enums.sql
      0003_tables.sql
      0004_indexes.sql
      0005_rls.sql
      0006_functions_util.sql   # 공용 헬퍼(에러, 권한판단, vault 접근)
      0007_rpc_session.sql
      0008_rpc_participation.sql
      0009_rpc_payment_refund.sql
      0010_rpc_entrypass.sql
      0011_triggers.sql         # auth.users→users, updated_at
      0015_cron.sql
      0013_storage.sql          # 버킷 + storage RLS
    functions/
      send-push/index.ts        # Edge: FCM HTTP v1
    tests/
      *.sql                     # pgTAP
  docs/supabase/*.md            # 본 문서 세트
```

## 4. 사전 준비물 (구현 착수 전 사람이 할 일 — 문준수)

1. [ ] **Docker Desktop 설치** (로컬 스택 `supabase start` 전제).
2. [ ] Supabase CLI 설치(`scoop install supabase` 또는 npm). `supabase init` → `supabase start`로 로컬 기동 확인.
3. [ ] supabase.com 프로젝트 생성(무료 티어, 리전 서울 `ap-northeast-2`). URL·anon key·service_role key 확보.
4. [ ] Vault에 시크릿 등록: `qr_hmac_secret`, `refund_account_key`. Edge용 시크릿: `FCM_SERVICE_ACCOUNT_JSON`(FCM HTTP v1 서비스계정), `WEBHOOK_SECRET`.
5. [ ] Firebase 프로젝트는 **FCM 발신 전용으로 1개 유지**(콘솔에서 서비스계정 키 발급 + 웹앱 등록으로 클라 senderId/VAPID 확보).

## 5. 구현 웨이브 (위임 단위 — 각각 독립 검증 가능)

| Wave | 내용 | 지침 | 검증 |
|------|------|------|------|
| **S1** | migrations 0001–0005 + 0011 + 0013 (스키마·RLS·트리거·스토리지) | 01 전체 | `supabase db reset` 무오류 + pgTAP: 제약(정원 CHECK·중복 UNIQUE)·RLS(본인/운영자/타인 접근 매트릭스) |
| **S2** | migrations 0006–0010 (RPC 15종 + 헬퍼) | 02 전체 | pgTAP: 기존 vitest 54건 시나리오 이식(02 §5 목록) — happy/guard/edge 전수 |
| **S3** | 0015(cron) + Edge `send-push` + 웹훅 배선 | 03 전체 | 로컬: `supabase functions serve` + curl 계약 테스트, cron은 SQL 함수 직접 호출 검증 |
| **S4** | FE `supabaseRepository` 구현(HOAN 주도, 우리는 계약 지원) | contract-v3 | ass_client `npm run check`/`build` + 로컬 스택 연동 수동 E2E |

**위임 프로토콜(각 Wave 공통)**: ① 해당 지침 md를 Codex 프롬프트의 유일 기준으로 지정 ② 브랜치 `supabase-backend`, 커밋 금지 ③ 완료 기준 = 위 검증 명령 통과 ④ 우리 환경 재검증 → 커밋·푸시. (Wave 1·2에서 검증된 파이프라인 그대로. Codex가 wedge되면 산출물은 디스크에 남으므로 직접 인계.)

## 6. 명시적 비범위 (v2 이월)

processRefund 활성화(A3), Expo 네이티브, 소셜 로그인, 현장결제(onsite), 알림 고도화(푸시 UX), Realtime 전면 적용(알림함·운영자 큐 외), 다중 환경(dev/prod 분리 — 로컬 스택이 dev 역할).
