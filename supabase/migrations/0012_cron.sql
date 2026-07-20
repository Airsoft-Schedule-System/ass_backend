create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'status-transition',
  '0 * * * *',
  $$select public.fn_status_transition()$$
);

select cron.schedule(
  'send-reminders',
  '*/30 * * * *',
  $$select public.fn_send_reminders()$$
);
