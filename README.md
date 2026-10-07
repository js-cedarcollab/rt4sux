# rt4sux

A small, always-on tracker that records whether King County Metro Route 4 runs the trips it publishes, and how late they are, at a handful of Queen Anne and downtown stops.

Output is evidence a neighborhood group can hand to Metro and a city council office: scheduled versus observed trips, on-time performance, and the longest real-world gap between buses by time of day.

See [route4-tracker-spec.md](route4-tracker-spec.md) for the full build brief.

## Stack

- **Supabase** (Postgres, Edge Functions, pg_cron): data, polling, classification
- **Vercel**: read-only public dashboard
- **Data**: Metro static GTFS and GTFS-realtime feeds (no API key required)

## Layout

- `supabase/migrations/` database schema and jobs, applied in order
- `supabase/functions/load-gtfs` loads Route 4 from Metro's static GTFS zip
- `supabase/functions/poll-realtime` polls Metro's trip updates feed and records observations

## Polling

Metro's real-time feed is a snapshot of current predictions only (stops drop out once a bus passes), so history cannot be recovered later. The poller therefore runs every 2 minutes, weekdays only, inside each monitored stop's focus window plus 15 minutes of padding (currently 7:15-9:45 AM and 3:45-6:15 PM Pacific). The window check runs in Postgres before any function is invoked.

## Caveats

"Observed" times are the last predicted arrival seen before a vehicle dropped out of the real-time feed. They are a proxy, not true AVL timestamps. "No bus observed" can mean a bus did not run or that the tracking feed had a gap.

Transit scheduling, geographic, and real-time data provided by permission of King County.
