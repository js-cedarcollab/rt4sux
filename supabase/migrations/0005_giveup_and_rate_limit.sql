-- "I gave up on the bus" reports, hashed-IP rate limiting for the public report endpoint,
-- and a daily job that keeps the next week of expected trips filled in.
alter type public.rider_outcome add value if not exists 'gave_up';

alter table public.rider_reports
  add column if not exists alternative text
  check (alternative in ('walked','drove','rideshare','other_route','other'));

create table public.report_rate (
  ip_hash text not null,
  at timestamptz not null default now()
);
create index on public.report_rate (ip_hash, at);
alter table public.report_rate enable row level security;
revoke all on public.report_rate from anon, authenticated;

-- ~02:00 Pacific
select cron.schedule('rt4-expected-trips', '0 9 * * *',
  $$select public.generate_expected_trips((now() at time zone 'America/Los_Angeles')::date, 8)$$);
