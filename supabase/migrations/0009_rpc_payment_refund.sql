create or replace function public.submit_payment(
  p_participation_id uuid,
  p_sender_name text,
  p_amount numeric,
  p_receipt_path text
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
  v_submission_id uuid;
  v_next_count int;
  v_entry_pass_id uuid;
begin
  v_uid := public.current_uid();

  if nullif(btrim(p_sender_name), '') is null then
    perform public.app_error('invalid-argument', 'senderName는 필수 문자열입니다');
  end if;
  if p_amount is null then
    perform public.app_error('invalid-argument', 'amount는 숫자여야 합니다');
  end if;
  if nullif(btrim(p_receipt_path), '') is null then
    perform public.app_error('invalid-argument', 'receipt_path는 필수 문자열입니다');
  end if;

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

  if v_participation.user_id <> v_uid then
    perform public.app_error('permission-denied', '본인 참가 신청에만 송금증을 제출할 수 있습니다');
  end if;

  perform public.assert_session_status('submit_payment', v_session.status);

  if v_session.payment_method <> 'pre_transfer' then
    perform public.app_error('failed-precondition', '선입금 세션에만 송금증을 제출할 수 있습니다');
  end if;

  if v_participation.status <> 'awaitingPayment' then
    perform public.app_error(
      'failed-precondition',
      format('입금 대기(awaitingPayment) 상태가 아닙니다 (현재: %s)', v_participation.status)
    );
  end if;

  if p_amount <> v_session.game_fee then
    perform public.app_error('failed-precondition', '입금 금액이 게임비와 일치하지 않습니다');
  end if;

  if p_receipt_path not like format('receipts/%s/%%', p_participation_id) then
    perform public.app_error('invalid-argument', 'receipt_path는 receipts/{participationId}/ 경로여야 합니다');
  end if;

  if not exists (
    select 1
    from storage.objects o
    where o.bucket_id = 'receipts'
      and o.name = p_receipt_path
      and (o.owner = v_uid or o.owner_id = v_uid::text)
  ) then
    perform public.app_error('failed-precondition', '송금증 업로드를 확인할 수 없습니다');
  end if;

  if v_session.confirmed_count >= v_session.capacity then
    perform public.app_error(
      'failed-precondition',
      '정원이 마감되었습니다',
      'capacityFilled'
    );
  end if;

  insert into public.payment_submissions (
    participation_id,
    game_session_id,
    user_id,
    sender_name,
    amount,
    receipt_path,
    status
  ) values (
    p_participation_id,
    v_participation.game_session_id,
    v_uid,
    p_sender_name,
    p_amount,
    p_receipt_path,
    'pending'
  )
  returning id into v_submission_id;

  update public.participations
  set status = 'confirmed'
  where id = p_participation_id;

  v_next_count := v_session.confirmed_count + 1;

  update public.game_sessions
  set confirmed_count = v_next_count,
      status = case
        when status = 'recruiting' and v_next_count >= capacity then 'closed'::public.game_session_status
        else status
      end
  where id = v_session.id;

  v_entry_pass_id := public.issue_entry_pass(v_participation, v_session);

  perform public.notify(
    v_participation.user_id,
    'participation.confirmed',
    '참석이 확정되었습니다',
    format('%s 참석 확정! QR 입장권을 확인하세요', v_session.title),
    format('/participations/%s/pass', v_participation.id),
    jsonb_build_object('entryPassId', v_entry_pass_id::text),
    v_session.id,
    v_participation.id
  );

  return jsonb_build_object('success', true, 'paymentSubmissionId', v_submission_id);
end;
$$;

drop function if exists public.approve_payment(uuid);

create or replace function public.mark_payment_reviewed(p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_submission public.payment_submissions;
  v_session public.game_sessions;
begin
  v_uid := public.current_uid();

  perform 1
  from public.game_sessions
  where id = (
    select game_session_id
    from public.payment_submissions
    where id = p_submission_id
  )
  for update;

  select *
    into v_submission
  from public.payment_submissions
  where id = p_submission_id
  for update;

  if not found then
    perform public.app_error('not-found', '송금증을 찾을 수 없습니다');
  end if;

  select *
    into v_session
  from public.game_sessions
  where id = v_submission.game_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);

  if v_submission.status <> 'pending' then
    perform public.app_error(
      'failed-precondition',
      format('검수 전(pending) 상태가 아닙니다 (현재: %s)', v_submission.status)
    );
  end if;

  update public.payment_submissions
  set status = 'approved',
      reviewed_by = v_uid,
      reviewed_at = now()
  where id = p_submission_id;

  return jsonb_build_object('success', true);
end;
$$;

create or replace function public.reject_payment(
  p_submission_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_submission public.payment_submissions;
  v_participation public.participations;
  v_session public.game_sessions;
  v_next_count int;
begin
  v_uid := public.current_uid();

  if nullif(btrim(p_reason), '') is null then
    perform public.app_error('invalid-argument', 'reason는 필수 문자열입니다');
  end if;

  perform 1
  from public.game_sessions
  where id = (
    select game_session_id
    from public.payment_submissions
    where id = p_submission_id
  )
  for update;

  select *
    into v_submission
  from public.payment_submissions
  where id = p_submission_id
  for update;

  if not found then
    perform public.app_error('not-found', '송금증을 찾을 수 없습니다');
  end if;

  select *
    into v_participation
  from public.participations
  where id = v_submission.participation_id
  for update;

  if not found then
    perform public.app_error('not-found', '참가 신청을 찾을 수 없습니다');
  end if;

  select *
    into v_session
  from public.game_sessions
  where id = v_submission.game_session_id
  for update;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);
  perform public.assert_session_status('reject_payment', v_session.status);

  if v_submission.status not in ('pending', 'approved') then
    perform public.app_error(
      'failed-precondition',
      format('반려 가능한 송금증 상태가 아닙니다 (현재: %s)', v_submission.status)
    );
  end if;

  if v_participation.status <> 'confirmed' then
    perform public.app_error(
      'failed-precondition',
      format('확정된 참가만 송금증을 반려할 수 있습니다 (현재: %s)', v_participation.status)
    );
  end if;

  update public.payment_submissions
  set status = 'rejected',
      rejection_reason = p_reason,
      reviewed_by = v_uid,
      reviewed_at = now()
  where id = p_submission_id;

  update public.participations
  set status = 'awaitingPayment'
  where id = v_participation.id;

  update public.entry_passes
  set status = 'revoked'
  where participation_id = v_participation.id
    and status = 'active';

  v_next_count := greatest(v_session.confirmed_count - 1, 0);

  update public.game_sessions
  set confirmed_count = v_next_count,
      status = case
        when status = 'closed'
          and v_next_count < capacity
          and starts_at > now()
        then 'recruiting'::public.game_session_status
        else status
      end
  where id = v_session.id;

  perform public.notify(
    v_participation.user_id,
    'payment.decision',
    '송금증이 반려되었습니다',
    format('%s. 다시 송금증을 첨부해주세요', p_reason),
    format('/participations/%s/payment', v_participation.id),
    jsonb_build_object('decision', 'rejected', 'reason', p_reason),
    v_session.id,
    v_participation.id
  );

  return jsonb_build_object('success', true);
end;
$$;

create or replace function public.request_refund(
  p_participation_id uuid,
  p_bank_name text,
  p_account_number text,
  p_account_holder text,
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
  v_refund_id uuid;
begin
  v_uid := public.current_uid();

  if nullif(btrim(p_bank_name), '') is null then
    perform public.app_error('invalid-argument', 'bankName는 필수 문자열입니다');
  end if;
  if nullif(btrim(p_account_number), '') is null then
    perform public.app_error('invalid-argument', 'accountNumber는 필수 문자열입니다');
  end if;
  if nullif(btrim(p_account_holder), '') is null then
    perform public.app_error('invalid-argument', 'accountHolder는 필수 문자열입니다');
  end if;

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

  if v_participation.user_id <> v_uid then
    perform public.app_error('permission-denied', '본인 참가 신청만 환불을 요청할 수 있습니다');
  end if;

  if v_participation.status <> 'cancelled' then
    perform public.app_error(
      'failed-precondition',
      format('취소된 참가만 환불 요청할 수 있습니다 (현재: %s)', v_participation.status)
    );
  end if;

  if now() >= v_session.cancel_deadline then
    perform public.app_error('failed-precondition', '환불 요청 가능 시간이 지났습니다');
  end if;

  if not exists (
    select 1
    from public.payment_submissions ps
    where ps.participation_id = p_participation_id
      and ps.status = 'approved'
  ) then
    perform public.app_error('failed-precondition', '확인된 입금 내역이 있어야 환불 요청할 수 있습니다');
  end if;

  begin
    insert into public.refund_requests (
      participation_id,
      game_session_id,
      user_id,
      bank_name,
      account_number_encrypted,
      account_holder,
      reason,
      status
    ) values (
      p_participation_id,
      v_participation.game_session_id,
      v_uid,
      p_bank_name,
      extensions.armor(extensions.pgp_sym_encrypt(p_account_number, public.vault_secret('refund_account_key'))),
      p_account_holder,
      nullif(p_reason, ''),
      'requested'
    )
    returning id into v_refund_id;
  exception
    when unique_violation then
      perform public.app_error('already-exists', '이미 환불 요청이 접수되었습니다');
  end;

  update public.participations
  set status = 'refundRequested'
  where id = p_participation_id;

  return jsonb_build_object('success', true, 'refundRequestId', v_refund_id);
end;
$$;

revoke execute on function public.submit_payment(uuid, text, numeric, text) from public;
revoke execute on function public.mark_payment_reviewed(uuid) from public;
revoke execute on function public.reject_payment(uuid, text) from public;
revoke execute on function public.request_refund(uuid, text, text, text, text) from public;

grant execute on function public.submit_payment(uuid, text, numeric, text) to authenticated;
grant execute on function public.mark_payment_reviewed(uuid) to authenticated;
grant execute on function public.reject_payment(uuid, text) to authenticated;
grant execute on function public.request_refund(uuid, text, text, text, text) to authenticated;
