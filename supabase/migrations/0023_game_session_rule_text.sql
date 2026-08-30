-- 게임 세션 규칙을 구조화 필드와 기타 규칙 문자열로 분리한다.
-- 적용된 0018은 유지하고, 이 migration에서 세션의 저장 구조와 RPC 입력을 변경한다.
-- 주의: 적용하는 환경의 모든 게임·참가·입장권·게임 관련 알림을 영구 삭제한다.
-- 회원·팀·필드·프리셋·게임과 무관한 알림은 유지한다. 적용 전 필요하면 백업한다.
begin;

-- 삭제 중 새 게임 데이터가 들어오지 않도록 잠그고, FK의 자식부터 삭제한다.
-- 이후 스키마 변경이 실패하면 이 삭제도 함께 rollback된다.
lock table public.game_sessions, public.participations,
  public.entry_passes, public.notifications in access exclusive mode;

delete from public.notifications
where game_session_id is not null or participation_id is not null;
delete from public.entry_passes;
delete from public.participations;
delete from public.game_sessions;

-- 빈 테이블이므로 기존 JSON을 이관하지 않는다. 기타 규칙은 text로 직접 저장한다.
-- 탄속(FPS)은 필수, BB탄 무게(g)·바이오탄 필수 여부·탄창 제한은 선택 항목이다.
alter table public.game_sessions
  alter column custom_rules type text using ''::text,
  alter column custom_rules set default '',
  add column muzzle_velocity_fps numeric not null check (muzzle_velocity_fps > 0),
  add column bb_weight_grams numeric check (bb_weight_grams > 0),
  add column bio_bb_required boolean,
  add column magazine_limit integer check (magazine_limit > 0);

-- 입력 시그니처가 달라지므로 기존 JSON RPC를 제거하고 개별 파라미터 RPC를 만든다.
-- 기존 p_input/p_updates 호출은 더 이상 사용할 수 없으며 호출부 변경이 필요하다.
drop function if exists public.create_game_session(jsonb);
drop function if exists public.update_game_session(uuid, jsonb);

-- 게임 생성: 핵심 규칙은 각 컬럼에, p_additional_rules는 custom_rules에 저장한다.
-- 기타 규칙 문자열은 trim하거나 블록으로 변환하지 않으므로 줄바꿈도 그대로 저장된다.
create function public.create_game_session(
  p_title text,
  p_starts_at timestamptz,
  p_capacity integer,
  p_game_fee numeric,
  p_muzzle_velocity_fps numeric default null,
  p_field_id uuid default null,
  p_field_name text default null,
  p_ends_at timestamptz default null,
  p_preset_id uuid default null,
  p_host_team_id uuid default null,
  p_cancel_deadline timestamptz default null,
  p_bb_weight_grams numeric default null,
  p_bio_bb_required boolean default null,
  p_magazine_limit integer default null,
  p_additional_rules text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.current_uid();
  v_preset public.game_rule_presets;
  v_muzzle numeric := p_muzzle_velocity_fps;
  v_bb numeric := p_bb_weight_grams;
  v_bio boolean := p_bio_bb_required;
  v_mag integer := p_magazine_limit;
  v_rules text := coalesce(p_additional_rules, '');
  v_id uuid;
begin
  -- 인증된 사용자의 프로필 완성 여부와 게임 생성에 필요한 기본 정보를 검사한다.
  perform public.assert_profile_complete(v_uid);
  if nullif(btrim(p_title), '') is null then
    perform public.app_error('invalid-argument', 'title는 필수 문자열입니다');
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    perform public.app_error('invalid-argument', 'startsAt은 미래 시각이어야 합니다');
  end if;
  if p_capacity is null or p_capacity < 1 then
    perform public.app_error('invalid-argument', 'capacity는 1 이상의 정수여야 합니다');
  end if;
  if p_game_fee is null or p_game_fee < 0 then
    perform public.app_error('invalid-argument', 'gameFee는 0 이상이어야 합니다');
  end if;
  -- 등록된 필드 ID와 직접 입력한 필드 이름 중 정확히 하나만 허용한다.
  if (p_field_id is null) = (nullif(btrim(p_field_name), '') is null) then
    perform public.app_error('invalid-argument', 'fieldId 또는 fieldName 중 정확히 하나를 제공해야 합니다');
  end if;
  if p_ends_at is not null and p_ends_at <= p_starts_at then
    perform public.app_error('invalid-argument', 'endsAt은 startsAt 이후여야 합니다');
  end if;
  if p_cancel_deadline is not null and (
    p_cancel_deadline < p_starts_at - interval '7 days'
    or p_cancel_deadline > p_starts_at - interval '24 hours'
  ) then
    perform public.app_error('invalid-argument', 'cancelDeadline은 시작 7일 전부터 24시간 전 사이여야 합니다');
  end if;
  -- 공개 프리셋 또는 본인 프리셋만 읽고, 입력하지 않은 핵심 규칙을 복사한다.
  -- 세션은 복사본을 소유하므로 이후 프리셋을 수정해도 기존 세션은 바뀌지 않는다.
  if p_preset_id is not null then
    select * into v_preset from public.game_rule_presets
    where id = p_preset_id and (is_public or owner_id = v_uid);
    if not found then
      perform public.app_error('not-found', '게임 룰 프리셋을 찾을 수 없습니다');
    end if;
    v_muzzle := coalesce(v_muzzle, (v_preset.rules->>'muzzleVelocityFps')::numeric);
    v_bb := coalesce(v_bb, (v_preset.rules->>'bbWeightGrams')::numeric);
    v_bio := coalesce(v_bio, (v_preset.rules->>'bioBbRequired')::boolean);
    v_mag := coalesce(v_mag, (v_preset.rules->>'magazineLimit')::integer);
    -- 프리셋 JSON은 유지하되 핵심 규칙만 복사한다. 기타 규칙은 입력 문자열을 사용한다.
  end if;
  if v_muzzle is null or v_muzzle <= 0 then
    perform public.app_error('invalid-argument', 'muzzleVelocityFps는 0보다 커야 합니다');
  end if;
  if v_bb <= 0 or v_mag <= 0 then
    perform public.app_error('invalid-argument', 'BB탄 무게와 탄창 제한은 지정할 경우 0보다 커야 합니다');
  end if;
  -- 취소 마감 미입력 시 시작 48시간 전을 사용하고 모집 중 상태로 생성한다.
  insert into public.game_sessions (
    title, created_by_user_id, field_id, field_name, host_team_id, starts_at, ends_at,
    capacity, game_fee, preset_id, custom_rules, muzzle_velocity_fps, bb_weight_grams,
    bio_bb_required, magazine_limit, cancel_deadline, status
  ) values (
    btrim(p_title), v_uid, p_field_id, nullif(btrim(p_field_name), ''), p_host_team_id,
    p_starts_at, p_ends_at, p_capacity, p_game_fee, p_preset_id, v_rules, v_muzzle, v_bb,
    v_bio, v_mag, coalesce(p_cancel_deadline, p_starts_at - interval '48 hours'), 'recruiting'
  ) returning id into v_id;
  return jsonb_build_object('success', true, 'gameSessionId', v_id);
end;
$$;

-- 게임 수정: null 파라미터는 기존 값 유지, 기타 규칙의 빈 문자열은 내용 비우기를 뜻한다.
-- 이 인터페이스에서는 선택 컬럼 값을 명시적으로 SQL NULL로 지우는 동작은 지원하지 않는다.
create function public.update_game_session(
  p_session_id uuid,
  p_title text default null,
  p_cancel_deadline timestamptz default null,
  p_capacity integer default null,
  p_game_fee numeric default null,
  p_ends_at timestamptz default null,
  p_muzzle_velocity_fps numeric default null,
  p_bb_weight_grams numeric default null,
  p_bio_bb_required boolean default null,
  p_magazine_limit integer default null,
  p_additional_rules text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.current_uid();
  v_session public.game_sessions;
  v_participation public.participations;
  v_fields text[] := '{}';
  v_changed_fields text;
  v_title text;
  v_game_fee numeric(12,0);
begin
  -- 동시 수정 충돌을 막기 위해 세션을 먼저 잠그고 소유자와 수정 가능한 상태를 검사한다.
  select * into v_session from public.game_sessions where id = p_session_id for update;
  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;
  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('update_game_session', v_session.status);
  if p_title is not null and btrim(p_title) = '' then
    perform public.app_error('invalid-argument', 'title은 비울 수 없습니다');
  end if;
  if p_capacity < v_session.capacity then
    perform public.app_error('failed-precondition', 'capacity는 줄일 수 없습니다');
  end if;
  if p_game_fee < 0 then
    perform public.app_error('invalid-argument', 'gameFee는 0 이상이어야 합니다');
  end if;
  if p_muzzle_velocity_fps <= 0 or p_bb_weight_grams <= 0 or p_magazine_limit <= 0 then
    perform public.app_error('invalid-argument', '탄속, BB탄 무게와 탄창 제한은 지정할 경우 0보다 커야 합니다');
  end if;
  if p_ends_at <= v_session.starts_at then
    perform public.app_error('invalid-argument', 'endsAt은 startsAt 이후여야 합니다');
  end if;
  if p_cancel_deadline < v_session.starts_at - interval '7 days'
    or p_cancel_deadline > v_session.starts_at - interval '24 hours'
  then
    perform public.app_error('invalid-argument', 'cancelDeadline은 시작 7일 전부터 24시간 전 사이여야 합니다');
  end if;

  v_title := coalesce(btrim(p_title), v_session.title);
  v_game_fee := coalesce(p_game_fee, v_session.game_fee);
  if v_game_fee is distinct from v_session.game_fee and v_session.confirmed_count > 0 then
    perform public.app_error('failed-precondition', '확정 참가자가 있으면 게임비를 변경할 수 없습니다');
  end if;

  -- 실제 값이 달라진 항목만 반환한다. 같은 요청을 재전송하면 쓰기·알림을 생략한다.
  if v_title is distinct from v_session.title then
    v_fields := array_append(v_fields, 'title');
  end if;
  if row(
    coalesce(p_muzzle_velocity_fps, v_session.muzzle_velocity_fps),
    coalesce(p_bb_weight_grams, v_session.bb_weight_grams),
    coalesce(p_bio_bb_required, v_session.bio_bb_required),
    coalesce(p_magazine_limit, v_session.magazine_limit),
    coalesce(p_additional_rules, v_session.custom_rules)
  ) is distinct from row(
    v_session.muzzle_velocity_fps, v_session.bb_weight_grams,
    v_session.bio_bb_required, v_session.magazine_limit, v_session.custom_rules
  ) then
    v_fields := array_append(v_fields, 'customRules');
  end if;
  if p_capacity is not null and p_capacity <> v_session.capacity then
    v_fields := array_append(v_fields, 'capacity');
  end if;
  if v_game_fee is distinct from v_session.game_fee then
    v_fields := array_append(v_fields, 'gameFee');
  end if;
  if p_ends_at is not null and p_ends_at is distinct from v_session.ends_at then
    v_fields := array_append(v_fields, 'endsAt');
  end if;
  if p_cancel_deadline is not null and p_cancel_deadline <> v_session.cancel_deadline then
    v_fields := array_append(v_fields, 'cancelDeadline');
  end if;
  if cardinality(v_fields) = 0 then
    return jsonb_build_object('success', true, 'updatedFields', v_fields);
  end if;

  -- 전달된 파라미터만 반영한다. 기타 규칙은 문자열 그대로 저장한다.
  update public.game_sessions set
    title = v_title,
    cancel_deadline = coalesce(p_cancel_deadline, cancel_deadline),
    capacity = coalesce(p_capacity, capacity),
    game_fee = v_game_fee,
    ends_at = coalesce(p_ends_at, ends_at),
    muzzle_velocity_fps = coalesce(p_muzzle_velocity_fps, muzzle_velocity_fps),
    bb_weight_grams = coalesce(p_bb_weight_grams, bb_weight_grams),
    bio_bb_required = coalesce(p_bio_bb_required, bio_bb_required),
    magazine_limit = coalesce(p_magazine_limit, magazine_limit),
    custom_rules = coalesce(p_additional_rules, custom_rules)
  where id = p_session_id;

  -- 기존 정책대로 정원 또는 규칙 변경 시 확정 참가자에게만 알린다.
  if 'capacity' = any(v_fields) or 'customRules' = any(v_fields) then
    v_changed_fields := array_to_string(v_fields, ',');
    for v_participation in
      select * from public.participations
      where game_session_id = p_session_id and status = 'confirmed'
    loop
      perform public.notify(
        v_participation.user_id, 'session.changed', '게임 정보가 변경되었습니다',
        format('%s의 정보가 변경되었습니다 (%s)', v_title, v_changed_fields),
        format('/sessions/%s', p_session_id),
        jsonb_build_object('type', 'updated', 'fields', v_changed_fields),
        p_session_id, v_participation.id
      );
    end loop;
  end if;
  return jsonb_build_object('success', true, 'updatedFields', to_jsonb(v_fields));
end;
$$;

-- 새 RPC는 로그인한 사용자만 호출할 수 있도록 PUBLIC 기본 실행 권한을 회수한다.
revoke execute on function public.create_game_session(text, timestamptz, integer, numeric, numeric, uuid, text, timestamptz, uuid, uuid, timestamptz, numeric, boolean, integer, text) from public;
grant execute on function public.create_game_session(text, timestamptz, integer, numeric, numeric, uuid, text, timestamptz, uuid, uuid, timestamptz, numeric, boolean, integer, text) to authenticated;
revoke execute on function public.update_game_session(uuid, text, timestamptz, integer, numeric, timestamptz, numeric, numeric, boolean, integer, text) from public;
grant execute on function public.update_game_session(uuid, text, timestamptz, integer, numeric, timestamptz, numeric, numeric, boolean, integer, text) to authenticated;

commit;
