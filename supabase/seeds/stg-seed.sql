-- 스테이징 시드 데이터 — FE 개발용
--
-- 실행: .github/workflows/seed-stg.yml (workflow_dispatch)
--       또는  supabase db query --linked -f supabase/seeds/stg-seed.sql
--
-- ⚠️ __SEED_PASSWORD__ 는 워크플로가 실행 직전에 치환한다.
--    이 파일에 실제 비밀번호를 적지 말 것 (public repo).
--
-- 성질: 고정 UUID라 여러 번 실행해도 안전하다. 다만 대상에 따라 갱신 여부가 다르다.
--
--   참조 데이터(팀·필드·프리셋·룰 노트)와 게임의 custom_rules → do update
--     정본이므로 재실행이 "최신 정의로 맞추는" 동작이 되어야 한다.
--     스키마가 바뀌었는데 do nothing이면 옛 데이터가 영영 남는다(실제로 겪음).
--
--   계정·참가·입장권·알림 → do nothing
--     앱에서 테스트하며 만든 상태를 덮으면 안 된다.
--     게임의 제목·상태·인원수도 같은 이유로 갱신하지 않는다.
--
-- 범위: 선입금 폐기(0017) · 게임룰 구조(0018) 이후 스키마 기준.

begin;

-- ─────────────────────────────────────────────────────────
-- 1. 계정 — 실제 로그인 가능
--
--    auth.users + auth.identities 두 곳이 모두 있어야 이메일 로그인이 된다.
--    public.users는 handle_new_user 트리거가 자동 생성한다.
--    비밀번호 해시는 실제 가입과 동일한 형식($2a$10$)을 쓴다.
-- ─────────────────────────────────────────────────────────
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
select
  v.id::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated',
  'authenticated',
  v.email,
  extensions.crypt('__SEED_PASSWORD__', extensions.gen_salt('bf', 10)),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object(
    'sub', v.id,
    'email', v.email,
    'display_name', v.display_name,
    'email_verified', true,
    'phone_verified', false
  ),
  now(),
  now()
from (values
  ('a0000000-0000-0000-0000-000000000001', 'host@ass.test',  '김호스트'),
  ('a0000000-0000-0000-0000-000000000002', 'p1@ass.test',    '박플레이어'),
  ('a0000000-0000-0000-0000-000000000003', 'p2@ass.test',    '이참가'),
  ('a0000000-0000-0000-0000-000000000004', 'p3@ass.test',    '최게스트'),
  ('a0000000-0000-0000-0000-000000000005', 'p4@ass.test',    '정신입'),
  ('a0000000-0000-0000-0000-000000000006', 'p5@ass.test',    '강루키')
) as v(id, email, display_name)
on conflict (id) do nothing;

-- GoTrue는 이 토큰 컬럼들을 non-nullable 문자열로 읽는다. NULL로 두면
-- 로그인이 "Database error querying schema"(500)로 실패한다.
update auth.users
set confirmation_token      = coalesce(confirmation_token, ''),
    recovery_token          = coalesce(recovery_token, ''),
    email_change            = coalesce(email_change, ''),
    email_change_token_new  = coalesce(email_change_token_new, '')
where email like '%@ass.test';

insert into auth.identities (id, provider_id, user_id, provider, identity_data, created_at, updated_at)
select
  gen_random_uuid(),
  u.id::text,
  u.id,
  'email',
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true, 'phone_verified', false),
  now(),
  now()
from auth.users u
where u.email like '%@ass.test'
  and not exists (
    select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email'
  );

-- 연락처는 트리거가 채우지 않으므로 따로 넣는다 (프로필 완성 판정에는 닉네임만 필요)
update public.users set phone_number = '010-0000-000' || right(id::text, 1)
where email like '%@ass.test' and phone_number is null;

-- ─────────────────────────────────────────────────────────
-- 2. 참조 데이터
-- ─────────────────────────────────────────────────────────
insert into public.teams (id, name) values
  ('b0000000-0000-0000-0000-000000000001', '서울 팬텀'),
  ('b0000000-0000-0000-0000-000000000002', '경기 레이븐')
on conflict (id) do update
  set name = excluded.name;

insert into public.fields (id, name, address, lat, lng) values
  ('c0000000-0000-0000-0000-000000000001', '파주 서바이벌 필드', '경기 파주시 조리읍', 37.7583, 126.7800),
  ('c0000000-0000-0000-0000-000000000002', '용인 CQB 아레나',    '경기 용인시 처인구', 37.2411, 127.1776),
  ('c0000000-0000-0000-0000-000000000003', '김포 야외 필드',      '경기 김포시 대곶면', 37.6100, 126.5150),
  ('c0000000-0000-0000-0000-000000000004', '남양주 우드랜드',     '경기 남양주시 화도읍', 37.6650, 127.3050)
on conflict (id) do update
  set name    = excluded.name,
      address = excluded.address,
      lat     = excluded.lat,
      lng     = excluded.lng;

-- 공용 프리셋 — owner_id null + is_public true (0018 스키마)
insert into public.game_rule_presets (id, name, description, rules, owner_id, is_public) values
  (
    'd0000000-0000-0000-0000-000000000001',
    '수도권 표준',
    '수도권 필드에서 통용되는 기본 규격',
    '{"muzzleVelocityFps": 400, "bbWeightGrams": 0.25, "bioBbRequired": true, "magazineLimit": null}'::jsonb,
    null,
    true
  ),
  (
    'd0000000-0000-0000-0000-000000000002',
    'CQB 실내',
    '실내 근접전 기준 — 탄속을 낮게 제한',
    '{"muzzleVelocityFps": 330, "bbWeightGrams": 0.20, "bioBbRequired": true, "magazineLimit": 5}'::jsonb,
    null,
    true
  )
on conflict (id) do update
  set name        = excluded.name,
      description = excluded.description,
      rules       = excluded.rules,
      owner_id    = excluded.owner_id,
      is_public   = excluded.is_public;

-- 개인 룰 노트 — owner_id 지정 + is_public false.
-- 별도 테이블 없이 같은 구조를 쓴다(2026-07-16 회의: "별도 테이블로 만들기보다").
-- 게임 생성 폼에서 불러와 noteBlocks로 이어붙이는 용도다.
insert into public.game_rule_presets (id, name, description, rules, owner_id, is_public) values
  (
    'd0000000-0000-0000-0000-000000000011',
    '기관총 운용 규칙',
    '박스매거진·지향사격 관련 로컬룰',
    '{"muzzleVelocityFps": 400, "noteBlocks": [{"title": "기관총 운용", "body": "박스매거진 허용. 지향사격만 가능하며 조준사격은 금지."}]}'::jsonb,
    'a0000000-0000-0000-0000-000000000001',
    false
  ),
  (
    'd0000000-0000-0000-0000-000000000012',
    '근거리 교전 규칙',
    '동시전사·세이프티킬 처리',
    '{"muzzleVelocityFps": 400, "noteBlocks": [{"title": "근거리 동시전사", "body": "5m 이내 동시 피격 시 양측 전사 처리."}, {"title": "세이프티킬", "body": "3m 이내에서는 사격 대신 구두 선언으로 전사 처리."}]}'::jsonb,
    'a0000000-0000-0000-0000-000000000001',
    false
  )
on conflict (id) do update
  set name        = excluded.name,
      description = excluded.description,
      rules       = excluded.rules,
      owner_id    = excluded.owner_id,
      is_public   = excluded.is_public;

-- ─────────────────────────────────────────────────────────
-- 3. 게임 세션 — 상태별로 하나씩 (목록·상세 화면 검증용)
-- ─────────────────────────────────────────────────────────
insert into public.game_sessions (
  id, title, created_by_user_id, host_team_id, field_id,
  starts_at, ends_at, capacity, confirmed_count, game_fee,
  preset_id, custom_rules, cancel_deadline, status
) values
  -- 모집 중 · 자리 여유 (승인 대기 2건 포함 — 운영 화면 확인용)
  ('e0000000-0000-0000-0000-000000000001', '주말 정기전 — 파주',
   'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
   now() + interval '7 days', now() + interval '7 days 6 hours', 20, 3, 30000,
   'd0000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400, "bbWeightGrams": 0.25, "bioBbRequired": true, "noteBlocks": [{"title": "기관총 운용", "body": "박스매거진 허용. 지향사격만 가능."}, {"title": "근거리 동시전사", "body": "5m 이내 동시 피격 시 양측 전사 처리."}]}'::jsonb, now() + interval '5 days', 'recruiting'),

  -- 모집 중 · 마감 임박 (1자리)
  ('e0000000-0000-0000-0000-000000000002', 'CQB 야간전 — 용인',
   'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002',
   now() + interval '3 days', now() + interval '3 days 4 hours', 6, 5, 25000,
   'd0000000-0000-0000-0000-000000000002', '{"muzzleVelocityFps": 330, "bbWeightGrams": 0.20, "bioBbRequired": true, "magazineLimit": 5}'::jsonb, now() + interval '1 day', 'recruiting'),

  -- 정원 마감
  ('e0000000-0000-0000-0000-000000000003', '소수 정예 미션 — 김포',
   'a0000000-0000-0000-0000-000000000001', null, 'c0000000-0000-0000-0000-000000000003',
   now() + interval '5 days', now() + interval '5 days 5 hours', 3, 3, 40000,
   'd0000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400, "bbWeightGrams": 0.25, "bioBbRequired": true, "magazineLimit": null}'::jsonb, now() + interval '3 days', 'closed'),

  -- 진행 중 (QR 스캔 화면 확인용)
  ('e0000000-0000-0000-0000-000000000004', '오늘 진행 중 — 남양주',
   'a0000000-0000-0000-0000-000000000001', null, 'c0000000-0000-0000-0000-000000000004',
   now() - interval '1 hour', now() + interval '5 hours', 10, 2, 20000,
   'd0000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400, "bbWeightGrams": 0.25, "bioBbRequired": true, "magazineLimit": null}'::jsonb, now() - interval '2 days', 'inProgress'),

  -- 완료 (출석 이력 확인용)
  ('e0000000-0000-0000-0000-000000000005', '지난주 정기전 — 파주',
   'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
   now() - interval '3 days', now() - interval '3 days' + interval '6 hours', 10, 2, 30000,
   'd0000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400, "bbWeightGrams": 0.25, "bioBbRequired": true, "magazineLimit": null}'::jsonb, now() - interval '5 days', 'completed'),

  -- 취소됨
  ('e0000000-0000-0000-0000-000000000006', '우천 취소된 게임 — 용인',
   'a0000000-0000-0000-0000-000000000001', null, 'c0000000-0000-0000-0000-000000000002',
   now() + interval '10 days', now() + interval '10 days 5 hours', 12, 0, 25000,
   'd0000000-0000-0000-0000-000000000002', '{"muzzleVelocityFps": 330, "bbWeightGrams": 0.20, "bioBbRequired": true, "magazineLimit": 5}'::jsonb, now() + interval '8 days', 'cancelled'),

  -- 다른 사람이 호스트 (p1 시점의 "운영" 탭 확인용)
  ('e0000000-0000-0000-0000-000000000007', '박플레이어가 여는 번개',
   'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003',
   now() + interval '9 days', now() + interval '9 days 4 hours', 8, 1, 15000,
   'd0000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400, "bbWeightGrams": 0.25, "bioBbRequired": true, "magazineLimit": null}'::jsonb, now() + interval '7 days', 'recruiting')
-- 룰은 참조 성격이라 갱신하되, 제목·상태·인원수는 앱에서 테스트하며
-- 바뀌었을 수 있으므로 덮지 않는다.
on conflict (id) do update
  set custom_rules = excluded.custom_rules,
      preset_id    = excluded.preset_id;

-- ─────────────────────────────────────────────────────────
-- 4. 참가 — 상태 5종을 모두 포함
-- ─────────────────────────────────────────────────────────
insert into public.participations (id, game_session_id, user_id, status) values
  -- E1 확정 3 + 승인 대기 2 + 반려 1
  ('f0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'confirmed'),
  ('f0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003', 'confirmed'),
  ('f0000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000004', 'confirmed'),
  ('f0000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005', 'pendingApproval'),
  ('f0000000-0000-0000-0000-000000000005', 'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000006', 'pendingApproval'),

  -- E2 확정 5 (1자리 남음)
  ('f0000000-0000-0000-0000-000000000006', 'e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', 'confirmed'),
  ('f0000000-0000-0000-0000-000000000007', 'e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000003', 'confirmed'),
  ('f0000000-0000-0000-0000-000000000008', 'e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000004', 'confirmed'),
  ('f0000000-0000-0000-0000-000000000009', 'e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000005', 'confirmed'),
  ('f0000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000006', 'confirmed'),

  -- E3 정원 마감
  ('f0000000-0000-0000-0000-00000000000b', 'e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', 'confirmed'),
  ('f0000000-0000-0000-0000-00000000000c', 'e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000003', 'confirmed'),
  ('f0000000-0000-0000-0000-00000000000d', 'e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000004', 'confirmed'),

  -- E4 진행 중 — 출석 1 + 미출석 1
  ('f0000000-0000-0000-0000-00000000000e', 'e0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000002', 'attended'),
  ('f0000000-0000-0000-0000-00000000000f', 'e0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000003', 'confirmed'),

  -- E5 완료 — 출석 이력
  ('f0000000-0000-0000-0000-000000000010', 'e0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000002', 'attended'),
  ('f0000000-0000-0000-0000-000000000011', 'e0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000003', 'attended'),

  -- E6 취소된 게임
  ('f0000000-0000-0000-0000-000000000012', 'e0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000002', 'cancelled'),

  -- E7 p1이 호스트 — 호스트 본인 참가 + 승인 대기 1
  ('f0000000-0000-0000-0000-000000000013', 'e0000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000002', 'confirmed'),
  ('f0000000-0000-0000-0000-000000000014', 'e0000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000003', 'pendingApproval'),

  -- 반려 이력 (내 참가 화면에서 반려 상태 확인용)
  ('f0000000-0000-0000-0000-000000000015', 'e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000005', 'rejected')
on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────
-- 5. QR 서명 시크릿 — 없을 때만 생성
--
--    이게 없으면 build_entry_pass_token·get_entry_pass_token이 전부 실패해
--    QR 화면을 아예 테스트할 수 없다. 값은 실행 시마다 무작위로 만들어
--    저장소에 알려진 값이 남지 않게 한다.
--    ⚠️ 운영(prd)에는 이 경로로 만들지 말고 별도로 주입할 것.
-- ─────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'qr_hmac_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'qr_hmac_secret');
  end if;
end;
$$;

-- ─────────────────────────────────────────────────────────
-- 6. 입장권 — 확정자에게 활성, 출석자에게 사용됨
--    토큰 해시는 실제 발급 함수와 같은 방식으로 만든다.
-- ─────────────────────────────────────────────────────────
insert into public.entry_passes (
  id, participation_id, game_session_id, user_id,
  status, qr_token_hash, issued_at, expires_at, used_at, scanned_by
)
select
  v.id::uuid,
  v.participation_id::uuid,
  p.game_session_id,
  p.user_id,
  v.status::public.entry_pass_status,
  public.hash_entry_pass_token(
    public.build_entry_pass_token(v.id::uuid, p.game_session_id, p.user_id, now(), 'v1')
  ),
  now(),
  s.starts_at + interval '12 hours',
  case when v.status = 'used' then s.starts_at + interval '30 minutes' else null end,
  case when v.status = 'used' then s.created_by_user_id else null end
from (values
  ('11000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 'active'),
  ('11000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000002', 'active'),
  ('11000000-0000-0000-0000-000000000003', 'f0000000-0000-0000-0000-000000000006', 'active'),
  ('11000000-0000-0000-0000-000000000004', 'f0000000-0000-0000-0000-00000000000b', 'active'),
  ('11000000-0000-0000-0000-000000000005', 'f0000000-0000-0000-0000-00000000000e', 'used'),
  ('11000000-0000-0000-0000-000000000006', 'f0000000-0000-0000-0000-00000000000f', 'active'),
  ('11000000-0000-0000-0000-000000000007', 'f0000000-0000-0000-0000-000000000013', 'active')
) as v(id, participation_id, status)
join public.participations p on p.id = v.participation_id::uuid
join public.game_sessions s on s.id = p.game_session_id
on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────
-- 7. 알림 — 알림 목록 화면용 (읽음/안읽음 섞어서)
-- ─────────────────────────────────────────────────────────
insert into public.notifications (
  id, user_id, type, title, body, action_url, data,
  game_session_id, participation_id, is_read, created_at
) values
  ('12000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002',
   'participation.decision', '참가 신청이 승인되었습니다',
   '주말 정기전 — 파주 참가 신청이 승인되어 참석이 확정되었습니다',
   '/participations/f0000000-0000-0000-0000-000000000001',
   '{"decision":"approved"}'::jsonb,
   'e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001',
   false, now() - interval '2 hours'),

  ('12000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002',
   'participation.confirmed', '참석이 확정되었습니다',
   '주말 정기전 — 파주 참석 확정! QR 입장권을 확인하세요',
   '/participations/f0000000-0000-0000-0000-000000000001/pass',
   '{"entryPassId":"11000000-0000-0000-0000-000000000001"}'::jsonb,
   'e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001',
   false, now() - interval '2 hours'),

  ('12000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002',
   'session.upcoming_reminder', '내일 게임이 있습니다',
   'CQB 야간전 — 용인 시작 24시간 전입니다',
   '/sessions/e0000000-0000-0000-0000-000000000002',
   null,
   'e0000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000006',
   true, now() - interval '1 day'),

  ('12000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000002',
   'session.changed', '게임이 취소되었습니다',
   '우천 취소된 게임 — 용인이(가) 취소되었습니다. 기상 악화',
   '/sessions/e0000000-0000-0000-0000-000000000006',
   '{"type":"cancelled","reason":"기상 악화"}'::jsonb,
   'e0000000-0000-0000-0000-000000000006', 'f0000000-0000-0000-0000-000000000012',
   true, now() - interval '3 days'),

  ('12000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000005',
   'participation.decision', '참가 신청 결과 안내',
   '소수 정예 미션 — 김포 참가 신청이 반려되었습니다',
   '/participations/f0000000-0000-0000-0000-000000000015',
   '{"decision":"rejected"}'::jsonb,
   'e0000000-0000-0000-0000-000000000003', 'f0000000-0000-0000-0000-000000000015',
   false, now() - interval '5 hours')
on conflict (id) do nothing;

commit;

-- 결과 요약
select
  (select count(*) from auth.users where email like '%@ass.test') as 계정,
  (select count(*) from public.game_sessions) as 게임,
  (select count(*) from public.participations) as 참가,
  (select count(*) from public.entry_passes) as 입장권,
  (select count(*) from public.notifications) as 알림;
