# ASS 백엔드 GREEN 범위 구현 설계서

| 항목 | 내용 |
|------|------|
| 작성 | Claude Code (구조 설계) — 구현은 Codex |
| 작성일 | 2026-05-29 |
| 상태 | 구현 사양 (Codex 작업 지시서 겸용) |
| 범위 | `mvp-review-action-items.md` 파트 B 중 **착수 가능(GREEN)** = BE 단독 B1-1·B1-2·B1-5·B1-6 + 공통 B3-1·B3-3 |
| 기준 SoT | `../ass_knowledge/database/erd-v2.md`, `../ass_knowledge/api/api-spec-v2.md`, `../ass_knowledge/decisions/2026-05-25-backend-decision-v1.md` |

> 이 문서는 **구조/설계**다. 시그니처·책임·규칙·인덱스를 확정하되, 함수 본문 구현은 Codex가 채운다.
> 역할 분담: **구조 = Claude**, **코드 = Codex**.

---

## 0. 범위 (Scope)

### 포함 (이번 착수)
| ID | 내용 | 산출물 위치 |
|----|------|------------|
| B1-1 | `approvePayment` 정원 가드 | `lib/guards.ts` + `functions/payment/approvePayment.ts` |
| B1-2 | 운영 mutation 세션상태 가드 | `lib/guards.ts` + 각 콜러블 |
| B1-5 | 보안규칙 ↔ 쿼리 ↔ 인덱스 정합 | `firestore.rules`, `firestore.indexes.json`, `storage.rules` |
| B1-6 | 프로필 필수값 서버 검증 | `lib/validation.ts` + `createGameSession`/`requestParticipation` |
| B3-1 | 권한 판단 중앙화 | `lib/permissions.ts` + `firestore.rules` helper |
| B3-3 | 확장성 seam 유지 규칙 | `lib/seams.ts`, `notifications/notifier.ts`, `lib/status.ts` + §9 |

### 제외 (이번 착수 아님 — 사유)
- **B3-2** 상태/이벤트 enum *교차 레포 공유 패키지* — 선행 A6(상태 수 확정). 단, **BE 내부 상수**는 `lib/status.ts`로 중앙화(=B3-3 seam). 공유 패키지화만 보류.
- **B1-3** `markAttendance` — 선행 A5.
- **B1-4** `notifications` 컬렉션 영속화 — 선행 A8. (단 Notifier seam은 미리 둔다.)
- **실 FCM 발신 구현** — `NoopNotifier`로 seam만 확보, 실제 전송은 후속.
- A-의존 함수 본문: `cancelGameSession`/`cancelParticipation`/`submitPayment`/`requestRefund`/`processRefund`/`scanEntryPass`/`getEntryPassToken`/`onParticipationConfirmed`/`scheduled*`/`updateGameSession` — **index.ts에 TODO 주석으로만 명시**, 본문 미구현.

### 이번에 구현할 콜러블 (가드를 실제로 품는 최소 집합)
`onUserCreate`(트리거), `createGameSession`, `requestParticipation`, `approveParticipation`, `approvePayment`(B1-1 flagship), `rejectParticipation`, `rejectPayment`.
→ 이들은 모두 A-비의존이며 FCM은 Notifier seam으로 분리하므로 GREEN-safe.

---

## 1. 기술 전제 (backend-decision-v1 기준)

| 항목 | 결정 |
|------|------|
| 런타임 | Node.js 20, TypeScript |
| 콜러블 | `firebase-functions/v2/https` `onCall` |
| Auth 트리거 | `onUserCreate` 는 Gen1 `firebase-functions/v1` `functions.auth.user().onCreate()` (v2에 Auth onCreate 없음) |
| 시크릿 | `firebase-functions/params` `defineSecret('QR_HMAC_SECRET')`, `defineSecret('REFUND_ACCOUNT_KEY')` — 이번 범위 함수는 미사용이나 `config/runtime.ts`에 정의만 둠 |
| 리전 | **`asia-northeast3`(서울)** 기본값 (한국 사용자) — `config/runtime.ts` 한 곳에서 관리. ※ 미확정 기본값, 추후 조정 가능 |
| 에러 | `HttpsError`(`firebase-functions/v2/https`) — 코드 매핑은 api-spec §1.4 |
| 테스트 | **Vitest** (순수 lib 단위 테스트 중심; Jest 사용해도 무방) |
| 린트 | ESLint + `@typescript-eslint` (flat config) |

---

## 2. 디렉토리 트리

```
ass_backend/
├── firebase.json
├── .firebaserc                      # default = "ass-mvp-PLACEHOLDER" (실 project id 커밋 금지)
├── .gitignore
├── firestore.rules                  # B1-5 + B3-1
├── firestore.indexes.json           # B1-5 (ERD §8, 8개)
├── storage.rules                    # B1-5 (api-spec §3.3)
├── README.md                        # (기존) 빌드/배포/에뮬레이터 메모 추가
├── AGENTS.md                        # (기존) 유지
├── docs/
│   └── green-scope-implementation-plan.md   # (본 문서)
└── functions/
    ├── package.json
    ├── tsconfig.json
    ├── vitest.config.ts
    ├── eslint.config.js
    ├── .gitignore                   # lib/ (컴파일 산출물), node_modules, .env*
    └── src/
        ├── index.ts                 # 콜러블 export 배럴 + 미구현 함수 TODO 목록
        ├── config/
        │   └── runtime.ts           # region, runtime opts, defineSecret, db 핸들
        ├── types/                   # api-spec §6 / ERD §5 전사(transcription)
        │   ├── common.ts            # §6.1
        │   ├── status.ts            # §6.2 (union 타입)
        │   ├── entities.ts          # ERD §5 (10개 엔티티)
        │   ├── functions.ts         # §6.3 (콜러블 I/O — 18개 모두 전사 OK)
        │   └── events.ts            # §6.4 (FCM 6개 envelope)
        ├── lib/
        │   ├── errors.ts            # HttpsError 팩토리 (코드별)
        │   ├── permissions.ts       # B3-1: 권한 판단 단일 출처(BE측)
        │   ├── status.ts            # B3-3: 상태 상수 객체 + 전이/터미널 테이블
        │   ├── guards.ts            # B1-1 정원 가드 + B1-2 세션상태 화이트리스트
        │   ├── validation.ts        # B1-6: 프로필 필수값 + 입력 검증 헬퍼
        │   ├── collections.ts       # 컬렉션명 상수 + 타입드 ref 헬퍼
        │   └── seams.ts             # B3-3: paymentMethod/EntryPass/denormalization seam
        ├── notifications/
        │   └── notifier.ts          # B3-3: Notifier 인터페이스 + NoopNotifier
        ├── triggers/
        │   └── onUserCreate.ts      # users/{uid} 문서 생성 (B1-6 전제: 프로필 존재)
        └── functions/
            ├── session/
            │   └── createGameSession.ts      # B1-6
            ├── participation/
            │   ├── requestParticipation.ts   # B1-6 + 본인세션 금지
            │   ├── approveParticipation.ts   # B1-2
            │   └── rejectParticipation.ts    # B1-2
            └── payment/
                ├── approvePayment.ts         # B1-1 (flagship) + B1-2
                └── rejectPayment.ts          # B1-2
        └── __tests__/
            ├── permissions.test.ts
            ├── guards.test.ts
            ├── validation.test.ts
            └── status.test.ts
```

---

## 3. lib 모듈 명세 (순수·테스트 가능 우선)

> 원칙: lib/*는 **Firestore I/O 없이** 순수 함수로 작성(데이터는 인자로 주입). 그래야 단위 테스트가 쉽고 콜러블/트리거/규칙이 같은 규칙을 공유한다.

### 3.1 `lib/errors.ts`
api-spec §1.4 코드별 팩토리. 메시지는 한국어.
```ts
export const errUnauthenticated   = (m='로그인이 필요합니다') => new HttpsError('unauthenticated', m);
export const errPermissionDenied  = (m='권한이 없습니다') => new HttpsError('permission-denied', m);
export const errNotFound          = (m='대상을 찾을 수 없습니다') => new HttpsError('not-found', m);
export const errInvalidArgument   = (m: string) => new HttpsError('invalid-argument', m);
export const errFailedPrecondition= (m: string) => new HttpsError('failed-precondition', m);
export const errAlreadyExists     = (m: string) => new HttpsError('already-exists', m);
```

### 3.2 `lib/permissions.ts` — B3-1 (권한 중앙화)
> "createdByUserId === uid 를 흩지 말 것." BE측 단일 출처. 추후 admin/FM/전역GM 추가 시 **여기 + firestore.rules** 두 곳만 수정.
```ts
export interface SessionOwnerView { createdByUserId: string; }
export interface ParticipantView { userId: string; }

export function isSessionOwner(s: SessionOwnerView, uid: string): boolean;
export function isParticipant(p: ParticipantView, uid: string): boolean;

// 콜러블 진입부 표준 가드
export function requireAuth(auth: { uid?: string } | undefined): string;          // 없으면 errUnauthenticated, 있으면 uid 반환
export function assertSessionOwner(s: SessionOwnerView, uid: string): void;        // 아니면 errPermissionDenied
export function assertParticipantOrOwner(p: ParticipantView, s: SessionOwnerView, uid: string): void;
```

### 3.3 `lib/status.ts` — B3-3 seam (BE 내부 상수 중앙화)
> `'recruiting'` 같은 리터럴을 함수마다 하드코딩 금지. 여기서만 정의.
> **B3-2와의 경계**: 교차 레포(FE/BE) 공유 패키지는 A6 확정 후(B3-2). 지금은 BE 내부 상수만.
```ts
export const SESSION = { RECRUITING:'recruiting', CLOSED:'closed', IN_PROGRESS:'inProgress', COMPLETED:'completed', CANCELLED:'cancelled' } as const;
export const PARTICIPATION = { PENDING_APPROVAL:'pendingApproval', REJECTED:'rejected', AWAITING_PAYMENT:'awaitingPayment', PAYMENT_REVIEW:'paymentReview', CONFIRMED:'confirmed', CANCELLED:'cancelled', REFUND_REQUESTED:'refundRequested', ATTENDED:'attended' } as const;
export const PAYMENT_SUBMISSION = { PENDING:'pending', APPROVED:'approved', REJECTED:'rejected' } as const;
export const ENTRY_PASS = { ACTIVE:'active', USED:'used', REVOKED:'revoked', EXPIRED:'expired' } as const;
export const REFUND = { REQUESTED:'requested', APPROVED:'approved', COMPLETED:'completed', REJECTED:'rejected' } as const;

export const TERMINAL_SESSION = new Set([SESSION.COMPLETED, SESSION.CANCELLED]);
export const PAYMENT_METHOD = { PRE_TRANSFER:'pre_transfer' } as const;  // §10.1, seam: 현장결제 대비
```
union 타입은 `types/status.ts`에서 import (이중 정의 금지 — 상수→타입 파생).

### 3.4 `lib/guards.ts` — B1-1 + B1-2
```ts
// ── B1-1: 정원 가드 (approvePayment 트랜잭션 내부에서 호출) ──
export function assertCapacityAvailable(s: { confirmedCount: number; capacity: number }): void;
//   confirmedCount >= capacity → errFailedPrecondition('정원이 가득 찼습니다')
export function reachesCapacityAfterIncrement(s: { confirmedCount: number; capacity: number }): boolean;
//   (confirmedCount + 1) >= capacity  → true 면 호출부에서 status=closed 전이

// ── B1-2: 운영 mutation 세션상태 화이트리스트 ──
export type GuardedOperation =
  | 'requestParticipation' | 'approveParticipation' | 'rejectParticipation'
  | 'approvePayment' | 'rejectPayment';

export const OPERATION_SESSION_WHITELIST: Record<GuardedOperation, ReadonlyArray<SessionStatus>> = {
  requestParticipation: [SESSION.RECRUITING],
  approveParticipation: [SESSION.RECRUITING, SESSION.CLOSED],
  rejectParticipation:  [SESSION.RECRUITING, SESSION.CLOSED],
  approvePayment:       [SESSION.RECRUITING, SESSION.CLOSED],
  rejectPayment:        [SESSION.RECRUITING, SESSION.CLOSED],
};
export function assertSessionStatusAllows(op: GuardedOperation, s: { status: SessionStatus }): void;
//   화이트리스트 밖이면 errFailedPrecondition(`현재 세션 상태(${s.status})에서는 ${op}를 할 수 없습니다`)
```
근거: 검토 문서 B1-2 — `inProgress/completed/cancelled` 이후 승인·확정 차단. `requestParticipation`은 `recruiting`만(api-spec §2.6 검증 1).

### 3.5 `lib/validation.ts` — B1-6
```ts
export const REQUIRED_PROFILE_FIELDS = ['displayName'] as const;   // ERD §5.1: displayName required, phoneNumber nullable
export function isProfileComplete(u: { displayName?: string | null }): boolean; // displayName trim 비어있지 않음
export function assertProfileComplete(u: { displayName?: string | null }): void; // 아니면 errFailedPrecondition('프로필(닉네임)을 먼저 완성해주세요')

// createGameSession 입력 검증 (api-spec §2.2)
export function assertCreateGameSessionInput(input): void;
//   1) fieldId XOR fieldName(정확히 하나)  2) startsAt 미래  3) capacity>0, gameFee>=0  4) presetId XOR customRules
//   위반 시 errInvalidArgument(구체 메시지)
```
근거: 검토 B1-6 — `onUserCreate`가 만든 user는 이메일가입 시 displayName이 빌 수 있음 → 서버 선검증.

### 3.6 `lib/collections.ts`
```ts
export const COL = { users:'users', teams:'teams', fields:'fields', gameRulePresets:'gameRulePresets',
  gameSessions:'gameSessions', participations:'participations', paymentSubmissions:'paymentSubmissions',
  refundRequests:'refundRequests', entryPasses:'entryPasses' } as const;
// 타입드 DocumentReference 헬퍼(선택): sessionRef(db,id) 등. FirestoreDataConverter는 과설계 지양, 최소만.
```

### 3.7 `lib/seams.ts` — B3-3 (확장성 seam)
주석/구조로 seam을 명시 (검토 B3-3 항목 1:1 대응):
```ts
// (a) paymentMethod 분기 seam: 현재 PRE_TRANSFER 단일. 결제수단 비교/분기는 이 헬퍼 경유.
export function isPreTransfer(method: string): boolean;
// (b) EntryPass 발급 트리거 단일화: EntryPass 생성은 onParticipationConfirmed 단 한 곳에서만(주석 규칙 + 본 범위 외).
// (c) denormalization 동기화 규칙: gameStartsAt 등은 startsAt 불변 전제. updateGameSession은 startsAt 변경 금지(api-spec §2.3 금지필드).
export const IMMUTABLE_SESSION_FIELDS = ['startsAt','createdByUserId','confirmedCount','status'] as const;
// (d) 알림 envelope 표준: notifications/notifier.ts 의 NotificationEnvelope 단일 형태.
```

---

## 4. Notifier seam — `notifications/notifier.ts` (B3-3)

실 FCM은 아직 안 만든다. 콜러블이 발신을 **호출만** 하도록 인터페이스를 둔다.
```ts
export interface NotificationEnvelope {
  type: string;            // 'payment.decision' 등 (api-spec §4)
  userId: string;          // 수신자
  title: string; body: string;
  actionUrl: string;
  data?: Record<string, string>;   // FCM string-only
  gameSessionId?: string; participationId?: string;
}
export interface Notifier {
  send(e: NotificationEnvelope): Promise<void>;
  sendMany(es: NotificationEnvelope[]): Promise<void>;
}
export class NoopNotifier implements Notifier { /* console.debug만, TODO: 실 FCM(B1-4/A8 이후) */ }
export const notifier: Notifier = new NoopNotifier();   // 단일 인스턴스, 후속 교체점
```
콜러블은 트랜잭션 **커밋 후** `notifier.sendMany([...])` 호출(트랜잭션 안에서 외부효과 금지).

---

## 5. 콜러블/트리거 명세 (Codex 구현)

> 공통 골격: `onCall({region}, async (req) => { const uid = requireAuth(req.auth); ... })`.
> 상태 전이 함수는 **모든 read를 트랜잭션 앞부분에서** 수행 후 write(파이어스토어 규칙). 멱등성: 현재 status가 기대값 아니면 `failed-precondition`(api-spec §1.6).

### 5.1 `triggers/onUserCreate.ts` (Gen1 Auth)
- api-spec §2.1. `users/{uid}` 생성: `{ displayName, email, phoneNumber, teamId:null, createdAt, lastActiveAt }`. `role` 필드 두지 않음. displayName은 provider 정보(없으면 ''로 둘 수 있음 → B1-6이 이후 가드).

### 5.2 `functions/session/createGameSession.ts` — B1-6
- api-spec §2.2. 입력 검증: `assertCreateGameSessionInput` + **`assertProfileComplete`(users/{uid} 읽어서)**.
- 생성: `status:'recruiting'`, `confirmedCount:0`, `createdByUserId:uid`, `paymentMethod:PRE_TRANSFER`. `cancelDeadline` 미지정 시 `startsAt - 48h`.
- 반환 `{ success:true, gameSessionId }`.

### 5.3 `functions/participation/requestParticipation.ts` — B1-6 + 본인세션 금지
- api-spec §2.6. 검증: **`assertProfileComplete`**, `assertSessionStatusAllows('requestParticipation', session)`(=recruiting), 본인 세션 아님(`!isSessionOwner`), (gameSessionId,userId) 중복 없음(`already-exists`).
- 생성: `status:'pendingApproval'`, `gameStartsAt: session.startsAt`(denormalized).
- 반환 `{ success:true, participationId, status:'pendingApproval' }`.

### 5.4 `functions/participation/approveParticipation.ts` — B1-2
- api-spec §2.7. 트랜잭션: participation+session read → `assertSessionOwner` → `assertSessionStatusAllows('approveParticipation', session)` → `participation.status === 'pendingApproval'` 확인 → `awaitingPayment` 전이.
- 커밋 후 Notifier: `participation.decision`(approved) + `payment.requested` (seam 통해, NoopNotifier).
- 반환 `{ success:true, newStatus:'awaitingPayment' }`.

### 5.5 `functions/participation/rejectParticipation.ts` — B1-2
- api-spec §2.8. `assertSessionOwner` + `assertSessionStatusAllows('rejectParticipation',·)` + `pendingApproval` 확인 → `rejected`. 커밋 후 `participation.decision`(rejected, reason). 반환 `{success:true}`.

### 5.6 `functions/payment/approvePayment.ts` — **B1-1 flagship** + B1-2
- api-spec §2.11 + §5.6.1. **Transaction(required)**:
  1. read paymentSubmission(없으면 not-found), participation, gameSession
  2. `assertSessionOwner(session, uid)` (B3-1)
  3. `assertSessionStatusAllows('approvePayment', session)` (B1-2)
  4. 멱등: `submission.status==='pending'` && `participation.status==='paymentReview'` 아니면 failed-precondition
  5. **`assertCapacityAvailable(session)` (B1-1 핵심)** — confirmedCount>=capacity면 거부
  6. write: submission→`approved`(+reviewedBy,reviewedAt), participation→`confirmed`, `confirmedCount = confirmedCount+1`
  7. `reachesCapacityAfterIncrement(session)` && `session.status==='recruiting'` → session.status=`closed`
- 커밋 후 Notifier: `payment.decision`(approved) + `participation.confirmed`.
- **EntryPass 생성은 여기서 하지 않음** — `onParticipationConfirmed` 트리거 담당(seam (b), 본 범위 외 / api-spec §2.15).
- 반환 `{ success:true, participationId }`.

### 5.7 `functions/payment/rejectPayment.ts` — B1-2
- api-spec §2.12. `assertSessionOwner` + `assertSessionStatusAllows('rejectPayment',·)` + `submission.status==='pending'` → submission `rejected`(+rejectionReason), participation `awaitingPayment`(재제출). 커밋 후 `payment.decision`(rejected, reason). 반환 `{success:true}`.

### 5.8 `index.ts`
- 위 7개 export. 하단에 **미구현 함수 11개 TODO 주석**(이름 + 선행 결정 표기): `updateGameSession`, `cancelGameSession`, `cancelParticipation`, `submitPayment`, `requestRefund`, `processRefund`, `getEntryPassToken`, `scanEntryPass`, `onParticipationConfirmed`, `scheduledStatusTransition`, `scheduledReminder`.

---

## 6. `firestore.indexes.json` — B1-5 (ERD §8, 8개)

> 방향은 FE orderBy와 일치해야 함(B1-5 "FE와 합의"). 아래는 기본값; FE 확정 시 조정/추가.

| # | collectionGroup | fields (order) |
|---|-----------------|----------------|
| 1 | gameSessions | status ASC, startsAt ASC |
| 2 | gameSessions | createdByUserId ASC, startsAt ASC |
| 3 | participations | userId ASC, gameStartsAt ASC |
| 4 | participations | gameSessionId ASC, status ASC, createdAt ASC |
| 5 | paymentSubmissions | gameSessionId ASC, status ASC, submittedAt ASC |
| 6 | refundRequests | gameSessionId ASC, status ASC, requestedAt ASC |
| 7 | entryPasses | userId ASC, gameSessionId ASC, status ASC |
| 8 | gameRulePresets | ownerId ASC, updatedAt DESC |

`{ "indexes": [ {collectionGroup, queryScope:"COLLECTION", fields:[{fieldPath,order}]}... ], "fieldOverrides": [] }`.

---

## 7. `firestore.rules` — B1-5 + B3-1

`rules_version='2'`. **helper 함수가 B3-1의 규칙측 단일 출처**(lib/permissions.ts와 의미 일치).

```
function isSignedIn()            { return request.auth != null; }
function selfUid()              { return request.auth.uid; }
function isSelf(userId)          { return isSignedIn() && request.auth.uid == userId; }
function sessionData(sid)        { return get(/databases/$(database)/documents/gameSessions/$(sid)).data; }
function isSessionOwner(sid)     { return isSignedIn() && sessionData(sid).createdByUserId == request.auth.uid; }
```

| 컬렉션 | read | create | update | delete |
|--------|------|--------|--------|--------|
| users/{uid} | isSelf | false (트리거가 Admin SDK로 생성) | isSelf **且 변경키 ⊆ {displayName,phoneNumber,teamId}** & role 추가 금지 | false |
| users/{uid}/fcmTokens/{iid} | isSelf(uid) | isSelf(uid) | isSelf(uid) | isSelf(uid) |
| gameSessions/{sid} | isSignedIn | false (콜러블) | false | false |
| participations/{id} | isSelf(res.userId) ∨ isSessionOwner(res.gameSessionId) | false | false | false |
| paymentSubmissions/{id} | isSelf(res.userId) ∨ isSessionOwner(res.gameSessionId) | false | false | false |
| refundRequests/{id} | isSelf(res.userId) ∨ isSessionOwner(res.gameSessionId) | false | false | false |
| entryPasses/{id} | isSelf(res.userId) ∨ isSessionOwner(res.gameSessionId) | false | false | false |
| teams/{id} | isSignedIn | false (시드/콘솔) | false | false |
| fields/{id} | isSignedIn | false | false | false |  ← B3-3: Field 엔티티 유지
| gameRulePresets/{id} | isSignedIn 且 (res.isPublic ∨ isSelf(res.ownerId)) | isSignedIn 且 req.ownerId==uid | isSelf(res.ownerId) | isSelf(res.ownerId) |
| /{document=**} | false | false | false | false |  ← 명시적 catch-all deny |

설계 의도(B1-5 핵심): participations 의 두 쿼리 형태가 **동시에** 성립.
- "내 신청": `where('userId','==',uid)` → read 규칙의 `isSelf` 분기 + 인덱스 #3.
- "세션 신청자": `where('gameSessionId','==',sid)` (sid는 호출자가 소유) → `isSessionOwner` 분기 + 인덱스 #4.
> Firestore 쿼리 보안: 클라이언트는 위 두 형태로만 질의(전체 컬렉션 스캔 불가). FE에 이 제약 공유.

서버 관리 컬렉션(gameSessions/participations/payment/refund/entryPasses)은 **클라 직접 쓰기 전면 금지** → 모든 전이는 콜러블(Admin SDK, 규칙 우회). 검토 B1-3 권고(수동 출석도 콜러블화)와 정합 → 수동 출석용 클라 직접 쓰기 경로는 두지 않음(A5 후 markAttendance 콜러블).

---

## 8. `storage.rules` — B1-5 (api-spec §3.3) + ⚠️ 한계

```
match /b/{bucket}/o {
  match /paymentReceipts/{paymentSubmissionId}/{filename} {
    allow create: if request.auth != null
      && request.resource.size < 5 * 1024 * 1024
      && request.resource.contentType.matches('image/(jpeg|png|webp)')
      && request.resource.metadata.uploaderId == request.auth.uid;
    allow read: if request.auth != null
      && resource.metadata.uploaderId == request.auth.uid;   // 업로더(본인)만
    allow update, delete: if false;
  }
  match /{all=**} { allow read, write: if false; }
}
```

⚠️ **명세 한계(보고 대상, §11)**: api-spec §3.3은 read에 `isSessionOwnerOfSubmission()`을 넣었으나 **Storage 규칙은 Firestore를 조회할 수 없다**. 따라서 "세션 운영자의 송금증 열람"은 Storage 규칙으로 강제 불가.
→ 본 구현은 read를 **업로더 본인**으로 한정. 운영자 열람은 후속 `getReceiptUrl` 콜러블(Admin SDK signed URL)로 처리. api-spec §3.3 수정 필요(§11에 기록).

---

## 9. B3-3 seam 체크리스트 (검토 문서 1:1)

| seam | 처리 |
|------|------|
| paymentMethod enum 분기(현장결제 대비) | `PAYMENT_METHOD` 상수 + `isPreTransfer()` 경유. 직접 `==='pre_transfer'` 금지 |
| EntryPass 발급 트리거 단일화 | 생성은 `onParticipationConfirmed`만(주석 규칙). approvePayment는 생성 안 함 |
| 알림 envelope/컬렉션 표준화 | `NotificationEnvelope` 단일 형태. 영속 컬렉션은 B1-4(A8) |
| Field 엔티티 유지 | fields 컬렉션 규칙 유지(읽기 전용) — 직접입력 병행해도 엔티티 보존 |
| denormalized 동기화("startsAt 변경 금지") | `IMMUTABLE_SESSION_FIELDS`에 startsAt 포함, updateGameSession(후속)에서 차단 |
| 역할 확장 대비(B3-1) | permissions.ts + rules helper 두 곳만 수정점 |

---

## 10. 설정 파일 요점

- **firebase.json**: `functions.source="functions"`, `functions.runtime="nodejs20"`, `firestore.rules/indexes`, `storage.rules`, emulators(auth/firestore/functions/storage/ui).
- **.firebaserc**: `{ "projects": { "default": "ass-mvp-PLACEHOLDER" } }`.
- **functions/package.json**: deps `firebase-admin`, `firebase-functions`; dev `typescript`, `vitest`, `eslint`, `@typescript-eslint/*`, `firebase-functions-test`(선택). scripts: `build`(tsc), `lint`, `test`(vitest run), `serve`(emulators).
- **functions/tsconfig.json**: `target ES2021`, `module commonjs`, `outDir lib`, `strict true`, `esModuleInterop true`.
- **.gitignore (루트+functions)**: `node_modules/`, `functions/lib/`, `.env`, `.env.*`, `*.local`, `.firebase/`, `serviceAccount*.json`, `*-key.json`. → **시크릿/로컬 env/자격증명 커밋 금지(AGENTS.md)**.

---

## 11. 구현 후 SoT 갱신 필요 (보고)

1. **api-spec §3.3 Storage read 규칙**: Firestore 조회 불가 → 운영자 열람은 콜러블 signed URL 방식으로 정정 필요.
2. (확인 요청) 인덱스 정렬 방향(#3 gameStartsAt, #8 updatedAt) — FE orderBy 확정 후 조정.

> AGENTS.md: 구현이 API/스키마/결정을 바꾸면 ../ass_knowledge 갱신. 위 1은 §3.3 정정 후보로 사용자 보고 후 반영.

---

## 12. 완료 기준 (Definition of Done)

- [ ] `cd functions && npm i && npm run build` (tsc) 통과
- [ ] `npm test` (vitest) — permissions/guards/validation/status 단위 테스트 통과
- [ ] `npm run lint` 통과
- [ ] firestore.rules / storage.rules 문법 유효(에뮬레이터 또는 `firebase deploy --only firestore:rules --dry-run` 수준)
- [ ] firestore.indexes.json 8개, ERD §8과 일치
- [ ] index.ts에 미구현 11함수 TODO 명시
- [ ] .gitignore에 시크릿/env/자격증명 제외 확인

---

## 13. 구현 현황 (2026-05-29 — Claude 임시 직접 구현)

> Codex 위임이 **윈도우 샌드박스 오류**(`codex-windows-sandbox-setup.exe` spawn 실패 — `[windows] sandbox="elevated"` ↔ 헤드리스 플러그인 실행 충돌)로 막혀, 사용자 지시에 따라 Claude가 본 설계서대로 **임시 직접 구현**. 추후 Codex 정상화 시 동일 사양으로 재수행/재검증 예정.

검증 결과(로컬, node v24):
- `npm install` ✅ (398 packages) · `npm run build`(tsc) ✅ exit 0 · `npm test`(vitest) ✅ 24 tests/4 files · `npm run lint`(eslint) ✅ exit 0
- 자가검증 grep ✅ 폐기 모델 잔재(organizerId/USER_ROLE/payments/eventLogs/'open') **0건**, createdByUserId/confirmedCount/8개 상태 사용 확인

비고:
- 1차 Codex 산출물(고정 역할 기반 모델)은 SoT 위반으로 **전량 교체**됨.
- §11-1 재확인: api-spec §3.3 Storage read는 Firestore 조회 불가 → read를 **업로더 본인**으로 한정. 운영자 열람은 후속 `getReceiptUrl` 콜러블(signed URL) 필요. **api-spec §3.3 정정 후보.**
- 인덱스 정렬방향(#3 gameStartsAt ASC, #8 updatedAt DESC)은 FE orderBy 확정 후 조정.

---

## 14. Codex 헤드리스 샌드박스 수리 기록 (2026-05-30)

**근본원인(규명 완료):**
- PATH로 잡히는 Codex 설치 `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin` 에 `codex.exe`만 있고 샌드박스 헬퍼가 누락 → 모든 sandboxed 명령이 `program not found`로 실패(파일 쓰기는 내부 patch라 동작). Defender 격리 무관.
- **적용된 수리**: `codex-windows-sandbox-setup.exe` + `codex-command-runner.exe`를 0.134.0 패키지 사본(`~/.codex/packages/standalone/releases/0.134.0-x86_64-pc-windows-msvc/codex-resources/`)에서 위 bin으로 복사. → `program not found` 해소, sandbox write 동작 확인(자가테스트 파일 생성 성공).
- **남은 단 하나의 차단요인**: 헬퍼가 requireAdministrator → 비승격 헤드리스 실행 시 spawn이 **os error 740(권한 상승 필요)**. codex가 명령마다 헬퍼를 재호출하므로 비승격에선 `node/npm/tsc` 실행 불가(파일 쓰기만 됨).
  - ⇒ "1회 대화형 실행"만으론 안 됨(매 명령 재호출). 

**해결(사용자 선택 = Claude Code 관리자 권한 재시작):**
- Claude Code(= Codex 컴패니언 부모)를 관리자로 실행하면 자식 codex가 승격을 상속 → 740 해소 → elevated 샌드박스 정상화. 보안 격리는 유지.

**재시작(관리자) 후 후속 절차:**
1. `node "<plugins>/openai-codex/codex/1.0.4/scripts/codex-companion.mjs" setup --json` → ready 확인.
2. 본 GREEN 작업을 Codex로 재수행/교차검증(이 설계서 사양 그대로). 산출물을 현재 Claude 임시 구현(이미 build/test/lint 통과)과 비교.
3. 일치 확인 후 §11(§3.3 Storage 등) SoT 정정 반영.

> **[최종·정정 2026-05-30]** "관리자 재시작"은 **불가**로 판명 — Claude/Codex 모두 MSIX(Store) 앱이라 Windows가 관리자 실행을 막음.
> 대신 **2가지로 GUI에서 직접 호출 복구·검증 완료**:
> 1. 누락 헬퍼 복구: `codex-windows-sandbox-setup.exe`(+`codex-command-runner.exe`)를 `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin`(PATH 설치)에 0.134.0 패키지 사본에서 복사 → "program not found" 해소.
> 2. `~/.codex/config.toml` `[windows] sandbox` `elevated`→**`unelevated`**(공식 fallback, 관리자 불요). 백업 `config.toml.bak-claude-20260530`. **사용자 승인 후 적용.**
>
> **검증(16:34)**: write 자가테스트 — `.codex-selftest3.txt` 생성 + `node --version`=**v24.15.0** 정상, 샌드박스 로그 **SUCCESS**(os740 소멸). → **GUI Claude Code 플러그인에서 Codex 호출 end-to-end 동작**(관리자·터미널·재시작 불필요).
> 원복: config `unelevated`→`elevated` 또는 백업 복사.
>
> 현재 상태: GREEN 백엔드 = 완료·검증(Claude 임시) · Codex 호출 워크플로 = 복구·검증 완료. 이제 Codex로 GREEN 교차검증 가능.

---

## 15. Codex 교차검증 결과 & 레이아웃 정렬 (2026-05-30)

- Codex가 동일 사양으로 `ass_backend_codex`에 **독립 재구현** → SoT 충실(역할모델 잔재 0건), 두 구현 **거의 동등**. 둘 다 build/test/lint 독립 통과(Codex판: 내 환경에서 install/build/test 18/lint 통과).
- 1차 실패(역할모델 드리프트)는 "코드 실력"이 아니라 **샌드박스가 깨져 문서를 못 읽은 것**이었음이 역으로 확정됨.
- **채택(Codex의 좋은 디테일):** ① 콜러블 `src/functions/{session,participation,payment}/` 재배치(설계서 §2 일치) ② `firestore.rules` `hasNoRoleField()`(역할금지 불변 강화) ③ 알림 body에 `session.title`(api-spec §4 템플릿 일치).
- `ass_backend_codex` 삭제 → 단일 캐노니컬 = `ass_backend`. 재검증: tsc ✅ · vitest **24** ✅ · eslint ✅.
