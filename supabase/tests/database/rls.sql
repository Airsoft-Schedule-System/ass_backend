begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create schema if not exists tests;

create or replace function tests.try_exec(sql text)
returns boolean
language plpgsql
security invoker
as $$
begin
  execute sql;
  return true;
exception
  when others then
    return false;
end;
$$;

create or replace function tests.exec_row_count(sql text)
returns integer
language plpgsql
security invoker
as $$
declare
  affected_rows integer;
begin
  execute sql;
  get diagnostics affected_rows = row_count;
  return affected_rows;
exception
  when others then
    return -1;
end;
$$;

grant usage on schema tests to anon, authenticated;
grant execute on function tests.try_exec(text) to anon, authenticated;
grant execute on function tests.exec_row_count(text) to anon, authenticated;

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
  (
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'owner@example.test',
    'test-password-hash',
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Owner"}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'self@example.test',
    'test-password-hash',
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Self"}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'other@example.test',
    'test-password-hash',
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Other"}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000004',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'other-owner@example.test',
    'test-password-hash',
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Other Owner"}',
    now(),
    now()
  );

insert into public.teams (id, name)
values ('10000000-0000-0000-0000-000000000001', 'Alpha');

insert into public.fields (id, name, address, lat, lng)
values ('20000000-0000-0000-0000-000000000001', 'Field A', 'Seoul', 37.1, 127.1);

insert into public.game_rule_presets (id, name, rules, owner_id, is_public)
values
  ('30000000-0000-0000-0000-000000000001', 'Public preset', '{}', null, true),
  ('30000000-0000-0000-0000-000000000002', 'Owner preset', '{}', '00000000-0000-0000-0000-000000000001', false),
  ('30000000-0000-0000-0000-000000000003', 'Other owner preset', '{}', '00000000-0000-0000-0000-000000000004', false);

insert into public.game_sessions (
  id,
  title,
  created_by_user_id,
  host_team_id,
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
  cancel_deadline
) values
  (
    '40000000-0000-0000-0000-000000000001',
    'Owner session',
    '00000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001',
    now() + interval '7 days',
    now() + interval '7 days 6 hours',
    20,
    1,
    30000,
    'Bank',
    '123-456',
    'Owner',
    '30000000-0000-0000-0000-000000000001',
    now() + interval '5 days'
  ),
  (
    '40000000-0000-0000-0000-000000000002',
    'Other session',
    '00000000-0000-0000-0000-000000000004',
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001',
    now() + interval '8 days',
    now() + interval '8 days 6 hours',
    20,
    1,
    30000,
    'Bank',
    '123-456',
    'Other Owner',
    '30000000-0000-0000-0000-000000000001',
    now() + interval '6 days'
  );

insert into public.participations (id, game_session_id, user_id, status)
values
  ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'confirmed'),
  ('50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'confirmed');

insert into public.payment_submissions (
  id,
  participation_id,
  game_session_id,
  user_id,
  sender_name,
  amount,
  receipt_path
) values
  ('60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'Self', 30000, '50000000-0000-0000-0000-000000000001/receipt.jpg'),
  ('60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'Other', 30000, '50000000-0000-0000-0000-000000000002/receipt.jpg');

insert into public.refund_requests (
  id,
  participation_id,
  game_session_id,
  user_id,
  bank_name,
  account_number_encrypted,
  account_holder
) values
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'Bank', 'encrypted-self', 'Self'),
  ('70000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'Bank', 'encrypted-other', 'Other');

insert into public.entry_passes (
  id,
  participation_id,
  game_session_id,
  user_id,
  qr_token_hash,
  expires_at
) values
  ('80000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'hash-self', now() + interval '8 days'),
  ('80000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'hash-other', now() + interval '9 days');

insert into public.notifications (
  id,
  user_id,
  type,
  title,
  body,
  action_url,
  game_session_id,
  participation_id
) values
  ('90000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'payment.decision', 'Paid', 'Confirmed', '/participations/50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'payment.decision', 'Paid', 'Confirmed', '/participations/50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002');

insert into public.fcm_tokens (user_id, installation_id, token, platform)
values
  ('00000000-0000-0000-0000-000000000002', 'self-device', 'self-token', 'web'),
  ('00000000-0000-0000-0000-000000000003', 'other-device', 'other-token', 'web');

select ok(
  not tests.try_exec($$
    insert into public.game_sessions (
      id,
      title,
      created_by_user_id,
      field_id,
      starts_at,
      capacity,
      confirmed_count,
      game_fee,
      bank_name,
      bank_account_number,
      bank_account_holder,
      preset_id,
      cancel_deadline
    ) values (
      '40000000-0000-0000-0000-000000000099',
      'Over capacity',
      '00000000-0000-0000-0000-000000000001',
      '20000000-0000-0000-0000-000000000001',
      now() + interval '1 day',
      1,
      2,
      0,
      'Bank',
      '123',
      'Owner',
      '30000000-0000-0000-0000-000000000001',
      now() + interval '12 hours'
    )
  $$),
  'capacity_not_exceeded rejects confirmed_count above capacity'
);

select ok(
  not tests.try_exec($$
    insert into public.participations (game_session_id, user_id)
    values ('40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002')
  $$),
  'one_participation_per_user rejects duplicate user per session'
);

reset role;
set local role anon;
set local "request.jwt.claim.sub" = '';
set local "request.jwt.claim.role" = 'anon';

select ok(not tests.try_exec('select id from public.users limit 1'), 'anon cannot select users');
select ok(not tests.try_exec('select id from public.teams limit 1'), 'anon cannot select teams');
select ok(not tests.try_exec('select id from public.fields limit 1'), 'anon cannot select fields');
select ok(not tests.try_exec('select id from public.game_rule_presets limit 1'), 'anon cannot select game_rule_presets');
select ok(not tests.try_exec('select id from public.game_sessions limit 1'), 'anon cannot select game_sessions');
select ok(not tests.try_exec('select id from public.participations limit 1'), 'anon cannot select participations');
select ok(not tests.try_exec('select id from public.payment_submissions limit 1'), 'anon cannot select payment_submissions');
select ok(not tests.try_exec('select id from public.refund_requests limit 1'), 'anon cannot select refund_requests');
select ok(not tests.try_exec('select id from public.entry_passes limit 1'), 'anon cannot select entry_passes');
select ok(not tests.try_exec('select id from public.notifications limit 1'), 'anon cannot select notifications');
select ok(not tests.try_exec('select user_id from public.fcm_tokens limit 1'), 'anon cannot select fcm_tokens');
select ok(not tests.try_exec($$update public.users set display_name = 'Anon' where id = '00000000-0000-0000-0000-000000000002'$$), 'anon cannot update users');
select ok(not tests.try_exec($$insert into public.fcm_tokens (user_id, installation_id, token) values ('00000000-0000-0000-0000-000000000002', 'anon-device', 'token')$$), 'anon cannot write fcm_tokens');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000002';
set local "request.jwt.claim.role" = 'authenticated';

select is((select count(*) from public.users where id = '00000000-0000-0000-0000-000000000002'), 1::bigint, 'self can select own user profile');
select is((select count(*) from public.users where id = '00000000-0000-0000-0000-000000000003'), 0::bigint, 'self cannot select unrelated user profile');
select is((select count(*) from public.teams), 1::bigint, 'authenticated self can select teams');
select is((select count(*) from public.fields), 1::bigint, 'authenticated self can select fields');
select is((select count(*) from public.game_rule_presets), 1::bigint, 'self sees only public presets without ownership');
select is((select count(*) from public.game_sessions), 2::bigint, 'authenticated self can select all sessions');
select is((select count(*) from public.participations where id = '50000000-0000-0000-0000-000000000001'), 1::bigint, 'self can select own participation');
select is((select count(*) from public.participations where id = '50000000-0000-0000-0000-000000000002'), 0::bigint, 'self cannot select other participation');
select is((select count(*) from public.payment_submissions where id = '60000000-0000-0000-0000-000000000001'), 1::bigint, 'self can select own payment submission');
select is((select count(*) from public.payment_submissions where id = '60000000-0000-0000-0000-000000000002'), 0::bigint, 'self cannot select other payment submission');
select is((select count(*) from public.refund_requests where id = '70000000-0000-0000-0000-000000000001'), 1::bigint, 'self can select own refund request');
select is((select count(*) from public.refund_requests where id = '70000000-0000-0000-0000-000000000002'), 0::bigint, 'self cannot select other refund request');
select ok(not tests.try_exec('select account_number_encrypted from public.refund_requests limit 1'), 'authenticated cannot select refund account ciphertext column directly');
select is((select count(*) from public.entry_passes where id = '80000000-0000-0000-0000-000000000001'), 1::bigint, 'self can select own entry pass');
select is((select count(*) from public.entry_passes where id = '80000000-0000-0000-0000-000000000002'), 0::bigint, 'self cannot select other entry pass');
select is((select count(*) from public.notifications where id = '90000000-0000-0000-0000-000000000001'), 1::bigint, 'self can select own notification');
select is((select count(*) from public.notifications where id = '90000000-0000-0000-0000-000000000002'), 0::bigint, 'self cannot select other notification');
select is((select count(*) from public.fcm_tokens where installation_id = 'self-device'), 1::bigint, 'self can select own fcm token');
select is((select count(*) from public.fcm_tokens where installation_id = 'other-device'), 0::bigint, 'self cannot select other fcm token');

select ok(tests.try_exec($$update public.users set display_name = 'Self Updated', phone_number = '010-0000-0000', team_id = '10000000-0000-0000-0000-000000000001', last_active_at = now() where id = '00000000-0000-0000-0000-000000000002'$$), 'self can update allowed user profile columns');
select ok(not tests.try_exec($$update public.users set email = 'changed@example.test' where id = '00000000-0000-0000-0000-000000000002'$$), 'self cannot update disallowed user profile columns');
select ok(not tests.try_exec($$insert into public.teams (name) values ('Blocked')$$), 'authenticated cannot directly write teams');
select ok(not tests.try_exec($$insert into public.fields (name) values ('Blocked')$$), 'authenticated cannot directly write fields');
select ok(tests.try_exec($$insert into public.game_rule_presets (id, name, owner_id) values ('30000000-0000-0000-0000-000000000099', 'Self preset', '00000000-0000-0000-0000-000000000002')$$), 'preset owner can insert own preset');
select ok(tests.try_exec($$update public.game_rule_presets set name = 'Self preset updated' where id = '30000000-0000-0000-0000-000000000099'$$), 'preset owner can update own preset');
select ok(tests.try_exec($$delete from public.game_rule_presets where id = '30000000-0000-0000-0000-000000000099'$$), 'preset owner can delete own preset');
select ok(not tests.try_exec($$insert into public.game_rule_presets (name, owner_id) values ('Forged preset', '00000000-0000-0000-0000-000000000003')$$), 'preset insert cannot forge owner_id');
select ok(not tests.try_exec($$update public.game_sessions set title = 'Blocked' where id = '40000000-0000-0000-0000-000000000001'$$), 'authenticated cannot directly write game_sessions');
select ok(not tests.try_exec($$update public.participations set status = 'cancelled' where id = '50000000-0000-0000-0000-000000000001'$$), 'self cannot directly write participations');
select ok(not tests.try_exec($$update public.payment_submissions set status = 'approved' where id = '60000000-0000-0000-0000-000000000001'$$), 'self cannot directly write payment_submissions');
select ok(not tests.try_exec($$update public.refund_requests set status = 'completed' where id = '70000000-0000-0000-0000-000000000001'$$), 'self cannot directly write refund_requests');
select ok(not tests.try_exec($$update public.entry_passes set status = 'used' where id = '80000000-0000-0000-0000-000000000001'$$), 'self cannot directly write entry_passes');
select ok(tests.try_exec($$update public.notifications set is_read = true where id = '90000000-0000-0000-0000-000000000001'$$), 'self can update notification is_read');
select ok(not tests.try_exec($$update public.notifications set title = 'Blocked' where id = '90000000-0000-0000-0000-000000000001'$$), 'self cannot update notification columns except is_read');
select ok(tests.try_exec($$insert into public.fcm_tokens (user_id, installation_id, token, platform) values ('00000000-0000-0000-0000-000000000002', 'self-temp', 'token', 'web')$$), 'self can insert own fcm token');
select ok(tests.try_exec($$update public.fcm_tokens set token = 'token-updated' where user_id = '00000000-0000-0000-0000-000000000002' and installation_id = 'self-temp'$$), 'self can update own fcm token');
select ok(tests.try_exec($$delete from public.fcm_tokens where user_id = '00000000-0000-0000-0000-000000000002' and installation_id = 'self-temp'$$), 'self can delete own fcm token');
select ok(not tests.try_exec($$insert into public.fcm_tokens (user_id, installation_id, token) values ('00000000-0000-0000-0000-000000000003', 'forged-temp', 'token')$$), 'self cannot insert fcm token for another user');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000003';
set local "request.jwt.claim.role" = 'authenticated';

select is((select count(*) from public.users where id = '00000000-0000-0000-0000-000000000002'), 0::bigint, 'other user cannot select self profile');
select is((select count(*) from public.participations where id = '50000000-0000-0000-0000-000000000001'), 0::bigint, 'other user cannot select self participation');
select is((select count(*) from public.payment_submissions where id = '60000000-0000-0000-0000-000000000001'), 0::bigint, 'other user cannot select self payment submission');
select is((select count(*) from public.refund_requests where id = '70000000-0000-0000-0000-000000000001'), 0::bigint, 'other user cannot select self refund request');
select is((select count(*) from public.entry_passes where id = '80000000-0000-0000-0000-000000000001'), 0::bigint, 'other user cannot select self entry pass');
select is((select count(*) from public.notifications where id = '90000000-0000-0000-0000-000000000001'), 0::bigint, 'other user cannot select self notification');
select is((select count(*) from public.fcm_tokens where installation_id = 'self-device'), 0::bigint, 'other user cannot select self fcm token');
select is(tests.exec_row_count($$update public.users set display_name = 'Other Changed Self' where id = '00000000-0000-0000-0000-000000000002'$$), 0, 'other user cannot update self profile');
select is(tests.exec_row_count($$update public.game_rule_presets set name = 'Blocked' where id = '30000000-0000-0000-0000-000000000002'$$), 0, 'other user cannot update another owner preset');
select is(tests.exec_row_count($$update public.notifications set is_read = true where id = '90000000-0000-0000-0000-000000000001'$$), 0, 'other user cannot update self notification');
select is(tests.exec_row_count($$update public.fcm_tokens set token = 'blocked' where user_id = '00000000-0000-0000-0000-000000000002' and installation_id = 'self-device'$$), 0, 'other user cannot update self fcm token');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is((select display_name from public.users where id = '00000000-0000-0000-0000-000000000002'), 'Self Updated', 'session owner can select own session applicant display_name');
select is((select count(*) from public.users where id = '00000000-0000-0000-0000-000000000003'), 0::bigint, 'session owner cannot select applicant from another session');
select is((select count(*) from public.participations where id = '50000000-0000-0000-0000-000000000001'), 1::bigint, 'session owner can select own session participation');
select is((select count(*) from public.participations where id = '50000000-0000-0000-0000-000000000002'), 0::bigint, 'session owner cannot select other session participation');
select is((select count(*) from public.payment_submissions where id = '60000000-0000-0000-0000-000000000001'), 1::bigint, 'session owner can select own session payment submission');
select is((select count(*) from public.payment_submissions where id = '60000000-0000-0000-0000-000000000002'), 0::bigint, 'session owner cannot select other session payment submission');
select is((select count(*) from public.refund_requests where id = '70000000-0000-0000-0000-000000000001'), 1::bigint, 'session owner can select own session refund request');
select is((select count(*) from public.refund_requests where id = '70000000-0000-0000-0000-000000000002'), 0::bigint, 'session owner cannot select other session refund request');
select is((select count(*) from public.entry_passes where id = '80000000-0000-0000-0000-000000000001'), 1::bigint, 'session owner can select own session entry pass');
select is((select count(*) from public.entry_passes where id = '80000000-0000-0000-0000-000000000002'), 0::bigint, 'session owner cannot select other session entry pass');
select is((select count(*) from public.notifications where id = '90000000-0000-0000-0000-000000000001'), 0::bigint, 'session owner cannot select applicant notification');
select is(tests.exec_row_count($$update public.users set display_name = 'Owner Changed Applicant' where id = '00000000-0000-0000-0000-000000000002'$$), 0, 'session owner cannot update applicant profile');
select ok(not tests.try_exec($$update public.participations set status = 'attended' where id = '50000000-0000-0000-0000-000000000001'$$), 'session owner cannot directly write participations');
select ok(not tests.try_exec($$update public.payment_submissions set status = 'approved' where id = '60000000-0000-0000-0000-000000000001'$$), 'session owner cannot directly write payment_submissions');
select ok(not tests.try_exec($$update public.refund_requests set status = 'approved' where id = '70000000-0000-0000-0000-000000000001'$$), 'session owner cannot directly write refund_requests');
select ok(not tests.try_exec($$update public.entry_passes set status = 'used' where id = '80000000-0000-0000-0000-000000000001'$$), 'session owner cannot directly write entry_passes');

reset role;
select * from finish();

rollback;
