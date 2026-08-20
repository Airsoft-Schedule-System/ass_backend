begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(52);

create schema if not exists tests;

create or replace function tests.error_hint(sql text)
returns text
language plpgsql
security invoker
as $$
declare
  v_hint text;
begin
  execute sql;
  return null;
exception
  when others then
    get stacked diagnostics v_hint = PG_EXCEPTION_HINT;
    return v_hint;
end;
$$;

create or replace function tests.error_detail(sql text)
returns text
language plpgsql
security invoker
as $$
declare
  v_detail text;
begin
  execute sql;
  return null;
exception
  when others then
    get stacked diagnostics v_detail = PG_EXCEPTION_DETAIL;
    return v_detail;
end;
$$;

do $$
begin
  perform vault.create_secret('qr-test-secret', 'qr_hmac_secret');
end;
$$;

grant usage on schema tests to anon, authenticated;
grant execute on function tests.error_hint(text) to anon, authenticated;
grant execute on function tests.error_detail(text) to anon, authenticated;

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner@example.test', 'test-password-hash', now(), '{"provider":"email","providers":["email"]}', '{"display_name":"Owner"}', now(), now()),
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'player@example.test', 'test-password-hash', now(), '{"provider":"email","providers":["email"]}', '{"display_name":"Player"}', now(), now()),
  ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'other@example.test', 'test-password-hash', now(), '{"provider":"email","providers":["email"]}', '{"display_name":"Other"}', now(), now()),
  ('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'other-owner@example.test', 'test-password-hash', now(), '{"provider":"email","providers":["email"]}', '{"display_name":"Other Owner"}', now(), now()),
  ('00000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'incomplete@example.test', 'test-password-hash', now(), '{"provider":"email","providers":["email"]}', '{"display_name":""}', now(), now());

insert into public.teams (id, name)
values ('10000000-0000-0000-0000-000000000001', 'Alpha');

insert into public.fields (id, name, address, lat, lng)
values ('20000000-0000-0000-0000-000000000001', 'Field A', 'Seoul', 37.1, 127.1);

insert into public.game_rule_presets (id, name, rules, owner_id, is_public)
values ('30000000-0000-0000-0000-000000000001', 'Public preset', '{}', null, true);

insert into public.game_sessions (
  id,
  title,
  created_by_user_id,
  field_id,
  starts_at,
  ends_at,
  capacity,
  confirmed_count,
  game_fee,
  preset_id,
  custom_rules,
  cancel_deadline,
  status
) values
  ('41000000-0000-0000-0000-000000000001', 'Request Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 10, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000002', 'Other Owner Session', '00000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', now() + interval '8 days', now() + interval '8 days 6 hours', 10, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '6 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000003', 'Closed Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 1, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '5 days', 'closed'),
  ('41000000-0000-0000-0000-000000000004', 'In Progress Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '1 hour', now() + interval '5 hours', 10, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() - interval '1 day', 'inProgress'),
  ('41000000-0000-0000-0000-000000000005', 'Completed Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '3 days', now() - interval '2 days', 10, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() - interval '4 days', 'completed'),
  ('41000000-0000-0000-0000-000000000006', 'Capacity Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 1, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '7 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000007', 'Full Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 1, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '7 days', 'closed'),
  ('41000000-0000-0000-0000-000000000008', 'Closed Cancel Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 2, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '7 days', 'closed'),
  ('41000000-0000-0000-0000-000000000009', 'Refund Future Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 3, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '7 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000010', 'Refund Past Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '2 days', now() + interval '2 days 6 hours', 3, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() - interval '1 hour', 'recruiting'),
  ('41000000-0000-0000-0000-000000000011', 'Transition Full', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '4 days', now() + interval '4 days 6 hours', 1, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '2 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000012', 'Transition Past Start', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '1 hour', now() + interval '5 hours', 10, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() - interval '1 day', 'recruiting'),
  ('41000000-0000-0000-0000-000000000013', 'Transition Complete', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '2 days', now() - interval '1 day', 10, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() - interval '3 days', 'inProgress'),
  ('41000000-0000-0000-0000-000000000014', 'Reminder Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '24 hours', now() + interval '30 hours', 10, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '12 hours', 'recruiting'),
  ('41000000-0000-0000-0000-000000000015', 'QR Reuse Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 10, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000016', 'QR Expired Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '2 days', now() - interval '1 day', 10, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() - interval '3 days', 'inProgress'),
  ('41000000-0000-0000-0000-000000000017', 'Operator Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 1, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000018', 'Review Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 1, 1, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '5 days', 'closed'),
  ('41000000-0000-0000-0000-000000000019', 'Operator Refund Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 2, 0, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000020', 'Cancel Count Session', '00000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 5, 2, 30000, '30000000-0000-0000-0000-000000000001', '{"muzzleVelocityFps": 400}'::jsonb, now() + interval '5 days', 'closed');

insert into public.participations (id, game_session_id, user_id, status)
values
  ('51000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000002', 'pendingApproval'),
  ('51000000-0000-0000-0000-000000000002', '41000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000002', 'pendingApproval'),
  ('51000000-0000-0000-0000-000000000003', '41000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000003', 'pendingApproval'),
  ('51000000-0000-0000-0000-000000000004', '41000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000005', '41000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000006', '41000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000002', 'cancelled'),
  ('51000000-0000-0000-0000-000000000007', '41000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000003', 'cancelled'),
  ('51000000-0000-0000-0000-000000000008', '41000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000009', '41000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000010', '41000000-0000-0000-0000-000000000016', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000011', '41000000-0000-0000-0000-000000000018', '00000000-0000-0000-0000-000000000002', 'pendingApproval'),
  ('51000000-0000-0000-0000-000000000012', '41000000-0000-0000-0000-000000000018', '00000000-0000-0000-0000-000000000003', 'confirmed'),
  ('51000000-0000-0000-0000-000000000013', '41000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000014', '41000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000003', 'confirmed');

insert into storage.objects (id, bucket_id, name, owner, owner_id, metadata)
values
  (
    'a1000000-0000-0000-0000-000000000001',
    'receipts',
    'receipts/51000000-0000-0000-0000-000000000011/upload.jpg',
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000002',
    '{"mimetype":"image/jpeg"}'
  ),
  (
    'a1000000-0000-0000-0000-000000000002',
    'receipts',
    'receipts/51000000-0000-0000-0000-000000000002/upload.jpg',
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000002',
    '{"mimetype":"image/jpeg"}'
  ),
  (
    'a1000000-0000-0000-0000-000000000003',
    'receipts',
    'receipts/51000000-0000-0000-0000-000000000003/upload.jpg',
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000003',
    '{"mimetype":"image/jpeg"}'
  ),
  (
    'a1000000-0000-0000-0000-000000000004',
    'receipts',
    'receipts/51000000-0000-0000-0000-000000000012/resubmit.jpg',
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000003',
    '{"mimetype":"image/jpeg"}'
  );

insert into public.entry_passes (
  id,
  participation_id,
  game_session_id,
  user_id,
  qr_token_hash,
  issued_at,
  expires_at
) values
  (
    '81000000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000009',
    '41000000-0000-0000-0000-000000000015',
    '00000000-0000-0000-0000-000000000002',
    public.hash_entry_pass_token(public.build_entry_pass_token('81000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000002', now(), 'v1')),
    now(),
    now() + interval '1 day'
  ),
  (
    '81000000-0000-0000-0000-000000000002',
    '51000000-0000-0000-0000-000000000010',
    '41000000-0000-0000-0000-000000000016',
    '00000000-0000-0000-0000-000000000002',
    public.hash_entry_pass_token(public.build_entry_pass_token('81000000-0000-0000-0000-000000000002', '41000000-0000-0000-0000-000000000016', '00000000-0000-0000-0000-000000000002', now() - interval '2 days', 'v1')),
    now() - interval '2 days',
    now() - interval '1 hour'
  ),
  (
    '81000000-0000-0000-0000-000000000003',
    '51000000-0000-0000-0000-000000000004',
    '41000000-0000-0000-0000-000000000008',
    '00000000-0000-0000-0000-000000000002',
    'cancel-hash',
    now(),
    now() + interval '1 day'
  ),
  (
    '81000000-0000-0000-0000-000000000004',
    '51000000-0000-0000-0000-000000000012',
    '41000000-0000-0000-0000-000000000018',
    '00000000-0000-0000-0000-000000000003',
    'review-hash',
    now(),
    now() + interval '8 days'
  );

create temp table test_tokens (
  name text primary key,
  entry_pass_id uuid not null,
  token text not null
) on commit drop;

insert into test_tokens
values
  (
    'reuse',
    '81000000-0000-0000-0000-000000000001',
    public.build_entry_pass_token('81000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000002', (select issued_at from public.entry_passes where id = '81000000-0000-0000-0000-000000000001'), 'v1')
  ),
  (
    'expired',
    '81000000-0000-0000-0000-000000000002',
    public.build_entry_pass_token('81000000-0000-0000-0000-000000000002', '41000000-0000-0000-0000-000000000016', '00000000-0000-0000-0000-000000000002', (select issued_at from public.entry_passes where id = '81000000-0000-0000-0000-000000000002'), 'v1')
  );

grant select on test_tokens to authenticated;

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  tests.error_hint($$select public.create_game_session('{}'::jsonb)$$),
  'unauthenticated',
  'unauthenticated RPC call is rejected with hint'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.request_participation('41000000-0000-0000-0000-000000000001')->>'status',
  'pendingApproval',
  'authenticated user can request participation'
);

select is(
  tests.error_hint($$select public.request_participation('41000000-0000-0000-0000-000000000001')$$),
  'already-exists',
  'duplicate participation request is rejected'
);

select is(
  tests.error_hint($$select public.request_participation('41000000-0000-0000-0000-000000000003')$$),
  'failed-precondition',
  'request_participation rejects closed session'
);

select is(
  tests.error_hint($$select public.approve_participation((select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000001' and user_id = '00000000-0000-0000-0000-000000000002'))$$),
  'permission-denied',
  'non-owner cannot approve participation'
);

select is(
  (select data->>'entryPassId' from public.notifications where participation_id = '51000000-0000-0000-0000-000000000002' and type = 'participation.confirmed'),
  (select id::text from public.entry_passes where participation_id = '51000000-0000-0000-0000-000000000002' and status = 'active'),
  'participation.confirmed notification includes entryPassId'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000003';
set local "request.jwt.claim.role" = 'authenticated';

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.approve_participation((select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000001' and user_id = '00000000-0000-0000-0000-000000000002'))->>'newStatus',
  'confirmed',
  'session owner can approve participation'
);

reset role;

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  tests.error_hint($$select public.approve_participation('51000000-0000-0000-0000-000000000001')$$),
  'failed-precondition',
  'approve_participation rejects inProgress session'
);

select is(
  tests.error_hint($$select public.update_game_session('41000000-0000-0000-0000-000000000005', '{"title":"Blocked"}'::jsonb)$$),
  'failed-precondition',
  'update_game_session rejects completed session'
);

select is(
  tests.error_hint($$
    select public.create_game_session(
      jsonb_build_object(
        'title', 'Bad Deadline Session',
        'fieldId', '20000000-0000-0000-0000-000000000001',
        'startsAt', (now() + interval '5 days')::text,
        'endsAt', (now() + interval '5 days 6 hours')::text,
        'capacity', 10,
        'gameFee', 30000,
        'presetId', '30000000-0000-0000-0000-000000000001',
        'customRules', jsonb_build_object('muzzleVelocityFps', 400),
        'cancelDeadline', (now() + interval '6 days')::text
      )
    )
  $$),
  'invalid-argument',
  'create_game_session rejects cancelDeadline after startsAt'
);

select is(
  tests.error_hint($$
    select public.create_game_session(
      jsonb_build_object(
        'title', 'Bad Field Session',
        'fieldId', 'not-a-uuid',
        'startsAt', (now() + interval '5 days')::text,
        'endsAt', (now() + interval '5 days 6 hours')::text,
        'capacity', 10,
        'gameFee', 30000,
        'presetId', '30000000-0000-0000-0000-000000000001',
        'customRules', jsonb_build_object('muzzleVelocityFps', 400)
      )
    )
  $$),
  'invalid-argument',
  'create_game_session rejects malformed fieldId with app hint'
);

select is(
  public.update_game_session('41000000-0000-0000-0000-000000000015', '{"capacity":11}'::jsonb)->'updatedFields',
  '["capacity"]'::jsonb,
  'update_game_session returns camelCase updatedFields'
);

reset role;

select is(
  (select count(*) from public.notifications where game_session_id = '41000000-0000-0000-0000-000000000015' and type = 'session.changed'),
  1::bigint,
  'update_game_session capacity change creates session.changed notification'
);

-- ── RT-04: 값이 그대로면 변경으로 치지 않는다 ──────────────
-- 같은 값을 반복해서 보내면 알림이 계속 생겨 외부 메일 릴레이가 됐다.
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.update_game_session('41000000-0000-0000-0000-000000000015', '{"capacity":11}'::jsonb)->'updatedFields',
  '[]'::jsonb,
  'update_game_session은 같은 capacity 재전송을 변경으로 치지 않는다'
);

select is(
  public.update_game_session(
    '41000000-0000-0000-0000-000000000015',
    jsonb_build_object('customRules', (select custom_rules from public.game_sessions where id = '41000000-0000-0000-0000-000000000015'))
  )->'updatedFields',
  '[]'::jsonb,
  'update_game_session은 같은 customRules 재전송을 변경으로 치지 않는다'
);

reset role;

select is(
  (select count(*) from public.notifications where game_session_id = '41000000-0000-0000-0000-000000000015' and type = 'session.changed'),
  1::bigint,
  'no-op 업데이트는 알림을 추가로 만들지 않는다'
);

-- 실제로 바뀌면 여전히 알린다
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.update_game_session('41000000-0000-0000-0000-000000000015', '{"capacity":12}'::jsonb)->'updatedFields',
  '["capacity"]'::jsonb,
  '실제 capacity 변경은 여전히 변경으로 친다'
);

reset role;

select is(
  (select count(*) from public.notifications where game_session_id = '41000000-0000-0000-0000-000000000015' and type = 'session.changed'),
  2::bigint,
  '실제 변경은 알림을 만든다'
);

-- ── RT-06: auth 이메일 변경이 발송 주소에 반영된다 ──────────
update auth.users set email = 'owner-changed@example.test'
where id = '00000000-0000-0000-0000-000000000001';

select is(
  (select email from public.users where id = '00000000-0000-0000-0000-000000000001'),
  'owner-changed@example.test',
  'auth 이메일 변경이 public.users로 동기화된다'
);

-- 가드를 "auth 이메일과 일치하는 변경만 허용"으로 다시 썼으므로,
-- 권한 있는 경로에서도 임의 값은 여전히 막혀야 한다.
select throws_ok(
  $$update public.users set email = 'attacker@example.test'
    where id = '00000000-0000-0000-0000-000000000001'$$,
  '42501',
  'users.email must match the authenticated identity',
  'public.users.email을 auth와 다른 값으로 바꿀 수 없다'
);

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

-- RLS(notifications_select_self)에 가려 통과하는 거짓 양성을 피하려고 롤 해제 후 확인
reset role;

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

-- 알림 수신자는 참가자(...0003)이고 현재 롤은 운영자(...0001) — notifications_select_self RLS를 우회하기 위해 롤 해제 후 확인
reset role;

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000003';
set local "request.jwt.claim.role" = 'authenticated';

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.cancel_participation('51000000-0000-0000-0000-000000000004')->>'refundEligible',
  'true',
  'cancel_participation treats rejected payment evidence as refund eligible'
);

select is(
  (select status::text from public.game_sessions where id = '41000000-0000-0000-0000-000000000008'),
  'recruiting',
  'cancel_participation reopens a closed session when capacity frees'
);

select is(
  (select status::text from public.entry_passes where id = '81000000-0000-0000-0000-000000000003'),
  'revoked',
  'cancel_participation revokes active entry pass'
);

select is(
  tests.error_hint($$select public.join_as_operator('41000000-0000-0000-0000-000000000011')$$),
  'failed-precondition',
  'join_as_operator rejects full capacity'
);

select is(
  public.join_as_operator('41000000-0000-0000-0000-000000000017')->>'status',
  'confirmed',
  'join_as_operator immediately confirms owner'
);

select is(
  (select count(*) from public.entry_passes where participation_id = (select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000017' and user_id = '00000000-0000-0000-0000-000000000001')),
  0::bigint,
  'join_as_operator does not issue an entry pass'
);

do $$
begin
  perform public.join_as_operator('41000000-0000-0000-0000-000000000019');
end;
$$;

select is(
  public.cancel_participation((select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000019' and user_id = '00000000-0000-0000-0000-000000000001'))->>'refundEligible',
  'true',
  'cancel_participation treats operator self-join like any confirmed participation'
);

select is(
  public.mark_attendance((select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000017' and user_id = '00000000-0000-0000-0000-000000000001'))->>'success',
  'true',
  'mark_attendance works without an entry pass'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000004';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.cancel_game_session('41000000-0000-0000-0000-000000000002', 'weather')->>'affectedParticipations',
  '0',
  'cancel_game_session is callable by session owner'
);

do $$
begin
  perform public.cancel_game_session('41000000-0000-0000-0000-000000000020', 'count reset');
end;
$$;

select is(
  (select confirmed_count from public.game_sessions where id = '41000000-0000-0000-0000-000000000020'),
  0,
  'cancel_game_session resets confirmed_count to zero'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.get_entry_pass_token('41000000-0000-0000-0000-000000000015')->>'token',
  (select token from test_tokens where name = 'reuse'),
  'get_entry_pass_token recomputes QR token from stored fields'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  tests.error_hint($$select public.scan_entry_pass('81000000-0000-0000-0000-000000000001', 'forged-token')$$),
  'failed-precondition',
  'scan_entry_pass rejects forged token'
);

select is(
  tests.error_hint($$select public.scan_entry_pass('81000000-0000-0000-0000-000000000001', null::text)$$),
  'failed-precondition',
  'scan_entry_pass rejects null token'
);

select is(
  tests.error_hint($$select public.scan_entry_pass('81000000-0000-0000-0000-000000000002', (select token from test_tokens where name = 'expired'))$$),
  'failed-precondition',
  'scan_entry_pass rejects expired pass'
);

select is(
  public.scan_entry_pass('81000000-0000-0000-0000-000000000001', (select token from test_tokens where name = 'reuse'))->>'success',
  'true',
  'scan_entry_pass uses valid token'
);

select is(
  tests.error_hint($$select public.scan_entry_pass('81000000-0000-0000-0000-000000000001', (select token from test_tokens where name = 'reuse'))$$),
  'failed-precondition',
  'scan_entry_pass rejects token reuse'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.cancel_participation('51000000-0000-0000-0000-000000000005')->>'refundEligible',
  'true',
  'cancel_participation returns refundEligible before deadline'
);

reset role;

update public.participations
set status = 'cancelled'
where id = '51000000-0000-0000-0000-000000000005';

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000003';
set local "request.jwt.claim.role" = 'authenticated';

reset role;

select public.fn_status_transition();
select is((select status::text from public.game_sessions where id = '41000000-0000-0000-0000-000000000011'), 'closed', 'fn_status_transition closes full recruiting session');
select is((select status::text from public.game_sessions where id = '41000000-0000-0000-0000-000000000012'), 'inProgress', 'fn_status_transition starts past recruiting session');
select is((select status::text from public.game_sessions where id = '41000000-0000-0000-0000-000000000013'), 'completed', 'fn_status_transition completes ended inProgress session');
select public.fn_status_transition();
select is((select count(*) from public.game_sessions where id in ('41000000-0000-0000-0000-000000000011', '41000000-0000-0000-0000-000000000012', '41000000-0000-0000-0000-000000000013') and status in ('closed', 'inProgress', 'completed')), 3::bigint, 'fn_status_transition is idempotent on second run');

select public.fn_send_reminders();
select is((select reminder_sent from public.game_sessions where id = '41000000-0000-0000-0000-000000000014'), true, 'fn_send_reminders marks session as sent');
select is((select count(*) from public.notifications where game_session_id = '41000000-0000-0000-0000-000000000014' and type = 'session.upcoming_reminder'), 1::bigint, 'fn_send_reminders creates reminder notification');
select public.fn_send_reminders();
select is((select count(*) from public.notifications where game_session_id = '41000000-0000-0000-0000-000000000014' and type = 'session.upcoming_reminder'), 1::bigint, 'fn_send_reminders is idempotent');

-- 아래 중복 입장권 테스트의 전제. 예전에는 submit_payment가 첫 입장권을 발급했으나
-- 그 경로가 사라져, 부분 유니크 인덱스를 검증하려면 활성 입장권을 직접 심어야 한다.
insert into public.entry_passes (
  participation_id,
  game_session_id,
  user_id,
  qr_token_hash,
  expires_at
) values (
  '51000000-0000-0000-0000-000000000013',
  '41000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000002',
  'duplicate-active-seed',
  now() + interval '1 day'
);

select throws_ok(
  $$
    insert into public.entry_passes (
      participation_id,
      game_session_id,
      user_id,
      qr_token_hash,
      expires_at
    ) values (
      '51000000-0000-0000-0000-000000000013',
      '41000000-0000-0000-0000-000000000020',
      '00000000-0000-0000-0000-000000000002',
      'duplicate-active',
      now() + interval '1 day'
    )
  $$,
  '23505',
  'duplicate key value violates unique constraint "one_active_pass_per_participation"',
  'partial unique index rejects duplicate active entry pass'
);

-- ── 0018 게임룰 구조 ───────────────────────────────────────
select is(
  tests.error_hint($$
    select public.create_game_session(
      jsonb_build_object(
        'title', 'No Rules Session',
        'fieldId', '20000000-0000-0000-0000-000000000001',
        'startsAt', (now() + interval '5 days')::text,
        'capacity', 10,
        'gameFee', 30000
      )
    )
  $$),
  'invalid-argument',
  'create_game_session은 customRules 없이 거부한다'
);

select is(
  tests.error_hint($$
    select public.create_game_session(
      jsonb_build_object(
        'title', 'No Velocity Session',
        'fieldId', '20000000-0000-0000-0000-000000000001',
        'startsAt', (now() + interval '5 days')::text,
        'capacity', 10,
        'gameFee', 30000,
        'customRules', jsonb_build_object('bbWeightGrams', 0.25)
      )
    )
  $$),
  'invalid-argument',
  'create_game_session은 탄속 없는 룰을 거부한다'
);

select is(
  tests.error_hint($$
    select public.create_game_session(
      jsonb_build_object(
        'title', 'Bad Notes Session',
        'fieldId', '20000000-0000-0000-0000-000000000001',
        'startsAt', (now() + interval '5 days')::text,
        'capacity', 10,
        'gameFee', 30000,
        'customRules', jsonb_build_object(
          'muzzleVelocityFps', 400,
          'noteBlocks', jsonb_build_array(jsonb_build_object('title', '기관총'))
        )
      )
    )
  $$),
  'invalid-argument',
  'create_game_session은 body 없는 노트 블록을 거부한다'
);

-- 프리셋 출처 + 이어붙인 노트 = 회의가 그리던 조합
select is(
  (public.create_game_session(
    jsonb_build_object(
      'title', 'Preset With Notes',
      'fieldId', '20000000-0000-0000-0000-000000000001',
      'startsAt', (now() + interval '6 days')::text,
      'capacity', 10,
      'gameFee', 30000,
      'presetId', '30000000-0000-0000-0000-000000000001',
      'customRules', jsonb_build_object(
        'muzzleVelocityFps', 400,
        'bioBbRequired', true,
        'noteBlocks', jsonb_build_array(
          jsonb_build_object('title', '기관총 운용', 'body', '박스매거진 허용'),
          jsonb_build_object('title', '근거리 동시전사', 'body', '5m 이내 양측 전사')
        )
      )
    )
  ))->>'success',
  'true',
  '프리셋과 룰 노트를 함께 지정해 게임을 만들 수 있다'
);

select is(
  (select jsonb_array_length(custom_rules->'noteBlocks')
   from public.game_sessions where title = 'Preset With Notes'),
  2,
  '이어붙인 노트 블록이 그대로 저장된다'
);

select is(
  (select preset_id::text from public.game_sessions where title = 'Preset With Notes'),
  '30000000-0000-0000-0000-000000000001',
  '프리셋 출처가 함께 기록된다'
);

-- 프리셋에서 시작했어도 그 게임에서만 룰을 고칠 수 있다 (회의 §4)
select is(
  public.update_game_session(
    (select id from public.game_sessions where title = 'Preset With Notes'),
    jsonb_build_object('customRules', jsonb_build_object('muzzleVelocityFps', 350))
  )->'updatedFields',
  '["customRules"]'::jsonb,
  '프리셋 기반 세션도 룰을 수정할 수 있다'
);

select * from finish();

rollback;