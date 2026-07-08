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
  v_bank_name text;
  v_bank_account_number text;
  v_bank_account_holder text;
  v_preset_id uuid;
  v_custom_rules jsonb;
  v_cancel_deadline timestamptz;
  v_session_id uuid;
  v_has_field_id boolean;
  v_has_field_name boolean;
  v_has_preset boolean;
  v_has_custom boolean;
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

  if coalesce(jsonb_typeof(p_input->'bankAccount'), 'null') <> 'object' then
    perform public.app_error('invalid-argument', 'bankAccount(bankName, accountNumber, accountHolder)는 필수입니다');
  end if;

  v_bank_name := nullif(btrim(p_input->'bankAccount'->>'bankName'), '');
  v_bank_account_number := nullif(btrim(p_input->'bankAccount'->>'accountNumber'), '');
  v_bank_account_holder := nullif(btrim(p_input->'bankAccount'->>'accountHolder'), '');
  if v_bank_name is null then
    perform public.app_error('invalid-argument', 'bankAccount.bankName는 필수 문자열입니다');
  end if;
  if v_bank_account_number is null then
    perform public.app_error('invalid-argument', 'bankAccount.accountNumber는 필수 문자열입니다');
  end if;
  if v_bank_account_holder is null then
    perform public.app_error('invalid-argument', 'bankAccount.accountHolder는 필수 문자열입니다');
  end if;

  v_has_preset := nullif(p_input->>'presetId', '') is not null;
  v_has_custom := p_input ? 'customRules'
    and coalesce(jsonb_typeof(p_input->'customRules'), 'null') = 'object';
  if v_has_preset = v_has_custom then
    perform public.app_error('invalid-argument', 'presetId 또는 customRules 중 정확히 하나를 제공해야 합니다');
  end if;

  if v_has_preset then
    v_preset_id := public.try_uuid(p_input->>'presetId');
    if not exists (
      select 1
      from public.game_rule_presets gp
      where gp.id = v_preset_id
        and (gp.is_public or gp.owner_id = v_uid)
    ) then
      perform public.app_error('not-found', '게임 룰 프리셋을 찾을 수 없습니다');
    end if;
  else
    v_custom_rules := p_input->'customRules';
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
    title,
    created_by_user_id,
    host_team_id,
    field_id,
    field_name,
    starts_at,
    ends_at,
    capacity,
    confirmed_count,
    game_fee,
    payment_method,
    bank_name,
    bank_account_number,
    bank_account_holder,
    preset_id,
    custom_rules,
    cancel_deadline,
    status
  ) values (
    v_title,
    v_uid,
    v_host_team_id,
    v_field_id,
    v_field_name,
    v_starts_at,
    v_ends_at,
    v_capacity,
    0,
    v_game_fee,
    'pre_transfer',
    v_bank_name,
    v_bank_account_number,
    v_bank_account_holder,
    v_preset_id,
    v_custom_rules,
    v_cancel_deadline,
    'recruiting'
  )
  returning id into v_session_id;

  return jsonb_build_object('success', true, 'gameSessionId', v_session_id);
end;
$$;

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
  v_key text;
  v_updated_fields text[] := array[]::text[];
  v_title text;
  v_custom_rules jsonb;
  v_cancel_deadline timestamptz;
  v_capacity int;
  v_game_fee numeric(12,0);
  v_ends_at timestamptz;
  v_changed_fields text;
  v_participation public.participations;
begin
  v_uid := public.current_uid();

  if coalesce(jsonb_typeof(p_updates), 'null') <> 'object' then
    perform public.app_error('invalid-argument', 'updates는 객체여야 합니다');
  end if;
  if p_updates = '{}'::jsonb then
    perform public.app_error('invalid-argument', 'updates에 변경할 필드가 없습니다');
  end if;

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
    if v_session.preset_id is not null then
      perform public.app_error('failed-precondition', '프리셋 세션은 customRules를 변경할 수 없습니다');
    end if;
    if coalesce(jsonb_typeof(p_updates->'customRules'), 'null') <> 'object' then
      perform public.app_error('invalid-argument', 'updates.customRules는 객체여야 합니다');
    end if;
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
    if v_capacity < v_session.confirmed_count then
      perform public.app_error('failed-precondition', 'capacity는 확정 인원보다 작을 수 없습니다');
    end if;
  end if;

  if p_updates ? 'gameFee' then
    if jsonb_typeof(p_updates->'gameFee') <> 'number'
      or (p_updates->>'gameFee')::numeric < 0
    then
      perform public.app_error('invalid-argument', 'updates.gameFee는 0 이상이어야 합니다');
    end if;
    if v_session.confirmed_count > 0 then
      perform public.app_error('failed-precondition', '확정 참가자가 있으면 gameFee를 변경할 수 없습니다');
    end if;
    v_game_fee := (p_updates->>'gameFee')::numeric(12,0);
  end if;

  if p_updates ? 'cancelDeadline' then
    if nullif(p_updates->>'cancelDeadline', '') is null then
      perform public.app_error('invalid-argument', 'updates.cancelDeadline는 유효한 시각이어야 합니다');
    end if;
    v_cancel_deadline := public.try_timestamptz(p_updates->>'cancelDeadline');
    if v_cancel_deadline < v_session.starts_at - interval '7 days'
      or v_cancel_deadline > v_session.starts_at - interval '24 hours'
    then
      perform public.app_error('invalid-argument', 'cancelDeadline은 시작 7일 전부터 24시간 전 사이여야 합니다');
    end if;
  end if;

  if p_updates ? 'endsAt' then
    if nullif(p_updates->>'endsAt', '') is null then
      perform public.app_error('invalid-argument', 'updates.endsAt는 유효한 시각이어야 합니다');
    end if;
    v_ends_at := public.try_timestamptz(p_updates->>'endsAt');
    if v_ends_at <= v_session.starts_at then
      perform public.app_error('invalid-argument', 'endsAt은 startsAt 이후여야 합니다');
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
        format('%s의 %s 정보가 업데이트되었습니다', v_title, v_changed_fields),
        format('/sessions/%s', p_session_id),
        jsonb_build_object('type', 'updated', 'changedFields', v_changed_fields),
        p_session_id,
        v_participation.id
      );
    end loop;
  end if;

  return jsonb_build_object(
    'success', true,
    'updatedFields', to_jsonb(v_updated_fields)
  );
end;
$$;

create or replace function public.cancel_game_session(
  p_session_id uuid,
  p_reason text default null
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
  v_affected int := 0;
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
  perform public.assert_session_status('cancel_game_session', v_session.status);

  update public.game_sessions
  set status = 'cancelled',
      confirmed_count = 0
  where id = p_session_id;

  for v_participation in
    update public.participations
    set status = 'cancelled'
    where game_session_id = p_session_id
      and status in ('pendingApproval', 'awaitingPayment', 'paymentReview', 'confirmed')
    returning *
  loop
    v_affected := v_affected + 1;
    perform public.notify(
      v_participation.user_id,
      'session.changed',
      '게임이 취소되었습니다',
      case
        when nullif(p_reason, '') is null then
          format('%s이(가) 취소되었습니다.', v_session.title)
        else
          format('%s이(가) 취소되었습니다. %s', v_session.title, p_reason)
      end,
      format('/sessions/%s', p_session_id),
      jsonb_strip_nulls(jsonb_build_object('type', 'cancelled', 'reason', nullif(p_reason, ''))),
      p_session_id,
      v_participation.id
    );
  end loop;

  update public.entry_passes
  set status = 'revoked'
  where game_session_id = p_session_id
    and status = 'active';

  return jsonb_build_object('success', true, 'affectedParticipations', v_affected);
end;
$$;

revoke execute on function public.create_game_session(jsonb) from public;
revoke execute on function public.update_game_session(uuid, jsonb) from public;
revoke execute on function public.cancel_game_session(uuid, text) from public;

grant execute on function public.create_game_session(jsonb) to authenticated;
grant execute on function public.update_game_session(uuid, jsonb) to authenticated;
grant execute on function public.cancel_game_session(uuid, text) to authenticated;
