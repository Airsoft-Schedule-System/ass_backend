create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text not null default '',
  phone_number text,
  team_id uuid references public.teams(id),
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now()
);

create table public.fields (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  lat double precision,
  lng double precision,
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
  field_name text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  capacity int not null check (capacity > 0),
  confirmed_count int not null default 0,
  game_fee numeric(12,0) not null check (game_fee >= 0),
  payment_method payment_method not null default 'pre_transfer',
  bank_name text not null,
  bank_account_number text not null,
  bank_account_holder text not null,
  preset_id uuid references public.game_rule_presets(id),
  custom_rules jsonb,
  cancel_deadline timestamptz not null,
  status game_session_status not null default 'recruiting',
  reminder_sent boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint capacity_not_exceeded check (confirmed_count between 0 and capacity),
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
  constraint one_participation_per_user unique (game_session_id, user_id)
);

create table public.payment_submissions (
  id uuid primary key default gen_random_uuid(),
  participation_id uuid not null references public.participations(id),
  game_session_id uuid not null references public.game_sessions(id),
  user_id uuid not null references public.users(id),
  sender_name text not null,
  amount numeric(12,0) not null,
  receipt_path text not null,
  status payment_submission_status not null default 'pending',
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references public.users(id),
  reviewed_at timestamptz,
  rejection_reason text
);

create table public.refund_requests (
  id uuid primary key default gen_random_uuid(),
  participation_id uuid not null references public.participations(id) unique,
  game_session_id uuid not null references public.game_sessions(id),
  user_id uuid not null references public.users(id),
  bank_name text not null,
  account_number_encrypted text not null,
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
  qr_token_hash text not null,
  qr_secret_version text not null default 'v1',
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  scanned_by uuid references public.users(id)
);

create unique index one_active_pass_per_participation
  on public.entry_passes (participation_id)
  where status = 'active';

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
