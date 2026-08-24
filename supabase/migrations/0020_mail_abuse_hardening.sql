-- 메일 증폭 차단 + 권한 하드닝 — 2026-08-20 레드팀 RT-04 · RT-06 · 하드닝 메모
--
-- ⚠️ 이 마이그레이션은 0019(PR #12) 다음에 적용되어야 한다.
--    원격 이력 앞에 끼어드는 번호는 db push 가 거부한다.

-- ─────────────────────────────────────────────────────────
-- 1. RT-04 — 값이 실제로 바뀐 것만 변경으로 친다
--
--    기존 update_game_session 은 p_updates 에 키가 들어 있기만 하면
--    실제 변경 여부와 무관하게 updatedFields 에 넣었다.
--    같은 customRules 를 반복해서 보내면 그때마다 확정 참가자 전원에게
--    session.changed 알림이 생기고, 이 타입은 항상 이메일 발송 대상이다.
--
--    공격자는 자기 게임에 피해자를 승인시킨 뒤 no-op 업데이트를 반복해
--    신뢰 발신자 이름으로 메일을 계속 보낼 수 있다. webhook secret 도
--    필요 없다. 알림 행과 pg_net 요청도 함께 무한히 늘어난다.
--
--    값 비교를 넣어 증폭의 원천을 없앤다.
-- ─────────────────────────────────────────────────────────
create or replace function public.update_game_session(
  p_session_id uuid,
  p_updates jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_session public.game_sessions;
  v_participation public.participations;
  v_key text;
  v_updated_fields text[] := '{}';
  v_changed_fields text;
  v_title text;
  v_custom_rules jsonb;
  v_cancel_deadline timestamptz;
  v_capacity int;
  v_game_fee numeric(12,0);
  v_ends_at timestamptz;
begin
  v_uid := public.current_uid();

  select *
    into v_session
  from public.game_sessions
  where id = p_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('update_game_session', v_session.status);

  if coalesce(jsonb_typeof(p_updates), 'null') <> 'object' then
    perform public.app_error('invalid-argument', 'updates는 객체여야 합니다');
  end if;

  v_title := v_session.title;
  v_custom_rules := v_session.custom_rules;
  v_cancel_deadline := v_session.cancel_deadline;
  v_capacity := v_session.capacity;
  v_game_fee := v_session.game_fee;
  v_ends_at := v_session.ends_at;

  -- 허용된 키인지 먼저 확인한다. 변경 여부 판정은 각 항목에서 따로 한다.
  for v_key in select jsonb_object_keys(p_updates)
  loop
    if v_key not in ('title', 'customRules', 'cancelDeadline', 'capacity', 'gameFee', 'endsAt') then
      perform public.app_error('invalid-argument', format('%s는 변경할 수 없는 필드입니다', v_key));
    end if;
  end loop;

  if p_updates ? 'title' then
    v_title := nullif(btrim(p_updates->>'title'), '');
    if v_title is null then
      perform public.app_error('invalid-argument', 'updates.title는 필수 문자열입니다');
    end if;
    if v_title is distinct from v_session.title then
      v_updated_fields := array_append(v_updated_fields, 'title');
    end if;
  end if;

  if p_updates ? 'customRules' then
    perform public.assert_game_rules(p_updates->'customRules');
    v_custom_rules := p_updates->'customRules';
    -- jsonb 동등 비교는 키 순서를 무시하므로 의미 기준으로 판정된다.
    if v_custom_rules is distinct from v_session.custom_rules then
      v_updated_fields := array_append(v_updated_fields, 'customRules');
    end if;
  end if;

  if p_updates ? 'capacity' then
    if jsonb_typeof(p_updates->'capacity') <> 'number'
      or (p_updates->>'capacity')::numeric <> trunc((p_updates->>'capacity')::numeric)
      or (p_updates->>'capacity')::int < 1
    then
      perform public.app_error('invalid-argument', 'updates.capacity는 1 이상의 정수여야 합니다');
    end if;
    v_capacity := (p_updates->>'capacity')::int;
    -- 같은 값 재전송은 무해한 no-op 으로 통과시키고, 감소만 막는다.
    if v_capacity < v_session.capacity then
      perform public.app_error('failed-precondition', 'capacity는 현재 값보다 크게만 변경할 수 있습니다');
    end if;
    if v_capacity is distinct from v_session.capacity then
      v_updated_fields := array_append(v_updated_fields, 'capacity');
    end if;
  end if;

  if p_updates ? 'gameFee' then
    if jsonb_typeof(p_updates->'gameFee') <> 'number'
      or (p_updates->>'gameFee')::numeric < 0
    then
      perform public.app_error('invalid-argument', 'updates.gameFee는 0 이상이어야 합니다');
    end if;
    v_game_fee := (p_updates->>'gameFee')::numeric(12,0);
    -- 확정 참가자가 있으면 실제로 바꾸려 할 때만 막는다.
    if v_game_fee is distinct from v_session.game_fee then
      if v_session.confirmed_count > 0 then
        perform public.app_error('failed-precondition', '확정 참가자가 있으면 게임비를 변경할 수 없습니다');
      end if;
      v_updated_fields := array_append(v_updated_fields, 'gameFee');
    end if;
  end if;

  if p_updates ? 'endsAt' then
    v_ends_at := public.try_timestamptz(p_updates->>'endsAt');
    if v_ends_at <= v_session.starts_at then
      perform public.app_error('invalid-argument', 'updates.endsAt은 startsAt 이후여야 합니다');
    end if;
    if v_ends_at is distinct from v_session.ends_at then
      v_updated_fields := array_append(v_updated_fields, 'endsAt');
    end if;
  end if;

  if p_updates ? 'cancelDeadline' then
    v_cancel_deadline := public.try_timestamptz(p_updates->>'cancelDeadline');
    if v_cancel_deadline < v_session.starts_at - interval '7 days'
      or v_cancel_deadline > v_session.starts_at - interval '24 hours'
    then
      perform public.app_error('invalid-argument', 'updates.cancelDeadline은 시작 7일 전부터 24시간 전 사이여야 합니다');
    end if;
    if v_cancel_deadline is distinct from v_session.cancel_deadline then
      v_updated_fields := array_append(v_updated_fields, 'cancelDeadline');
    end if;
  end if;

  -- 바뀐 것이 없으면 쓰기도 알림도 하지 않는다.
  if array_length(v_updated_fields, 1) is null then
    return jsonb_build_object('success', true, 'updatedFields', '[]'::jsonb);
  end if;

  update public.game_sessions
  set title = v_title,
      custom_rules = v_custom_rules,
      cancel_deadline = v_cancel_deadline,
      capacity = v_capacity,
      game_fee = v_game_fee,
      ends_at = v_ends_at
  where id = p_session_id;

  if 'capacity' = any(v_updated_fields) or 'customRules' = any(v_updated_fields) then
    v_changed_fields := array_to_string(v_updated_fields, ',');

    for v_participation in
      select *
      from public.participations
      where game_session_id = p_session_id
        and status = 'confirmed'
    loop
      perform public.notify(
        v_participation.user_id,
        'session.changed',
        '게임 정보가 변경되었습니다',
        format('%s의 정보가 변경되었습니다 (%s)', v_title, v_changed_fields),
        format('/sessions/%s', p_session_id),
        jsonb_build_object('type', 'updated', 'fields', v_changed_fields),
        p_session_id,
        v_participation.id
      );
    end loop;
  end if;

  return jsonb_build_object('success', true, 'updatedFields', v_updated_fields);
end;
$$;

-- ─────────────────────────────────────────────────────────
-- 2. RT-06 — 인증 이메일과 발송 이메일이 갈라지는 것을 막는다
--
--    handle_new_user 는 auth user INSERT 때만 email 을 복사했고,
--    이후 변경을 따라가는 경로가 없었다. 사용자는 public.users.email 을
--    직접 고칠 수도 없다(컬럼 grant 밖).
--
--    Edge Function 은 public.users.email 을 수신 주소로 쓴다.
--    따라서 이메일을 바꾼 사용자는 이전 주소로 계속 메일을 받게 되고,
--    그 주소가 재할당됐다면 제3자에게 알림이 간다.
-- ─────────────────────────────────────────────────────────
-- guard_users_update 는 email 변경을 무조건 막고 있었다. 컬럼 grant 가
-- 이미 authenticated 의 email 수정을 차단하므로 이 트리거는 심층 방어인데,
-- 그 때문에 아래 동기화 경로까지 막힌다.
--
-- 규칙을 정확히 다시 쓴다: public.users.email 은 auth.users.email 을
-- 따라가는 값이므로, 그 값과 일치하는 변경만 허용한다.
-- 다른 값으로 바꾸려는 시도는 어떤 경로든 계속 거부된다.
create or replace function public.guard_users_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.id is distinct from old.id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'users update may only change display_name, phone_number, team_id, last_active_at'
      using errcode = '42501';
  end if;

  if new.email is distinct from old.email
    and new.email is distinct from (
      select a.email from auth.users a where a.id = new.id
    )
  then
    raise exception 'users.email must match the authenticated identity'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create or replace function public.sync_user_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.users
  set email = new.email
  where id = new.id
    and email is distinct from new.email;

  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed on auth.users;

create trigger on_auth_user_email_changed
after update of email on auth.users
for each row
when (old.email is distinct from new.email)
execute function public.sync_user_email();

-- 이미 갈라진 행이 있으면 지금 맞춘다.
update public.users u
set email = a.email
from auth.users a
where a.id = u.id
  and u.email is distinct from a.email;

-- ─────────────────────────────────────────────────────────
-- 3. 하드닝 — search_path 그림자 방지
--
--    is_session_owner 는 SECURITY DEFINER 인데 game_sessions 를
--    스키마 없이 참조한다. 호출자가 임시 객체를 만들 수 있는 경로를
--    얻으면 pg_temp.game_sessions 로 가려질 여지가 있다.
--    현재 Data API 에는 그런 경로가 없지만 방어를 명시해 둔다.
-- ─────────────────────────────────────────────────────────
create or replace function public.is_session_owner(sid uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.game_sessions g
    where g.id = sid
      and g.created_by_user_id = auth.uid()
  );
$$;

-- ─────────────────────────────────────────────────────────
-- 4. 하드닝 — 이후 만들어진 함수의 PUBLIC 실행 권한
--
--    0005 의 blanket revoke 는 그 시점에 존재하던 함수만 걷어냈다.
--    이후 추가된 tg_notify_email 등에 PUBLIC EXECUTE 가 남아 있다.
--    trigger 반환형이라 PostgREST 가 노출하지는 않지만, 기본값을
--    바꿔 두면 앞으로 같은 누락이 생기지 않는다.
-- ─────────────────────────────────────────────────────────
revoke execute on function public.tg_notify_email() from public;

alter default privileges in schema public
  revoke execute on functions from public;
