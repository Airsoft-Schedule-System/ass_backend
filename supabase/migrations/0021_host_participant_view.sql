-- 호스트 조회 전용 참가자 목록 — 2026-08-22
--
-- 배경
--   윤보혁 결정(8/21): "전화번호는 게임 종료 24시간 후 안 보이게"
--
--   RLS 만으로는 안 된다. RLS 는 행 단위라 컬럼을 상태·시간별로 가릴 수 없고,
--   행을 조건부로 숨기면 FE 의 신청자 목록이 통째로 깨진다.
--   participations 조회가 users(id, display_name, email, phone_number, team_id)
--   를 조인하고 있어, 승인 대기자의 이름까지 사라져 호스트가 누가 신청했는지
--   못 보게 된다.
--
--   그래서 호스트 조회 전용 RPC 로 컬럼을 나눈다.
--
-- 규칙
--   이름·상태  항상 보인다. 닉네임이라 실명이 아니고, 없으면 지난 게임 기록이
--              밴드보다 퇴보한다(사고·분쟁 시 그날 누가 있었는지 확인 필요).
--   전화번호   확정·출석 참가자에 한해, 게임 종료 +24시간까지만.
--              호스트가 번호를 쓸 일은 사실상 당일 비상연락뿐이고,
--              선입금이 없어지면서 입금 확인 용도도 사라졌다.
--              반려·취소된 신청자의 번호는 애초에 필요가 없다.
--   이메일     아예 주지 않는다. 연락은 앱 알림이 담당하므로 호스트가
--              참가자 이메일을 볼 이유가 없다. (지금은 보인다)
--
-- ⚠️ 2단계 작업이다. 이 마이그레이션은 RPC 만 추가한다.
--    users RLS 를 self-only 로 좁히는 것은 FE 가 이 RPC 로 전환한 뒤에 한다.
--    지금 좁히면 listParticipationsBySession 이 즉시 깨진다.

create or replace function public.list_session_participants(p_session_id uuid)
returns table (
  participation_id uuid,
  game_session_id uuid,
  user_id uuid,
  display_name text,
  team_id uuid,
  team_name text,
  phone_number text,
  status public.participation_status,
  entry_pass_status public.entry_pass_status,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid;
  v_session public.game_sessions;
  v_contact_visible boolean;
begin
  v_uid := public.current_uid();

  select *
    into v_session
  from public.game_sessions
  where id = p_session_id;

  if not found then
    perform public.app_error('not-found', '게임 세션을 찾을 수 없습니다');
  end if;

  perform public.assert_session_owner(v_session, v_uid);

  -- ends_at 은 선택 입력이라 없으면 시작 +6시간을 종료로 본다.
  v_contact_visible := now() < coalesce(
    v_session.ends_at,
    v_session.starts_at + interval '6 hours'
  ) + interval '24 hours';

  return query
  select
    p.id,
    p.game_session_id,
    p.user_id,
    u.display_name,
    u.team_id,
    t.name,
    case
      when v_contact_visible and p.status in ('confirmed', 'attended')
      then u.phone_number
      else null
    end,
    p.status,
    ep.status,
    p.created_at,
    p.updated_at
  from public.participations p
  join public.users u on u.id = p.user_id
  left join public.teams t on t.id = u.team_id
  left join public.entry_passes ep
    on ep.participation_id = p.id
   and ep.status = 'active'
  where p.game_session_id = p_session_id
  order by p.created_at;
end;
$$;

revoke execute on function public.list_session_participants(uuid) from public;
grant execute on function public.list_session_participants(uuid) to authenticated;

comment on function public.list_session_participants(uuid) is
  '호스트가 자기 게임의 참가자 목록을 조회한다. 이름·상태는 항상, '
  '전화번호는 확정·출석 참가자에 한해 게임 종료 +24시간까지, 이메일은 제외. '
  'FE 가 이 RPC 로 전환하면 users RLS 를 self-only 로 좁힌다. (2026-08-22)';
