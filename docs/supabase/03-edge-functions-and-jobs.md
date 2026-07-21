# 03 — Edge Functions · 스케줄 · 발신 채널 구현 지침 (Wave S3)

> 📌 **배달 채널 병기 (2026-07-20)**
> **MVP 현재 = 이메일(`send-email`)** · **v2 이월 = FCM Web Push(`send-push`)**
> 근거: `ass_knowledge/decisions/2026-07-20-notification-delivery-email-first.md`
> **§2A(이메일)가 현행 구현 대상이고, §2B(푸시)는 v2 착수 시 그대로 쓰는 보존 설계다.** 삭제하지 않는다.
> 두 어댑터는 배선(웹훅·cron·notifications)을 100% 공유하며, 교체·병행이 국소 변경으로 끝나도록 설계돼 있다.

전제: 01·02 완료(테이블·RPC·notify() 존재). 본 웨이브는 **알림의 "발신" 채널**과 배선만 담당 — 영속화(인앱 알림함)는 이미 RPC의 notify()가 보장하므로, **발신이 실패해도 제품은 동작한다**(A8 fallback 원칙 유지).

## 1. 아키텍처 (배선도)

```
RPC(notify) ──INSERT──▶ notifications ──Database Webhook(INSERT)──▶ Edge 어댑터
                            ▲                                          ├─ [MVP]  send-email ──▶ Brevo/Resend API ──▶ 메일함
fn_send_reminders(pg_cron) ──┘                                         └─ [v2]   send-push  ──▶ FCM HTTP v1 ──▶ 브라우저
```

- 단일 발신 경로: **notifications INSERT가 곧 발신 트리거.** RPC·cron 어느 쪽이 만들어도 동일 경로 — green-backend FcmNotifier의 "영속화 우선, 발신 best-effort" 원칙의 관계형 버전.
- 웹훅: Supabase Dashboard(또는 마이그레이션에서 `supabase_functions.http_request` 트리거)로 `notifications` INSERT → **현행은 `send-email`** 호출. 헤더에 `x-webhook-secret`(00 §4의 WEBHOOK_SECRET) 포함 — Edge가 검증. **v2 전환 시 이 호출 대상만 바꾸거나 추가한다.**

## 2A. Edge Function: `supabase/functions/send-email/index.ts` — **현행(MVP)**

- 런타임 Deno. 시크릿(Edge env): `EMAIL_API_KEY`, `EMAIL_FROM`(예: `ASS <noreply@도메인>`), `WEBHOOK_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`(자동 주입).
- 발신 서비스: **Brevo 권장**(무료 일 300/월 9,000 — 주말 버스트 대응). 대안 Resend(일 100 하드캡 주의). 결정문 §발신 서비스 참조.
- 처리 순서:
  1. `x-webhook-secret` 검증(불일치 401 — 외부 호출 차단).
  2. payload에서 notification record(`user_id, type, title, body, action_url, data`) 추출.
  3. **타입 필터** — 앱 밖 도달이 필요한 것만 발송(판정 원칙은 결정문 §알림 구조).
     - **발송**: `participation.decision`(승인·반려) · `payment.requested` · `payment.decision` · `session.upcoming_reminder` · `session.changed`
     - **제외**: `participation.confirmed` — Gate B에서 첨부 즉시 확정이라 **사용자가 그 순간 화면에 있음**. 제외 대상이면 200 즉시 종료.
     - **병합**: `participation.decision`(승인)과 `payment.requested`는 승인 시 동시 발생 → **1통으로 병합**. 구현은 택1(테스트로 고정): ⓐ 같은 participation에 대해 직전 N초 내 발신 이력이 있으면 스킵, ⓑ 승인 경로에서는 `payment.requested`만 메일 대상으로 삼기(제목에 승인 결과 포함).
     - **문구**: 반려 메일 제목은 중립적으로("「게임명」 신청 결과 안내"). 본문은 **요약 + 딥링크만**, 상세는 앱에서.
     - **호스트 대상 메일 없음** — 인벤토리 6종이 전부 게스트 대상이므로 별도 분기 불요(윤보혁 결정).
  4. service-role 클라이언트로 `users.email` 조회(`where id = user_id`). 비어 있으면 200 종료(인앱만).
  5. 발신: 제목 = notification.title, 본문 = body + **`action_url` 딥링크 버튼**("앱에서 확인하기"). 본문은 정보 최소화 — 상세는 앱에서 보게 유도(윤보혁 "앱 안에서 모두 해결" 모토 정합).
  6. **어떤 실패도 5xx로 던지지 않고 로깅 후 200**(웹훅 재시도 폭주 방지·제품 무영향 원칙).
- 검증: `supabase functions serve send-email` + curl(웹훅 페이로드 모사 / 시크릿 유·무 / 이메일 없는 사용자 / 필터 제외 타입 / API 실패 시 200 유지).
- **도메인·SPF/DKIM**: 네이버·다음은 미인증 발신을 지연·차단·스팸 처리한다. 로컬·dev 검증은 서비스 기본 발신 주소로 가능하되, **dev 배포(Phase 3) 전까지 커스텀 도메인 + SPF/DKIM 등록 필수**(Vercel 커스텀 도메인과 공용).

## 2B. Edge Function: `supabase/functions/send-push/index.ts` — **v2 이월 (설계 보존)**

> 아래는 현행 구현 대상이 **아니다.** v2에서 웹 푸시로 복귀·병행할 때 그대로 사용한다.
> 배선(웹훅·cron·notifications)이 동일하므로, 이 파일을 추가하고 웹훅 대상만 늘리면 된다. `fcm_tokens` 테이블은 이미 존재한다(미사용 보존).

- 런타임 Deno. 시크릿(Edge env): `FCM_SERVICE_ACCOUNT_JSON`, `WEBHOOK_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`(자동 주입).
- 처리 순서:
  1. `x-webhook-secret` 검증(불일치 401 — 외부 호출 차단).
  2. payload에서 notification record(user_id, type, title, body, action_url, data) 추출.
  3. service-role 클라이언트로 `fcm_tokens where user_id=...` 조회. 0건이면 200 종료(인앱만).
  4. **FCM HTTP v1** 발신: 서비스계정 JSON으로 OAuth2 토큰 발급(google-auth 라이브러리 또는 JWT 수동 서명 — Deno에서는 `https://www.googleapis.com/oauth2/v4/token`에 RS256 JWT) → `projects/{pid}/messages:send`에 토큰별 전송. payload: `notification{title,body}` + `data{type, actionUrl, ...}`(string-only) + `webpush.fcm_options.link = actionUrl`.
  5. 응답 404/UNREGISTERED → 해당 fcm_tokens 행 삭제(무효 토큰 정리 — FcmNotifier 이식).
  6. **어떤 실패도 5xx로 던지지 않고 로깅 후 200**(웹훅 재시도 폭주 방지·제품 무영향 원칙).
- 검증: `supabase functions serve send-push` + curl(웹훅 페이로드 모사, 시크릿 유/무, 토큰 0건/무효 토큰 케이스).

## 3. pg_cron 등록 (0015)

```sql
select cron.schedule('status-transition', '0 * * * *',    $$select fn_status_transition()$$);
select cron.schedule('send-reminders',    '*/30 * * * *', $$select fn_send_reminders()$$);
```
(함수 본문은 02 §3. 타임존: cron은 UTC 기준 — 두 함수 모두 절대시각 비교라 무관. 리마인더 윈도우 폭이 주기와 일치하므로 누락 없음.)

## 4. Storage 세부 (01 §7 보완)

- 버킷 `receipts`(private, 5MB 제한, `image/jpeg·png·webp`만 — 버킷 옵션으로 강제).
- 업로드(FE): `supabase.storage.from('receipts').upload('receipts/{participationId}/receipt-{ts}.{ext}', file)` — RLS가 본인 participation만 허용. `owner`는 Storage가 자동 기록 → 02 §2.9의 업로더 검증에 사용.
- 열람(FE): `createSignedUrl(path, 60)` — SELECT 정책(업로더 or 세션 운영자)이 통과 여부 결정. **별도 콜러블 불필요**(구 getReceiptUrl 계획 폐기 근거).

## 5. FE 알림 작업

### 5A. 현행(MVP) — **FE 작업 없음**

이메일 배달은 전적으로 서버측이다. FE는 **인앱 알림함(A8) 조회·읽음 처리만** 구현한다(contract-v3 §6 참조). 권한 요청·SW·토큰 관련 작업은 **전부 없음** — 이 전환의 가장 큰 이득.

### 5B. v2 이월 — 푸시 온보딩 (설계 보존, S4 아님)

- Firebase 웹앱 config + VAPID 공개키는 FCM **수신 전용**으로만 사용(데이터는 전부 Supabase).
- 사용자 액션 시 `Notification.requestPermission()` → FCM `getToken({vapidKey})` → `fcm_tokens` upsert(본인 RLS 허용). SW(`firebase-messaging-sw.js`)는 background 표시만.
- VAPID 키 없으면 이 단계 전체 skip — 인앱 알림함만으로 동작(A8 fallback).

## 6. S3 완료 기준 (현행 = 이메일 기준)

1. 로컬 스택에서 `submit_payment` 실행 → `notifications` 행 생성 + (serve 중인) `send-email` 호출 로그 확인.
2. **타입 필터 동작**: `participation.confirmed`는 메일 미발송, `session.changed`·리마인더는 발송.
3. 이메일 없는 사용자·시크릿 불일치·발신 API 실패 케이스에서 **모두 200 유지**(웹훅 재시도 폭주 없음).
4. cron 2종 등록 확인(`cron.job` 조회) + 함수 수동 호출 멱등.
5. 어떤 발신 실패도 RPC 트랜잭션을 롤백시키지 않음.

> v2(푸시) 복귀 시 완료 기준: 무효 토큰 삭제·토큰 0건 케이스 추가 + 실기기 수신 확인(에뮬레이터 불가).
