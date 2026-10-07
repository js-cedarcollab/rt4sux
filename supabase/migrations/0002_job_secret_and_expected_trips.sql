-- Server-side job secret: scheduled jobs send it as x-job-secret; Edge Functions verify it
-- through verify_job_secret(). The value is generated in the database and never leaves it.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.secrets (
  name text primary key,
  value text not null
);
insert into private.secrets (name, value)
values ('job_secret', encode(gen_random_bytes(32), 'hex'));

create or replace function public.verify_job_secret(p_secret text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists (select 1 from private.secrets where name = 'job_secret' and value = p_secret);
$$;
revoke all on function public.verify_job_secret(text) from public, anon, authenticated;
grant execute on function public.verify_job_secret(text) to service_role;

-- Expected trips: scheduled_time is measured from "noon minus 12h" of the service
-- day (GTFS rule), which stays correct across DST changes and after-midnight times.
create or replace function public.generate_expected_trips(p_from date, p_days int default 7)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  insert into expected_trips (service_date, trip_id, stop_id, scheduled_time)
  select d.service_date, t.trip_id, st.stop_id,
         ((d.service_date + time '12:00') at time zone 'America/Los_Angeles')
           - interval '12 hours' + st.arrival_secs * interval '1 second'
  from generate_series(p_from, p_from + (p_days - 1), interval '1 day') as g(ts)
  cross join lateral (select g.ts::date as service_date) d
  join gtfs_trips t on true
  join gtfs_stop_times st on st.trip_id = t.trip_id
  join stops s on s.stop_id = st.stop_id and s.active
  where (
    exists (
      select 1 from gtfs_calendar c
      where c.service_id = t.service_id
        and d.service_date between c.start_date and c.end_date
        and case extract(dow from d.service_date)::int
              when 0 then c.sunday when 1 then c.monday when 2 then c.tuesday
              when 3 then c.wednesday when 4 then c.thursday when 5 then c.friday
              else c.saturday end
    )
    and not exists (
      select 1 from gtfs_calendar_dates x
      where x.service_id = t.service_id and x.service_date = d.service_date and x.exception_type = 2
    )
  ) or exists (
      select 1 from gtfs_calendar_dates x
      where x.service_id = t.service_id and x.service_date = d.service_date and x.exception_type = 1
  )
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.generate_expected_trips(date, int) from public, anon, authenticated;
grant execute on function public.generate_expected_trips(date, int) to service_role;
