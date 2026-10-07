-- Live classification, gap metrics, and the single public read function for the dashboard.
-- Tables stay locked (RLS, no anon access). The page calls public_dashboard() only.

-- Classification --------------------------------------------------------------
-- One row per watched trip (a scheduled trip at a stop that has focus windows, falling
-- inside a window, on a weekday). Status is final 30 minutes after the scheduled time.
-- "unknown" means our own polling had gaps around the trip; it is never counted against Metro.
create or replace view public.trip_status_live with (security_invoker = true) as
with cfg as (
  select
    (select (value #>> '{}')::numeric from config where key = 'early_threshold_min') as early_m,
    (select (value #>> '{}')::numeric from config where key = 'late_threshold_min') as late_m,
    (select (value #>> '{}')::numeric from config where key = 'finalize_grace_min') as grace_m
), watched as (
  select e.service_date, e.trip_id, e.stop_id, e.scheduled_time, s.name as stop_name, s.direction
  from expected_trips e
  join stops s on s.stop_id = e.stop_id
  where s.active and s.focus_windows is not null
    and extract(isodow from e.service_date) <= 5
    and exists (
      select 1 from jsonb_array_elements(s.focus_windows) w
      where (e.scheduled_time at time zone 'America/Los_Angeles')::time
            between (w->>'start')::time and (w->>'end')::time
    )
)
select
  w.service_date, w.trip_id, w.stop_id, w.stop_name, w.direction, w.scheduled_time,
  o.first_seen_at, o.last_seen_at, o.last_predicted_time, o.ever_had_realtime,
  o.vehicle_id, o.relationship, cov.ok_polls, cov.bad_polls,
  round((extract(epoch from (o.last_predicted_time - w.scheduled_time)) / 60)::numeric, 1) as delay_min,
  case
    when now() < w.scheduled_time + cfg.grace_m * interval '1 minute' then 'pending'
    when coalesce(cov.bad_polls, 0) > 0 or coalesce(cov.ok_polls, 0) < 6 then 'unknown'
    when o.trip_id is null then 'not_observed'
    when not o.ever_had_realtime or o.last_predicted_time is null then 'no_realtime'
    when extract(epoch from (o.last_predicted_time - w.scheduled_time)) / 60 > cfg.late_m then 'late'
    when extract(epoch from (o.last_predicted_time - w.scheduled_time)) / 60 < -cfg.early_m then 'early'
    else 'on_time'
  end as status
from watched w
cross join cfg
left join observations o
  on o.service_date = w.service_date and o.trip_id = w.trip_id and o.stop_id = w.stop_id
left join lateral (
  select count(*) filter (where p.success) as ok_polls,
         count(*) filter (where not p.success) as bad_polls
  from poll_log p
  where p.source = 'metro_gtfs_rt'
    and p.polled_at between w.scheduled_time - interval '15 minutes'
                        and w.scheduled_time + interval '3 minutes'
) cov on true;

-- Gaps between consecutive buses actually seen. A gap is skipped if an unknown or still-pending
-- trip sits between the two buses, so polling holes never inflate Metro's numbers.
create or replace view public.trip_gaps_live with (security_invoker = true) as
with ordered as (
  select t.*,
         sum((t.status in ('unknown', 'pending'))::int) over (
           partition by t.stop_id, t.service_date order by t.scheduled_time rows unbounded preceding
         ) as cum_bad
  from trip_status_live t
), seen as (
  select o.*,
         lag(o.last_predicted_time) over w as prev_time,
         lag(o.cum_bad) over w as prev_bad
  from ordered o
  where o.status in ('on_time', 'late', 'early')
  window w as (partition by o.stop_id, o.service_date order by o.scheduled_time)
)
select stop_id, service_date, scheduled_time, last_predicted_time, prev_time,
       extract(epoch from (last_predicted_time - prev_time)) / 60 as gap_min
from seen
where prev_time is not null and cum_bad = prev_bad;

-- Public read function -----------------------------------------------------------
create or replace function public.public_dashboard(p_days int default 14)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d int := least(greatest(coalesce(p_days, 14), 1), 60);
  today date := (now() at time zone 'America/Los_Angeles')::date;
  pad int := coalesce((select (value #>> '{}')::int from config where key = 'poll_padding_min'), 15);
  local_ts timestamp := now() at time zone 'America/Los_Angeles';
  in_win boolean;
  last_poll record;
  j_today jsonb; j_stops jsonb; j_daily jsonb; j_health jsonb; j_reports jsonb; j_giveups jsonb;
begin
  select exists (
    select 1 from stops s, jsonb_array_elements(s.focus_windows) w
    where s.active and extract(isodow from local_ts) <= 5
      and local_ts::time between (w->>'start')::time - pad * interval '1 minute'
                             and (w->>'end')::time + pad * interval '1 minute'
  ) into in_win;

  -- Today, per watched stop
  select coalesce(jsonb_agg(x order by x->>'stop_id'), '[]') into j_today from (
    select jsonb_build_object(
      'stop_id', s.stop_id, 'name', s.name, 'role', s.role, 'windows', s.focus_windows,
      'trips', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'scheduled', t.scheduled_time, 'predicted', t.last_predicted_time,
          'delay_min', t.delay_min, 'status', t.status, 'has_rt', coalesce(t.ever_had_realtime, false),
          'last_seen', t.last_seen_at,
          'reports', (select coalesce(jsonb_agg(jsonb_build_object(
                        'what', r.what_happened, 'minutes_waited', r.minutes_waited,
                        'alternative', r.alternative)), '[]')
                      from rider_reports r
                      where r.stop_id = t.stop_id and r.scheduled_time = t.scheduled_time)
        ) order by t.scheduled_time), '[]')
        from trip_status_live t where t.stop_id = s.stop_id and t.service_date = today
      )
    ) as x
    from stops s where s.active and s.focus_windows is not null
  ) q;

  -- Per-stop summary over the last d days (finalized trips only)
  select coalesce(jsonb_agg(x order by x->>'stop_id'), '[]') into j_stops from (
    select jsonb_build_object(
      'stop_id', f.stop_id, 'name', f.stop_name,
      'scheduled', count(*),
      'known', count(*) filter (where f.status <> 'unknown'),
      'seen', count(*) filter (where f.status in ('on_time','late','early')),
      'on_time', count(*) filter (where f.status = 'on_time'),
      'late', count(*) filter (where f.status = 'late'),
      'early', count(*) filter (where f.status = 'early'),
      'no_bus', count(*) filter (where f.status in ('not_observed','no_realtime')),
      'unknown', count(*) filter (where f.status = 'unknown'),
      'median_gap_min', (select round(percentile_cont(0.5) within group (order by g.gap_min)::numeric, 1)
                         from trip_gaps_live g where g.stop_id = f.stop_id and g.service_date > today - d),
      'p90_gap_min', (select round(percentile_cont(0.9) within group (order by g.gap_min)::numeric, 1)
                      from trip_gaps_live g where g.stop_id = f.stop_id and g.service_date > today - d),
      'longest_gap_min', (select round(max(g.gap_min)::numeric, 1)
                          from trip_gaps_live g where g.stop_id = f.stop_id and g.service_date > today - d),
      'median_sched_gap_min', (
        select round(percentile_cont(0.5) within group (order by sg)::numeric, 1) from (
          select extract(epoch from (t.scheduled_time - lag(t.scheduled_time) over (
                   partition by t.stop_id, t.service_date order by t.scheduled_time))) / 60 as sg
          from trip_status_live t where t.stop_id = f.stop_id and t.service_date > today - d
        ) z where sg is not null)
    ) as x
    from trip_status_live f
    where f.service_date > today - d and f.status <> 'pending'
    group by f.stop_id, f.stop_name
  ) q;

  -- Per-day rows (used for the worst-days table)
  select coalesce(jsonb_agg(x order by (x->>'longest_gap_min')::numeric desc nulls last, x->>'service_date' desc), '[]')
  into j_daily from (
    select jsonb_build_object(
      'service_date', f.service_date, 'stop_id', f.stop_id, 'name', f.stop_name,
      'scheduled', count(*),
      'seen', count(*) filter (where f.status in ('on_time','late','early')),
      'no_bus', count(*) filter (where f.status in ('not_observed','no_realtime')),
      'unknown', count(*) filter (where f.status = 'unknown'),
      'longest_gap_min', (select round(max(g.gap_min)::numeric, 1) from trip_gaps_live g
                          where g.stop_id = f.stop_id and g.service_date = f.service_date)
    ) as x
    from trip_status_live f
    where f.service_date > today - d and f.service_date < today
    group by f.service_date, f.stop_id, f.stop_name
  ) q;

  -- Data quality
  select polled_at, success, error_text into last_poll
  from poll_log where source = 'metro_gtfs_rt' order by polled_at desc limit 1;

  select jsonb_build_object(
    'last_poll_at', last_poll.polled_at,
    'last_poll_ok', last_poll.success,
    'minutes_since_last_poll', round((extract(epoch from (now() - last_poll.polled_at)) / 60)::numeric, 1),
    'in_poll_window', in_win,
    'stalled', in_win and (last_poll.polled_at is null or now() - last_poll.polled_at > interval '6 minutes'),
    'polls', (select count(*) from poll_log where source = 'metro_gtfs_rt' and polled_at > now() - make_interval(days => d)),
    'polls_ok', (select count(*) from poll_log where source = 'metro_gtfs_rt' and success and polled_at > now() - make_interval(days => d)),
    'missed_dispatches', (
      select greatest(
        (select count(*) from poll_log where source = 'cron_dispatch' and polled_at > now() - make_interval(days => d)) -
        (select count(*) from poll_log where source = 'metro_gtfs_rt' and polled_at > now() - make_interval(days => d)), 0)),
    'recent_failures', (
      select coalesce(jsonb_agg(jsonb_build_object('at', polled_at, 'error', left(error_text, 120)) order by polled_at desc), '[]')
      from (select polled_at, error_text from poll_log
            where source = 'metro_gtfs_rt' and not success and polled_at > now() - make_interval(days => d)
            order by polled_at desc limit 5) f)
  ) into j_health;

  -- Rider reports (no free text, no reporter label)
  select coalesce(jsonb_agg(x order by x->>'reported_at' desc), '[]') into j_reports from (
    select jsonb_build_object(
      'reported_at', r.reported_at, 'service_date', r.service_date, 'stop_id', r.stop_id,
      'name', s.name, 'scheduled', r.scheduled_time, 'what', r.what_happened,
      'minutes_waited', r.minutes_waited, 'alternative', r.alternative) as x
    from rider_reports r join stops s using (stop_id)
    where r.service_date > today - d
    order by r.reported_at desc limit 25
  ) q;

  -- Gave up counts
  select coalesce(jsonb_agg(x order by x->>'stop_id'), '[]') into j_giveups from (
    select jsonb_build_object(
      'stop_id', s.stop_id, 'name', s.name,
      'gave_up', count(r.id) filter (where r.what_happened = 'gave_up'),
      'days_with_giveup', count(distinct r.service_date) filter (where r.what_happened = 'gave_up'),
      'reports', count(r.id)) as x
    from stops s
    left join rider_reports r on r.stop_id = s.stop_id and r.service_date > today - d
    where s.active and s.focus_windows is not null
    group by s.stop_id, s.name
  ) q;

  return jsonb_build_object(
    'generated_at', now(), 'days', d, 'today', j_today, 'stops', j_stops, 'daily', j_daily,
    'health', j_health, 'reports', j_reports, 'giveups', j_giveups,
    'thresholds', jsonb_build_object(
      'early_min', (select (value #>> '{}')::numeric from config where key = 'early_threshold_min'),
      'late_min', (select (value #>> '{}')::numeric from config where key = 'late_threshold_min'),
      'grace_min', (select (value #>> '{}')::numeric from config where key = 'finalize_grace_min'))
  );
end $$;
revoke all on function public.public_dashboard(int) from public;
grant execute on function public.public_dashboard(int) to anon, authenticated, service_role;

-- Views are internal: not readable by the public roles.
revoke all on public.trip_status_live from anon, authenticated;
revoke all on public.trip_gaps_live from anon, authenticated;
