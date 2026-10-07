# Route 4 reliability tracker: build brief

## Goal

Build a small, always-on system that records whether King County Metro Route 4 actually runs the trips it publishes, and how late those trips are, at a handful of Queen Anne and downtown stops. The output is evidence a neighborhood group can hand to Metro and a city council office: scheduled versus observed trips, on-time performance, and the longest real-world gap between buses by time of day.

This is a standalone project. It gets its own GitHub repo, its own Vercel project, and its own Supabase project. It shares nothing with any other project.

## Why this exists

Riders on Queen Anne report waits of 30 to 40 minutes on a route that is scheduled every 15 minutes on weekdays. The published timetable (Aug 29, 2026 through Mar 26, 2027) shows roughly 15 minute weekday daytime service, uneven evening service that settles to 30 minutes, and 30 minute service on weekends. In 2024 Metro moved all Queen Anne trips from Route 3 onto Route 4 and said service levels would not change. The question is whether the published trips are being delivered.

Metro's public dashboard link is currently broken and no historical trip-level data is available, so this system collects its own.

## Scope

In scope: Route 4 only, both directions, at the monitored stops below. Scheduled versus observed trips, lateness, gaps between buses, a public read-only dashboard, and a way for a rider to log what happened at the stop.

Out of scope: other routes, street segment speeds, maps, passenger counts, anything predictive.

## Data sources

1. **Metro static GTFS**, the schedule of record. Download from Metro's GTFS page (metro.kingcounty.gov/gtfs/ was the historical location; verify the current URL). Load it into Supabase. It defines the full set of expected Route 4 trips and their scheduled stop times, including times past 24:00 for the after-midnight tail of a service day. Reload at every service change (the next one after Mar 26, 2027 is the spring 2027 change). The published pamphlet is only a sanity check.
2. **OneBusAway Puget Sound API** (arrivals-and-departures-for-stop), for real-time predictions. Requires an API key that Jesse will supply through an environment variable. Do not commit it. Verify the current base URL and key process in the OneBusAway and Sound Transit Open Transit Data documentation. Stop IDs are expected to be the agency prefix plus the stop number (for example 1_12910); confirm this.
3. **Rider reports**, entered by hand through a form on the dashboard. These are ground truth.

## Monitored stops

Stop numbers below come from the published Route 4 timetable. Verify each against the API before relying on it.

Direction A (from Seattle Pacific University toward Judkins Park):
- 3rd Ave W & W Cremona St, #41255 (route start)
- Boston St & Queen Anne Ave N, #3930
- 3rd Ave & Cedar St, #2220
- 9th Ave & Jefferson St, #12910

Direction B (from Judkins Park toward Seattle Pacific University):
- Jefferson St & 9th Ave, #12880
- 3rd Ave & Cedar St, #1690
- Boston St & 1st Ave N, #4370
- W Nickerson St & 3rd Ave W, #18220 (route end)

Two stops are not in the timetable and must be found with a stops-for-location lookup, then confirmed with Jesse before going live:
- The rider's boarding stop near 3rd Ave W & W McGraw St, direction toward downtown. Also its opposite-direction partner for the trip home.
- The Route 4 stop nearest 500 5th Ave N (both directions).

Keep the stop list in a config table so stops can be added or removed without code changes.

## Data model (Supabase / Postgres)

- `stops`: stop_id, name, direction, notes, active flag.
- `expected_trips`: service_date, trip_id, stop_id, scheduled_time (timestamptz, America/Los_Angeles), generated from GTFS. Populate daily for the next several days.
- `observations`: service_date, trip_id, stop_id, first_seen_at, last_seen_at, last_predicted_time, ever_had_realtime (bool), vehicle_id. One row per trip per stop, upserted on each poll. Do not store every raw poll indefinitely.
- `raw_polls`: short-lived raw API responses for debugging. Retention 7 days, purged by a scheduled job.
- `poll_log`: poll timestamp, stop_id, success flag, HTTP status, error text. Used for data quality (see below).
- `trip_results`: one row per expected trip per stop with a final classification (see below), computed after the fact.
- `rider_reports`: reported_at, service_date, stop_id, scheduled_time, what_happened (enum: bus came on time, bus came late, bus never came, bus bypassed or full, other), minutes_waited (optional), note (optional), reporter label (free text).

Enable row level security. Public read access only to the aggregate views the dashboard uses. Writes to `rider_reports` only through a single validated endpoint with basic rate limiting. No secrets in the client.

## Polling

Poll every 60 seconds, for each active monitored stop, from about 4:00 AM to 2:00 AM Pacific every day. Route 4 has Night Owl trips, so confirm service hours from GTFS and widen the window if needed. Use `minutesBefore=5` and `minutesAfter=60`, filter to Route 4, and upsert into `observations`.

Scheduling must be able to run every minute. Preferred approach: Supabase pg_cron invoking an Edge Function. GitHub Actions cron is too coarse and unreliable for this, so do not use it for polling. If another approach is better, explain why before building it. Add a heartbeat so a silent failure of the poller is visible on the dashboard.

Confirm that the chosen Supabase plan will not auto-pause the project for inactivity. If it can, flag it and propose a fix.

## Classification

A finalization job runs shortly after each expected trip's scheduled time (allow 30 minutes of grace) and writes `trip_results`. "Actual time" is the last predicted arrival observed before the vehicle was no longer listed, which is a proxy, not a true AVL timestamp. Label it that way in the UI.

Statuses:
- `on_time`
- `late` (beyond the lateness threshold)
- `early` (beyond the earliness threshold)
- `no_realtime` (the trip was listed but never had a prediction)
- `not_observed` (the trip never appeared in the feed at all)
- `unknown` (our polling had gaps around that trip; never counted against Metro)

Keep thresholds as config constants. Placeholder defaults: early more than 1 minute, late more than 5 minutes. Look up Metro's published on-time definition and use it if it differs. Say clearly in the dashboard what the thresholds are.

Important: `no_realtime` and `not_observed` mean "a bus may not have run, or the tracking feed had a gap." Do not label either as "canceled" or "missed" in any public view. Call them "no bus observed" and explain the caveat. Real-time data near the start of routes has a history of gaps, and the rider's boarding stop is close to the start.

## Gap metric

For each monitored stop, direction, and time-of-day block (AM peak, midday, PM peak, evening, weekend), compute the scheduled gap between consecutive trips and the observed gap between consecutive buses actually seen. Report the median observed gap, the 90th percentile gap, and the longest gap each day. This directly tests the "waiting 40 minutes" experience.

## Dashboard (Vercel, single page, read-only)

Plain, fast, readable on a phone. Sections:
1. **Today** at the rider's boarding stop: each scheduled trip with scheduled time, observed time, and status.
2. **Last 14 days**: percentage of scheduled trips observed, percentage on time, count of `no bus observed`, worst single gap, by time-of-day block.
3. **Worst days**: a short ranked table linking to that day's trip list.
4. **Data quality**: polling success rate, any outage windows, last heartbeat.
5. **Rider reports**: the form (see below) and recent entries shown beside the automatic results for the same trips.
6. A short methods note: what "observed" means, what the thresholds are, and the caveat above.

Shareable URL, no login required to view.

## Rider reports

A mobile-friendly form that takes about 15 seconds: stop (default to the boarding stop), scheduled time, what happened, optional minutes waited and note. A report for a given scheduled trip is displayed next to the automatic classification for that trip so disagreements are visible. These are the credibility check on the automatic data.

## Data quality rules

- Never treat a gap in our own polling as a missed Metro trip. If polls failed within a window around a trip, classify it `unknown`.
- Handle service days that cross midnight (GTFS times above 24:00).
- Handle daylight saving transitions and holiday schedules (the pamphlet lists Sunday service on Labor Day, Thanksgiving, Christmas, and New Year's Day).
- Handle snow routing and any posted detours without crashing the matcher; log them.
- Store all times as timestamptz and display in America/Los_Angeles.

## Build order

1. New repo, Supabase project, and Vercel project, wired together with environment variables.
2. Load GTFS, generate `expected_trips`, and confirm the daily trip count at the route start matches the published timetable.
3. Poller plus `poll_log`, run for one full day in observe-only mode.
4. Classification and gap metrics, validated by hand on that day's data.
5. Dashboard and rider report form.
6. Heartbeat, alerting on a stalled poller, and retention purge.

## First-week acceptance checks

- Expected trip counts per day match the published pamphlet within a small tolerance.
- Poll success rate is above 99 percent, and any outage is visible on the dashboard.
- For three days, hand-compare the rider's notes against the automatic classification at the boarding stop and report the disagreements.
- No page or API response exposes secrets or raw rider report free text beyond what is intended.

## Open items for Jesse

- OneBusAway API key (supply as an environment variable).
- Confirm the boarding stop ID and the stop nearest 500 5th Ave N.
- Confirm Metro's current on-time definition if it differs from the placeholders.
- Decide whether the dashboard stays public or sits behind a simple link before it is shared with anyone outside the group.
