# Wave 2 구현 설계 — QR 출석(A5) + 알림(A8)

| 항목 | 내용 |
|------|------|
| 작성 | Claude (설계) → Codex (구현) |
| 작성일 | 2026-06-11 |
| 선행 | Wave 1 완료(`wave1-implementation-plan.md`, green-backend b4fe23f) + SoT 갱신(knowledge 50050d3) |
| 기준 | `../../ass_knowledge/api/api-spec-v2.md` §2.15–2.18·§2.17a·§4.1a · `erd-v2.md` §5.11 · `decisions/2026-06-09-product-decisions-A1-A8.md` |
| 범위 | onParticipationConfirmed(트리거) · getEntryPassToken · scanEntryPass · markAttendance · FcmNotifier(알림 영속화+실발신) · scheduledReminder |
| 범위 외 | processRefund(A3 비활성 유지 — MVP 백엔드 잔여는 이것뿐) |

## 0. 공통 규칙 (Wave 1 §0과 동일)

- v2 함수, `{ region: REGION }`. 시크릿 쓰는 함수만 `secrets: [...]` 선언.
- lib 중앙화(permissions/guards/status/collections/errors/policy), tx read-before-write, 알림은 커밋 후 notifier.
- 한국어 주석/에러 메시지, 파일당 1함수, 배럴/엔트리/TODO 갱신.
- 검증: `npm run build` · `npm test` · `npm run lint` 전부 통과. 기존 44개 테스트 무손상.

## 1. 공유 코드 (함수보다 먼저)

### 1.1 `lib/qr.ts` (신규 — 순수, 단위테스트 대상)
```ts
export const QR_SECRET_VERSION = "v1";
// api-spec §2.15: 토큰 = HMAC-SHA256(secret, entryPassId + gameSessionId + userId + issuedAtMs + version)
// 직렬화는 "|" 구분으로 고정: `${entryPassId}|${gameSessionId}|${userId}|${issuedAtMs}|${version}`
// 반환은 base64url (원문은 어디에도 저장 금지)
buildEntryPassToken(f: { entryPassId; gameSessionId; userId; issuedAtMs: number; version: string }, secretValue: string): string
// 저장용 해시 = SHA256(token) hex
hashEntryPassToken(token: string): string
```
**재현성 핵심**: 토큰은 발급 시점과 `getEntryPassToken` 재계산 시점에 **완전히 동일한 입력**이어야 한다. 따라서 EntryPass의 `issuedAt`은 `FieldValue.serverTimestamp()`가 아니라 **구체값 `Timestamp.now()`** 로 저장한다(트리거 §2.1). 재계산은 저장된 `issuedAt.toMillis()`·`qrSecretVersion`을 사용.

### 1.2 `lib/policy.ts` 확장
```ts
// §2.18: 게임 시작 24h ± 30min 윈도우 (스케줄 주기 30분)
isInReminderWindow(startsAtMs: number, nowMs: number): boolean  // now+23.5h <= startsAt <= now+24.5h
```

### 1.3 `lib/guards.ts` — GuardedOperation 확장
```
scanEntryPass:   [RECRUITING, CLOSED, IN_PROGRESS]   // 터미널(completed/cancelled)만 차단
markAttendance:  [RECRUITING, CLOSED, IN_PROGRESS]
```

### 1.4 `lib/collections.ts`
`NOTIFICATIONS: "notifications"` 추가.

### 1.5 types
- `types/entities.ts`: `Notification` 인터페이스 추가(ERD §5.11 전사 — userId/type/title/body/actionUrl/data(Record<string,string>|null)/gameSessionId·participationId(string|null)/isRead/createdAt).
- `types/functions.ts`: `MarkAttendanceInput { participationId }` / `MarkAttendanceOutput { success: true }` 추가(§2.17a). GetEntryPassToken·ScanEntryPass 타입은 기존 존재.

## 2. 알림 (A8)

### 2.1 `notifications/notifier.ts` — `FcmNotifier`로 교체
- `NotificationEnvelope`/`Notifier` 인터페이스 불변(호출부 무수정). `NoopNotifier`는 삭제하지 말고 남겨두되 싱글턴만 교체: `export const notifier: Notifier = new FcmNotifier();`
- `FcmNotifier.send(envelope)` 순서(§4.1a):
  1. **영속화 먼저(보장)**: `notifications` add — `{ userId, type, title, body, actionUrl, data ?? null, gameSessionId ?? null, participationId ?? null, isRead: false, createdAt: serverTimestamp }`.
  2. 토큰 조회: `users/{userId}/fcmTokens` 전체. 없으면 종료(인앱만).
  3. `getMessaging().sendEachForMulticast({ tokens, notification: { title, body }, data: { type, actionUrl, ...envelope.data } })` — FCM data는 string-only 유지.
  4. 무효 토큰 정리: 응답 에러 코드가 `messaging/registration-token-not-registered` 또는 `messaging/invalid-argument`(또는 `invalid-registration-token`)이면 해당 토큰 문서 삭제. 판정은 순수 함수 `shouldDeleteFcmToken(errorCode: string): boolean`으로 분리(단위테스트).
  5. **모든 실패는 console.error 로깅만** — 절대 throw하지 않는다(알림 실패가 본 작업·트랜잭션 결과를 깨면 안 됨).
- `sendMany`: `Promise.allSettled`.

### 2.2 `functions/scheduled/reminder.ts` — `scheduledReminder` (§2.18)
- `onSchedule({ schedule: "every 30 minutes", timeZone: "Asia/Seoul", region: REGION })`.
- 후보 조회: status별(`RECRUITING`, `CLOSED`) `startsAt` 범위 쿼리(`>= now+23.5h && <= now+24.5h` — 기존 인덱스 status+startsAt 사용) → 메모리에서 `reminderSent !== true` 필터(기존 문서엔 필드 없음 = false 취급).
- 세션별 개별 tx: 재read → `reminderSent !== true` 재확인 → `reminderSent: true` 마킹. **마킹 후** 커밋되면 confirmed 참가 조회 → `session.upcoming_reminder` envelope 전원 발송.
  - 명세는 "발신 후 마킹"이나, 중복 푸시 방지를 우선해 **선마킹-후발신**으로 구현(마킹과 발신 사이 크래시 시 해당 회차 미발신 허용 — MVP 트레이드오프, 주석 명시).
- envelope: `type: "session.upcoming_reminder"`, title/body에 세션명·시작시각, `actionUrl: /sessions/{id}`.
- 개별 세션 실패는 로깅 후 계속.

## 3. QR 출석 (A5)

### 3.1 `triggers/onParticipationConfirmed.ts` (§2.15)
- `onDocumentUpdated("participations/{participationId}")` (`firebase-functions/v2/firestore`), `{ region: REGION, secrets: [QR_HMAC_SECRET] }`.
- 발화 조건: `before.status !== 'confirmed' && after.status === 'confirmed'`. 아니면 즉시 return.
- tx:
  1. read: 같은 participationId의 `active` EntryPass 존재 → **skip(멱등)**. 세션 read(없으면 로깅 후 종료).
  2. EntryPass 생성: docRef 선생성으로 id 확보 → `issuedAt = Timestamp.now()`(**serverTimestamp 금지** — §1.1 재현성), `expiresAt = session.startsAt + 24h`, `qrSecretVersion: QR_SECRET_VERSION`, `qrTokenHash = hashEntryPassToken(buildEntryPassToken({...}, QR_HMAC_SECRET.value()))`, `status: ACTIVE`, `usedAt/scannedBy: null`.
  3. participation update: `entryPassId` 역참조 + updatedAt.
- 실패는 throw(트리거 재시도에 위임) — 단 멱등 가드가 중복 생성을 막는다.
- **A7 명문화**: `joinAsOperator`는 문서를 생성 시점부터 confirmed로 만들므로 onDocument**Updated**가 발화하지 않음 → 운영자 자기 참가는 EntryPass 미발급(의도된 동작, §2.6a — 출석은 markAttendance로). 파일 상단 주석에 기록.

### 3.2 `functions/entry/getEntryPassToken.ts` (§2.16 — read-only)
- onCall `{ region, secrets: [QR_HMAC_SECRET] }`. Input `{ gameSessionId }`.
- 본인 participation 조회(gameSessionId+userId) → 없으면 not-found, `status !== confirmed`면 failed-precondition, `entryPassId == null`이면 failed-precondition("입장권이 아직 발급되지 않았습니다").
- EntryPass read → `status === active`·`expiresAt > now` 검증 → 저장 필드로 토큰 재계산(`issuedAt.toMillis()`, `qrSecretVersion`) → `{ entryPassId, token, expiresAt }` 반환. 쓰기 없음.

### 3.3 `functions/entry/scanEntryPass.ts` (§2.17 — tx)
- onCall `{ region, secrets: [QR_HMAC_SECRET] }`. Input `{ qrPayload: { entryPassId, token } }`(형태 검증 invalid-argument).
- tx read: entryPass(not-found) → participation → session → user(`users/{entryPass.userId}` — displayName 출력용).
- 검증 순서: `assertSessionOwner(session, uid)` → `assertSessionStatusAllows("scanEntryPass")` → 토큰 검증 `hashEntryPassToken(token) === entryPass.qrTokenHash`(불일치 failed-precondition "유효하지 않은 QR 코드입니다") → `entryPass.status === active` → `expiresAt > now` → `participation.status === confirmed`.
- 쓰기: entryPass → `used`/`usedAt: now`/`scannedBy: uid`, participation → `attended`/updatedAt.
- Output `{ success: true, userId, displayName }`.

### 3.4 `functions/participation/markAttendance.ts` (§2.17a — tx, B1-3)
- onCall `{ region }`(시크릿 불필요). Input `{ participationId }`.
- tx read: participation → session → (entryPassId 있으면) entryPass.
- 검증: `assertSessionOwner` → `assertSessionStatusAllows("markAttendance")` → `participation.status === confirmed`.
- 쓰기: participation → `attended`/updatedAt. entryPass가 존재하고 `active`면 → `used`/`usedAt`/`scannedBy: uid`(수동 처리자 기록). **entryPass 없으면 skip — A7 운영자 자기 참가가 이 경로**(주석 명시).
- Output `{ success: true }`.

## 4. 보안 규칙 / 인덱스

### 4.1 `firestore.rules`
`refundRequests` 블록 뒤에 추가(기존 헬퍼 재사용):
```
match /notifications/{notificationId} {
  allow read: if isSignedIn() && isSelf(resource.data.userId);
  allow create, delete: if false; // 서버(Cloud Functions)만 생성
  allow update: if isSignedIn() && isSelf(resource.data.userId)
    && request.resource.data.diff(resource.data).affectedKeys().hasOnly(['isRead'])
    && request.resource.data.isRead is bool;
}
```

### 4.2 `firestore.indexes.json`
```
notifications: (userId ASC, createdAt DESC)            — 알림함 최신순
notifications: (userId ASC, isRead ASC, createdAt DESC) — 미읽음 필터/배지
```

## 5. 배럴/엔트리

- `functions/index.ts`: `getEntryPassToken`, `scanEntryPass`, `markAttendance` export 추가.
- 루트 `index.ts`: 위 3개 + `onParticipationConfirmed`(트리거) + `scheduledReminder` export. TODO 갱신 → 잔여: `processRefund(A3 비활성)`만.

## 6. 테스트 (vitest — 기존 컨벤션)

신규: `qr.test.ts` / 기존 파일 확장: `policy.test.ts`, `guards.test.ts`, (notifier 판정은) `notifier.test.ts` 또는 기존 적절 파일.
1. qr: 같은 입력+같은 시크릿 → 같은 토큰(결정성) / 시크릿·필드 하나라도 다르면 다른 토큰 / `hashEntryPassToken(token)` 일치 검증 / 토큰이 base64url 문자집합만 포함.
2. policy.isInReminderWindow: 정확히 24h 전 true / 23.5h·24.5h 경계 / 23h·25h false.
3. guards: scanEntryPass·markAttendance 화이트리스트(허용 3종, completed/cancelled 차단).
4. shouldDeleteFcmToken: registration-token-not-registered → true, 무관 코드 → false.
- FcmNotifier 본체·트리거·스케줄러는 에뮬레이터 영역(백로그) — 단위테스트 강제하지 않음.

## 7. 완료 기준

1. `npm run build` / `npm test`(기존 44 + 신규 전부) / `npm run lint` 통과.
2. QR 토큰 원문이 저장·로그 어디에도 남지 않음(해시만 저장).
3. EntryPass `issuedAt`이 구체값(Timestamp.now())으로 저장됨 — getEntryPassToken 재계산과 일치.
4. 알림 실패(영속화 제외)가 어떤 콜러블/트리거의 성공도 깨지 않음(throw 금지).
5. joinAsOperator 경로에서 EntryPass가 생성되지 않음(트리거 미발화) + markAttendance가 entryPass 없이도 동작.
6. 기존 GREEN/Wave1 콜러블 동작 불변(notifier 싱글턴 교체 외).
