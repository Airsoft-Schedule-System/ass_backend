# 03 — Edge Functions · 스케줄 · 푸시(FCM) 구현 지침 (Wave S3)

전제: 01·02 완료(테이블·RPC·notify() 존재). 본 웨이브는 **알림의 "발신" 채널**과 배선만 담당 — 영속화(인앱 알림함)는 이미 RPC의 notify()가 보장하므로, 푸시가 실패해도 제품은 동작한다(A8 iOS fallback 원칙 유지).

## 1. 아키텍처 (배선도)

```
RPC(notify) ──INSERT──▶ notifications ──Database Webhook(INSERT)──▶ Edge: send-push ──HTTP v1──▶ FCM ──▶ 브라우저
                            ▲                                            │
fn_send_reminders(pg_cron) ──┘                          fcm_tokens 조회·무효 토큰 삭제
```

- 단일 발신 경로: **notifications INSERT가 곧 푸시 트리거.** RPC·cron 어느 쪽이 만들어도 동일 경로 — green-backend FcmNotifier의 "영속화 우선, 발신 best-effort" 원칙의 관계형 버전.
- 웹훅: Supabase Dashboard(또는 마이그레이션에서 `supabase_functions.http_request` 트리거)로 `notifications` INSERT → `send-push` 호출. 헤더에 `x-webhook-secret`(00 §4의 WEBHOOK_SECRET) 포함 — Edge가 검증.

## 2. Edge Function: `supabase/functions/send-push/index.ts`

- 런타임 Deno. 시크릿(Edge env): `FCM_SERVICE_ACCOUNT_JSON`, `WEBHOOK_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`(자동 주입).
- 처리 순서:
  1. `x-webhook-secret` 검증(불일치 401 — 외부 호출 차단).
  2. payload에서 notification record(user_id, type, title, body, action_url, data) 추출.
  3. service-role 클라이언트로 `fcm_tokens where user_id=...` 조회. 0건이면 200 종료(인앱만).
  4. **FCM HTTP v1** 발신: 서비스계정 JSON으로 OAuth2 토큰 발급(google-auth 라이브러리 또는 JWT 수동 서명 — Deno에서는 `https://www.googleapis.com/oauth2/v4/token`에 RS256 JWT) → `projects/{pid}/messages:send`에 토큰별 전송. payload: `notification{title,body}` + `data{type, actionUrl, ...}`(string-only) + `webpush.fcm_options.link = actionUrl`.
  5. 응답 404/UNREGISTERED → 해당 fcm_tokens 행 삭제(무효 토큰 정리 — FcmNotifier 이식).
  6. **어떤 실패도 5xx로 던지지 않고 로깅 후 200**(웹훅 재시도 폭주 방지·제품 무영향 원칙).
- 검증: `supabase functions serve send-push` + curl(웹훅 페이로드 모사, 시크릿 유/무, 토큰 0건/무효 토큰 케이스).

## 3. pg_cron 등록 (0012)

```sql
select cron.schedule('status-transition', '0 * * * *',    $$select fn_status_transition()$$);
select cron.schedule('send-reminders',    '*/30 * * * *', $$select fn_send_reminders()$$);
```
(함수 본문은 02 §3. 타임존: cron은 UTC 기준 — 두 함수 모두 절대시각 비교라 무관. 리마인더 윈도우 폭이 주기와 일치하므로 누락 없음.)

## 4. Storage 세부 (01 §7 보완)

- 버킷 `receipts`(private, 5MB 제한, `image/jpeg·png·webp`만 — 버킷 옵션으로 강제).
- 업로드(FE): `supabase.storage.from('receipts').upload('receipts/{participationId}/receipt-{ts}.{ext}', file)` — RLS가 본인 participation만 허용. `owner`는 Storage가 자동 기록 → 02 §2.9의 업로더 검증에 사용.
- 열람(FE): `createSignedUrl(path, 60)` — SELECT 정책(업로더 or 세션 운영자)이 통과 여부 결정. **별도 콜러블 불필요**(구 getReceiptUrl 계획 폐기 근거).

## 5. FE 푸시 온보딩 (참고 — S4/HOAN, contract-v3 §6과 세트)

- Firebase 웹앱 config + VAPID 공개키는 FCM **수신 전용**으로만 사용(데이터는 전부 Supabase).
- 사용자 액션 시 `Notification.requestPermission()` → FCM `getToken({vapidKey})` → `fcm_tokens` upsert(본인 RLS 허용). SW(`firebase-messaging-sw.js`)는 background 표시만.
- VAPID 키 없으면 이 단계 전체 skip — 인앱 알림함만으로 동작(A8 fallback).

## 6. S3 완료 기준

1. 로컬 스택에서 approve_payment 실행 → notifications 행 + (serve 중인) send-push 호출 로그 확인.
2. 무효 토큰 삭제·토큰 0건·시크릿 불일치 케이스 통과.
3. cron 2종 등록 확인(`cron.job` 조회) + 함수 수동 호출 멱등.
4. 어떤 푸시 실패도 RPC 트랜잭션·웹훅 재시도 폭주를 유발하지 않음.
