insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do update
set public = excluded.public;

-- storage.objects는 supabase_storage_admin 소유 + RLS 기본 활성 상태다.
-- postgres 롤로는 ALTER TABLE ... ENABLE RLS 불가(42501)이고 불필요하므로 정책만 생성한다.
drop policy if exists receipts_insert_own on storage.objects;
drop policy if exists receipts_select_own_or_session_owner on storage.objects;

create policy receipts_insert_own
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'receipts'
  and exists (
    select 1
    from public.participations p
    where p.id = ((storage.foldername(name))[1])::uuid
      and p.user_id = auth.uid()
  )
);

create policy receipts_select_own_or_session_owner
on storage.objects
for select
to authenticated
using (
  bucket_id = 'receipts'
  and exists (
    select 1
    from public.participations p
    where p.id = ((storage.foldername(name))[1])::uuid
      and (
        p.user_id = auth.uid()
        or public.is_session_owner(p.game_session_id)
      )
  )
);
