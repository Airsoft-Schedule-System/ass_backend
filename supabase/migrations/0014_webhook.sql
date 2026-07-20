create or replace function public.tg_notify_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := rtrim(
      coalesce(
        nullif(current_setting('app.settings.functions_url', true), ''),
        'http://host.docker.internal:54321/functions/v1'
      ),
      '/'
    ) || '/send-email',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', coalesce(
        nullif(current_setting('app.settings.webhook_secret', true), ''),
        'local-dev-secret'
      )
    ),
    body := to_jsonb(new),
    timeout_milliseconds := 5000
  );

  return new;
exception
  when others then
    return new;
end;
$$;

drop trigger if exists on_notification_created on public.notifications;

create trigger on_notification_created
after insert on public.notifications
for each row execute function public.tg_notify_email();
