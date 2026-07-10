# S3 구현 핸드오프 — Codex 작업지시서 (알림 발신 웨이브)

> 이 문서는 **Codex가 그대로 실행**하도록 쓴 작업지시서다. 상위 설계는 `03-edge-functions-and-jobs.md`, 배경 결정은 `ass_knowledge/decisions/2026-07-09-notification-channel-fcm-web-push.md`(= A안 FCM Web Push 확정). 본 문서와 03이 충돌하면 **본 문서 우선**(더 구체·최신).

## 0. 미션 (한 줄)

`notifications` INSERT가 곧 푸시 트리거가 되도록 **발신 경로(Edge send-push)와 스케줄(pg_cron)을 배선**한다. 인앱 알림함(notifications/notify)은 S2에서 이미 동작하므로, **푸시는 best-effort** — 실패해도 제품·RPC 트랜잭션에 영향 0.

## 1. 범위 (DO / DON'T)

**DO**
- 마이그레이션 `0012_cron.sql`: `pg_cron`·`pg_net` 확장 생성 + cron 2종 등록.
- 마이그레이션 `0013_webhook.sql`(또는 0014, 0013_storage와 번호 충돌 주의 → **0014_webhook.sql**): `notifications` INSERT → `send-push` 호출 트리거.
- Edge Function `supabase/functions/send-push/index.ts` (Deno, FCM HTTP v1).
- `supabase/config.toml`에 `[functions.send-push]` 등록(필요 시).
- pgTAP `supabase/tests/database/cron.sql`: cron 등록·트리거 존재 검증.

**DON'T**
- RPC(0006–0010)·`notifications`/`notify()` 스키마·비즈니스 로직 **손대지 말 것**(발신은 순수 consumer).
- **실제 FCM 서비스계정 JSON·VAPID 키·웹훅 시크릿을 절대 커밋하지 말 것.** 로컬은 mock 모드로 검증(§5).
- `fcm_tokens` RLS는 이미 0005에 있음(self CRUD) → **추가하지 말 것.**

## 2. 착수 전 확인 (스택에 대고 먼저 검증 — 가정 금지)

Docker Desktop이 떠 있어야 함. `supabase db reset` 후:
1. `select * from pg_available_extensions where name in ('pg_cron','pg_net');` — 로컬 이미지에 있는지(있음이 정상). 없으면 즉시 보고하고 중단.
2. `select nspname from pg_namespace where nspname='supabase_functions';` + `\df supabase_functions.http_request` — Supabase 로컬이 제공하는 웹훅 트리거 함수 존재 여부. **있으면** 그걸 사용(§4a), **없으면** pg_net 직접 호출 트리거로 대체(§4b).
3. cron.schedule 실행 롤: 로컬은 superuser(postgres) → SECURITY DEFINER 함수 호출 문제 없음.

## 3. T1 — `0012_cron.sql` (스케줄)

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 함수 본문은 0010(fn_status_transition, fn_send_reminders)에 이미 존재.
select cron.schedule('status-transition', '0 * * * *',    $$select public.fn_status_transition()$$);
select cron.schedule('send-reminders',    '*/30 * * * *', $$select public.fn_send_reminders()$$);
```
- 멱등성: 재적용 대비 등록 전 `cron.unschedule`를 `where exists`로 감싸거나, `cron.schedule` 재호출이 같은 jobname을 갱신하는 점을 이용(동일 jobname이면 덮어씀). **db reset 반복에도 중복 job이 안 생기게** 할 것.
- 타임존: cron은 UTC. 두 함수 모두 절대시각 비교라 무관(03 §3).

## 4. T2 — `0014_webhook.sql` (notifications INSERT → send-push)

로컬에서 Edge가 서빙되는 URL: `http://host.docker.internal:54321/functions/v1/send-push` (DB 컨테이너에서 호스트로 나가는 경로). 실배포는 프로젝트 함수 URL — **하드코딩 말고** `current_setting('app.settings.functions_url', true)` 또는 Vault에서 읽어 조립(로컬 기본값 fallback).

**4a. supabase_functions.http_request 존재 시**
```sql
create trigger on_notification_created
after insert on public.notifications
for each row execute function supabase_functions.http_request(
  '<functions_url>/send-push', 'POST',
  '{"Content-Type":"application/json","x-webhook-secret":"<from vault/env>"}',
  '{}', '5000'
);
```
**4b. 없으면 pg_net 직접 호출 트리거 함수 작성**
```sql
create or replace function public.tg_notify_push() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := public.notify_functions_url() || '/send-push',
    headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', public.vault_secret('webhook_secret')),
    body := to_jsonb(new)
  );
  return new;
exception when others then
  return new; -- 발신 실패가 INSERT를 막지 않음(best-effort)
end; $$;
create trigger on_notification_created after insert on public.notifications
for each row execute function public.tg_notify_push();
```
- 웹훅 시크릿은 Vault(`webhook_secret`)에서. 로컬 검증 땐 vault에 dummy 값 넣고, mock 모드 Edge가 통과시키게.
- **트리거가 절대 예외를 던져 INSERT/RPC 트랜잭션을 깨지 않게** exception 처리 필수.

## 5. T3 — Edge `supabase/functions/send-push/index.ts` + 로컬 시크릿 처리 (핵심)

처리 순서(03 §2 그대로) + **mock 모드**:
1. `x-webhook-secret` 검증(불일치 401).
2. payload(new notification row) 파싱: user_id, type, title, body, action_url, data.
3. service-role 클라이언트로 `select token, platform from fcm_tokens where user_id = ...` — **platform 무관 전순회**(web/ios/android 모두. iOS 설치형 PWA 대비 — 결정문 가드레일).
4. **mock 모드 분기**: `Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')`가 없거나 `PUSH_DRY_RUN=1`이면 → 실제 발신 대신 `console.log`로 "would send to N tokens" 남기고 200. **실키 없이 로컬 전 구간 검증 가능하게 하는 게 이 항목의 목적.**
5. 실 모드: 서비스계정 JSON으로 RS256 JWT 서명 → `oauth2/v4/token`에서 access token → `projects/{pid}/messages:send` 토큰별 전송. payload: `notification{title,body}` + `data{...string-only}` + `webpush.fcm_options.link = action_url`.
6. 응답 404/UNREGISTERED → 해당 `fcm_tokens` 행 삭제(무효 토큰 정리).
7. **어떤 실패도 5xx로 던지지 않고 200**(웹훅 재시도 폭주 방지).

> **어댑터 경계 원칙(결정문 가드레일)**: send-push는 "notification row → 디바이스 배달" 변환만. FCM 특화 로직은 이 함수 안에만. 토큰 조회·무효정리·전순회는 채널 교체(v2 Expo/APNs) 시 이 파일만 바뀌게 유지.

`config.toml`:
```toml
[functions.send-push]
verify_jwt = false   # 웹훅이 service-role/시크릿으로 호출 — JWT 아님
```

## 6. T4 — pgTAP `supabase/tests/database/cron.sql`

- `cron.job`에 'status-transition'·'send-reminders' 2행 존재 + schedule 문자열 일치.
- `pg_trigger`에 `on_notification_created` 존재(relation=public.notifications).
- db reset 2회로도 job 중복 안 생김(멱등) — 가능하면 검증.
- 기존 `supabase test db`(rls.sql·rpc.sql) 계속 PASS.

## 7. 검증 루프 (Codex가 돌릴 것)

```
& <supabase.exe> db reset            # 0012/0014 적용 무오류
& <supabase.exe> test db             # pgTAP 전체 PASS(+cron.sql)
& <supabase.exe> functions serve send-push   # (별 터미널)
# 웹훅 페이로드 모사 curl: 시크릿 유/무, 토큰 0건/무효, mock 모드 200 확인
```
- Supabase CLI 전체경로: `E:\Airsoft_Schedule_Workspace\.tools\supabase.exe`.
- **Codex 샌드박스가 Docker 파이프 접근 거부(EPERM)로 db reset/test db를 못 돌릴 수 있음** — 그 경우 편집·정적검증까지 하고 **"검증은 오케스트레이터(Claude)가 수행"으로 보고**하고 멈출 것. (S2 때와 동일 분담.)

## 8. 완료 기준 (03 §6 + 본 문서)

1. 0012/0014 db reset 무오류, cron 2종 등록 확인, 웹훅 트리거 생성 확인.
2. mock 모드로 approve_payment→notifications INSERT→send-push 호출 로그 확인(실키 0).
3. 시크릿 불일치 401 / 토큰 0건 200 / 무효 토큰 삭제 경로 통과.
4. 어떤 푸시 실패도 RPC·INSERT 트랜잭션·웹훅 재시도 폭주를 유발하지 않음.
5. `notifications`/RPC 스키마 무변경, 실시크릿 미커밋.

## 9. 실배포 시 주입(사람 몫 — Codex 범위 밖, 문서화만)

FCM 서비스계정 JSON(HTTP v1)·VAPID 공개키(FE)·`webhook_secret`·기존 `qr_hmac_secret`/`refund_account_key`를 Edge env / Vault에 주입. 로컬은 전부 dummy/mock.
