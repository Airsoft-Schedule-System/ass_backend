-- QR 서명 키 회전 — 2026-08-22 레드팀 RT-08
--
-- 무엇이 잘못됐나
--   entry_passes.qr_secret_version 컬럼이 있는데 키 선택에 쓰이지 않았다.
--   build_entry_pass_token 은 버전과 무관하게 항상 vault_secret('qr_hmac_secret')
--   하나만 봤고, 버전은 HMAC 의 "메시지"에만 섞였다.
--
--   그래서 시크릿을 바꾸면(회전) 이렇게 된다.
--     · get_entry_pass_token 은 새 시크릿으로 토큰을 다시 계산해 돌려준다
--     · 그 토큰의 해시는 저장된 구 해시와 달라 스캔이 실패한다
--     · 회전 전에 캡처해 둔 구 토큰은 저장 해시와 같아 계속 성공한다
--
--   즉 회전이 구 토큰을 폐기하지 못하면서 사용자에게는 실패할 토큰을 보여준다.
--   최악의 조합이다.
--
-- 어떻게 고치나
--   버전이 실제로 키를 고르게 한다. 발급 시점의 버전이 패스에 저장되므로
--   회전 뒤에도 구 패스는 구 키로 계속 검증되고, 새 패스만 새 키를 쓴다.
--
-- 회전 절차
--   1. Vault 에 qr_hmac_secret_v2 를 만든다
--   2. alter database ... set app.settings.qr_secret_version = 'v2';
--   3. 이후 발급되는 패스는 v2 로 서명된다. 기존 v1 패스는 그대로 동작한다
--   4. v1 패스가 전부 만료되면 qr_hmac_secret 을 지운다

-- ─────────────────────────────────────────────────────────
-- 1. 버전 → 시크릿 이름
--
--    v1 은 이미 배포된 이름(qr_hmac_secret)을 그대로 쓴다.
--    v2 부터 버전별 이름을 쓴다.
-- ─────────────────────────────────────────────────────────
create or replace function public.qr_secret_name(p_version text)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_version, 'v1') = 'v1' then 'qr_hmac_secret'
    else 'qr_hmac_secret_' || p_version
  end;
$$;

-- 새로 발급할 패스에 쓸 버전. 설정으로 바꿀 수 있어야 회전이 가능하다.
create or replace function public.current_qr_secret_version()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('app.settings.qr_secret_version', true), ''),
    'v1'
  );
$$;

revoke execute on function public.qr_secret_name(text) from public;
revoke execute on function public.current_qr_secret_version() from public;

-- ─────────────────────────────────────────────────────────
-- 2. 토큰 생성이 버전으로 키를 고르게 한다
-- ─────────────────────────────────────────────────────────
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
set search_path = public, pg_temp
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
      -- 이전에는 버전과 무관하게 항상 qr_hmac_secret 이었다.
      convert_to(public.vault_secret(public.qr_secret_name(p_version)), 'utf8'),
      'sha256'::text
    ),
    'base64'
  );
$$;

-- ─────────────────────────────────────────────────────────
-- 3. 발급 시 현재 버전을 기록한다 (하드코딩된 'v1' 제거)
-- ─────────────────────────────────────────────────────────
create or replace function public.issue_entry_pass(
  p_participation public.participations,
  p_session public.game_sessions
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_existing_id uuid;
  v_entry_pass_id uuid := gen_random_uuid();
  v_issued_at timestamptz := now();
  v_version text := public.current_qr_secret_version();
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

-- ─────────────────────────────────────────────────────────
-- 4. 조회 시 방어 검사
--
--    재계산한 토큰의 해시가 저장된 해시와 다르면, 그 토큰은 스캔에서
--    반드시 실패한다. 그대로 돌려주면 사용자는 QR 을 보여줬는데
--    "유효하지 않은 QR" 을 듣게 되고 원인을 알 수 없다.
--    조용히 실패시키지 말고 여기서 드러낸다.
-- ─────────────────────────────────────────────────────────
create or replace function public.get_entry_pass_token(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
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

  if public.hash_entry_pass_token(v_token) is distinct from v_entry_pass.qr_token_hash then
    perform public.app_error(
      'failed-precondition',
      '입장권을 검증할 수 없습니다. 운영자에게 문의해주세요',
      'signatureMismatch'
    );
  end if;

  return jsonb_build_object(
    'entryPassId', v_entry_pass.id,
    'token', v_token,
    'expiresAt', v_entry_pass.expires_at
  );
end;
$$;
