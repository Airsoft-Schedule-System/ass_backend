begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);

reset role;

select ok(
  exists (select 1 from pg_extension where extname = 'pg_cron'),
  'pg_cron extension exists'
);

select ok(
  exists (select 1 from pg_extension where extname = 'pg_net'),
  'pg_net extension exists'
);

select is(
  (select min(schedule) from cron.job where jobname = 'status-transition'),
  '0 * * * *',
  'status-transition has the hourly schedule'
);

select is(
  (select min(command) from cron.job where jobname = 'status-transition'),
  'select public.fn_status_transition()',
  'status-transition calls the status transition function'
);

select is(
  (select min(schedule) from cron.job where jobname = 'send-reminders'),
  '*/30 * * * *',
  'send-reminders has the thirty-minute schedule'
);

select is(
  (select min(command) from cron.job where jobname = 'send-reminders'),
  'select public.fn_send_reminders()',
  'send-reminders calls the reminder function'
);

select lives_ok(
  $test$
    select cron.schedule(
      'status-transition',
      '0 * * * *',
      $command$select public.fn_status_transition()$command$
    )
  $test$,
  'status-transition can be registered again'
);

select is(
  (select count(*) from cron.job where jobname = 'status-transition'),
  1::bigint,
  'status-transition registration is idempotent'
);

select lives_ok(
  $test$
    select cron.schedule(
      'send-reminders',
      '*/30 * * * *',
      $command$select public.fn_send_reminders()$command$
    )
  $test$,
  'send-reminders can be registered again'
);

select is(
  (select count(*) from cron.job where jobname = 'send-reminders'),
  1::bigint,
  'send-reminders registration is idempotent'
);

select is(
  (
    select count(*)
    from pg_trigger
    where tgname = 'on_notification_created'
      and tgrelid = 'public.notifications'::regclass
      and not tgisinternal
  ),
  1::bigint,
  'notification webhook trigger exists once'
);

select ok(
  exists (
    select 1
    from pg_trigger
    where tgname = 'on_notification_created'
      and tgrelid = 'public.notifications'::regclass
      and not tgisinternal
      and (tgtype::integer & 1) = 1
      and (tgtype::integer & 4) = 4
      and (tgtype::integer & 2) = 0
      and (tgtype::integer & 64) = 0
  ),
  'notification webhook trigger is AFTER INSERT FOR EACH ROW'
);

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
    'f0000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'full-name@example.test',
    'test-password-hash',
    now(),
    '{"provider":"google","providers":["google"]}',
    '{"full_name":"Google Full Name"}',
    now(),
    now()
  ),
  (
    'f0000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'name@example.test',
    'test-password-hash',
    now(),
    '{"provider":"google","providers":["google"]}',
    '{"name":"Google Name"}',
    now(),
    now()
  );

select is(
  (
    select display_name
    from public.users
    where id = 'f0000000-0000-0000-0000-000000000001'
  ),
  'Google Full Name',
  'handle_new_user falls back to full_name'
);

select is(
  (
    select display_name
    from public.users
    where id = 'f0000000-0000-0000-0000-000000000002'
  ),
  'Google Name',
  'handle_new_user falls back to name'
);

select * from finish();

rollback;
