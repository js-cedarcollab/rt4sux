-- Base schema for the Route 4 tracker.
-- RLS is enabled on every table with no policies; public reads go through aggregate views
-- (added later) and writes go through Edge Functions using the service role.

-- Config -------------------------------------------------------------
create table public.config (
  key text primary key,
  value jsonb not null,
  note text
);
insert into public.config (key, value, note) values
  ('route_id', '"100219"', 'GTFS route_id for Route 4'),
  ('early_threshold_min', '1', 'Early if more than this many minutes ahead of schedule (placeholder)'),
  ('late_threshold_min', '5', 'Late if more than this many minutes behind schedule (placeholder)'),
  ('finalize_grace_min', '30', 'Minutes after scheduled time before a trip is finalized'),
  ('poll_gap_window_min', '10', 'Polling failures within this window around a trip make it unknown'),
  ('timezone', '"America/Los_Angeles"', 'Display and service-day timezone');

-- Monitored stops (stop_id equals Metro GTFS stop_id / public stop number) --
create table public.stops (
  stop_id text primary key,
  name text not null,
  direction text not null check (direction in ('A','B')),
  role text,
  notes text,
  active boolean not null default true
);

-- GTFS (Route 4 only) -------------------------------------------------
create table public.gtfs_feed_info (
  id int primary key default 1 check (id = 1),
  feed_version text,
  feed_start_date date,
  feed_end_date date,
  loaded_at timestamptz not null default now()
);
create table public.gtfs_trips (
  trip_id text primary key,
  service_id text not null,
  direction_id smallint not null,
  headsign text,
  block_id text
);
create table public.gtfs_stop_times (
  trip_id text not null references public.gtfs_trips(trip_id) on delete cascade,
  stop_sequence int not null,
  stop_id text not null,
  arrival_secs int not null,    -- seconds after midnight of service day; may exceed 86400
  departure_secs int not null,
  timepoint boolean,
  primary key (trip_id, stop_sequence)
);
create index on public.gtfs_stop_times (stop_id);
create table public.gtfs_calendar (
  service_id text primary key,
  monday boolean, tuesday boolean, wednesday boolean, thursday boolean,
  friday boolean, saturday boolean, sunday boolean,
  start_date date not null, end_date date not null
);
create table public.gtfs_calendar_dates (
  service_id text not null,
  service_date date not null,
  exception_type smallint not null,  -- 1 added, 2 removed
  primary key (service_id, service_date)
);

-- Expected trips -----------------------------------------------------
create table public.expected_trips (
  service_date date not null,
  trip_id text not null references public.gtfs_trips(trip_id),
  stop_id text not null references public.stops(stop_id),
  scheduled_time timestamptz not null,
  primary key (service_date, trip_id, stop_id)
);
create index on public.expected_trips (stop_id, scheduled_time);

-- Observations -------------------------------------------------------
create table public.observations (
  service_date date not null,
  trip_id text not null,
  stop_id text not null,
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  last_predicted_time timestamptz,
  ever_had_realtime boolean not null default false,
  vehicle_id text,
  primary key (service_date, trip_id, stop_id)
);
create index on public.observations (stop_id, last_seen_at);

-- Raw polls (7 day retention) and poll log ---------------------------
create table public.raw_polls (
  id bigint generated always as identity primary key,
  polled_at timestamptz not null default now(),
  source text not null,
  payload jsonb
);
create index on public.raw_polls (polled_at);

create table public.poll_log (
  id bigint generated always as identity primary key,
  polled_at timestamptz not null default now(),
  source text not null default 'metro_gtfs_rt',
  stop_id text,
  success boolean not null,
  http_status int,
  feed_timestamp timestamptz,
  entities_seen int,
  route4_entities int,
  error_text text
);
create index on public.poll_log (polled_at);

-- Results ------------------------------------------------------------
create type public.trip_status as enum
  ('on_time','late','early','no_realtime','not_observed','unknown');

create table public.trip_results (
  service_date date not null,
  trip_id text not null,
  stop_id text not null,
  scheduled_time timestamptz not null,
  actual_time timestamptz,            -- proxy: last predicted arrival seen
  delay_min numeric,
  status public.trip_status not null,
  time_block text,
  computed_at timestamptz not null default now(),
  primary key (service_date, trip_id, stop_id)
);
create index on public.trip_results (stop_id, scheduled_time);

-- Rider reports ------------------------------------------------------
create type public.rider_outcome as enum
  ('on_time','late','never_came','bypassed_or_full','other');

create table public.rider_reports (
  id bigint generated always as identity primary key,
  reported_at timestamptz not null default now(),
  service_date date not null,
  stop_id text not null references public.stops(stop_id),
  scheduled_time timestamptz,
  what_happened public.rider_outcome not null,
  minutes_waited int check (minutes_waited between 0 and 240),
  note text check (char_length(note) <= 500),
  reporter_label text check (char_length(reporter_label) <= 60)
);
create index on public.rider_reports (stop_id, scheduled_time);

-- Lock everything down -----------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
