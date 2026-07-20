# Gate B 패치 — Codex 작업지시서

| 항목 | 내용 |
|------|------|
| 브랜치 | `feature/gate-b` (develop `46d1837`에서 분기) |
| 결정 근거 | `../../../ass_knowledge/decisions/2026-07-16-a2-gate-b-payment-flow.md` (D-1~D-7) |
| FE 계약 | `../../../ass_knowledge/api/fe-be-contract-v3-addendum-gate-b.md` |
| 원칙 | 실배포 전이므로 마이그레이션 **in-place 편집** (S2 하드닝과 동일 방식). `0002_enums.sql` 무변경 — `paymentReview` enum 값은 DB에 남기고 미사용 처리 |
| 완료 기준 | `supabase db reset` 무오류 + `supabase test db` 전체 PASS (CI 게이트와 동일) |

## 무엇을 바꾸나 (한 줄)

결제 흐름의 관문 2개(승인+입금확인)를 1개(승인)로: **송금증 첨부 = 즉시 확정**, 입금확인 관문 폐지, 호스트는 사후 반려·검수 마커만.

```
신청 → pendingApproval → (호스트 승인) → awaitingPayment → submit_payment → confirmed 직행(+EntryPass)
                                                                └ 이후 호스트: mark_payment_reviewed(검수 마커) / reject_payment(사후 반려)
```

## 파일별 변경 스펙

### 0006_functions_util.sql — `app_error` 확장

- `app_error(p_code text, p_message text)` → **optional 3번째 인자 `p_detail text default null`** 추가(하위호환 — 기존 호출부 무변경).
- `p_detail`이 있으면 `raise exception ... using detail = p_detail` 형태로 전달. revoke 구문도 새 시그니처 반영.

### 0009_rpc_payment_refund.sql — 핵심 재작성

**`submit_payment(p_participation_id, p_sender_name, p_amount, p_receipt_path)`** — 시그니처 유지, 동작 변경:
1. 기존 검증 유지: try_uuid, 본인 소유, `status = 'awaitingPayment'`, 입력값 검증.
2. 부모 세션 로우 락(기존 부모-먼저-락 패턴 `for update`).
3. **정원 가드(신규, D-2)**: `confirmed_count >= capacity`이면 `app_error('failed-precondition', '정원이 마감되었습니다', 'capacityFilled')` — 상태는 `awaitingPayment` 그대로(트랜잭션 롤백으로 자연 보장). 세션 status 가드(recruiting/closed 허용)는 기존 정책 유지.
4. submission insert (`status = 'pending'` — 의미: "증빙 기록").
5. participation → `confirmed`, `confirmed_count + 1`, capacity 도달 시 세션 `recruiting → closed` 전이(기존 approve_payment에 있던 로직 이관).
6. **EntryPass 인라인 발급** — 기존 approve_payment의 `issue_entry_pass(...)` 호출을 이관, `participations.entry_pass_id` 세팅.
7. 알림: `notify(..., 'participation.confirmed', ...)` (entryPassId 포함 data) — **이관**. `payment.decision(approved)`는 발신하지 않음.

**`approve_payment`** — **함수 제거**(drop). 관련 grant·주석 정리. 대체:

**`mark_payment_reviewed(p_submission_id uuid)` (신규, D-4)** — 경량 검수 마커:
- 검증: 세션 운영자 본인, submission 존재, `status = 'pending'`.
- 동작: `status → 'approved'` + `reviewed_by`/`reviewed_at` 기록. **participation·세션·알림 무변경**(비관문).
- 반환 `{success: true}`. grant to authenticated.

**`reject_payment(p_submission_id, p_reason)`** — 용도 변경(D-3): 사후 반려.
1. 검증: 운영자 본인, submission 존재·`pending`(검수 전) 또는 `approved`(검수 후에도 반려 가능), 대상 participation `status = 'confirmed'`.
2. 부모 세션 로우 락.
3. submission → `rejected` + 사유·reviewed_by/at.
4. participation → `awaitingPayment` (재제출 대기), `entry_pass_id` null.
5. EntryPass → `revoked`.
6. `confirmed_count − 1`, 세션이 `closed`였고 정원에 여유가 생기면 `recruiting` 재개(기존 cancel_participation의 재개 로직과 동일 조건 — startsAt 전에만).
7. 알림: `payment.decision` (decision: 'rejected', reason 포함) → 참가자.

**`request_refund`** — 변경 없음(cancelled에서 진입, 기존 그대로).

### 0008_rpc_participation.sql — 소변경

- **`cancel_participation`**: 허용 상태 목록에서 `paymentReview` 제거. `refundEligible` 판정의 `exists(approved payment)` 조건(S2 하드닝 ④) → **`exists(해당 participation의 payment_submission 아무 status나)`** 로 재정의(D-6) — 사후 반려로 강등된 사람도 돈은 냈으므로 자격 유지.
- `approve_participation`: 무변경(정원 가드 두지 않음 — D-2 "승인은 정원 미점유").
- `join_as_operator`(A7): 무변경 — 증빙 없는 confirmed 경로로 존속(D-5).

### 0010_rpc_entrypass.sql — 확인 위주

- `issue_entry_pass` 헬퍼가 submit_payment에서 호출 가능한지 확인(스키마 경로·권한). 필요 시 호출부만 조정, 로직 무변경.
- scan/mark_attendance/get_entry_pass_token 무변경.

### supabase/tests/database/rpc.sql — 결제축 테스트 재작성

기존 approve_payment 경유 테스트를 새 흐름으로 교체 + 신규 케이스:
1. submit_payment → participation `confirmed` 직행 + `confirmed_count` 증가 + EntryPass active 발급 + notifications에 `participation.confirmed` 1건.
2. 정원 마감 상태에서 submit_payment → 에러(failed-precondition), **errdetail = 'capacityFilled'** 확인(`throws_ok` + detail 검증 가능한 형태로), 상태 `awaitingPayment` 유지.
3. capacity 도달 시 세션 `closed` 전이.
4. `mark_payment_reviewed`: pending → approved, participation 무변경. 비운영자 호출 → permission-denied.
5. `reject_payment`(사후 반려): confirmed → awaitingPayment, EntryPass `revoked`, `entry_pass_id` null, count −1, closed → recruiting 재개, `payment.decision(rejected)` 알림 1건.
6. 반려 후 재제출(submit_payment 재호출) → 다시 confirmed + 새 EntryPass.
7. A7: join_as_operator confirmed에 submission 없음 — 기존 테스트 유지 확인.
8. cancel_participation: paymentReview 케이스 제거, refundEligible이 submission 존재 기준으로 판정되는지(반려만 있는 경우 포함).
9. 기존 무관 테스트(세션·승인·QR·알림 인프라)는 전부 GREEN 유지.

`rls.sql`: paymentReview 참조가 있으면 정리(있는지 확인만, 정책 자체는 무변경 예상).

## 하지 말 것

- `0002_enums.sql` 수정 금지 (`paymentReview` 값 유지·미사용).
- `0007`(세션), `0011`(트리거), `0013`(스토리지) 무접촉.
- **push 금지** — 커밋까지만(브랜치 `feature/gate-b`). PR은 오케스트레이터가.
- 새 마이그레이션 파일 추가 금지(in-place 원칙).

## 검증

```
supabase db reset    # 무오류
supabase test db     # 전체 PASS (155개 기준 증감 보고)
```
Docker/스택을 쓸 수 없으면 편집·커밋까지만 하고 "검증 미실시" 명시 — 검증은 오케스트레이터가 수행.

## 보고 형식

변경 파일 목록 / 함수별 변경 요지 / 테스트 증감(±N) / 검증 결과(또는 미실시 사유) / 스펙과 다르게 판단한 지점(있다면 근거).
