# rt4sux

A small, always-on tracker that records whether King County Metro Route 4 runs the trips it publishes, and how late they are, at a handful of Queen Anne and downtown stops.

Output is evidence a neighborhood group can hand to Metro and a city council office: scheduled versus observed trips, on-time performance, and the longest real-world gap between buses by time of day.

See [route4-tracker-spec.md](route4-tracker-spec.md) for the full build brief.

## Stack

- **Supabase** (Postgres, Edge Functions, pg_cron): data, polling, classification
- **Vercel**: read-only public dashboard
- **Data**: Metro static GTFS and GTFS-realtime feeds (no API key required)

## Layout

- `supabase/functions/` Edge Functions (`load-gtfs` loads Route 4 from Metro's GTFS zip)

## Caveats

"Observed" times are the last predicted arrival seen before a vehicle dropped out of the real-time feed. They are a proxy, not true AVL timestamps. "No bus observed" can mean a bus did not run or that the tracking feed had a gap.

Transit scheduling, geographic, and real-time data provided by permission of King County.
