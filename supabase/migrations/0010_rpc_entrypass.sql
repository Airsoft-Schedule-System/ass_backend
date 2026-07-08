create or replace function public.build_entry_pass_token(
  p_entry_pass_id uuid,
  p_game_session_id uuid,
  p_user_id uuid,
  p_issued_at timestamptz,
  p_version text
)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select encode(
    extensions.hmac(
      convert_to(
        concat_ws(
          '|',
          p_entry_pass_id::text,
          p_game_session_id::text,
          p_user_id::text,
          floor(extract(epoch from p_issued_at) * 1000)::bigint::text,
          p_version
        ),
        'utf8'
      ),
      convert_to(public.vault_secret('qr_hmac_secret'), 'utf8'),
      'sha256'::text
    ),
    'base64'
  );
$$;

create or replace function public.hash_entry_pass_token(p_token text)
returns text
language sql
immutable
security definer
set search_path = public
as $$
  select encode(extensions.digest(convert_to(p_token, 'utf8'), 'sha256'::text), 'hex');
$$;

create or replace function public.issue_entry_pass(
  p_participation public.participations,
  p_session public.game_sessions
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing_id uuid;
  v_entry_pass_id uuid := gen_random_uuid();
  v_issued_at timestamptz := now();
  v_version text := 'v1';
  v_token text;
begin
  select ep.id
    into v_existing_id
  from public.entry_passes ep
  where ep.participation_id = p_participation.id
    and ep.status = 'active'
  limit 1;

  if v_existing_id is not null then
    return v_existing_id;
  end if;

  v_token := public.build_entry_pass_token(
    v_entry_pass_id,
    p_session.id,
    p_participation.user_id,
    v_issued_at,
    v_version
  );

  insert into public.entry_passes (
    id,
    participation_id,
    game_session_id,
    user_id,
    status,
    qr_token_hash,
    qr_secret_version,
    issued_at,
    expires_at
  ) values (
    v_entry_pass_id,
    p_participation.id,
    p_session.id,
    p_participation.user_id,
    'active',
    public.hash_entry_pass_token(v_token),
    v_version,
    v_issued_at,
    p_session.starts_at + interval '24 hours'
  );

  return v_entry_pass_id;
end;
$$;

create or replace function public.get_entry_pass_token(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_participation public.participations;
  v_entry_pass public.entry_passes;
  v_token text;
begin
  v_uid := public.current_uid();

  select *
    into v_participation
  from public.participations
  where game_session_id = p_session_id
    and user_id = v_uid
  limit 1;

  if not found then
    perform public.app_error('not-found', '참가 신청을 찾을 수 없습니다');
  end if;

  if v_participation.status <> 'confirmed' then
    perform public.app_error('failed-precondition', '확정된 참가자만 입장권을 조회할 수 있습니다');
  end if;

  select *
    into v_entry_pass
  from public.entry_passes
  where participation_id = v_participation.id
    and game_session_id = p_session_id
    and user_id = v_uid
    and status = 'active'
  limit 1;

  if not found then
    perform public.app_error('failed-precondition', '입장권이 아직 발급되지 않았습니다');
  end if;

  if v_entry_pass.expires_at <= now() then
    perform public.app_error('failed-precondition', '입장권이 만료되었습니다');
  end if;

  v_token := public.build_entry_pass_token(
    v_entry_pass.id,
    v_entry_pass.game_session_id,
    v_entry_pass.user_id,
    v_entry_pass.issued_at,
    v_entry_pass.qr_secret_version
  );

  return jsonb_build_object(
    'entryPassId', v_entry_pass.id,
    'token', v_token,
    'expiresAt', v_entry_pass.expires_at
  );
end;
$$;

create or replace function public.scan_entry_pass(
  p_entry_pass_id uuid,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_entry_pass public.entry_passes;
  v_participation public.participations;
  v_session public.game_sessions;
  v_user public.users;
  v_now timestamptz := now();
begin
  v_uid := public.current_uid();

  select *
    into v_entry_pass
  from public.entry_passes
  where id = p_entry_pass_id
  for update;

  if not found then
    perform public.app_error('not-found', '입장권을 찾을 수 없습니다');
  end if;

  select *
    into v_participation
  from public.participations
  where id = v_entry_pass.participation_id
  for update;

  if not found then
    perform public.app_error('not-found', '참가 신청을 찾을 수 없습니다');
  end if;

  select *
    into v_session
  from public.game_sessions
  where id = v_entry_pass.game_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  select *
    into v_user
  from public.users
  where id = v_entry_pass.user_id;

  if not found then
    perform public.app_error('not-found', '사용자 프로필이 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('scan_entry_pass', v_session.status);

  if public.hash_entry_pass_token(p_token) <> v_entry_pass.qr_token_hash then
    perform public.app_error('failed-precondition', '유효하지 않은 QR');
  end if;

  if v_entry_pass.status <> 'active' then
    perform public.app_error('failed-precondition', '사용 가능한 입장권이 아닙니다');
  end if;

  if v_entry_pass.expires_at <= v_now then
    perform public.app_error('failed-precondition', '입장권이 만료되었습니다');
  end if;

  if v_participation.status <> 'confirmed' then
    perform public.app_error(
      'failed-precondition',
      format('출석 처리 가능한 참가 상태가 아닙니다 (현재: %s)', v_participation.status)
    );
  end if;

  update public.entry_passes
  set status = 'used',
      used_at = v_now,
      scanned_by = v_uid
  where id = p_entry_pass_id;

  update public.participations
  set status = 'attended'
  where id = v_participation.id;

  return jsonb_build_object(
    'success', true,
    'userId', v_entry_pass.user_id,
    'displayName', v_user.display_name
  );
end;
$$;

create or replace function public.fn_status_transition()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.game_sessions
  set status = 'closed'
  where status = 'recruiting'
    and confirmed_count >= capacity;

  update public.game_sessions
  set status = 'inProgress'
  where status in ('recruiting', 'closed')
    and starts_at <= now();

  update public.game_sessions
  set status = 'completed'
  where status = 'inProgress'
    and coalesce(ends_at, starts_at + interval '24 hours') <= now();
end;
$$;

create or replace function public.fn_send_reminders()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.game_sessions;
  v_participation public.participations;
  v_starts_at text;
  v_field_name text;
begin
  for v_session in
    update public.game_sessions
    set reminder_sent = true
    where status in ('recruiting', 'closed')
      and reminder_sent = false
      and starts_at between now() + interval '23.5 hours' and now() + interval '24.5 hours'
    returning *
  loop
    select coalesce(v_session.field_name, f.name, '')
      into v_field_name
    from public.fields f
    where f.id = v_session.field_id;

    v_field_name := coalesce(v_field_name, v_session.field_name, '');
    v_starts_at := to_char(v_session.starts_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI');

    for v_participation in
      select *
      from public.participations
      where game_session_id = v_session.id
        and status = 'confirmed'
    loop
      perform public.notify(
        v_participation.user_id,
        'session.upcoming_reminder',
        '게임 24시간 전 안내',
        case
          when v_field_name = '' then
            format('%s 게임이 %s에 시작됩니다.', v_session.title, v_starts_at)
          else
            format('%s 게임이 %s에 시작됩니다. %s에서 만나요', v_session.title, v_starts_at, v_field_name)
        end,
        format('/sessions/%s', v_session.id),
        jsonb_build_object('startsAt', v_starts_at, 'fieldName', v_field_name),
        v_session.id,
        v_participation.id
      );
    end loop;
  end loop;
end;
$$;

revoke execute on function public.build_entry_pass_token(uuid, uuid, uuid, timestamptz, text) from public, anon, authenticated;
revoke execute on function public.hash_entry_pass_token(text) from public, anon, authenticated;
revoke execute on function public.issue_entry_pass(public.participations, public.game_sessions) from public, anon, authenticated;
revoke execute on function public.get_entry_pass_token(uuid) from public;
revoke execute on function public.scan_entry_pass(uuid, text) from public;
revoke execute on function public.fn_status_transition() from public, anon, authenticated;
revoke execute on function public.fn_send_reminders() from public, anon, authenticated;

grant execute on function public.get_entry_pass_token(uuid) to authenticated;
grant execute on function public.scan_entry_pass(uuid, text) to authenticated;
