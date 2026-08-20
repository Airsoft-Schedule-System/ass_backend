-- 게임룰 구조 확정 — 구조화 핵심 필드 + 이어붙이는 룰 노트
--
-- 근거: 2026-07-16 회의 확정 방향
--   "핵심 규칙은 프리셋, 복잡한 규칙은 저장 노트·자유 입력을 조합"
--   "저장된 룰 노트는 게임 생성 폼에서 불러오고, 해당 게임에서만 추가 수정"
--
-- 문제였던 것: rules_xor 제약이 preset_id 와 custom_rules 중 하나만 허용해
--   "수도권 표준 프리셋 + 기관총 노트" 같은 조합이 스키마에서 막혀 있었다.
--   회의가 그리려던 게 정확히 그 조합인데 구현이 XOR이었다.
--
-- 바뀌는 모델:
--   custom_rules = 그 게임의 최종 룰 (프리셋·노트를 불러와 복사한 결과). 항상 존재한다.
--   preset_id    = 출처 표시(provenance). 선택이며, 읽기 시점에 참조하지 않는다.
--
--   복사본이므로 원본 프리셋·노트를 나중에 고쳐도 과거 게임은 바뀌지 않는다.

-- ─────────────────────────────────────────────────────────
-- 1. 룰 형태 검증 헬퍼
--
--    "정의가 어디에도 없어서 화면을 못 만든다"가 이 작업의 출발점이었다.
--    최소한의 형태를 DB에서 강제해 다시 흐트러지지 않게 한다.
-- ─────────────────────────────────────────────────────────
create or replace function public.assert_game_rules(p_rules jsonb)
returns void
language plpgsql
immutable
as $$
declare
  v_block jsonb;
begin
  if coalesce(jsonb_typeof(p_rules), 'null') <> 'object' then
    perform public.app_error('invalid-argument', 'customRules는 객체여야 합니다');
  end if;

  -- ⚠️ 키가 없으면 jsonb_typeof가 NULL이고 `NULL <> 'number'` 는 TRUE가 아니라 NULL이다.
  --    그대로 두면 검증이 조용히 통과한다. 항상 coalesce로 감싼다.

  -- 탄속은 "내 총이 이 게임에 나갈 수 있나"를 가르는 유일한 수치라 필수로 둔다.
  if coalesce(jsonb_typeof(p_rules->'muzzleVelocityFps'), 'null') <> 'number'
    or (p_rules->>'muzzleVelocityFps')::numeric <= 0
  then
    perform public.app_error('invalid-argument', 'customRules.muzzleVelocityFps는 0보다 큰 숫자여야 합니다');
  end if;

  if p_rules ? 'bbWeightGrams'
    and coalesce(jsonb_typeof(p_rules->'bbWeightGrams'), 'null') not in ('number', 'null')
  then
    perform public.app_error('invalid-argument', 'customRules.bbWeightGrams는 숫자여야 합니다');
  end if;

  if p_rules ? 'bioBbRequired'
    and coalesce(jsonb_typeof(p_rules->'bioBbRequired'), 'null') not in ('boolean', 'null')
  then
    perform public.app_error('invalid-argument', 'customRules.bioBbRequired는 불리언이어야 합니다');
  end if;

  if p_rules ? 'magazineLimit'
    and coalesce(jsonb_typeof(p_rules->'magazineLimit'), 'null') not in ('number', 'null')
  then
    perform public.app_error('invalid-argument', 'customRules.magazineLimit는 숫자여야 합니다');
  end if;

  -- 특수화기·로컬룰은 별도 테이블을 만들지 않고 블록 배열로 이어붙인다.
  if p_rules ? 'noteBlocks' then
    if jsonb_typeof(p_rules->'noteBlocks') <> 'array' then
      perform public.app_error('invalid-argument', 'customRules.noteBlocks는 배열이어야 합니다');
    end if;

    for v_block in select * from jsonb_array_elements(p_rules->'noteBlocks')
    loop
      if coalesce(jsonb_typeof(v_block), 'null') <> 'object'
        or coalesce(jsonb_typeof(v_block->'title'), 'null') <> 'string'
        or coalesce(jsonb_typeof(v_block->'body'), 'null') <> 'string'
        or btrim(coalesce(v_block->>'body', '')) = ''
      then
        perform public.app_error(
          'invalid-argument',
          'noteBlocks의 각 항목은 { title, body } 문자열이어야 하며 body는 비울 수 없습니다'
        );
      end if;
    end loop;
  end if;
end;
$$;

revoke execute on function public.assert_game_rules(jsonb) from public;
grant execute on function public.assert_game_rules(jsonb) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────
-- 2. 기존 데이터 이관 — 프리셋만 있던 세션에 룰을 복사해 넣는다
-- ─────────────────────────────────────────────────────────
update public.game_sessions gs
set custom_rules = coalesce(gp.rules, '{}'::jsonb)
from public.game_rule_presets gp
where gs.preset_id = gp.id
  and gs.custom_rules is null;

-- 그래도 비어 있는 경우(프리셋이 사라졌거나 rules가 null) 최소 형태를 채운다.
update public.game_sessions
set custom_rules = '{"muzzleVelocityFps": 400}'::jsonb
where custom_rules is null;

-- 탄속이 없는 기존 룰에 기본값을 넣어 새 제약을 통과시킨다.
update public.game_sessions
set custom_rules = custom_rules || '{"muzzleVelocityFps": 400}'::jsonb
where jsonb_typeof(custom_rules->'muzzleVelocityFps') is distinct from 'number';

update public.game_rule_presets
set rules = coalesce(rules, '{}'::jsonb) || '{"muzzleVelocityFps": 400}'::jsonb
where jsonb_typeof(rules->'muzzleVelocityFps') is distinct from 'number';

-- ─────────────────────────────────────────────────────────
-- 3. XOR 제약 해제 — 프리셋과 노트를 함께 쓸 수 있게 한다
-- ─────────────────────────────────────────────────────────
alter table public.game_sessions
  drop constraint if exists rules_xor;

alter table public.game_sessions
  alter column custom_rules set not null;

-- ─────────────────────────────────────────────────────────
-- 4. 게임 생성 — customRules 필수, presetId는 출처 표시
-- ─────────────────────────────────────────────────────────
create or replace function public.create_game_session(p_input jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_title text;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
  v_field_id uuid;
  v_field_name text;
  v_host_team_id uuid;
  v_capacity int;
  v_game_fee numeric(12,0);
  v_preset_id uuid;
  v_custom_rules jsonb;
  v_cancel_deadline timestamptz;
  v_session_id uuid;
  v_has_field_id boolean;
  v_has_field_name boolean;
begin
  v_uid := public.current_uid();
  perform public.assert_profile_complete(v_uid);

  if coalesce(jsonb_typeof(p_input), 'null') <> 'object' then
    perform public.app_error('invalid-argument', '입력은 객체여야 합니다');
  end if;

  v_title := nullif(btrim(p_input->>'title'), '');
  if v_title is null then
    perform public.app_error('invalid-argument', 'title는 필수 문자열입니다');
  end if;

  v_has_field_id := nullif(p_input->>'fieldId', '') is not null;
  v_has_field_name := nullif(btrim(p_input->>'fieldName'), '') is not null;
  if v_has_field_id = v_has_field_name then
    perform public.app_error('invalid-argument', 'fieldId 또는 fieldName 중 정확히 하나를 제공해야 합니다');
  end if;

  if v_has_field_id then
    v_field_id := public.try_uuid(p_input->>'fieldId');
  else
    v_field_name := nullif(btrim(p_input->>'fieldName'), '');
  end if;

  if jsonb_typeof(p_input->'capacity') <> 'number'
    or (p_input->>'capacity')::numeric <> trunc((p_input->>'capacity')::numeric)
    or (p_input->>'capacity')::int < 1
  then
    perform public.app_error('invalid-argument', 'capacity는 1 이상의 정수여야 합니다');
  end if;
  v_capacity := (p_input->>'capacity')::int;

  if jsonb_typeof(p_input->'gameFee') <> 'number'
    or (p_input->>'gameFee')::numeric < 0
  then
    perform public.app_error('invalid-argument', 'gameFee는 0 이상이어야 합니다');
  end if;
  v_game_fee := (p_input->>'gameFee')::numeric(12,0);

  if nullif(p_input->>'startsAt', '') is null then
    perform public.app_error('invalid-argument', 'startsAt는 필수입니다');
  end if;
  v_starts_at := public.try_timestamptz(p_input->>'startsAt');
  if v_starts_at <= now() then
    perform public.app_error('invalid-argument', 'startsAt은 미래 시각이어야 합니다');
  end if;

  if nullif(p_input->>'endsAt', '') is not null then
    v_ends_at := public.try_timestamptz(p_input->>'endsAt');
    if v_ends_at <= v_starts_at then
      perform public.app_error('invalid-argument', 'endsAt은 startsAt 이후여야 합니다');
    end if;
  end if;

  -- 룰은 프리셋·노트를 화면에서 합쳐 보낸 최종본이다. 항상 필요하다.
  v_custom_rules := p_input->'customRules';
  perform public.assert_game_rules(v_custom_rules);

  -- 프리셋은 출처 표시일 뿐이라 선택이며, 접근 가능한 것만 허용한다.
  if nullif(p_input->>'presetId', '') is not null then
    v_preset_id := public.try_uuid(p_input->>'presetId');
    if not exists (
      select 1
      from public.game_rule_presets gp
      where gp.id = v_preset_id
        and (gp.is_public or gp.owner_id = v_uid)
    ) then
      perform public.app_error('not-found', '게임 룰 프리셋을 찾을 수 없습니다');
    end if;
  end if;

  if nullif(p_input->>'hostTeamId', '') is not null then
    v_host_team_id := public.try_uuid(p_input->>'hostTeamId');
  end if;

  if nullif(p_input->>'cancelDeadline', '') is not null then
    v_cancel_deadline := public.try_timestamptz(p_input->>'cancelDeadline');
    if v_cancel_deadline < v_starts_at - interval '7 days'
      or v_cancel_deadline > v_starts_at - interval '24 hours'
    then
      perform public.app_error('invalid-argument', 'cancelDeadline은 시작 7일 전부터 24시간 전 사이여야 합니다');
    end if;
  else
    v_cancel_deadline := v_starts_at - interval '48 hours';
  end if;

  insert into public.game_sessions (
    title, created_by_user_id, host_team_id, field_id, field_name,
    starts_at, ends_at, capacity, confirmed_count, game_fee,
    preset_id, custom_rules, cancel_deadline, status
  ) values (
    v_title, v_uid, v_host_team_id, v_field_id, v_field_name,
    v_starts_at, v_ends_at, v_capacity, 0, v_game_fee,
    v_preset_id, v_custom_rules, v_cancel_deadline, 'recruiting'
  )
  returning id into v_session_id;

  return jsonb_build_object('success', true, 'gameSessionId', v_session_id);
end;
$$;

-- ─────────────────────────────────────────────────────────
-- 5. 게임 수정 — 프리셋에서 시작했어도 룰을 고칠 수 있다
--
--    회의의 "해당 게임에서만 추가 수정" 을 반영한다.
--    기존에는 preset_id가 있으면 customRules 변경을 막고 있었다.
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

  for v_key in select jsonb_object_keys(p_updates)
  loop
    if v_key not in ('title', 'customRules', 'cancelDeadline', 'capacity', 'gameFee', 'endsAt') then
      perform public.app_error('invalid-argument', format('%s는 변경할 수 없는 필드입니다', v_key));
    end if;
    v_updated_fields := array_append(v_updated_fields, v_key);
  end loop;

  if p_updates ? 'title' then
    v_title := nullif(btrim(p_updates->>'title'), '');
    if v_title is null then
      perform public.app_error('invalid-argument', 'updates.title는 필수 문자열입니다');
    end if;
  end if;

  if p_updates ? 'customRules' then
    perform public.assert_game_rules(p_updates->'customRules');
    v_custom_rules := p_updates->'customRules';
  end if;

  if p_updates ? 'capacity' then
    if jsonb_typeof(p_updates->'capacity') <> 'number'
      or (p_updates->>'capacity')::numeric <> trunc((p_updates->>'capacity')::numeric)
      or (p_updates->>'capacity')::int < 1
    then
      perform public.app_error('invalid-argument', 'updates.capacity는 1 이상의 정수여야 합니다');
    end if;
    v_capacity := (p_updates->>'capacity')::int;
    if v_capacity <= v_session.capacity then
      perform public.app_error('failed-precondition', 'capacity는 현재 값보다 크게만 변경할 수 있습니다');
    end if;
  end if;

  if p_updates ? 'gameFee' then
    if jsonb_typeof(p_updates->'gameFee') <> 'number'
      or (p_updates->>'gameFee')::numeric < 0
    then
      perform public.app_error('invalid-argument', 'updates.gameFee는 0 이상이어야 합니다');
    end if;
    if v_session.confirmed_count > 0 then
      perform public.app_error('failed-precondition', '확정 참가자가 있으면 게임비를 변경할 수 없습니다');
    end if;
    v_game_fee := (p_updates->>'gameFee')::numeric(12,0);
  end if;

  if p_updates ? 'endsAt' then
    v_ends_at := public.try_timestamptz(p_updates->>'endsAt');
    if v_ends_at <= v_session.starts_at then
      perform public.app_error('invalid-argument', 'updates.endsAt은 startsAt 이후여야 합니다');
    end if;
  end if;

  if p_updates ? 'cancelDeadline' then
    v_cancel_deadline := public.try_timestamptz(p_updates->>'cancelDeadline');
    if v_cancel_deadline < v_session.starts_at - interval '7 days'
      or v_cancel_deadline > v_session.starts_at - interval '24 hours'
    then
      perform public.app_error('invalid-argument', 'updates.cancelDeadline은 시작 7일 전부터 24시간 전 사이여야 합니다');
    end if;
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
