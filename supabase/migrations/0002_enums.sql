create type game_session_status as enum (
  'recruiting',
  'closed',
  'inProgress',
  'completed',
  'cancelled'
);

create type participation_status as enum (
  'pendingApproval',
  'rejected',
  'awaitingPayment',
  'paymentReview',
  'confirmed',
  'cancelled',
  'refundRequested',
  'attended'
);

create type payment_submission_status as enum (
  'pending',
  'approved',
  'rejected'
);

create type refund_request_status as enum (
  'requested',
  'approved',
  'completed',
  'rejected'
);

create type entry_pass_status as enum (
  'active',
  'used',
  'revoked',
  'expired'
);

create type payment_method as enum (
  'pre_transfer'
);

create type fcm_platform as enum (
  'web',
  'ios',
  'android'
);
