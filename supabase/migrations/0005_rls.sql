create or replace function public.is_session_owner(sid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from game_sessions g
    where g.id = sid
      and g.created_by_user_id = auth.uid()
  );
$$;

create or replace function public.guard_users_update()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id
    or new.email is distinct from old.email
    or new.created_at is distinct from old.created_at
  then
    raise exception 'users update may only change display_name, phone_number, team_id, last_active_at'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger guard_users_update
before update on public.users
for each row execute function public.guard_users_update();

create or replace function public.guard_notifications_update()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id
    or new.user_id is distinct from old.user_id
    or new.type is distinct from old.type
    or new.title is distinct from old.title
    or new.body is distinct from old.body
    or new.action_url is distinct from old.action_url
    or new.data is distinct from old.data
    or new.game_session_id is distinct from old.game_session_id
    or new.participation_id is distinct from old.participation_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'notifications update may only change is_read'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger guard_notifications_update
before update on public.notifications
for each row execute function public.guard_notifications_update();

alter table public.users enable row level security;
alter table public.teams enable row level security;
alter table public.fields enable row level security;
alter table public.game_rule_presets enable row level security;
alter table public.game_sessions enable row level security;
alter table public.participations enable row level security;
alter table public.payment_submissions enable row level security;
alter table public.refund_requests enable row level security;
alter table public.entry_passes enable row level security;
alter table public.notifications enable row level security;
alter table public.fcm_tokens enable row level security;

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
  )
);

create policy users_update_self
on public.users
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

create policy teams_select_authenticated
on public.teams
for select
to authenticated
using (auth.uid() is not null);

create policy fields_select_authenticated
on public.fields
for select
to authenticated
using (auth.uid() is not null);

create policy game_rule_presets_select_public_or_owner
on public.game_rule_presets
for select
to authenticated
using (is_public or owner_id = auth.uid());

create policy game_rule_presets_insert_owner
on public.game_rule_presets
for insert
to authenticated
with check (owner_id = auth.uid());

create policy game_rule_presets_update_owner
on public.game_rule_presets
for update
to authenticated
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

create policy game_rule_presets_delete_owner
on public.game_rule_presets
for delete
to authenticated
using (owner_id = auth.uid());

create policy game_sessions_select_authenticated
on public.game_sessions
for select
to authenticated
using (auth.uid() is not null);

create policy participations_select_self_or_session_owner
on public.participations
for select
to authenticated
using (user_id = auth.uid() or public.is_session_owner(game_session_id));

create policy payment_submissions_select_self_or_session_owner
on public.payment_submissions
for select
to authenticated
using (user_id = auth.uid() or public.is_session_owner(game_session_id));

create policy refund_requests_select_self_or_session_owner
on public.refund_requests
for select
to authenticated
using (user_id = auth.uid() or public.is_session_owner(game_session_id));

create policy entry_passes_select_self_or_session_owner
on public.entry_passes
for select
to authenticated
using (user_id = auth.uid() or public.is_session_owner(game_session_id));

create policy notifications_select_self
on public.notifications
for select
to authenticated
using (user_id = auth.uid());

create policy notifications_update_self
on public.notifications
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy fcm_tokens_select_self
on public.fcm_tokens
for select
to authenticated
using (user_id = auth.uid());

create policy fcm_tokens_insert_self
on public.fcm_tokens
for insert
to authenticated
with check (user_id = auth.uid());

create policy fcm_tokens_update_self
on public.fcm_tokens
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy fcm_tokens_delete_self
on public.fcm_tokens
for delete
to authenticated
using (user_id = auth.uid());

revoke all on schema public from public, anon, authenticated;
grant usage on schema public to anon, authenticated;

revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant select on public.users to authenticated;
grant update (display_name, phone_number, team_id, last_active_at) on public.users to authenticated;

grant select on public.teams to authenticated;
grant select on public.fields to authenticated;

grant select, insert, update, delete on public.game_rule_presets to authenticated;

grant select on public.game_sessions to authenticated;
grant select on public.participations to authenticated;
grant select on public.payment_submissions to authenticated;

grant select (
  id,
  participation_id,
  game_session_id,
  user_id,
  bank_name,
  account_holder,
  reason,
  status,
  requested_at,
  processed_by,
  processed_at,
  note
) on public.refund_requests to authenticated;
revoke select (account_number_encrypted) on public.refund_requests from anon, authenticated;

grant select on public.entry_passes to authenticated;

grant select on public.notifications to authenticated;
grant update (is_read) on public.notifications to authenticated;

grant select, insert, update, delete on public.fcm_tokens to authenticated;

grant execute on function public.is_session_owner(uuid) to authenticated;

-- service_role: 위 blanket revoke(from public)가 service_role 베이스라인까지 걷어내므로,
-- 서버 전용(Edge Function) 경로가 읽어야 하는 것을 명시적으로 되돌린다.
-- send-email Edge Function이 수신자 주소를 조회한다(RLS 우회 = service-role 필수).
grant select (id, email) on public.users to service_role;
