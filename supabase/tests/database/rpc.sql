begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(80);

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

grant usage on schema tests to anon, authenticated;
grant execute on function tests.error_hint(text) to anon, authenticated;
grant execute on function tests.error_detail(text) to anon, authenticated;

do $$
begin
  perform vault.create_secret('qr-test-secret', 'qr_hmac_secret');
  perform vault.create_secret('refund-test-secret', 'refund_account_key');
end;
$$;

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
  bank_name,
  bank_account_number,
  bank_account_holder,
  preset_id,
  cancel_deadline,
  status
) values
  ('41000000-0000-0000-0000-000000000001', 'Request Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 10, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000002', 'Other Owner Session', '00000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', now() + interval '8 days', now() + interval '8 days 6 hours', 10, 0, 30000, 'Bank', '123-456', 'Other Owner', '30000000-0000-0000-0000-000000000001', now() + interval '6 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000003', 'Closed Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 1, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '5 days', 'closed'),
  ('41000000-0000-0000-0000-000000000004', 'In Progress Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '1 hour', now() + interval '5 hours', 10, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() - interval '1 day', 'inProgress'),
  ('41000000-0000-0000-0000-000000000005', 'Completed Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '3 days', now() - interval '2 days', 10, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() - interval '4 days', 'completed'),
  ('41000000-0000-0000-0000-000000000006', 'Capacity Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 1, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '7 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000007', 'Full Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 1, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '7 days', 'closed'),
  ('41000000-0000-0000-0000-000000000008', 'Closed Cancel Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 2, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '7 days', 'closed'),
  ('41000000-0000-0000-0000-000000000009', 'Refund Future Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '9 days', now() + interval '9 days 6 hours', 3, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '7 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000010', 'Refund Past Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '2 days', now() + interval '2 days 6 hours', 3, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() - interval '1 hour', 'recruiting'),
  ('41000000-0000-0000-0000-000000000011', 'Transition Full', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '4 days', now() + interval '4 days 6 hours', 1, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '2 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000012', 'Transition Past Start', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '1 hour', now() + interval '5 hours', 10, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() - interval '1 day', 'recruiting'),
  ('41000000-0000-0000-0000-000000000013', 'Transition Complete', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '2 days', now() - interval '1 day', 10, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() - interval '3 days', 'inProgress'),
  ('41000000-0000-0000-0000-000000000014', 'Reminder Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '24 hours', now() + interval '30 hours', 10, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '12 hours', 'recruiting'),
  ('41000000-0000-0000-0000-000000000015', 'QR Reuse Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 10, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000016', 'QR Expired Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() - interval '2 days', now() - interval '1 day', 10, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() - interval '3 days', 'inProgress'),
  ('41000000-0000-0000-0000-000000000017', 'Operator Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 1, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000018', 'Review Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 1, 1, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '5 days', 'closed'),
  ('41000000-0000-0000-0000-000000000019', 'Operator Refund Session', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 2, 0, 30000, 'Bank', '123-456', 'Owner', '30000000-0000-0000-0000-000000000001', now() + interval '5 days', 'recruiting'),
  ('41000000-0000-0000-0000-000000000020', 'Cancel Count Session', '00000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', now() + interval '7 days', now() + interval '7 days 6 hours', 5, 2, 30000, 'Bank', '123-456', 'Other Owner', '30000000-0000-0000-0000-000000000001', now() + interval '5 days', 'closed');

insert into public.participations (id, game_session_id, user_id, status)
values
  ('51000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000002', 'pendingApproval'),
  ('51000000-0000-0000-0000-000000000002', '41000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000002', 'awaitingPayment'),
  ('51000000-0000-0000-0000-000000000003', '41000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000003', 'awaitingPayment'),
  ('51000000-0000-0000-0000-000000000004', '41000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000005', '41000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000006', '41000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000002', 'cancelled'),
  ('51000000-0000-0000-0000-000000000007', '41000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000003', 'cancelled'),
  ('51000000-0000-0000-0000-000000000008', '41000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000009', '41000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000010', '41000000-0000-0000-0000-000000000016', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000011', '41000000-0000-0000-0000-000000000018', '00000000-0000-0000-0000-000000000002', 'awaitingPayment'),
  ('51000000-0000-0000-0000-000000000012', '41000000-0000-0000-0000-000000000018', '00000000-0000-0000-0000-000000000003', 'confirmed'),
  ('51000000-0000-0000-0000-000000000013', '41000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('51000000-0000-0000-0000-000000000014', '41000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000003', 'confirmed');

insert into public.payment_submissions (
  id,
  participation_id,
  game_session_id,
  user_id,
  sender_name,
  amount,
  receipt_path,
  status
) values
  ('61000000-0000-0000-0000-000000000003', '51000000-0000-0000-0000-000000000005', '41000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000002', 'Player', 30000, 'receipts/51000000-0000-0000-0000-000000000005/a.jpg', 'approved'),
  ('61000000-0000-0000-0000-000000000004', '51000000-0000-0000-0000-000000000006', '41000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000002', 'Player', 30000, 'receipts/51000000-0000-0000-0000-000000000006/a.jpg', 'approved'),
  ('61000000-0000-0000-0000-000000000005', '51000000-0000-0000-0000-000000000012', '41000000-0000-0000-0000-000000000018', '00000000-0000-0000-0000-000000000003', 'Other', 30000, 'receipts/51000000-0000-0000-0000-000000000012/a.jpg', 'pending'),
  ('61000000-0000-0000-0000-000000000006', '51000000-0000-0000-0000-000000000004', '41000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000002', 'Player', 30000, 'receipts/51000000-0000-0000-0000-000000000004/a.jpg', 'rejected');

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
  tests.error_hint($$select public.submit_payment('51000000-0000-0000-0000-000000000012', 'Player', 30000, 'receipts/51000000-0000-0000-0000-000000000012/a.jpg')$$),
  'permission-denied',
  'non-participant cannot submit payment for another user'
);

select is(
  public.submit_payment('51000000-0000-0000-0000-000000000002', 'Player', 30000, 'receipts/51000000-0000-0000-0000-000000000002/upload.jpg')->>'success',
  'true',
  'participant can submit payment for own uploaded receipt'
);

select is(
  (select status::text from public.participations where id = '51000000-0000-0000-0000-000000000002'),
  'confirmed',
  'submit_payment immediately confirms participation'
);

select is(
  (select status::text from public.payment_submissions where participation_id = '51000000-0000-0000-0000-000000000002'),
  'pending',
  'submit_payment records pending evidence'
);

select is(
  (select confirmed_count from public.game_sessions where id = '41000000-0000-0000-0000-000000000006'),
  1,
  'submit_payment increments confirmed_count'
);

select is(
  (select status::text from public.game_sessions where id = '41000000-0000-0000-0000-000000000006'),
  'closed',
  'submit_payment closes session when capacity is reached'
);

select is(
  (select count(*) from public.entry_passes where participation_id = '51000000-0000-0000-0000-000000000002' and status = 'active'),
  1::bigint,
  'submit_payment issues an active entry pass'
);

select is(
  (select count(*) from public.notifications where participation_id = '51000000-0000-0000-0000-000000000002' and type = 'participation.confirmed'),
  1::bigint,
  'submit_payment creates one participation.confirmed notification'
);

select is(
  (select data->>'entryPassId' from public.notifications where participation_id = '51000000-0000-0000-0000-000000000002' and type = 'participation.confirmed'),
  (select id::text from public.entry_passes where participation_id = '51000000-0000-0000-0000-000000000002' and status = 'active'),
  'participation.confirmed notification includes entryPassId'
);

select is(
  (select count(*) from public.notifications where participation_id = '51000000-0000-0000-0000-000000000002' and type = 'payment.decision'),
  0::bigint,
  'submit_payment does not create an approved payment.decision notification'
);

select hasnt_function(
  'public',
  'approve_payment',
  array['uuid'],
  'approve_payment is removed'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000003';
set local "request.jwt.claim.role" = 'authenticated';

select throws_ok(
  $$select public.submit_payment('51000000-0000-0000-0000-000000000003', 'Other', 30000, 'receipts/51000000-0000-0000-0000-000000000003/upload.jpg')$$,
  'P0001',
  '정원이 마감되었습니다',
  'submit_payment rejects a full session'
);

select is(
  tests.error_hint($$select public.submit_payment('51000000-0000-0000-0000-000000000003', 'Other', 30000, 'receipts/51000000-0000-0000-0000-000000000003/upload.jpg')$$),
  'failed-precondition',
  'full submit_payment uses failed-precondition'
);

select is(
  tests.error_detail($$select public.submit_payment('51000000-0000-0000-0000-000000000003', 'Other', 30000, 'receipts/51000000-0000-0000-0000-000000000003/upload.jpg')$$),
  'capacityFilled',
  'full submit_payment exposes capacityFilled detail'
);

select is(
  (select status::text from public.participations where id = '51000000-0000-0000-0000-000000000003'),
  'awaitingPayment',
  'full submit_payment leaves participation awaitingPayment'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.approve_participation((select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000001' and user_id = '00000000-0000-0000-0000-000000000002'))->>'newStatus',
  'awaitingPayment',
  'session owner can approve participation'
);

reset role;

select is(
  (select count(*) from public.notifications where participation_id = (select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000001' and user_id = '00000000-0000-0000-0000-000000000002') and type in ('participation.decision', 'payment.requested')),
  2::bigint,
  'approve_participation creates decision and payment requested notifications'
);

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
        'bankAccount', jsonb_build_object(
          'bankName', 'Bank',
          'accountNumber', '123-456',
          'accountHolder', 'Owner'
        ),
        'presetId', '30000000-0000-0000-0000-000000000001',
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
        'bankAccount', jsonb_build_object(
          'bankName', 'Bank',
          'accountNumber', '123-456',
          'accountHolder', 'Owner'
        ),
        'presetId', '30000000-0000-0000-0000-000000000001'
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

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  tests.error_hint($$select public.mark_payment_reviewed('61000000-0000-0000-0000-000000000005')$$),
  'permission-denied',
  'non-owner cannot mark payment reviewed'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.mark_payment_reviewed('61000000-0000-0000-0000-000000000005')->>'success',
  'true',
  'session owner can mark payment reviewed'
);

select is(
  (select status::text from public.payment_submissions where id = '61000000-0000-0000-0000-000000000005'),
  'approved',
  'mark_payment_reviewed moves pending evidence to approved'
);

select is(
  (select reviewed_by::text from public.payment_submissions where id = '61000000-0000-0000-0000-000000000005'),
  '00000000-0000-0000-0000-000000000001',
  'mark_payment_reviewed records the reviewer'
);

select is(
  (select status::text from public.participations where id = '51000000-0000-0000-0000-000000000012'),
  'confirmed',
  'mark_payment_reviewed leaves participation unchanged'
);

select is(
  (select confirmed_count from public.game_sessions where id = '41000000-0000-0000-0000-000000000018'),
  1,
  'mark_payment_reviewed leaves session count unchanged'
);

-- RLS(notifications_select_self)에 가려 통과하는 거짓 양성을 피하려고 롤 해제 후 확인
reset role;

select is(
  (select count(*) from public.notifications where participation_id = '51000000-0000-0000-0000-000000000012'),
  0::bigint,
  'mark_payment_reviewed does not create a notification'
);

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.reject_payment('61000000-0000-0000-0000-000000000005', 'bad image')->>'success',
  'true',
  'session owner can reject reviewed payment evidence'
);

select is(
  (select status::text from public.payment_submissions where id = '61000000-0000-0000-0000-000000000005'),
  'rejected',
  'reject_payment marks evidence rejected'
);

select is(
  (select status::text from public.participations where id = '51000000-0000-0000-0000-000000000012'),
  'awaitingPayment',
  'reject_payment returns confirmed participation to awaitingPayment'
);

select is(
  (select status::text from public.entry_passes where id = '81000000-0000-0000-0000-000000000004'),
  'revoked',
  'reject_payment revokes the active entry pass'
);

select is(
  (select confirmed_count from public.game_sessions where id = '41000000-0000-0000-0000-000000000018'),
  0,
  'reject_payment decrements confirmed_count'
);

select is(
  (select status::text from public.game_sessions where id = '41000000-0000-0000-0000-000000000018'),
  'recruiting',
  'reject_payment reopens a closed future session'
);

-- 알림 수신자는 참가자(...0003)이고 현재 롤은 운영자(...0001) — notifications_select_self RLS를 우회하기 위해 롤 해제 후 확인
reset role;

select is(
  (select count(*) from public.notifications where participation_id = '51000000-0000-0000-0000-000000000012' and type = 'payment.decision' and data->>'decision' = 'rejected' and data->>'reason' = 'bad image'),
  1::bigint,
  'reject_payment creates one rejected payment.decision notification'
);

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000003';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  public.submit_payment('51000000-0000-0000-0000-000000000012', 'Other', 30000, 'receipts/51000000-0000-0000-0000-000000000012/resubmit.jpg')->>'success',
  'true',
  'rejected participant can resubmit payment evidence'
);

select is(
  (select status::text from public.participations where id = '51000000-0000-0000-0000-000000000012'),
  'confirmed',
  'resubmission confirms participation again'
);

select is(
  (select count(*) from public.entry_passes where participation_id = '51000000-0000-0000-0000-000000000012' and status = 'active'),
  1::bigint,
  'resubmission issues a new active entry pass'
);

select is(
  (select count(*) from public.entry_passes where participation_id = '51000000-0000-0000-0000-000000000012' and status = 'revoked'),
  1::bigint,
  'resubmission preserves the revoked entry pass history'
);

select is(
  (select confirmed_count from public.game_sessions where id = '41000000-0000-0000-0000-000000000018'),
  1,
  'resubmission increments confirmed_count again'
);

select is(
  (select status::text from public.game_sessions where id = '41000000-0000-0000-0000-000000000018'),
  'closed',
  'resubmission closes the session again at capacity'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  (select count(*) from public.payment_submissions where participation_id = '51000000-0000-0000-0000-000000000012' and status = 'pending'),
  1::bigint,
  'resubmission records new pending evidence'
);

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

select is(
  (select count(*) from public.payment_submissions where participation_id = (select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000017' and user_id = '00000000-0000-0000-0000-000000000001')),
  0::bigint,
  'join_as_operator remains confirmed without payment evidence'
);

do $$
begin
  perform public.join_as_operator('41000000-0000-0000-0000-000000000019');
end;
$$;

select is(
  public.cancel_participation((select id from public.participations where game_session_id = '41000000-0000-0000-0000-000000000019' and user_id = '00000000-0000-0000-0000-000000000001'))->>'refundEligible',
  'false',
  'cancel_participation returns refundEligible false for operator self-join without payment'
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

select is(
  public.request_refund('51000000-0000-0000-0000-000000000005', 'Bank', '111-222', 'Player', 'cannot attend')->>'success',
  'true',
  'request_refund succeeds for eligible cancelled participation'
);

reset role;

select isnt(
  (select account_number_encrypted from public.refund_requests where participation_id = '51000000-0000-0000-0000-000000000005'),
  '111-222',
  'request_refund stores ciphertext instead of plaintext'
);

update public.participations
set status = 'cancelled'
where id = '51000000-0000-0000-0000-000000000005';

set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  tests.error_hint($$select public.request_refund('51000000-0000-0000-0000-000000000005', 'Bank', '111-222', 'Player', null)$$),
  'already-exists',
  'request_refund rejects duplicate refund'
);

select is(
  tests.error_hint($$select public.request_refund('51000000-0000-0000-0000-000000000006', 'Bank', '333-444', 'Player', null)$$),
  'failed-precondition',
  'request_refund rejects after refund deadline'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000003';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  tests.error_hint($$select public.request_refund('51000000-0000-0000-0000-000000000007', 'Bank', '555-666', 'Other', null)$$),
  'failed-precondition',
  'request_refund rejects cancelled participation without approved payment history'
);

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

select throws_ok(
  $$
    insert into public.entry_passes (
      participation_id,
      game_session_id,
      user_id,
      qr_token_hash,
      expires_at
    ) values (
      '51000000-0000-0000-0000-000000000002',
      '41000000-0000-0000-0000-000000000006',
      '00000000-0000-0000-0000-000000000002',
      'duplicate-active',
      now() + interval '1 day'
    )
  $$,
  '23505',
  'duplicate key value violates unique constraint "one_active_pass_per_participation"',
  'partial unique index rejects duplicate active entry pass'
);

select * from finish();

rollback;
