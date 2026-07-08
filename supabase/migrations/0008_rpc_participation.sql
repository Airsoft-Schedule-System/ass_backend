create or replace function public.request_participation(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_session public.game_sessions;
  v_participation_id uuid;
begin
  v_uid := public.current_uid();
  perform public.assert_profile_complete(v_uid);

  select *
    into v_session
  from public.game_sessions
  where id = p_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_status('request_participation', v_session.status);

  if v_session.created_by_user_id = v_uid then
    perform public.app_error('failed-precondition', '본인 세션은 join_as_operator 사용');
  end if;

  begin
    insert into public.participations (game_session_id, user_id, status)
    values (p_session_id, v_uid, 'pendingApproval')
    returning id into v_participation_id;
  exception
    when unique_violation then
      perform public.app_error('already-exists', '이미 신청한 세션입니다');
  end;

  return jsonb_build_object(
    'success', true,
    'participationId', v_participation_id,
    'status', 'pendingApproval'
  );
end;
$$;

create or replace function public.join_as_operator(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_session public.game_sessions;
  v_participation_id uuid;
  v_next_count int;
begin
  v_uid := public.current_uid();
  perform public.assert_profile_complete(v_uid);

  select *
    into v_session
  from public.game_sessions
  where id = p_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('join_as_operator', v_session.status);

  if v_session.confirmed_count >= v_session.capacity then
    perform public.app_error('failed-precondition', '정원이 가득 찼습니다');
  end if;

  begin
    insert into public.participations (game_session_id, user_id, status)
    values (p_session_id, v_uid, 'confirmed')
    returning id into v_participation_id;
  exception
    when unique_violation then
      perform public.app_error('already-exists', '이미 신청한 세션입니다');
  end;

  v_next_count := v_session.confirmed_count + 1;

  update public.game_sessions
  set confirmed_count = v_next_count,
      status = case
        when status = 'recruiting' and v_next_count >= capacity then 'closed'::public.game_session_status
        else status
      end
  where id = p_session_id;

  return jsonb_build_object(
    'success', true,
    'participationId', v_participation_id,
    'status', 'confirmed'
  );
end;
$$;

create or replace function public.approve_participation(p_participation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_participation public.participations;
  v_session public.game_sessions;
begin
  v_uid := public.current_uid();

  perform 1
  from public.game_sessions
  where id = (
    select game_session_id
    from public.participations
    where id = p_participation_id
  )
  for update;

  select *
    into v_participation
  from public.participations
  where id = p_participation_id
  for update;

  if not found then
    perform public.app_error('not-found', '참가 신청을 찾을 수 없습니다');
  end if;

  select *
    into v_session
  from public.game_sessions
  where id = v_participation.game_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('approve_participation', v_session.status);

  if v_participation.status <> 'pendingApproval' then
    perform public.app_error(
      'failed-precondition',
      format('승인 대기(pendingApproval) 상태가 아닙니다 (현재: %s)', v_participation.status)
    );
  end if;

  update public.participations
  set status = 'awaitingPayment'
  where id = p_participation_id;

  perform public.notify(
    v_participation.user_id,
    'participation.decision',
    '참가 신청이 승인되었습니다',
    format('%s 참가 신청이 승인되었습니다. 입금 안내를 확인하세요', v_session.title),
    format('/participations/%s', p_participation_id),
    jsonb_build_object('decision', 'approved'),
    v_participation.game_session_id,
    p_participation_id
  );

  perform public.notify(
    v_participation.user_id,
    'payment.requested',
    '입금 안내',
    format('%s 게임비 %s원을 %s까지 입금해주세요', v_session.title, v_session.game_fee, v_session.cancel_deadline),
    format('/participations/%s/payment', p_participation_id),
    jsonb_build_object(
      'bankName', v_session.bank_name,
      'accountNumber', v_session.bank_account_number,
      'accountHolder', v_session.bank_account_holder,
      'gameFee', v_session.game_fee::text,
      'cancelDeadline', v_session.cancel_deadline::text
    ),
    v_participation.game_session_id,
    p_participation_id
  );

  return jsonb_build_object('success', true, 'newStatus', 'awaitingPayment');
end;
$$;

create or replace function public.reject_participation(
  p_participation_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_participation public.participations;
  v_session public.game_sessions;
begin
  v_uid := public.current_uid();

  perform 1
  from public.game_sessions
  where id = (
    select game_session_id
    from public.participations
    where id = p_participation_id
  )
  for update;

  select *
    into v_participation
  from public.participations
  where id = p_participation_id
  for update;

  if not found then
    perform public.app_error('not-found', '참가 신청을 찾을 수 없습니다');
  end if;

  select *
    into v_session
  from public.game_sessions
  where id = v_participation.game_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('reject_participation', v_session.status);

  if v_participation.status <> 'pendingApproval' then
    perform public.app_error(
      'failed-precondition',
      format('승인 대기(pendingApproval) 상태가 아닙니다 (현재: %s)', v_participation.status)
    );
  end if;

  update public.participations
  set status = 'rejected'
  where id = p_participation_id;

  perform public.notify(
    v_participation.user_id,
    'participation.decision',
    '참가 신청이 거절되었습니다',
    case
      when nullif(p_reason, '') is null then
        format('%s 참가 신청이 거절되었습니다.', v_session.title)
      else
        format('%s 참가 신청이 거절되었습니다. %s', v_session.title, p_reason)
    end,
    format('/participations/%s', p_participation_id),
    jsonb_strip_nulls(jsonb_build_object('decision', 'rejected', 'reason', nullif(p_reason, ''))),
    v_participation.game_session_id,
    p_participation_id
  );

  return jsonb_build_object('success', true);
end;
$$;

create or replace function public.cancel_participation(
  p_participation_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_participation public.participations;
  v_session public.game_sessions;
  v_refund_eligible boolean;
  v_next_count int;
begin
  v_uid := public.current_uid();

  perform 1
  from public.game_sessions
  where id = (
    select game_session_id
    from public.participations
    where id = p_participation_id
  )
  for update;

  select *
    into v_participation
  from public.participations
  where id = p_participation_id
  for update;

  if not found then
    perform public.app_error('not-found', '참가 신청을 찾을 수 없습니다');
  end if;

  select *
    into v_session
  from public.game_sessions
  where id = v_participation.game_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  if v_participation.user_id <> v_uid and v_session.created_by_user_id <> v_uid then
    perform public.app_error('permission-denied', '본인 또는 세션 운영자만 수행할 수 있습니다');
  end if;

  if v_participation.status not in ('pendingApproval', 'awaitingPayment', 'paymentReview', 'confirmed') then
    perform public.app_error(
      'failed-precondition',
      format('취소 가능한 참가 상태가 아닙니다 (현재: %s)', v_participation.status)
    );
  end if;

  v_refund_eligible := v_participation.status = 'confirmed'
    and now() < v_session.cancel_deadline
    and exists (
      select 1
      from public.payment_submissions ps
      where ps.participation_id = p_participation_id
        and ps.status = 'approved'
    );

  update public.participations
  set status = 'cancelled'
  where id = p_participation_id;

  if v_participation.status = 'confirmed' then
    v_next_count := greatest(v_session.confirmed_count - 1, 0);

    update public.game_sessions
    set confirmed_count = v_next_count,
        status = case
          when status = 'closed' and v_next_count < capacity then 'recruiting'::public.game_session_status
          else status
        end
    where id = v_session.id;

    update public.entry_passes
    set status = 'revoked'
    where participation_id = p_participation_id
      and status = 'active';
  end if;

  return jsonb_build_object('success', true, 'refundEligible', v_refund_eligible);
end;
$$;

create or replace function public.mark_attendance(p_participation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_participation public.participations;
  v_session public.game_sessions;
  v_now timestamptz := now();
begin
  v_uid := public.current_uid();

  perform 1
  from public.game_sessions
  where id = (
    select game_session_id
    from public.participations
    where id = p_participation_id
  )
  for update;

  select *
    into v_participation
  from public.participations
  where id = p_participation_id
  for update;

  if not found then
    perform public.app_error('not-found', '참가 신청을 찾을 수 없습니다');
  end if;

  select *
    into v_session
  from public.game_sessions
  where id = v_participation.game_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('mark_attendance', v_session.status);

  if v_participation.status <> 'confirmed' then
    perform public.app_error(
      'failed-precondition',
      format('출석 처리 가능한 참가 상태가 아닙니다 (현재: %s)', v_participation.status)
    );
  end if;

  update public.participations
  set status = 'attended'
  where id = p_participation_id;

  update public.entry_passes
  set status = 'used',
      used_at = v_now,
      scanned_by = v_uid
  where participation_id = p_participation_id
    and status = 'active';

  return jsonb_build_object('success', true);
end;
$$;

revoke execute on function public.request_participation(uuid) from public;
revoke execute on function public.join_as_operator(uuid) from public;
revoke execute on function public.approve_participation(uuid) from public;
revoke execute on function public.reject_participation(uuid, text) from public;
revoke execute on function public.cancel_participation(uuid, text) from public;
revoke execute on function public.mark_attendance(uuid) from public;

grant execute on function public.request_participation(uuid) to authenticated;
grant execute on function public.join_as_operator(uuid) to authenticated;
grant execute on function public.approve_participation(uuid) to authenticated;
grant execute on function public.reject_participation(uuid, text) to authenticated;
grant execute on function public.cancel_participation(uuid, text) to authenticated;
grant execute on function public.mark_attendance(uuid) to authenticated;
