create extension if not exists supabase_vault cascade;

create or replace function public.app_error(err_code text, msg text)
returns void
language plpgsql
as $$
begin
  raise exception '%', msg using errcode = 'P0001', hint = err_code;
end;
$$;

create or replace function public.current_uid()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();

  if v_uid is null then
    perform public.app_error('unauthenticated', '로그인이 필요합니다');
  end if;

  return v_uid;
end;
$$;

create or replace function public.assert_profile_complete(p_uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_display_name text;
begin
  select u.display_name
    into v_display_name
  from public.users u
  where u.id = p_uid;

  if not found then
    perform public.app_error('not-found', '사용자 프로필이 없습니다');
  end if;

  if nullif(btrim(v_display_name), '') is null then
    perform public.app_error('failed-precondition', '프로필(닉네임)을 먼저 완성해주세요');
  end if;
end;
$$;

create or replace function public.assert_session_owner(
  p_session public.game_sessions,
  p_uid uuid
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_session.created_by_user_id is distinct from p_uid then
    perform public.app_error('permission-denied', '세션 운영자만 수행할 수 있습니다');
  end if;
end;
$$;

create or replace function public.assert_session_status(
  p_operation text,
  p_status public.game_session_status
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_allowed public.game_session_status[];
begin
  v_allowed := case p_operation
    when 'request_participation' then array['recruiting'::public.game_session_status]
    when 'join_as_operator' then array['recruiting'::public.game_session_status]
    when 'approve_participation' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status]
    when 'reject_participation' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status]
    when 'submit_payment' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status]
    when 'approve_payment' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status]
    when 'reject_payment' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status]
    when 'update_game_session' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status, 'inProgress'::public.game_session_status]
    when 'cancel_game_session' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status, 'inProgress'::public.game_session_status]
    when 'scan_entry_pass' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status, 'inProgress'::public.game_session_status]
    when 'mark_attendance' then array['recruiting'::public.game_session_status, 'closed'::public.game_session_status, 'inProgress'::public.game_session_status]
    else null
  end;

  if v_allowed is null or p_status <> all(v_allowed) then
    perform public.app_error(
      'failed-precondition',
      format('현재 세션 상태(%s)에서는 이 작업을 할 수 없습니다', p_status)
    );
  end if;
end;
$$;

create or replace function public.notify(
  p_user_id uuid,
  p_type text,
  p_title text,
  p_body text,
  p_action_url text,
  p_data jsonb default null,
  p_session_id uuid default null,
  p_participation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.notifications (
    user_id,
    type,
    title,
    body,
    action_url,
    data,
    game_session_id,
    participation_id
  ) values (
    p_user_id,
    p_type,
    p_title,
    p_body,
    p_action_url,
    p_data,
    p_session_id,
    p_participation_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.vault_secret(p_name text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  select ds.decrypted_secret
    into v_secret
  from vault.decrypted_secrets ds
  where ds.name = p_name
  order by ds.updated_at desc
  limit 1;

  if nullif(v_secret, '') is null then
    perform public.app_error('failed-precondition', '서버 시크릿이 설정되지 않았습니다');
  end if;

  return v_secret;
end;
$$;

revoke execute on function public.app_error(text, text) from public, anon, authenticated;
revoke execute on function public.current_uid() from public, anon, authenticated;
revoke execute on function public.assert_profile_complete(uuid) from public, anon, authenticated;
revoke execute on function public.assert_session_owner(public.game_sessions, uuid) from public, anon, authenticated;
revoke execute on function public.assert_session_status(text, public.game_session_status) from public, anon, authenticated;
revoke execute on function public.notify(uuid, text, text, text, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.vault_secret(text) from public, anon, authenticated;
