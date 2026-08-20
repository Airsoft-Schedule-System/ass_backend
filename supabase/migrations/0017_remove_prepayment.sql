-- 선입금(송금증) 제도 폐기 — 2026-08-20 팀 결정
--
-- 배경: 본인인증(CI) 값을 사업자등록 없이 받을 수 없는 환경이라,
--       앱이 자금 흐름에 아무 권한도 없으면서 "확정"을 보증하는 모양이 된다.
--       책임 소지가 발생하고, 우리가 책임질 수 없으면 사용자도 신뢰할 수 없다.
--
-- 결정: 호스트 승인 = 참석 확정으로 단일화. 게임비는 현장 수령.
--
-- ⚠️ 0001~0015가 이미 원격에 적용돼 있어 기존 파일 in-place 편집은 반영되지 않는다.
--    (db push는 적용된 버전을 건너뛴다 — 로컬 db reset에서만 보이고 배포에선 안 보임)
--    그래서 순방향 마이그레이션으로 처리한다.

-- ─────────────────────────────────────────────────────────
-- 1. 결제·환불 RPC 제거
-- ─────────────────────────────────────────────────────────
drop function if exists public.submit_payment(uuid, text, numeric, text);
drop function if exists public.mark_payment_reviewed(uuid);
drop function if exists public.reject_payment(uuid, text);
drop function if exists public.request_refund(uuid, text, text, text, text);

-- ─────────────────────────────────────────────────────────
-- 2. 결제·환불 테이블 제거
--    RLS 정책·인덱스·grant는 테이블과 함께 사라진다.
-- ─────────────────────────────────────────────────────────
drop table if exists public.payment_submissions;
drop table if exists public.refund_requests;

drop type if exists public.payment_submission_status;
drop type if exists public.refund_request_status;

-- ─────────────────────────────────────────────────────────
-- 3. game_sessions에서 계좌·결제방식 제거
--    game_fee는 유지한다 — 현장 결제여도 금액은 알려야 한다.
-- ─────────────────────────────────────────────────────────
alter table public.game_sessions
  drop column if exists bank_name,
  drop column if exists bank_account_number,
  drop column if exists bank_account_holder,
  drop column if exists payment_method;

drop type if exists public.payment_method;

-- ─────────────────────────────────────────────────────────
-- 4. participation_status에서 결제 상태 3종 제거
--    Postgres는 enum 값 삭제를 지원하지 않아 타입을 재정의한다.
--    기존 데이터 매핑:
--      awaitingPayment·paymentReview → confirmed  (승인=확정 모델로 흡수)
--      refundRequested               → cancelled
-- ─────────────────────────────────────────────────────────
alter type public.participation_status rename to participation_status_legacy;

create type public.participation_status as enum (
  'pendingApproval',
  'rejected',
  'confirmed',
  'cancelled',
  'attended'
);

alter table public.participations
  alter column status drop default;

alter table public.participations
  alter column status type public.participation_status
  using (
    case status::text
      when 'awaitingPayment' then 'confirmed'
      when 'paymentReview'   then 'confirmed'
      when 'refundRequested' then 'cancelled'
      else status::text
    end::public.participation_status
  );

alter table public.participations
  alter column status set default 'pendingApproval';

drop type public.participation_status_legacy;

-- 상태 재매핑으로 어긋났을 수 있는 확정 인원을 실제 행 수로 되맞춘다.
update public.game_sessions gs
set confirmed_count = sub.cnt
from (
  select g.id, count(p.id) filter (where p.status = 'confirmed') as cnt
  from public.game_sessions g
  left join public.participations p on p.game_session_id = g.id
  group by g.id
) sub
where gs.id = sub.id
  and gs.confirmed_count is distinct from sub.cnt;

-- ─────────────────────────────────────────────────────────
-- 5. 세션 상태 게이트에서 결제 작업 제거
-- ─────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────
-- 6. 승인 = 확정
--    기존 submit_payment가 하던 일(정원 가드·확정·카운트·입장권 발급)을
--    승인 시점으로 옮긴다. 정원 가드가 승인 시점으로 이동하므로
--    호스트는 정원을 넘겨 승인할 수 없다.
-- ─────────────────────────────────────────────────────────
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
  v_next_count int;
  v_entry_pass_id uuid;
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

  if v_session.confirmed_count >= v_session.capacity then
    perform public.app_error(
      'failed-precondition',
      '정원이 마감되었습니다',
      'capacityFilled'
    );
  end if;

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
    'participation.decision',
    '참가 신청이 승인되었습니다',
    format('%s 참가 신청이 승인되어 참석이 확정되었습니다', v_session.title),
    format('/participations/%s', p_participation_id),
    jsonb_build_object('decision', 'approved'),
    v_participation.game_session_id,
    p_participation_id
  );

  perform public.notify(
    v_participation.user_id,
    'participation.confirmed',
    '참석이 확정되었습니다',
    format('%s 참석 확정! QR 입장권을 확인하세요', v_session.title),
    format('/participations/%s/pass', p_participation_id),
    jsonb_build_object('entryPassId', v_entry_pass_id::text),
    v_participation.game_session_id,
    p_participation_id
  );

  return jsonb_build_object(
    'success', true,
    'newStatus', 'confirmed',
    'entryPassId', v_entry_pass_id
  );
end;
$$;

-- ─────────────────────────────────────────────────────────
-- 7. 취소 — refundEligible 재정의
--    앱이 받은 돈이 없으므로 "송금증이 있는가"를 물을 수 없다.
--    이제는 "확정된 참가자가 마감 전에 취소했는가"만 본다.
--    실제 정산은 앱 밖(호스트-참가자 간)에서 이뤄진다.
-- ─────────────────────────────────────────────────────────
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

  if v_participation.status not in ('pendingApproval', 'confirmed') then
    perform public.app_error(
      'failed-precondition',
      format('취소 가능한 참가 상태가 아닙니다 (현재: %s)', v_participation.status)
    );
  end if;

  v_refund_eligible := v_participation.status = 'confirmed'
    and now() < v_session.cancel_deadline;

  update public.participations
  set status = 'cancelled'
  where id = p_participation_id;

  if v_participation.status = 'confirmed' then
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

    update public.entry_passes
    set status = 'revoked'
    where participation_id = p_participation_id
      and status = 'active';
  end if;

  return jsonb_build_object('success', true, 'refundEligible', v_refund_eligible);
end;
$$;

-- ─────────────────────────────────────────────────────────
-- 8. 게임 생성 — bankAccount 입력 제거
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
    v_preset_id,
    v_custom_rules,
    v_cancel_deadline,
    'recruiting'
  )
  returning id into v_session_id;

  return jsonb_build_object('success', true, 'gameSessionId', v_session_id);
end;
$$;

-- ─────────────────────────────────────────────────────────
-- 9. 게임 취소 — 사라진 상태 참조 제거
-- ─────────────────────────────────────────────────────────
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
      and status in ('pendingApproval', 'confirmed')
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

-- ─────────────────────────────────────────────────────────
-- 10. 송금증 스토리지 제거
--
--     ⚠️ storage.objects·storage.buckets는 SQL 직접 DELETE가 차단돼 있다
--        (42501 "Direct deletion from storage tables is not allowed").
--        마이그레이션으로는 버킷을 지울 수 없으므로, 접근 정책만 걷어내
--        아무도 읽고 쓸 수 없는 상태로 만든다.
--
--     남은 정리(사람 몫): 대시보드 Storage에서 receipts 버킷의 객체를 비우고
--        버킷을 삭제한다. 정책이 없어 이미 접근 불가라 급하지 않다.
-- ─────────────────────────────────────────────────────────
drop policy if exists receipts_insert_own on storage.objects;
drop policy if exists receipts_select_own_or_session_owner on storage.objects;
