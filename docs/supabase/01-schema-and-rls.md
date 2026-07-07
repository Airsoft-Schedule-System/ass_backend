# 01 — Postgres 스키마·RLS 구현 지침 (Wave S1)

기준: `ass_knowledge/database/erd-v2.md`(엔티티·관계·상태 모델 — 그대로 유효) + A1–A8 결정.
아래 DDL은 **그대로 마이그레이션에 옮겨도 되는 수준의 명세**다. 파일 분할은 00 §3 트리를 따른다.

## 1. 확장 (0001)

```sql
create extension if not exists pgcrypto;   -- gen_random_uuid, hmac, pgp_sym_encrypt
create extension if not exists pg_cron;    -- 상태전이·리마인더
create extension if not exists pg_net;     -- (웹훅 대안·cron→edge 호출용)
-- Vault는 Supabase 대시보드/CLI에서 활성화(supabase_vault). 시크릿 키 이름은 00 §4.
```

## 2. Enum (0002)

값 문자열은 fe-be-contract-v2의 camelCase를 **그대로** 사용한다(00 §2).

```sql
create type game_session_status  as enum ('recruiting','closed','inProgress','completed','cancelled');
create type participation_status as enum ('pendingApproval','rejected','awaitingPayment','paymentReview','confirmed','cancelled','refundRequested','attended');
create type payment_submission_status as enum ('pending','approved','rejected');
create type refund_request_status     as enum ('requested','approved','completed','rejected');
create type entry_pass_status         as enum ('active','used','revoked','expired');
create type payment_method            as enum ('pre_transfer');          -- onsite는 v2에서 ALTER TYPE ADD VALUE
create type fcm_platform              as enum ('web','ios','android');
```

## 3. 테이블 (0003) — ERD v2 §5 관계형 전사

공통: PK는 `uuid default gen_random_uuid()`(users 제외), 시각은 `timestamptz`, `created_at timestamptz not null default now()`. `updated_at`은 0011 트리거로 자동 갱신.

**관계형 정리로 제거되는 denormalized 필드** (Firestore 시절 산물 — 조인으로 대체):
`participation.gameStartsAt`(→ game_sessions 조인), `participation.entryPassId`(→ entry_passes가 participation_id 보유 + active partial unique).
**유지하는 denormalized**: payment_submissions·refund_requests·entry_passes·notifications의 `game_session_id`(RLS 정책 조인 비용 절감 — 명시적 트레이드오프).

```sql
-- users: auth.users 1:1 프로필. id = auth.users.id
create table public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text not null default '',          -- B1-6: 비어있으면 프로필 미완성
  phone_number text,
  team_id uuid references public.teams(id),
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now()
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.fields (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  lat double precision, lng double precision,
  created_at timestamptz not null default now()
);

create table public.game_rule_presets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  rules jsonb not null default '{}',
  owner_id uuid references public.users(id),
  is_public boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.game_sessions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  created_by_user_id uuid not null references public.users(id),
  host_team_id uuid references public.teams(id),
  field_id uuid references public.fields(id),
  field_name text,                                 -- field_id XOR field_name: CHECK 아래
  starts_at timestamptz not null,
  ends_at timestamptz,
  capacity int not null check (capacity > 0),
  confirmed_count int not null default 0,
  game_fee numeric(12,0) not null check (game_fee >= 0),
  payment_method payment_method not null default 'pre_transfer',
  bank_name text not null,                         -- bankAccount 객체 → 3컬럼 평탄화
  bank_account_number text not null,
  bank_account_holder text not null,
  preset_id uuid references public.game_rule_presets(id),
  custom_rules jsonb,
  cancel_deadline timestamptz not null,            -- 기본값(startsAt-48h)은 RPC에서 계산(A4)
  status game_session_status not null default 'recruiting',
  reminder_sent boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint capacity_not_exceeded check (confirmed_count between 0 and capacity),  -- ★B1-1 DB 보장
  constraint field_xor check ((field_id is null) <> (field_name is null)),
  constraint rules_xor check ((preset_id is null) <> (custom_rules is null))
);

create table public.participations (
  id uuid primary key default gen_random_uuid(),
  game_session_id uuid not null references public.game_sessions(id),
  user_id uuid not null references public.users(id),
  status participation_status not null default 'pendingApproval',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint one_participation_per_user unique (game_session_id, user_id)          -- ★중복 신청 DB 보장
);

create table public.payment_submissions (
  id uuid primary key default gen_random_uuid(),
  participation_id uuid not null references public.participations(id),
  game_session_id uuid not null references public.game_sessions(id),
  user_id uuid not null references public.users(id),
  sender_name text not null,
  amount numeric(12,0) not null,
  receipt_path text not null,                      -- storage 'receipts' 버킷 내 경로 (03 §4)
  status payment_submission_status not null default 'pending',
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references public.users(id),
  reviewed_at timestamptz,
  rejection_reason text
);

create table public.refund_requests (
  id uuid primary key default gen_random_uuid(),
  participation_id uuid not null references public.participations(id) unique,      -- 1참가 1환불요청
  game_session_id uuid not null references public.game_sessions(id),
  user_id uuid not null references public.users(id),
  bank_name text not null,
  account_number_encrypted text not null,          -- pgp_sym_encrypt 결과(armor). 평문 저장·로그 금지
  account_holder text not null,
  reason text,
  status refund_request_status not null default 'requested',
  requested_at timestamptz not null default now(),
  processed_by uuid references public.users(id),
  processed_at timestamptz,
  note text
);

create table public.entry_passes (
  id uuid primary key default gen_random_uuid(),
  participation_id uuid not null references public.participations(id),
  game_session_id uuid not null references public.game_sessions(id),
  user_id uuid not null references public.users(id),
  status entry_pass_status not null default 'active',
  qr_token_hash text not null,                     -- SHA256(HMAC) hex — 원문 미저장 원칙 유지
  qr_secret_version text not null default 'v1',
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  scanned_by uuid references public.users(id)
);
create unique index one_active_pass_per_participation on public.entry_passes (participation_id) where status = 'active';

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id),
  type text not null,
  title text not null,
  body text not null,
  action_url text not null,
  data jsonb,
  game_session_id uuid references public.game_sessions(id),
  participation_id uuid references public.participations(id),
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.fcm_tokens (
  user_id uuid not null references public.users(id) on delete cascade,
  installation_id text not null,
  token text not null,
  platform fcm_platform not null default 'web',
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (user_id, installation_id)
);
```

## 4. 인덱스 (0004) — ERD §8 대응

```sql
create index gs_status_starts on public.game_sessions (status, starts_at);
create index gs_owner_starts  on public.game_sessions (created_by_user_id, starts_at);
create index p_user           on public.participations (user_id, created_at desc);
create index p_session_status on public.participations (game_session_id, status, created_at);
create index ps_session_queue on public.payment_submissions (game_session_id, status, submitted_at);
create index rr_session_queue on public.refund_requests (game_session_id, status, requested_at);
create index ep_user_session  on public.entry_passes (user_id, game_session_id, status);
create index grp_owner        on public.game_rule_presets (owner_id, updated_at desc);
create index n_user_created   on public.notifications (user_id, created_at desc);
create index n_user_unread    on public.notifications (user_id, is_read, created_at desc);
```

(구 `participations(user_id, game_starts_at)`는 denorm 제거로 `p_user`+조인으로 대체 — FE 목록 쿼리는 contract-v3 §3 참조.)

## 5. 트리거 (0011)

```sql
-- (1) onUserCreate 대체: auth 가입 → 프로필 행 생성
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.users (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'display_name',''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- (2) updated_at 자동 갱신: game_sessions·participations·game_rule_presets에 공통 트리거
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
-- (테이블별 create trigger ... before update ... 3개 생성)
```

## 6. RLS 정책 (0005) — firestore.rules 의미 이식 + 관계형 확장

원칙: **전 테이블 `enable row level security`. 쓰기(INSERT/UPDATE/DELETE)는 기본 차단** — 모든 전이는 RPC(SECURITY DEFINER) 경유. 클라 직접 쓰기는 아래 명시 예외뿐. 헬퍼:

```sql
create or replace function public.is_session_owner(sid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from game_sessions g where g.id = sid and g.created_by_user_id = auth.uid()) $$;
```

| 테이블 | SELECT | 클라 직접 쓰기 (예외만) |
|--------|--------|--------------------------|
| users | 본인 **또는** "내가 운영하는 세션의 신청자"(`exists` participations 조인) — ★Firebase에서 불가했던 규칙, `getSessionParticipantProfiles` 콜러블 대체 | UPDATE 본인: `display_name, phone_number, team_id, last_active_at`만 (컬럼 제한은 `with check` + 트리거 또는 별도 뷰로; 지침: BEFORE UPDATE 트리거로 허용 외 컬럼 변경 시 exception) |
| teams / fields | 로그인 사용자 전체 | 없음(시드·콘솔) |
| game_rule_presets | `is_public` 또는 소유자 | INSERT/UPDATE/DELETE 소유자(owner_id = auth.uid()) |
| game_sessions | 로그인 사용자 전체 | 없음 |
| participations | 본인 또는 세션 운영자 | 없음 |
| payment_submissions | 본인 또는 세션 운영자 | 없음 |
| refund_requests | 본인 또는 세션 운영자. **단 `account_number_encrypted`는 컬럼 GRANT로 차단**(§6.1) | 없음 |
| entry_passes | 본인 또는 세션 운영자 | 없음 |
| notifications | 본인 | UPDATE 본인: `is_read`만(BEFORE UPDATE 트리거로 타 컬럼 차단) |
| fcm_tokens | 본인 | INSERT/UPDATE/DELETE 본인 |

```sql
-- 대표 예시 (전 테이블 동일 패턴으로 작성)
alter table public.participations enable row level security;
create policy p_select on public.participations for select
  using (user_id = auth.uid() or public.is_session_owner(game_session_id));
```

### 6.1 환불계좌 컬럼 보호
`revoke select (account_number_encrypted) on refund_requests from authenticated;` — RLS는 행 단위라 컬럼은 GRANT로 차단. 복호화는 v2 `process_refund` 활성화 시 RPC로만(02 §3.12). anon/authenticated의 기본 GRANT 정리 필수(`revoke all ... from anon` 후 필요한 select/execute만 재부여 — 마이그레이션 말미에 일괄).

### 6.2 pgTAP 검증 매트릭스 (S1 완료 기준)
행위자 {비로그인, 본인, 타인, 세션운영자} × 테이블별 SELECT/직접쓰기 — 기대값 표를 tests/rls.sql로 작성. 특히: 타인 participations 불가시, 운영자는 자기 세션 신청자 users.display_name 조회 가능, notifications는 is_read 외 UPDATE 거부, capacity CHECK·unique 위반 삽입 거부.

## 7. Storage (0013) — 03 §4와 세트

`receipts` 버킷(private) 생성 + `storage.objects` 정책: 경로 규약 `receipts/{participation_id}/{filename}`. INSERT는 본인(해당 participation.user_id = auth.uid() — 경로 파싱 `(storage.foldername(name))[1]::uuid` 조인), SELECT는 업로더 본인 또는 세션 운영자. → 클라 `createSignedUrl` 직접 사용 가능, `getReceiptUrl` 콜러블 불필요.
