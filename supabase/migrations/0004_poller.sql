-- Poller support: observation upsert rules, window-gated cron dispatch, retention purge,
-- and the pg_cron schedule. Polling is weekdays only, every 2 minutes, inside each stop's
-- focus window (padded). The window check runs in SQL so the Edge Function is never
-- invoked outside the windows.
create extension if not exists pg_net;
create extension if not exists pg_cron;

insert into public.config (key, value, note) values
  ('poll_padding_min', '15', 'Minutes of padding before and after each stop focus window when polling')
on conflict (key) do nothing;

alter table public.observations add column if not exists relationship text;  -- CANCELED / SKIPPED / ADDED etc, null when normal

-- Upsert rules: keep earliest first_seen_at, advance last_seen_at, never lose "had realtime".
create or replace function public.upsert_observations(p jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  insert into observations (service_date, trip_id, stop_id, first_seen_at, last_seen_at,
                            last_predicted_time, ever_had_realtime, vehicle_id, relationship)
  select (r->>'service_date')::date, r->>'trip_id', r->>'stop_id', now(), now(),
         nullif(r->>'predicted','')::timestamptz, coalesce((r->>'has_rt')::boolean, false),
         nullif(r->>'vehicle_id',''), nullif(r->>'relationship','')
  from jsonb_array_elements(p) r
  on conflict (service_date, trip_id, stop_id) do update set
    last_seen_at = excluded.last_seen_at,
    last_predicted_time = coalesce(excluded.last_predicted_time, observations.last_predicted_time),
    ever_had_realtime = observations.ever_had_realtime or excluded.ever_had_realtime,
    vehicle_id = coalesce(excluded.vehicle_id, observations.vehicle_id),
    relationship = coalesce(excluded.relationship, observations.relationship);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.upsert_observations(jsonb) from public, anon, authenticated;
grant execute on function public.upsert_observations(jsonb) to service_role;

create or replace function public.run_poll_if_in_window()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  local_ts timestamp := now() at time zone 'America/Los_Angeles';
  pad int := coalesce((select (value #>> '{}')::int from config where key = 'poll_padding_min'), 15);
  in_window boolean;
  secret text;
begin
  if extract(isodow from local_ts) > 5 then return 'weekend'; end if;

  select exists (
    select 1 from stops s, jsonb_array_elements(s.focus_windows) w
    where s.active
      and local_ts::time between (w->>'start')::time - pad * interval '1 minute'
                             and (w->>'end')::time   + pad * interval '1 minute'
  ) into in_window;
  if not in_window then return 'outside_window'; end if;

  select value into secret from private.secrets where name = 'job_secret';
  perform net.http_post(
    url := 'https://menpsabenhaosvkcwgvk.supabase.co/functions/v1/poll-realtime',
    headers := jsonb_build_object('x-job-secret', secret, 'Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  -- Dispatch record: a dispatch with no matching poll-realtime row means the function never ran.
  insert into poll_log (source, success) values ('cron_dispatch', true);
  return 'dispatched';
end $$;
revoke all on function public.run_poll_if_in_window() from public, anon, authenticated;

create or replace function public.purge_old_polls()
returns void
language sql
security definer
set search_path = public
as $$
  delete from raw_polls where polled_at < now() - interval '7 days';
$$;
revoke all on function public.purge_old_polls() from public, anon, authenticated;

-- Schedules (cron runs in UTC; the wrapper converts to Pacific, so DST is handled)
select cron.schedule('rt4-poll', '*/2 * * * *', $$select public.run_poll_if_in_window()$$);
select cron.schedule('rt4-purge', '15 10 * * *', $$select public.purge_old_polls()$$);
