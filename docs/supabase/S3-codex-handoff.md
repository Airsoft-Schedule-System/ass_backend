# S3 구현 핸드오프 — Codex 작업지시서 (알림 발신 웨이브 · **이메일**)

> 이 문서는 **Codex가 그대로 실행**하도록 쓴 작업지시서다.
> **배경 결정(최우선)**: `ass_knowledge/decisions/2026-07-20-notification-delivery-email-first.md` — MVP 앱 밖 배달 채널 = **이메일(`send-email`)**. FCM Web Push(`send-push`)는 **폐기가 아니라 v2 이월**(설계 보존).
> **상위 설계**: `03-edge-functions-and-jobs.md` **§2A(이메일 = 현행 구현 대상)**. §2B(푸시)는 v2 보존 설계이므로 **이번 웨이브에서 구현하지 않는다.**
> ⚠️ **문서 신뢰 순서**(CLAUDE.md): `decisions/` > `api/`·`database/` > 구현 코드. 본 문서와 03이 충돌하면 **03 §2A + 결정문**이 우선한다(과거 판(FCM push) 잔재가 있으면 이메일 기준으로 무시).

## 0. 미션 (한 줄)

`notifications` INSERT가 곧 **이메일 발신** 트리거가 되도록 **발신 경로(Edge `send-email`)와 스케줄(pg_cron)을 배선**한다. 인앱 알림함(A8)이 이미 기록·목록·읽음을 보장하므로, **이메일은 best-effort "앱 밖에 있는 사람을 앱으로 부르는 신호"** — 실패해도 제품·RPC 트랜잭션에 영향 0.

곁들여: **`handle_new_user` 트리거의 Google OAuth 이름 누락 버그**를 같은 웨이브에서 고친다(이메일 커버리지 = 이 트리거의 `users.email` 채우기에 의존).

## 1. 범위 (DO / DON'T)

**DO**
- **`0012_cron.sql`** (신규): `pg_cron`·`pg_net` 확장 보장 + cron 2종 등록(멱등).
- **`0014_webhook.sql`** (신규, `0013_storage.sql` 번호 충돌 회피 → **0014**): `notifications` INSERT → **`send-email`** 호출 트리거(best-effort, 예외로 INSERT 못 깨게).
- Edge Function **`supabase/functions/send-email/index.ts`** (Deno) — 03 §2A 처리 순서 + **타입 필터/병합** + **mock 모드**(실 API 키 없이 로컬 전 구간 검증).
- **`supabase/config.toml`에 첫 `[functions.send-email]` 블록** 추가(`verify_jwt = false`).
- **`0011_triggers.sql` in-place 수정**: `handle_new_user`가 Google OAuth 이름(`full_name`/`name`)도 읽게.
- pgTAP **`supabase/tests/database/cron.sql`** (신규): cron 2종 + 웹훅 트리거 존재·멱등 검증.

**DON'T**
- RPC(0006–0010)·`notifications`/`notify()` 스키마·비즈니스 로직 **손대지 말 것**(발신은 순수 consumer). 타입 필터는 **Edge 안**에서만.
- **`send-push`(FCM)·VAPID·Service Worker·`fcm_tokens` 관련 코드 작성 금지** — v2 이월분. `fcm_tokens` 테이블·RLS는 **이미 존재하며 미사용 보존**, 삭제·수정 금지(0003:138, 0005:75·179·185·191·198).
- **실 발신 API 키(`EMAIL_API_KEY`)·`WEBHOOK_SECRET`·기타 실시크릿을 절대 커밋하지 말 것.** 로컬은 dummy/mock(§5).
- **`0013_storage.sql`를 건드리거나 재번호 매기지 말 것.** 신규는 0012·0014.
- 마이그레이션은 실배포 전이라 in-place 편집 허용이나(CLAUDE.md), **cron·webhook은 새 관심사이므로 신규 파일**로. `handle_new_user`만 **기존 0011 in-place 편집**.

## 2. 착수 전 확인 (스택에 대고 먼저 검증 — 가정 금지)

Docker Desktop이 떠 있어야 함(현재 `supabase_*_ass_backend` 컨테이너 가동 중). CLI 전체경로: `E:\Airsoft_Schedule_Workspace\.tools\supabase.exe`. `db reset` 후 psql로:

1. `select * from pg_available_extensions where name in ('pg_cron','pg_net');` — 로컬 이미지에 있음이 정상. 없으면 즉시 보고·중단.
2. **`0001_extensions.sql`을 먼저 읽어** `pg_cron`/`pg_net`이 이미 `create extension` 되는지 확인. 이미 있으면 0012에서는 `create extension if not exists`가 무해한 no-op(그대로 둬도 됨). 없으면 0012가 생성한다.
3. `select nspname from pg_namespace where nspname='supabase_functions';` + `\df supabase_functions.http_request` — 로컬 웹훅 트리거 함수 존재 여부. **있으면** §4a 사용 가능, **없으면** §4b(pg_net 직접) 사용. **판단 근거를 보고에 남길 것.**
4. cron.schedule 실행 롤: 로컬은 superuser(postgres) → 문제 없음.

### 검증된 백엔드 사실 (SQL 대조 완료 — 이 값에 맞춰 구현)

| 항목 | 실제 정의 |
|------|-----------|
| `notify()` | `0006_functions_util.sql:144` — `notify(p_user_id, p_type, p_title, p_body, p_action_url, p_data default null, p_session_id default null, p_participation_id default null)`. INSERT 컬럼: `user_id, type, title, body, action_url, data, game_session_id, participation_id`. execute는 public/anon/authenticated에서 revoke(SECURITY DEFINER RPC 내부에서만 호출). |
| `notifications` 컬럼 | `0003_tables.sql:124` — **수신자 = `user_id`**(NOT recipient_user_id), `type`(**free text**, enum 없음), `title`, `body`, `action_url`(NOT NULL), `data jsonb`(nullable), `game_session_id`, `participation_id`, `is_read`, `created_at`. |
| `type` 리터럴(6종) | `session.changed`, `session.upcoming_reminder`, `participation.confirmed`, `payment.decision`, `participation.decision`, `payment.requested`. **enum 아님** — 문자열 비교로 필터. |
| cron 대상 함수 | `0010_rpc_entrypass.sql` — `public.fn_status_transition()`(:274), `public.fn_send_reminders()`(:298). 둘 다 SECURITY DEFINER. (03 §3의 "02 §3" 표기는 드리프트 — 실제는 0010) |
| `handle_new_user` | `0011_triggers.sql:1`(함수), 트리거 `on_auth_user_created`(:19). 현재 `coalesce(raw_user_meta_data->>'display_name','')`만 읽음 → **Google OAuth 시 `''`(버그)**. |
| `users` | `0003_tables.sql:7` — `email text`(nullable, :9), `display_name text not null default ''`(:10). email은 handle_new_user가 insert 시 `auth.users.email`로 채움. |
| pgTAP | `tests/database/rls.sql`(`plan(102)`), `rpc.sql`(`plan(80)`) = **182**. `cron.sql` 없음. `fn_send_reminders`는 rpc.sql:838·840에서 이미 테스트됨. |
| config.toml | `[functions.*]` 블록 **전무**. `[edge_runtime]`만 존재. → **첫 블록 추가**. |
| 마이그레이션 | 0012 비어 있음, 0013_storage가 최고 번호, 0014 없음. |

## 3. T1 — `0012_cron.sql` (스케줄)

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 함수 본문은 0010(fn_status_transition, fn_send_reminders)에 이미 존재.
select cron.schedule('status-transition', '0 * * * *',    $$select public.fn_status_transition()$$);
select cron.schedule('send-reminders',    '*/30 * * * *', $$select public.fn_send_reminders()$$);
```
- **멱등성 필수**: `db reset` 반복에도 중복 job이 안 생기게. `cron.schedule`는 동일 jobname 재호출 시 갱신(덮어씀)이므로 그 성질을 이용하거나, 등록 전 `cron.unschedule`을 `where exists`로 감싼다. **검증: db reset 2회 후 `cron.job`에 각 jobname 1행씩만.**
- 타임존: cron은 UTC. 두 함수 모두 절대시각 비교라 무관(03 §3, `fn_send_reminders`는 23.5–24.5h 윈도우).

## 4. T2 — `0014_webhook.sql` (notifications INSERT → **send-email**)

로컬 Edge 서빙 URL: `http://host.docker.internal:54321/functions/v1/send-email`(DB 컨테이너 → 호스트). **실배포 URL 하드코딩 금지** — `current_setting('app.settings.functions_url', true)`로 읽고 로컬 기본값 fallback으로 조립. 웹훅 시크릿도 `current_setting('app.settings.webhook_secret', true)` 또는 Vault에서 읽고, **로컬은 dummy**.

**핵심 원칙**: 트리거는 **모든** `notifications` INSERT에 발화하고, **발송 여부(타입 필터·병합) 판정은 전적으로 Edge**가 한다(단일 소스). 트리거는 "일단 넘긴다"만.

**4a. `supabase_functions.http_request` 존재 시**
```sql
create trigger on_notification_created
after insert on public.notifications
for each row execute function supabase_functions.http_request(
  '<functions_url>/send-email', 'POST',
  '{"Content-Type":"application/json","x-webhook-secret":"<from setting/vault>"}',
  '{}', '5000'
);
```
**4b. 없으면 pg_net 직접 호출 트리거 함수**(권장 — 로컬 결정론적, `supabase_functions` 스키마 의존 없음)
```sql
create or replace function public.tg_notify_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url     := coalesce(current_setting('app.settings.functions_url', true),
                        'http://host.docker.internal:54321/functions/v1') || '/send-email',
    headers := jsonb_build_object(
                 'Content-Type','application/json',
                 'x-webhook-secret', coalesce(current_setting('app.settings.webhook_secret', true), 'local-dev-secret')),
    body    := to_jsonb(new)
  );
  return new;
exception when others then
  return new; -- 발신 실패가 INSERT/RPC 트랜잭션을 절대 못 깨게(best-effort)
end; $$;

create trigger on_notification_created after insert on public.notifications
for each row execute function public.tg_notify_email();
```
- 참고: **`net.http_post`는 비동기**(요청을 큐에 넣고 즉시 request id 반환, 실패는 `net._http_response`에 기록될 뿐 예외를 안 던짐) → best-effort가 자연 충족. 그래도 `exception when others`는 belt-and-suspenders로 유지.
- `db reset`/`test db` 중 INSERT가 이 트리거를 발화시켜도(서버 없는 URL로) **큐잉만 되고 무해**하다.
- **트리거가 예외로 INSERT를 못 깨게** 하는 것이 이 파일의 최우선 불변식.

## 5. T3 — Edge `supabase/functions/send-email/index.ts` (핵심)

03 §2A 처리 순서 + **mock 모드**. 발신 서비스 = **Brevo 권장**(무료 일 300/월 9,000 — 주말 버스트 대응; 대안 Resend는 일 100 하드캡 주의). 어댑터는 **얇게** — "notification row → 메일 1통" 변환만, Brevo 특화 로직은 이 파일 안에만(채널 교체 대비).

**처리 순서**
1. `x-webhook-secret` 검증 — 불일치 **401**(외부 호출 차단).
2. payload(new notification row) 파싱: `user_id, type, title, body, action_url, data`.
3. **타입 필터**(앱 밖 도달이 필요한 것만):

   | type | 발송? | 비고 |
   |------|-------|------|
   | `participation.decision` (반려) | ✅ | 제목 **중립**: "「게임명」 신청 결과 안내" 수준 |
   | `payment.requested` | ✅ | 입금 안내 |
   | `payment.decision` (사후 반려) | ✅ | 확정 오인 시 헛걸음 방지 |
   | `session.upcoming_reminder` (24h) | ✅ | 앱 밖 도달 전형 |
   | `session.changed` (변경·취소) | ✅ **최우선** | 미인지 시 헛걸음(최악) |
   | `participation.decision` (승인) | ⚠️ **병합** | 아래 병합 규칙 참조 |
   | `participation.confirmed` | ❌ **제외** | Gate B 첨부 즉시 확정 → 사용자가 그 순간 화면에 있음. 즉시 200 종료 |

4. **병합 규칙(중복 방지) — 반드시 구현·테스트로 고정**: 승인 RPC(`0008_rpc_participation.sql`)는 **같은 트랜잭션에서 `participation.decision`(승인)과 `payment.requested`를 둘 다** `notify()` 한다(참조: 0008:165·176·256). 게스트는 승인 시 **정확히 1통**만 받아야 한다.
   - **권장 구현 ⓑ(무상태·결정론적)**: `payment.requested`를 승인 메일의 정본으로 삼고, **`participation.decision`(승인)은 이메일 미발송(인앱만)**. `participation.decision`(반려)는 계속 발송.
   - 이때 Edge가 **승인 vs 반려를 구분**해야 한다 → **`0008_rpc_participation.sql`의 두 `notify()` 호출부(:165 승인, :256 반려)를 직접 읽어** `type`/`data`/`title` 중 무엇으로 구분 가능한지 확인하고, 그 신호로 분기. (구분 신호가 payload에 없으면 대안 ⓐ: 같은 `participation_id`로 직전 N초 내 발신 이력 스킵 — 상태 필요하므로 ⓑ가 안 되는 경우에만.)
   - **어느 쪽을 택했든 curl 케이스로 고정**하고 보고에 명시.
5. service-role 클라이언트로 `select email from public.users where id = <user_id>`. **비어 있으면 200 종료**(인앱만 — 설계상 안전, 결정문 §커버리지).
6. 발신: 제목 = `notification.title`, 본문 = `body` + **`action_url` 딥링크 버튼**("앱에서 확인하기"). **본문은 정보 최소화** — 상세(계좌·QR·명단)는 앱에서(윤보혁 "앱 안에서 모두 해결" 모토). 반려는 제목 중립.
7. **mock 모드 분기**: `Deno.env.get('EMAIL_API_KEY')`가 없거나 `EMAIL_DRY_RUN=1`이면 → 실제 발신 대신 `console.log`("would email <email>: <title>")만 남기고 200. **실 API 키 없이 로컬 전 구간 검증**이 이 항목의 목적.
8. **어떤 실패도 5xx로 던지지 않고 로깅 후 200**(웹훅/pg_net 재시도 폭주 방지·제품 무영향).

`config.toml`(첫 함수 블록 추가):
```toml
[functions.send-email]
verify_jwt = false   # 웹훅이 service-role/시크릿으로 호출 — JWT 아님
```

## 6. T4 — `handle_new_user` 이름 누락 버그 수정 (`0011_triggers.sql` **in-place**)

현재(`0011_triggers.sql:12`)는 `display_name`만 읽어 **Google OAuth 가입 시 `display_name`이 `''`**. Google/일반 메타데이터 키를 순서대로 fallback:
```sql
-- 0011_triggers.sql, handle_new_user 내 insert 값
coalesce(
  new.raw_user_meta_data->>'display_name',
  new.raw_user_meta_data->>'full_name',   -- Google OIDC
  new.raw_user_meta_data->>'name',        -- Google/기타
  ''
)
```
- 이메일/비번 가입은 `display_name`, Google은 `full_name`/`name` 경로로 커버(결정문 §커버리지 — Google은 이메일 항상 제공 → `users.email` 100% 근접).
- `users.email`도 이 트리거가 `new.email`로 채운다(이미 그러함) — **email 채우기 로직은 건드리지 말고 이름 fallback만** 추가.

## 7. T5 — pgTAP `supabase/tests/database/cron.sql` (신규)

`plan(N)`으로 새 파일. 검증 항목:
- `cron.job`에 `status-transition`·`send-reminders` 2행 존재 + `schedule` 문자열 일치(`'0 * * * *'`, `'*/30 * * * *'`).
- `pg_trigger`에 `on_notification_created` 존재(relation = `public.notifications`, AFTER INSERT).
- (가능하면) db reset 멱등: 각 cron jobname 1행씩만.
- `handle_new_user` 이름 fallback 검증은 auth.users INSERT가 필요 → **가능하면** `full_name`만 있는 메타데이터로 insert 후 `public.users.display_name`이 채워지는지 1케이스(어려우면 생략하고 보고에 명시).
- **기존 182(rls 102 + rpc 80)는 계속 PASS**. cron.sql은 그 위에 더해진다(총계 = 182 + N).

## 8. 검증 루프 (Codex가 돌릴 것)

```
SB="E:/Airsoft_Schedule_Workspace/.tools/supabase.exe"
& $SB db reset                     # 0011수정/0012/0014 적용 무오류
& $SB test db                      # pgTAP 전체 PASS(182 + cron.sql)
& $SB functions serve send-email   # (별 터미널)
# 웹훅 페이로드 모사 curl: 시크릿 유/무(401), 이메일 없는 사용자(200), participation.confirmed(미발송 200),
#   session.changed(발송/mock 로그), 승인 병합(1통), API 실패 시 200 유지
```
- **Codex 샌드박스가 Docker 파이프 접근 거부(EPERM)로 `db reset`/`test db`를 못 돌릴 수 있음** — 그 경우 **편집·정적검증까지 하고 "검증은 오케스트레이터(Claude)가 수행"으로 보고하고 멈출 것**(S2 때와 동일 분담; CLAUDE.md §4 "Codex가 보고 단계에서 멈춤" 함정 — 산출물은 대체로 온전하니 워킹트리를 남겨두면 Claude가 검증·커밋해서 완주시킨다).

## 9. 완료 기준 (03 §6 이메일 기준 + 본 문서)

1. `0012`/`0014`/`0011수정` **db reset 무오류**, cron 2종 등록·웹훅 트리거 생성 확인.
2. mock 모드로 `submit_payment`/승인 → `notifications` INSERT → **`send-email` 호출 로그**(실 키 0) 확인.
3. **타입 필터 동작**: `participation.confirmed` 미발송, `session.changed`·리마인더 발송. **승인 병합 = 1통**(택1 고정).
4. 이메일 없는 사용자·시크릿 불일치(401)·발신 API 실패 케이스 **모두 200 유지**(재시도 폭주 없음).
5. 어떤 발신 실패도 RPC·INSERT 트랜잭션을 롤백시키지 않음.
6. `handle_new_user`가 `full_name`/`name` fallback으로 Google 이름 채움.
7. `notifications`/RPC 스키마 무변경, `fcm_tokens` 무변경, **실시크릿 미커밋**.

## 10. 실배포 시 주입 (사람 몫 — Codex 범위 밖, 문서화만)

- **Brevo 계정 + 발신자(도메인) 인증 + `EMAIL_API_KEY`** — Phase 3. 커스텀 도메인 + SPF/DKIM(가능하면 DMARC)은 네이버·다음 스팸 회피에 **필수**(Vercel 도메인과 공용).
- `EMAIL_FROM`(예: `ASS <noreply@도메인>`), `WEBHOOK_SECRET`, `app.settings.functions_url` — Edge env / DB 설정 / Vault.
- 로컬은 전부 dummy/mock. **`send-push`(FCM)·VAPID는 v2 착수 시** 03 §2B·5B 설계로 복귀.
