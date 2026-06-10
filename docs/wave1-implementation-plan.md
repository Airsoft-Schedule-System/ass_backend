# Wave 1 구현 설계 — A1–A8 확정 후 콜러블 확장

| 항목 | 내용 |
|------|------|
| 작성 | Claude (설계) → Codex (구현) |
| 작성일 | 2026-06-10 |
| 선행 | GREEN 완료(`green-scope-implementation-plan.md`), A1–A8 확정(`../../ass_knowledge/decisions/2026-06-09-product-decisions-A1-A8.md`) |
| 기준 | `../../ass_knowledge/api/api-spec-v2.md`(A7 갱신본) · `erd-v2.md` · `api/fe-be-contract-v2.md` |
| 범위 | joinAsOperator(A7) · submitPayment(A2) · cancelParticipation(A4) · requestRefund(A3) · updateGameSession · cancelGameSession · scheduledStatusTransition |
| 범위 외 | QR 일체(A5)·알림 실발신(A8)·processRefund(비활성)·onParticipationConfirmed — 2차 웨이브 |

## 0. 공통 규칙 (기존 GREEN과 동일)

- v2 onCall, `{ region: REGION }`. 진입부 `requireAuth` → 입력 검증 → (필요 시 B1-6 프로필 검증) → `db.runTransaction`.
- 권한은 `lib/permissions`(B3-1), 상태가드는 `lib/guards`(B1-2), 상태 리터럴은 `lib/status`, 컬렉션명은 `lib/collections`, 에러는 `lib/errors`만 사용. 직접 문자열 금지.
- 트랜잭션: 모든 read를 write보다 먼저. 알림은 **트랜잭션 커밋 후** `notifier`(Noop) seam으로.
- 주석·에러 메시지는 기존 파일과 같은 한국어 톤. 파일당 1콜러블, `functions/index.ts` 배럴 + 루트 `index.ts` export, TODO 주석에서 구현된 항목 제거.
- 검증: `npm run build`(tsc) · `npm test`(vitest) · `npm run lint`(eslint, --max-warnings 기준 기존과 동일) 모두 통과.

## 1. 공유 코드 변경 (콜러블보다 먼저)

### 1.1 `lib/guards.ts` — GuardedOperation 확장
```
joinAsOperator:        [RECRUITING]
submitPayment:         [RECRUITING, CLOSED]
updateGameSession:     [RECRUITING, CLOSED, IN_PROGRESS]   // = completed/cancelled 제외
cancelGameSession:     [RECRUITING, CLOSED, IN_PROGRESS]
```
(cancelParticipation은 세션상태 가드 없음 — 참가상태로만 제한.)

### 1.2 `lib/time.ts` (신규) — Timestamp 변환 헬퍼
`createGameSession.ts`의 로컬 `toTimestamp(value, field)`를 그대로 이동(시그니처 유지), createGameSession은 import로 교체. updateGameSession(cancelDeadline)에서 재사용.

### 1.3 `lib/policy.ts` (신규) — 순수 정책 함수 (단위테스트 대상)
```ts
// §10.3 / A4: 환불 자격 = 이전 상태 confirmed && 마감 전
isRefundEligible(previousStatus: ParticipationStatus, cancelDeadlineMs: number, nowMs: number): boolean

// §2.5: 세션 상태 자동 전이 판정 (한 단계만 반환, 없으면 null)
//  recruiting && confirmedCount >= capacity            -> closed
//  (recruiting|closed) && startsAtMs <= now            -> inProgress
//  inProgress && (endsAtMs ?? startsAtMs+24h) <= now   -> completed
nextSessionStatus(s: { status; confirmedCount; capacity; startsAtMs; endsAtMs: number|null }, nowMs): GameSessionStatus | null

// cancelParticipation 허용 이전 상태 (rejected/attended/cancelled/refundRequested 불가)
CANCELLABLE_PARTICIPATION_STATUS: ReadonlySet<ParticipationStatus> // {pendingApproval, awaitingPayment, paymentReview, confirmed}
```

### 1.4 `lib/crypto.ts` (신규) — 환불 계좌 암호화 (A3)
- node:crypto AES-256-GCM. 키 = `sha256(secretValue)` 32바이트(시크릿 길이 무관).
- `encryptRefundAccount(plain: string, secretValue: string): string` → `"v1:<iv b64>:<ct b64>:<tag b64>"`.
- `decryptRefundAccount(encoded: string, secretValue: string): string` — processRefund(후속)·테스트용. 위변조 시 throw.

### 1.5 `lib/validation.ts` — 세션 업데이트 검증 (순수)
```ts
// §2.3: allow-list 검증. 반환 = 적용할 필드명 배열.
// - 허용: title, customRules, cancelDeadline, capacity, gameFee, endsAt
// - 금지(IMMUTABLE_SESSION_FIELDS 포함) 또는 미지의 키 → invalid-argument
// - capacity: 증가만(new > old) 그리고 new >= confirmedCount
// - gameFee: confirmedCount === 0 일 때만 변경 가능(확정자 발생 후 금액 변경 금지)
// - customRules: session.presetId != null 이면 failed-precondition (MVP에서 프리셋→커스텀 전환 미지원)
// - cancelDeadline: 호출부에서 Timestamp 변환 후 ms로 전달. startsAt-7d <= cancelDeadline <= startsAt-24h (A4 조정 허용 범위)
validateSessionUpdates(updates: Record<string, unknown>, session: { capacity; confirmedCount; presetId; startsAtMs }, cancelDeadlineMs?: number): string[]
```
※ title/endsAt 타입 검증 포함(title 비공백 문자열, endsAt은 startsAt 이후).

### 1.6 `types/functions.ts` — A7 타입 추가
```ts
// 2.6a joinAsOperator (A7 — 운영자 자기 게임 참가, 자동확정)
export interface JoinAsOperatorInput { gameSessionId: string; }
export interface JoinAsOperatorOutput { success: true; participationId: string; status: "confirmed"; }
```

## 2. 콜러블 명세

### 2.1 `functions/participation/joinAsOperator.ts` (A7)
- Caller: **세션 운영자 본인**. 흐름:
  1. `requireAuth` → `gameSessionId` 검증 → B1-6 프로필 검증(requestParticipation과 동일).
  2. tx: 세션 read(없으면 not-found) → `assertSessionOwner`(운영자가 아니면 permission-denied) → `assertSessionStatusAllows("joinAsOperator")` → 중복 참가 검사(gameSessionId+userId, already-exists) → `assertCapacityAvailable`(B1-1).
  3. participation 생성: `status: CONFIRMED`(승인·결제 면제 — A7 자동확정), `gameStartsAt` denormalize, `entryPassId: null`.
  4. 세션 update: `confirmedCount: increment(1)`, `reachesCapacityAfterIncrement` && recruiting → `closed` (approvePayment와 동일 패턴).
- 알림 없음(자기 자신). EntryPass 미발급(2차 — onParticipationConfirmed 도입 시 운영자 self-참가는 발급 제외 or 발급해도 self-scan 미사용. 트리거 설계 시 재논의 주석).
- `requestParticipation.ts`의 owner 거부 메시지를 안내형으로 교체: `"본인이 만든 세션에는 일반 신청 대신 운영자 참가(joinAsOperator)를 사용하세요"`. 로직 불변(owner는 여전히 requestParticipation 불가).

### 2.2 `functions/payment/submitPayment.ts` (A2 — §2.10)
1. 입력: `participationId`·`senderName` 비공백, `amount` number, `receiptImageUrl`은 `paymentReceipts/` 접두 필수(invalid-argument). ※업로더 본인 검증(§3.5)은 Storage 메타데이터 조회 필요 → MVP에서는 경로 검증까지, 본검증은 후속 `getReceiptUrl` 계열과 함께(주석으로 명시).
2. tx: participation read → `isParticipant`가 아니면 permission-denied(본인만) → session read → `assertSessionStatusAllows("submitPayment")` → `isPreTransfer(session.paymentMethod)` seam 확인(false면 failed-precondition) → `participation.status === AWAITING_PAYMENT`(아니면 failed-precondition) → `amount === session.gameFee`(아니면 failed-precondition).
3. paymentSubmissions 생성(ERD §5.8 전 필드: status PENDING, submittedAt serverTimestamp, reviewedBy/reviewedAt/rejectionReason null, gameSessionId·userId denormalize) + participation → `PAYMENT_REVIEW`.
4. 알림 없음(§2.10 — payment.submitted 제거됨). Output `{ success: true, paymentSubmissionId }`.

### 2.3 `functions/participation/cancelParticipation.ts` (A4 — §2.9, tx)
1. 입력: `participationId`, `reason?`(ERD에 저장 필드 없음 — 수신만 하고 미저장, 주석으로 명시).
2. tx: participation read → session read → `assertParticipantOrOwner`(본인 또는 운영자) → 이전 상태가 `CANCELLABLE_PARTICIPATION_STATUS`에 없으면 failed-precondition.
3. `refundEligible = isRefundEligible(prevStatus, session.cancelDeadline.toMillis(), Date.now())`.
4. 쓰기: participation → `CANCELLED`. prevStatus가 `CONFIRMED`였다면 추가로:
   - 세션 `confirmedCount: increment(-1)`,
   - 세션이 `CLOSED`였다면 → `RECRUITING`(자리 복귀),
   - `participation.entryPassId != null`이면 해당 entryPasses 문서 status가 `active`일 때 → `revoked`(방어적 — 현재는 발급 주체가 없어 null임).
5. Output `{ success: true, refundEligible }`. 알림 없음(§2.9).

### 2.4 `functions/refund/requestRefund.ts` (A3 — §2.13)
- onCall 옵션에 `secrets: [REFUND_ACCOUNT_KEY]` 선언(runtime.ts에 정의돼 있음).
1. 입력: `participationId`·`bankName`·`accountNumber`·`accountHolder` 비공백, `reason?`.
2. tx 전 read 순서 주의(모두 tx 내 read 먼저): participation → `isParticipant` 본인만 → `status === CANCELLED` → session read(cancelDeadline) → `Date.now() < cancelDeadline`(아니면 failed-precondition, §10.3) → confirmed 이력: `paymentSubmissions where participationId==X && status==APPROVED limit 1` 존재(없으면 failed-precondition) → 중복: `refundRequests where participationId==X limit 1` 없음(already-exists).
3. `accountNumber`는 `encryptRefundAccount(plain, REFUND_ACCOUNT_KEY.value())`로 암호화 저장. **평문 로그 금지.**
4. refundRequests 생성(ERD §5.9 전 필드: status REQUESTED, requestedAt serverTimestamp, processedBy/processedAt/note null, reason ?? null, denormalize) + participation → `REFUND_REQUESTED`.
5. Output `{ success: true, refundRequestId }`. 알림 없음(§2.13). processRefund는 **구현하지 않음**(index.ts TODO 유지 — A3 접수까지).

### 2.5 `functions/session/updateGameSession.ts` (§2.3)
1. 입력: `gameSessionId`, `updates`(object). `updates.cancelDeadline` 있으면 `toTimestamp` 변환.
2. tx: session read → `assertSessionOwner` → `assertSessionStatusAllows("updateGameSession")` → `validateSessionUpdates(...)` → 통과 필드만 update(+`updatedAt`).
3. tx 후: `capacity` 증가 또는 `customRules` 변경이 포함됐다면 confirmed 참가자 전원에게 `session.changed`(type `'updated'`) envelope → `notifier.sendMany` (참가자 조회: participations where gameSessionId==X && status==CONFIRMED — tx 밖 일반 쿼리).
4. Output `{ success: true, updatedFields }`.

### 2.6 `functions/session/cancelGameSession.ts` (§2.4, tx)
1. tx: session read → `assertSessionOwner` → `assertSessionStatusAllows("cancelGameSession")` → tx 내 read: pre-terminal 참가 쿼리(`gameSessionId==X && status in [PENDING_APPROVAL, AWAITING_PAYMENT, PAYMENT_REVIEW, CONFIRMED]`) + active EntryPass 쿼리(`gameSessionId==X && status==ACTIVE`).
   - `refundRequested`는 이미 환불 파이프라인에 있으므로 건드리지 않음(설계 결정).
2. 쓰기: session → `CANCELLED`(+updatedAt), 조회된 participation 전부 → `CANCELLED`, EntryPass 전부 → `REVOKED`.
3. tx 후: 전이된 참가자들에게 `session.changed`(type `'cancelled'`, reason 포함 가능) envelope 발송.
4. Output `{ success: true, affectedParticipations: n }`. ※MVP 규모(정원 수십)에서 tx 500 write 한도 문제 없음 — 주석으로 한도 명시.

### 2.7 `functions/scheduled/statusTransition.ts` (§2.5)
- `onSchedule({ schedule: "every 1 hours", timeZone: "Asia/Seoul", region: REGION })` (`firebase-functions/v2/scheduler`).
- 흐름(읽기는 일반 쿼리, 전이는 세션별 개별 tx로 멱등):
  1. `status == RECRUITING` 전체 → 메모리에서 `confirmedCount >= capacity` 필터 → closed 후보.
  2. `status in [RECRUITING, CLOSED] && startsAt <= now` (기존 인덱스 `gameSessions(status,startsAt)` 사용 — status는 ==로 두 번 쿼리) → inProgress 후보.
  3. `status == IN_PROGRESS` 전체 → 메모리에서 `(endsAt ?? startsAt+24h) <= now` 필터 → completed 후보.
  4. 각 후보를 개별 `runTransaction`: 재read 후 `nextSessionStatus(...)` 재판정이 같을 때만 update(+updatedAt). 실패는 `console.error`로 세션 id와 함께 기록하고 계속.
- 신규 인덱스 불필요(status+startsAt 복합 인덱스 기존 보유).

## 3. 배럴/엔트리

- `functions/index.ts`: joinAsOperator·submitPayment·cancelParticipation·requestRefund·updateGameSession·cancelGameSession export 추가.
- 루트 `index.ts`: 위 6개 + `scheduledStatusTransition` export. TODO 주석에서 구현분 제거 → 잔여: `processRefund(A3 비활성), getEntryPassToken, scanEntryPass, markAttendance, onParticipationConfirmed, scheduledReminder`(2차).

## 4. 테스트 (vitest, 기존 `__tests__/` 컨벤션 — HttpsError code 검사 패턴)

신규 파일: `policy.test.ts`, `crypto.test.ts`, (validation·guards는 기존 파일에 추가)
1. guards: 신규 4개 operation의 화이트리스트 — 허용/차단 상태 각 1+.
2. policy.isRefundEligible: confirmed+마감 전 true / confirmed+마감 후 false / 비confirmed false.
3. policy.nextSessionStatus: 정원도달→closed, startsAt 경과→inProgress(recruiting·closed 양쪽), endsAt 경과→completed, endsAt null이면 startsAt+24h, 전이 없음→null.
4. policy.CANCELLABLE_PARTICIPATION_STATUS: 4개 허용·4개 차단.
5. crypto: 암호화→복호화 라운드트립, 다른 키/위변조 ct 복호화 실패, 출력 포맷 `v1:` 접두.
6. validation.validateSessionUpdates: 허용 필드 통과, `startsAt`/`status`/미지 키 invalid-argument, capacity 감소 거부·confirmedCount 미만 거부, gameFee는 confirmedCount>0이면 거부, presetId 세션의 customRules 거부, cancelDeadline 범위(7d~24h) 밖 거부.
- 기존 24개 테스트 무손상.

## 5. 완료 기준

1. `npm run build` / `npm test`(기존 24 + 신규 전부) / `npm run lint` 통과.
2. 모든 신규 콜러블이 §0 공통 규칙(중앙화 lib 사용, tx read-before-write, 커밋 후 알림) 준수.
3. requestParticipation의 owner 분기 메시지 갱신 외에 기존 GREEN 콜러블 동작 불변.
4. 평문 계좌번호가 로그·저장 어디에도 남지 않음.
