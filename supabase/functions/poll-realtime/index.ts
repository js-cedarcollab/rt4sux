// Polls Metro's GTFS-realtime trip updates, keeps Route 4 only, and upserts one
// observation per trip per monitored stop. Invoked by pg_cron through
// public.run_poll_if_in_window(), which only fires on weekdays inside the focus windows.
// Auth: x-job-secret header, verified via public.verify_job_secret.
import { createClient } from "npm:@supabase/supabase-js@2";
import GtfsRealtimeBindings from "npm:gtfs-realtime-bindings@1.1.1";

const FEED_URL = "https://s3.amazonaws.com/kcm-alerts-realtime-prod/tripupdates.pb";
const TRIP_REL = ["SCHEDULED", "ADDED", "UNSCHEDULED", "CANCELED", "REPLACEMENT", "DUPLICATED", "DELETED"];
const STOP_REL = ["SCHEDULED", "SKIPPED", "NO_DATA", "UNSCHEDULED"];

// protobufjs may hand back Long objects for 64-bit fields
// deno-lint-ignore no-explicit-any
const num = (x: any): number | null =>
  x == null ? null : typeof x === "object" && "toNumber" in x ? x.toNumber() : Number(x);

const iso = (sec: number | null) => (sec ? new Date(sec * 1000).toISOString() : null);

Deno.serve(async (req) => {
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: ok } = await db.rpc("verify_job_secret", {
    p_secret: req.headers.get("x-job-secret") ?? "",
  });
  if (ok !== true) return new Response("unauthorized", { status: 401 });

  const log = async (row: Record<string, unknown>) => {
    await db.from("poll_log").insert({ source: "metro_gtfs_rt", ...row });
  };

  let httpStatus: number | null = null;
  try {
    const [{ data: cfg }, { data: stops }] = await Promise.all([
      db.from("config").select("value").eq("key", "route_id").single(),
      db.from("stops").select("stop_id").eq("active", true),
    ]);
    const routeId = String(cfg?.value ?? "100219");
    const monitored = new Set((stops ?? []).map((s) => s.stop_id));

    const res = await fetch(FEED_URL, { headers: { "User-Agent": "rt4sux-reliability-tracker/1.0" } });
    httpStatus = res.status;
    if (!res.ok) throw new Error(`feed HTTP ${res.status}`);
    const feed = GtfsRealtimeBindings.transit_realtime.FeedMessage.decode(
      new Uint8Array(await res.arrayBuffer()),
    );
    const feedTs = num(feed.header.timestamp);

    const rows: Record<string, unknown>[] = [];
    const raw: unknown[] = [];
    let route4 = 0;
    let withVehicle = 0;
    const notes: string[] = [];

    for (const e of feed.entity) {
      const tu = e.tripUpdate;
      if (!tu || tu.trip?.routeId !== routeId) continue;
      route4++;
      const tripRel = TRIP_REL[tu.trip?.scheduleRelationship ?? 0] ?? "UNKNOWN";
      const vehicleId = tu.vehicle?.id || null;
      if (vehicleId) withVehicle++;
      if (tripRel !== "SCHEDULED") notes.push(`trip ${tu.trip?.tripId} ${tripRel}`);
      const d = tu.trip?.startDate ?? "";
      const serviceDate = `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}`;

      raw.push({
        trip_id: tu.trip?.tripId, rel: tripRel, vehicle: vehicleId,
        stops: (tu.stopTimeUpdate ?? []).filter((s) => monitored.has(s.stopId ?? "")).map((s) => ({
          stop_id: s.stopId, seq: s.stopSequence,
          arr: num(s.arrival?.time), dep: num(s.departure?.time), delay: num(s.arrival?.delay),
          rel: STOP_REL[s.scheduleRelationship ?? 0],
        })),
      });

      for (const su of tu.stopTimeUpdate ?? []) {
        if (!monitored.has(su.stopId ?? "")) continue;
        const stopRel = STOP_REL[su.scheduleRelationship ?? 0] ?? "UNKNOWN";
        const t = num(su.arrival?.time) ?? num(su.departure?.time);
        const relationship = tripRel !== "SCHEDULED" ? tripRel : stopRel !== "SCHEDULED" ? stopRel : null;
        rows.push({
          service_date: serviceDate,
          trip_id: tu.trip?.tripId,
          stop_id: su.stopId,
          // Schedule-only entries (no vehicle) carry no live prediction, so store none.
          predicted: vehicleId ? iso(t) : null,
          has_rt: Boolean(vehicleId && t),
          vehicle_id: vehicleId,
          relationship,
        });
      }
    }

    if (rows.length) {
      const { error } = await db.rpc("upsert_observations", { p: rows });
      if (error) throw new Error(`upsert_observations: ${error.message}`);
    }
    await db.from("raw_polls").insert({ source: "metro_gtfs_rt", payload: { feed_ts: feedTs, trips: raw } });
    await log({
      success: true, http_status: httpStatus, feed_timestamp: iso(feedTs),
      entities_seen: feed.entity.length, route4_entities: route4,
      error_text: notes.length ? notes.slice(0, 20).join("; ") : null,
    });
    return Response.json({
      feed_ts: iso(feedTs), entities: feed.entity.length, route4, with_vehicle: withVehicle,
      observations_upserted: rows.length, notes,
    });
  } catch (e) {
    await log({ success: false, http_status: httpStatus, error_text: String(e).slice(0, 500) });
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
