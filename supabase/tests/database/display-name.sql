begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(15);

reset role;

-- 스키마 계약 -------------------------------------------------------------

select ok(
  exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'users'
      and indexname = 'users_display_name_unique'
  ),
  'display_name has a unique index'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conname = 'users_display_name_not_blank'
      and conrelid = 'public.users'::regclass
  ),
  'display_name rejects blank values'
);

select ok(
  (
    select column_default is null
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'users'
      and column_name = 'display_name'
  ),
  'display_name default is removed (empty-string collisions impossible)'
);

-- 가입 트리거: 충돌해도 가입은 성공해야 한다 -------------------------------
-- 소셜 로그인은 이름이 자동으로 채워지므로 동명이인 충돌이 실제로 발생한다.

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  (
    'd0000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'dup-one@example.test', 'test-password-hash', now(),
    '{"provider":"google","providers":["google"]}',
    '{"full_name":"김민수"}',
    now(), now()
  ),
  (
    'd0000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'dup-two@example.test', 'test-password-hash', now(),
    '{"provider":"google","providers":["google"]}',
    '{"full_name":"김민수"}',
    now(), now()
  ),
  (
    'd0000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'no-name@example.test', 'test-password-hash', now(),
    '{"provider":"email","providers":["email"]}',
    '{}',
    now(), now()
  ),
  (
    'd0000000-0000-0000-0000-000000000004',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'latin@example.test', 'test-password-hash', now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Hong"}',
    now(), now()
  );

select is(
  (
    select count(*)::int
    from public.users
    where id in (
      'd0000000-0000-0000-0000-000000000001',
      'd0000000-0000-0000-0000-000000000002'
    )
  ),
  2,
  'duplicate social names still both sign up (signup is never blocked)'
);

select is(
  (select display_name from public.users where id = 'd0000000-0000-0000-0000-000000000001'),
  '김민수',
  'first signup keeps the requested name'
);

select is(
  (select display_name from public.users where id = 'd0000000-0000-0000-0000-000000000002'),
  '김민수1',
  'colliding signup is quietly suffixed'
);

select ok(
  (
    select nullif(btrim(display_name), '') is not null
    from public.users
    where id = 'd0000000-0000-0000-0000-000000000003'
  ),
  'signup without any name metadata still gets a usable name'
);

-- 프로필 수정: 여기서만 중복 에러를 본다 -----------------------------------

select throws_ok(
  $$update public.users
    set display_name = '김민수'
    where id = 'd0000000-0000-0000-0000-000000000002'$$,
  '23505',
  null,
  'renaming to an existing nickname is rejected'
);

select throws_ok(
  $$update public.users
    set display_name = '김민수  '
    where id = 'd0000000-0000-0000-0000-000000000002'$$,
  '23505',
  null,
  'surrounding whitespace does not bypass uniqueness'
);

select throws_ok(
  $$update public.users
    set display_name = 'HONG'
    where id = 'd0000000-0000-0000-0000-000000000002'$$,
  '23505',
  null,
  'letter case does not bypass uniqueness (impersonation guard)'
);

select throws_ok(
  $$update public.users
    set display_name = '   '
    where id = 'd0000000-0000-0000-0000-000000000002'$$,
  '23514',
  null,
  'blank nickname is rejected'
);

-- 육안으로 구분되지 않는 우회 차단 ----------------------------------------
-- 아래 두 케이스는 정규화 없이는 통과한다(로컬에서 재현 확인).

select throws_ok(
  $$update public.users
    set display_name = normalize('김민수', NFD)
    where id = 'd0000000-0000-0000-0000-000000000002'$$,
  '23505',
  null,
  'NFD variant cannot duplicate an NFC name (invisible impersonation guard)'
);

select is(
  (
    select display_name = normalize(display_name, NFC)
    from public.users
    where id = 'd0000000-0000-0000-0000-000000000004'
  ),
  true,
  'stored nicknames are NFC-normalized'
);

select throws_ok(
  $$update public.users
    set display_name = repeat('가', 21)
    where id = 'd0000000-0000-0000-0000-000000000002'$$,
  '23514',
  null,
  'nickname longer than 20 characters is rejected'
);

select is(
  (
    select display_name
    from public.users
    where id = 'd0000000-0000-0000-0000-000000000004'
  ),
  'Hong',
  'normalize trigger trims but preserves the visible name'
);

select * from finish();

rollback;
