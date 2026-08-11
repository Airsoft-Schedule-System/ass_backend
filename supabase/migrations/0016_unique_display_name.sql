-- 닉네임(display_name) 전역 유니크 — 대소문자·앞뒤 공백 무시
--
-- 배경: 동명이인이 참가자 목록·출석부에서 구분되지 않는 문제(최정환 제기, 2026-08).
--       초대·검색(2차 기능)의 선행 조건이기도 하다.
-- 시점: 프로덕션 데이터 0인 지금이 최저 비용. 제약은 나중에 **빼기는 공짜, 넣기는 비싸다**
--       (기존 사용자에게 개명을 강요하는 흐름이 필요해짐).
-- 원칙: **가입을 절대 막지 않는다.** 충돌은 트리거가 접미사로 조용히 해소하고,
--       사용자는 나중에 프로필에서 원하는 닉네임으로 바꾼다(그때만 중복 에러를 본다).

-- 1) 기존 데이터 정규화 --------------------------------------------------
-- dev/stg에 테스트 계정이 남아 있을 수 있어, 제약을 걸기 전에 먼저 정리한다.

-- 1a. 빈 닉네임 → 자동 생성
update public.users
set display_name = '유저' || substr(replace(id::text, '-', ''), 1, 6)
where nullif(btrim(display_name), '') is null;

-- 1b. 중복(대소문자·공백 무시) → 먼저 만든 계정이 원본을 유지하고 나머지에 번호 부여
with ranked as (
  select
    id,
    display_name,
    row_number() over (
      partition by lower(btrim(display_name))
      order by created_at, id
    ) as rn
  from public.users
)
update public.users u
set display_name = left(btrim(r.display_name), 17) || r.rn::text
from ranked r
where u.id = r.id
  and r.rn > 1;

-- 2) 제약 --------------------------------------------------------------
-- default '' 를 없앤다: 이게 남아 있으면 이름 없는 가입이 빈 문자열로 충돌한다.
alter table public.users alter column display_name drop default;

alter table public.users
  add constraint users_display_name_not_blank
  check (btrim(display_name) <> '');

-- 대소문자·공백을 무시한 유니크. 'Hong'/'hong'/' hong ' 을 같은 이름으로 취급해
-- 눈으로 구분되지 않는 사칭을 막는다.
create unique index users_display_name_unique
  on public.users (lower(btrim(display_name)));

-- 3) 가입 트리거 — 충돌 시 자동 접미사 -----------------------------------
-- 이메일 가입: 사용자가 닉네임을 직접 입력하므로 대개 그대로 통과한다.
-- 소셜 가입(Google): 이름이 자동으로 채워져 동명이인 충돌이 실제로 발생한다.
--   → 여기서 막으면 사용자는 영문도 모른 채 가입에 실패한다. 반드시 조용히 해소한다.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
  v_candidate text;
  v_suffix int := 0;
begin
  v_base := nullif(btrim(coalesce(
    new.raw_user_meta_data->>'display_name',
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'name'
  )), '');

  -- 이름을 전혀 못 얻은 경우(이메일 가입에서 미입력 등)
  if v_base is null then
    v_base := '유저' || substr(replace(new.id::text, '-', ''), 1, 6);
  end if;

  v_base := left(v_base, 20);
  v_candidate := v_base;

  -- 흔한 충돌은 접미사로 해소: 홍길동 → 홍길동2 → 홍길동3 ...
  while exists (
    select 1
    from public.users u
    where lower(btrim(u.display_name)) = lower(btrim(v_candidate))
  ) loop
    v_suffix := v_suffix + 1;
    exit when v_suffix > 99;
    v_candidate := left(v_base, 17) || v_suffix::text;
  end loop;

  begin
    insert into public.users (id, email, display_name)
    values (new.id, new.email, v_candidate);
  exception when unique_violation then
    -- 동시 가입 경합 또는 접미사 소진 시 최종 폴백(uid 조각은 충돌하지 않는다)
    insert into public.users (id, email, display_name)
    values (
      new.id,
      new.email,
      left(v_base, 12) || '_' || substr(replace(new.id::text, '-', ''), 1, 6)
    );
  end;

  return new;
end;
$$;

-- create or replace는 권한을 보존하지만, 0011의 의도를 명시적으로 유지한다.
revoke all on function public.handle_new_user() from public, anon, authenticated;
