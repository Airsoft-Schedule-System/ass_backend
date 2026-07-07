# 02 — RPC 함수 구현 지침 (Wave S2) : 콜러블 15종 → Postgres

기준: `ass_knowledge/api/api-spec-v2.md` §2(함수 명세)·§5(상태머신) + green-backend 구현 로직(`functions/src/functions/*` — 가드·전이·에러 의미를 그대로 이식). 상태값·전이 규칙은 **완전 동일**, 실행 형태만 SQL.

## 1. 공통 규약

- 전 함수 `security definer set search_path = public`, `language plpgsql`. 호출자 = `auth.uid()` (null이면 unauthenticated 에러).
- **함수 하나 = 트랜잭션 하나**(Postgres 기본) — Firestore runTransaction 블록과 1:1 대응. read-before-write 순서 고민 불필요, 대신 경합 지점은 `select ... for update`로 행 잠금(세션 행: 정원 증감 / 참가 행: 상태 전이).
- 반환: `returns jsonb` — 기존 콜러블 Output 형태(camelCase 키)를 jsonb로 그대로 (`jsonb_build_object('success', true, ...)`). FE 계약 불변.
- GRANT: `revoke execute ... from public; grant execute ... to authenticated;` 전 함수 일괄.

### 1.1 에러 규약 (0006 헬퍼)

```sql
create or replace function app_error(err_code text, msg text) returns void
language plpgsql as $$
begin raise exception '%', msg using errcode = 'P0001', hint = err_code; end $$;
```
`hint`에 기존 HttsError 코드 문자열을 실어 FE가 1:1 매핑(contract-v3 §4): `unauthenticated` · `permission-denied` · `not-found` · `failed-precondition` · `already-exists` · `invalid-argument`. 메시지는 green-backend의 한국어 문구 재사용. UNIQUE 위반(23505)·CHECK 위반(23514)은 FE에서 각각 already-exists·failed-precondition으로 매핑.

### 1.2 공용 헬퍼 (0006)

```sql
current_uid() returns uuid            -- auth.uid() null 검사 + unauthenticated
assert_profile_complete(uid)          -- users.display_name 비어있으면 failed-precondition (B1-6)
assert_session_owner(session_row, uid)-- created_by_user_id 불일치 → permission-denied (B3-1)
assert_session_status(op text, s game_session_status)  -- B1-2 화이트리스트(아래 표), 위반 → failed-precondition
notify(user_id, type, title, body, action_url, data jsonb, session_id, participation_id)
                                      -- notifications INSERT 한 줄 헬퍼(푸시는 03 웹훅이 담당)
vault_secret(name text) returns text  -- vault.decrypted_secrets 조회(qr_hmac_secret 등)
```

세션상태 화이트리스트(B1-2, guards.ts 이식): request_participation·join_as_operator `{recruiting}` / approve·reject participation·payment, submit_payment `{recruiting, closed}` / update·cancel_game_session, scan_entry_pass, mark_attendance `{recruiting, closed, inProgress}`.

## 2. 함수별 지침 (0007–0010)

표기: 【가드】권한·상태 검증 순서 그대로 구현. 【쓰기】단일 트랜잭션 내 수행. 【알림】notify() 호출(§4 이벤트 표).

### 0007 세션

**2.1 `create_game_session(p_input jsonb) → jsonb{success, gameSessionId}`**
【가드】current_uid → assert_profile_complete → 입력검증(title 비공백 / capacity≥1 정수 / game_fee≥0 / starts_at 미래 / bank 3필드 / field XOR·rules XOR는 CHECK가 잡지만 메시지 품질 위해 선검증 권장).
【쓰기】cancel_deadline 미지정 시 `starts_at - interval '48 hours'`(A4). status recruiting, confirmed_count 0.

**2.2 `update_game_session(p_session_id uuid, p_updates jsonb) → jsonb{success, updatedFields[]}`**
【가드】owner → assert_session_status('update_game_session') → allow-list `{title, custom_rules, cancel_deadline, capacity, game_fee, ends_at}` 외 키 → invalid-argument. capacity: 증가만 + `>= confirmed_count`. game_fee: confirmed_count=0일 때만. cancel_deadline: `starts_at-7d ≤ x ≤ starts_at-24h`(A4). preset 세션의 custom_rules 변경 → failed-precondition. **starts_at·status·confirmed_count·created_by_user_id 불변**(B3-3).
【쓰기】세션 행 `for update` 후 갱신. 【알림】capacity 증가 또는 custom_rules 변경 시 confirmed 참가자 전원 `session.changed`(data.type='updated').

**2.3 `cancel_game_session(p_session_id uuid, p_reason text default null) → jsonb{success, affectedParticipations}`**
【가드】owner → status 화이트리스트.
【쓰기】세션 `for update` → status cancelled. pre-terminal 참가(`pendingApproval,awaitingPayment,paymentReview,confirmed`) 일괄 → cancelled (refundRequested는 불변 — 환불 파이프라인 유지). active entry_passes → revoked. affected = 전이 행 수.
【알림】전이된 참가자 전원 `session.changed`(data.type='cancelled', reason 포함).

### 0008 참가

**2.4 `request_participation(p_session_id uuid) → jsonb{success, participationId, status:'pendingApproval'}`**
【가드】current_uid → profile → 세션 `for update`·존재(not-found) → assert_session_status → **운영자면 failed-precondition("본인 세션은 join_as_operator 사용")** → 중복은 UNIQUE가 잡음(23505→already-exists).
【쓰기】participations INSERT (pendingApproval).

**2.5 `join_as_operator(p_session_id uuid) → jsonb{success, participationId, status:'confirmed'}`** (A7 자동확정)
【가드】current_uid → profile → 세션 `for update` → **assert_session_owner(운영자만)** → status recruiting → 정원(`confirmed_count < capacity`, CHECK의 백업으로 명시 검증).
【쓰기】INSERT status **confirmed**(승인·결제 면제) + `confirmed_count+1` + 정원 도달 시 status→closed. **EntryPass 미발급**(A7 — 출석은 mark_attendance).
【알림】없음(자기 자신).

**2.6 `approve_participation(p_participation_id uuid) → jsonb{success, newStatus:'awaitingPayment'}`**
【가드】참가+세션 로드(참가 `for update`) → owner → assert_session_status → 참가 status = pendingApproval.
【쓰기】→ awaitingPayment. 【알림】`participation.decision`(approved) + `payment.requested`(입금 안내: 금액·계좌 data 포함) — 2건.

**2.7 `reject_participation(p_participation_id uuid, p_reason text default null) → jsonb{success}`**
동일 가드, pendingApproval → rejected. 【알림】`participation.decision`(rejected, reason).

**2.8 `cancel_participation(p_participation_id uuid, p_reason text default null) → jsonb{success, refundEligible}`**
【가드】참가 `for update`+세션 `for update` → **본인 또는 운영자**(assertParticipantOrOwner 이식) → 이전 status ∈ `{pendingApproval, awaitingPayment, paymentReview, confirmed}`(policy.ts CANCELLABLE 이식, 그 외 failed-precondition).
【계산】refundEligible = (이전 status = confirmed) and (now() < cancel_deadline) — A4.
【쓰기】→ cancelled. 이전이 confirmed면: `confirmed_count-1`, 세션이 closed였으면 → recruiting(자리 복귀), active entry_pass → revoked. reason은 미저장(스키마에 필드 없음 — v2 과제).

**2.15 `mark_attendance(p_participation_id uuid) → jsonb{success}`** (§2.17a)
【가드】참가 `for update`+세션 → owner → assert_session_status → status = confirmed.
【쓰기】→ attended. active entry_pass 있으면 → used(used_at, scanned_by). **없으면 skip — A7 운영자 자기참가 경로.**

### 0009 결제·환불

**2.9 `submit_payment(p_participation_id uuid, p_sender_name text, p_amount numeric, p_receipt_path text) → jsonb{success, paymentSubmissionId}`**
【가드】참가 `for update`+세션 → **본인만** → assert_session_status → payment_method = 'pre_transfer'(seam) → status = awaitingPayment → `p_amount = game_fee`(불일치 failed-precondition) → receipt_path가 `receipts/{participation_id}/` 접두인지 + **storage.objects에 해당 객체 존재·owner = uid 검증**(Firebase에서 못 하던 업로더 검증이 SQL 조인으로 가능 — `storage.objects where bucket_id='receipts' and name=p_receipt_path and owner=auth.uid()`).
【쓰기】payment_submissions INSERT(pending) + 참가 → paymentReview.

**2.10 `approve_payment(p_submission_id uuid) → jsonb{success, participationId}`** ★flagship
【가드】제출 `for update` → 참가 `for update` → 세션 `for update` → owner → assert_session_status → submission = pending → 참가 = paymentReview → 정원(`confirmed_count < capacity`).
【쓰기】submission → approved(reviewed_by/at) · 참가 → confirmed · `confirmed_count+1` · 도달 시 세션 → closed · **같은 트랜잭션에서 EntryPass 발급**(구 onParticipationConfirmed 트리거 대체): active 패스 없으면 §3.13 `issue_entry_pass()` 호출.
【알림】`payment.decision`(approved) + `participation.confirmed` — 2건.

**2.11 `reject_payment(p_submission_id uuid, p_reason text) → jsonb{success}`**
【가드】owner → submission = pending → 참가 = paymentReview. 【쓰기】submission → rejected(rejection_reason) · 참가 → awaitingPayment(재제출 — A6: 보류상태 없음). 【알림】`payment.decision`(rejected, reason).

**2.12 `request_refund(p_participation_id uuid, p_bank_name text, p_account_number text, p_account_holder text, p_reason text default null) → jsonb{success, refundRequestId}`**
【가드】참가 `for update`+세션 → 본인만 → status = cancelled → `now() < cancel_deadline`(A4/§10.3) → confirmed 이력(= approved payment_submission 존재) → 중복은 UNIQUE(participation_id)가 잡음.
【쓰기】`account_number_encrypted = pgp_sym_encrypt(p_account_number, vault_secret('refund_account_key'))` — **평문을 RAISE/RETURN/로그 어디에도 노출 금지.** INSERT(requested) + 참가 → refundRequested.
※ `process_refund`는 **구현하지 않음**(A3 — 접수까지. v2에서 복호화 `pgp_sym_decrypt` RPC와 함께 활성화).

### 0010 QR (§3.13 공용 헬퍼 포함)

```sql
-- 토큰 규약(green-backend lib/qr.ts와 동일 직렬화): 'id|session|user|issued_ms|version'
build_entry_pass_token(...) : encode(hmac(serialized, vault_secret('qr_hmac_secret'), 'sha256'), 'base64')
hash_entry_pass_token(token): encode(digest(token, 'sha256'), 'hex')
issue_entry_pass(participation, session) : INSERT active, expires_at = starts_at + 24h, qr_token_hash = hash(build(...))
```
issued_at은 `now()` 확정값을 변수로 잡아 INSERT와 해시 계산에 **동일 값** 사용(재계산 재현성 — Wave 2 §1.1 원칙 유지).

**2.13 `get_entry_pass_token(p_session_id uuid) → jsonb{entryPassId, token, expiresAt}`** (read-only)
【가드】본인 참가 조회(not-found) → status confirmed → active 패스 존재(없으면 failed-precondition "미발급") → 만료 검사.
【반환】저장 필드(issued_at, version)로 토큰 **재계산** 반환. 쓰기 없음.

**2.14 `scan_entry_pass(p_entry_pass_id uuid, p_token text) → jsonb{success, userId, displayName}`**
【가드】패스 `for update`(not-found) → 참가 `for update`+세션+유저 로드 → owner → assert_session_status → `hash(p_token) = qr_token_hash`(불일치 failed-precondition "유효하지 않은 QR") → status active → 미만료 → 참가 = confirmed.
【쓰기】패스 → used(used_at, scanned_by) · 참가 → attended.

## 3. 스케줄 함수 (0012에서 cron 등록 — 로직은 여기 정의)

**`fn_status_transition()`** (매시): 한 문장씩의 UPDATE 3개 — recruiting&정원참→closed / recruiting·closed&starts_at≤now→inProgress / inProgress&(ends_at≤now or starts_at+24h≤now)→completed. 순수 SQL이라 멱등.
**`fn_send_reminders()`** (매 30분): 대상 = status∈{recruiting,closed} · starts_at ∈ [now+23.5h, now+24.5h] · reminder_sent=false. 세션별: `update ... set reminder_sent=true where id=... and reminder_sent=false returning *`(선마킹) → confirmed 참가자 전원 notify(`session.upcoming_reminder`).

## 4. 알림 이벤트 표 (api-spec §4.1 6종 유지)

| type | 발신 RPC | 수신 |
|------|----------|------|
| participation.decision | approve/reject_participation | 참가자 |
| payment.requested | approve_participation | 참가자 |
| payment.decision | approve/reject_payment | 참가자 |
| participation.confirmed | approve_payment | 참가자 |
| session.upcoming_reminder | fn_send_reminders | 확정 참가자 전원 |
| session.changed | update/cancel_game_session | 확정(updated)/전이 대상(cancelled) |

## 5. pgTAP 테스트 이식 목록 (S2 완료 기준 — 기존 vitest 54건 시나리오 대응)

1. 가드: 각 RPC × {미인증, 타인, 운영자, 본인} 권한 매트릭스.
2. 상태 화이트리스트: 각 op × 세션 5상태(§1.2 표 그대로).
3. 정원: approve_payment/join_as_operator 정원 초과 거부 · 도달 시 closed 전이 · cancel_participation 시 -1과 closed→recruiting 복귀.
4. 중복: 재신청 23505, 환불 중복, active 패스 partial unique.
5. A7: join_as_operator 즉시 confirmed·패스 미발급 / mark_attendance 패스 없이 동작.
6. QR: 토큰 재계산 일치, 위조 토큰 거부, 만료·재사용 거부.
7. 환불: 마감 후 거부, confirmed 이력 없이 거부, 암호문 저장(평문 불일치) 확인.
8. 상태전이 함수: 3전이 각각 + 멱등(2회 호출 무변화).
9. 알림: 각 이벤트 후 notifications 행 생성(수신자·type).
