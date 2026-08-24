-- 좌석 점유 불변식 복구 — 2026-08-20 레드팀 RT-02
--
-- 무엇이 잘못됐나
--   confirmed_count 의 실제 의미는 "confirmed + attended = 점유한 좌석" 이다.
--   mark_attendance·scan_entry_pass 가 confirmed → attended 로 바꿀 때
--   카운트를 내리지 않기 때문이다(의도된 동작 — 출석했다고 자리가 비지 않는다).
--
--   그런데 0017 의 재계산은 confirmed 만 셌다.
--
--     count(p.id) filter (where p.status = 'confirmed')   ← attended 누락
--
--   출석 처리된 인원만큼 좌석이 비어 있는 것으로 잘못 계산되고,
--   그 자리에 승인이 들어가면 물리적 정원을 넘긴다.
--
-- 두 번째 문제
--   0017 은 awaitingPayment·paymentReview 를 confirmed 로 옮기면서
--   입장권을 발급하지 않았다. 이관된 사람은 get_entry_pass_token 이 영구 실패하고,
--   approve_participation 재호출도 상태 가드에 막혀 되돌릴 방법이 없다.
--
-- 이 마이그레이션은 두 가지를 모두 복구하고, 불변식을 주석으로 못박는다.

-- ─────────────────────────────────────────────────────────
-- 1. 불변식을 스키마에 기록한다
--
--    다음에 이 컬럼을 다시 세는 사람이 같은 실수를 하지 않도록.
-- ─────────────────────────────────────────────────────────
comment on column public.game_sessions.confirmed_count is
  '점유한 좌석 수 = participations 중 status in (confirmed, attended) 인 행의 수. '
  '출석해도 좌석은 비지 않으므로 attended 를 반드시 포함한다. '
  '재계산할 일이 있으면 두 상태를 함께 세야 한다 (2026-08-20 RT-02).';

-- ─────────────────────────────────────────────────────────
-- 2. 정원이 이미 점유보다 작아진 세션 구제
--
--    0017 의 과소 계산 뒤 그 자리에 승인이 들어갔다면 실제 점유가 capacity 를
--    넘었을 수 있다. 사람은 이미 확정·출석 상태라 되돌릴 수 없으므로,
--    capacity 를 실제 점유에 맞춰 올린다. capacity_not_exceeded CHECK 를
--    통과시키기 위해 다음 단계보다 먼저 수행해야 한다.
-- ─────────────────────────────────────────────────────────
update public.game_sessions gs
set capacity = occ.seats
from (
  select g.id, count(p.id) as seats
  from public.game_sessions g
  join public.participations p
    on p.game_session_id = g.id
   and p.status in ('confirmed', 'attended')
  group by g.id
) occ
where gs.id = occ.id
  and occ.seats > gs.capacity;

-- ─────────────────────────────────────────────────────────
-- 3. 점유 좌석 재계산 — attended 포함
-- ─────────────────────────────────────────────────────────
update public.game_sessions gs
set confirmed_count = occ.seats
from (
  select g.id,
         count(p.id) filter (where p.status in ('confirmed', 'attended')) as seats
  from public.game_sessions g
  left join public.participations p on p.game_session_id = g.id
  group by g.id
) occ
where gs.id = occ.id
  and gs.confirmed_count is distinct from occ.seats
  -- 취소된 세션은 0 으로 두는 것이 cancel_game_session 의 동작이다
  and gs.status <> 'cancelled';

-- ─────────────────────────────────────────────────────────
-- 4. 입장권이 없는 확정 참가자에게 발급
--
--    issue_entry_pass 는 멱등(활성 패스가 있으면 그것을 돌려준다)이라
--    이미 정상인 행에는 아무 영향이 없다.
--
--    ⚠️ build_entry_pass_token 이 Vault 의 qr_hmac_secret 을 쓴다.
--       시크릿이 없는 환경(로컬 초기화 직후 등)에서는 발급을 건너뛴다.
--       마이그레이션이 시크릿 부재로 실패하면 안 되기 때문이다.
-- ─────────────────────────────────────────────────────────
do $$
declare
  v_participation public.participations;
  v_session public.game_sessions;
  v_issued int := 0;
  v_skipped int := 0;
begin
  if not exists (
    select 1 from vault.decrypted_secrets where name = 'qr_hmac_secret'
  ) then
    raise notice 'qr_hmac_secret 이 없어 입장권 발급을 건너뜁니다. '
                 '시크릿 설정 후 이 마이그레이션의 4단계를 수동으로 재실행하십시오.';
    return;
  end if;

  for v_participation in
    select p.*
    from public.participations p
    join public.game_sessions g on g.id = p.game_session_id
    where p.status = 'confirmed'
      and g.status <> 'cancelled'
      and not exists (
        select 1 from public.entry_passes ep
        where ep.participation_id = p.id
          and ep.status = 'active'
      )
    order by p.created_at
  loop
    select * into v_session
    from public.game_sessions
    where id = v_participation.game_session_id;

    begin
      perform public.issue_entry_pass(v_participation, v_session);
      v_issued := v_issued + 1;
    exception when others then
      -- 개별 실패가 전체를 막지 않도록 한다. 남은 것은 로그로 확인한다.
      v_skipped := v_skipped + 1;
      raise notice '입장권 발급 실패 participation=% : %', v_participation.id, sqlerrm;
    end;
  end loop;

  raise notice '입장권 발급 % 건, 건너뜀 % 건', v_issued, v_skipped;
end;
$$;

-- ─────────────────────────────────────────────────────────
-- 5. assert_game_rules 의 불필요한 실행 권한 회수
--
--    0018 에서 authenticated 에 grant 했으나, 이 함수를 부르는
--    create_game_session·update_game_session 이 SECURITY DEFINER 라
--    호출자 권한이 필요 없다. 명세에 없는 RPC 가 Data API 에 노출되고,
--    잘못된 입력을 주면 내부 app_error 권한 부족으로 403 이 나가
--    오류 규약과도 어긋난다. (레드팀 하드닝 메모)
-- ─────────────────────────────────────────────────────────
revoke execute on function public.assert_game_rules(jsonb) from authenticated;
