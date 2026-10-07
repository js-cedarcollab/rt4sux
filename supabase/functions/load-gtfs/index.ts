// Loads Route 4 data from Metro's static GTFS zip into Postgres.
// Streams the zip (stop_times.txt is ~66 MB uncompressed) and keeps only Route 4 rows.
// Two passes over the zip so stop_times can be filtered by the trips found in pass one.
// Auth: x-job-secret header, verified against private.secrets via public.verify_job_secret.
import { createClient } from "npm:@supabase/supabase-js@2";
import { Unzip, UnzipInflate } from "npm:fflate@0.8.2";

// Plain HTTP on purpose: metro.kingcounty.gov resets TLS handshakes from the Supabase Edge
// runtime (verified Oct 2026). The loader sanity-checks what it loads (non-empty Route 4 set).
const GTFS_URL = "http://metro.kingcounty.gov/GTFS/google_transit.zip";

function parseCsvLine(line: string): string[] {
  const out: string[] = [];
  let cur = "";
  let q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; } else q = false;
      } else cur += c;
    } else if (c === '"') q = true;
    else if (c === ",") { out.push(cur); cur = ""; }
    else cur += c;
  }
  out.push(cur);
  return out;
}

function secs(t: string): number {
  const [h, m, s] = t.trim().split(":").map(Number);
  return h * 3600 + m * 60 + s;
}

// Streams the zip; for each wanted file calls onRow(headerIndexMap, fields) per CSV row.
async function streamZip(
  wanted: Record<string, (idx: Record<string, number>, f: string[]) => void>,
) {
  const res = await fetch(GTFS_URL, {
    headers: {
      "User-Agent": "Mozilla/5.0 (compatible; rt4sux-reliability-tracker/1.0)",
      "Accept": "application/zip,*/*",
    },
  });
  if (!res.ok || !res.body) throw new Error(`GTFS download failed: HTTP ${res.status}`);
  const unzip = new Unzip();
  unzip.register(UnzipInflate);
  unzip.onfile = (file) => {
    const handler = wanted[file.name];
    if (!handler) return;
    const dec = new TextDecoder();
    let buf = "";
    let idx: Record<string, number> | null = null;
    const line = (l: string) => {
      l = l.replace(/\r$/, "");
      if (!l) return;
      const f = parseCsvLine(l);
      if (!idx) {
        idx = {};
        f.forEach((h, i) => (idx![h.replace(/^﻿/, "")] = i));
      } else handler(idx, f);
    };
    file.ondata = (err, data, final) => {
      if (err) throw err;
      buf += dec.decode(data, { stream: !final });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        line(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
      }
      if (final && buf) line(buf);
    };
    file.start();
  };
  const reader = res.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) { unzip.push(new Uint8Array(0), true); break; }
    unzip.push(value);
  }
}

async function upsertBatches(
  db: ReturnType<typeof createClient>,
  table: string,
  rows: Record<string, unknown>[],
  onConflict: string,
) {
  for (let i = 0; i < rows.length; i += 1000) {
    const { error } = await db.from(table).upsert(rows.slice(i, i + 1000), { onConflict });
    if (error) throw new Error(`${table}: ${error.message}`);
  }
}

Deno.serve(async (req) => {
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: ok } = await db.rpc("verify_job_secret", {
    p_secret: req.headers.get("x-job-secret") ?? "",
  });
  if (ok !== true) return new Response("unauthorized", { status: 401 });

  try {
    const { data: cfg } = await db.from("config").select("value").eq("key", "route_id").single();
    const routeId = String(cfg?.value ?? "100219");

    // Pass 1: trips, calendars, feed info
    const trips: Record<string, unknown>[] = [];
    const tripIds = new Set<string>();
    const services = new Set<string>();
    let feed: Record<string, unknown> | null = null;
    const calendar: Record<string, string[]>[] = [];
    const calRows: { idx: Record<string, number>; f: string[] }[] = [];
    const calDateRows: { idx: Record<string, number>; f: string[] }[] = [];

    await streamZip({
      "trips.txt": (i, f) => {
        if (f[i.route_id] !== routeId) return;
        tripIds.add(f[i.trip_id]);
        services.add(f[i.service_id]);
        trips.push({
          trip_id: f[i.trip_id],
          service_id: f[i.service_id],
          direction_id: Number(f[i.direction_id]),
          headsign: f[i.trip_headsign] || null,
          block_id: f[i.block_id] || null,
        });
      },
      "calendar.txt": (i, f) => { calRows.push({ idx: i, f }); },
      "calendar_dates.txt": (i, f) => { calDateRows.push({ idx: i, f }); },
      "feed_info.txt": (i, f) => {
        const d = (s: string) => `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;
        feed = {
          id: 1,
          feed_version: f[i.feed_version],
          feed_start_date: d(f[i.feed_start_date]),
          feed_end_date: d(f[i.feed_end_date]),
          loaded_at: new Date().toISOString(),
        };
      },
    });
    void calendar;

    const d = (s: string) => `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;
    const calendarOut = calRows
      .filter(({ idx, f }) => services.has(f[idx.service_id]))
      .map(({ idx: i, f }) => ({
        service_id: f[i.service_id],
        monday: f[i.monday] === "1", tuesday: f[i.tuesday] === "1",
        wednesday: f[i.wednesday] === "1", thursday: f[i.thursday] === "1",
        friday: f[i.friday] === "1", saturday: f[i.saturday] === "1",
        sunday: f[i.sunday] === "1",
        start_date: d(f[i.start_date]), end_date: d(f[i.end_date]),
      }));
    const calDatesOut = calDateRows
      .filter(({ idx, f }) => services.has(f[idx.service_id]))
      .map(({ idx: i, f }) => ({
        service_id: f[i.service_id],
        service_date: d(f[i.date]),
        exception_type: Number(f[i.exception_type]),
      }));

    // Pass 2: stop_times for Route 4 trips only
    const stopTimes: Record<string, unknown>[] = [];
    await streamZip({
      "stop_times.txt": (i, f) => {
        if (!tripIds.has(f[i.trip_id])) return;
        stopTimes.push({
          trip_id: f[i.trip_id],
          stop_sequence: Number(f[i.stop_sequence]),
          stop_id: f[i.stop_id],
          arrival_secs: secs(f[i.arrival_time]),
          departure_secs: secs(f[i.departure_time]),
          timepoint: f[i.timepoint] === "1",
        });
      },
    });

    if (trips.length === 0) throw new Error(`No trips found for route ${routeId}; refusing to load`);

    await upsertBatches(db, "gtfs_trips", trips, "trip_id");
    await upsertBatches(db, "gtfs_calendar", calendarOut, "service_id");
    await upsertBatches(db, "gtfs_calendar_dates", calDatesOut, "service_id,service_date");
    await upsertBatches(db, "gtfs_stop_times", stopTimes, "trip_id,stop_sequence");
    if (feed) await upsertBatches(db, "gtfs_feed_info", [feed], "id");

    return Response.json({
      route_id: routeId,
      feed_version: (feed as Record<string, unknown> | null)?.feed_version,
      trips: trips.length,
      stop_times: stopTimes.length,
      calendar: calendarOut.length,
      calendar_dates: calDatesOut.length,
    });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
