-- 신청자 개인정보 열람 기한 — 2026-08-21 윤보혁 결정 (레드팀 RT-05)
--
-- 무엇이 문제였나
--   users 정책이 participation 행의 "존재"만 보고 상태나 시간을 보지 않았다.
--   한 번 신청하면 반려·취소·출석·게임 종료 뒤에도 그 게임의 호스트가
--   신청자의 현재 전화번호와 이메일을 영구히 읽을 수 있었다.
--
-- 결정 (윤보혁)
--   "전화번호는 게임 종료 24시간 후 안 보이게"
--
--   ⚠️ 데이터를 지우는 것이 아니다. 번호는 사용자 본인 프로필에 그대로 남는다.
--      만료되는 것은 호스트의 열람 권한이다.
--
-- 대안이었던 "관리자만 열람 + 호스트는 요청" 은 채택하지 않았다.
--   · ASS 에는 고정 역할이 없다(A1, mvp-scope 제외 범위에 명시)
--   · 관리자는 모든 게임의 모든 신청자를 보게 되어 노출 총량이 오히려 는다
--   · 윤보혁: "Admin의 업무부담이 너무 커짐"

drop policy if exists users_select_self_or_owned_session_applicant on public.users;

create policy users_select_self_or_owned_session_applicant
on public.users
for select
to authenticated
using (
  id = auth.uid()
  or exists (
    select 1
    from public.participations p
    join public.game_sessions g on g.id = p.game_session_id
    where p.user_id = users.id
      and g.created_by_user_id = auth.uid()
      -- ends_at 은 선택 입력이라 없으면 시작 +6시간을 종료로 본다.
      and now() < coalesce(g.ends_at, g.starts_at + interval '6 hours')
                  + interval '24 hours'
  )
);

comment on policy users_select_self_or_owned_session_applicant on public.users is
  '본인은 항상. 호스트는 자기 게임 신청자를 게임 종료 +24시간까지만. '
  '(2026-08-21 결정 — 열람 권한 만료이지 데이터 삭제가 아니다)';

-- ─────────────────────────────────────────────────────────
-- 남은 것 — 상태별 컬럼 분리는 FE 변경이 따라온다
--
--   지금은 승인 대기·반려된 신청자의 전화번호도 게임 종료 전까지 보인다.
--   호스트가 번호를 쓸 일은 사실상 당일 비상연락뿐이므로
--   "확정자만 번호, 나머지는 이름만" 이 더 좁다.
--
--   그런데 RLS 는 행 단위라 컬럼을 상태별로 가릴 수 없고,
--   행을 확정자로 좁히면 FE 의 신청자 목록이 깨진다.
--   participations 조회가 users(id, display_name, email, phone_number, team_id)
--   를 조인하고 있어, 승인 대기자의 이름까지 사라지기 때문이다.
--
--   호스트 조회 전용 뷰나 RPC 로 컬럼을 나눠야 하며 FE 동시 변경이 필요하다.
--   별도 과제로 남긴다.
-- ─────────────────────────────────────────────────────────
