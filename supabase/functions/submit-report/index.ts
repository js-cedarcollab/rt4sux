// Public endpoint for rider reports (including "I gave up on the bus").
// The only write path into rider_reports. No login: protection is strict validation,
// a honeypot field, and hashed-IP rate limiting. Nothing about the caller is stored but the hash.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
};
const OUTCOMES = ["on_time", "late", "never_came", "bypassed_or_full", "other", "gave_up"];
const ALTERNATIVES = ["walked", "drove", "rideshare", "other_route", "other"];
const HOURLY_LIMIT = 8;
const DAILY_LIMIT = 30;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const raw = await req.text();
  if (raw.length > 4096) return json({ error: "Too large" }, 413);
  let b: Record<string, unknown>;
  try { b = JSON.parse(raw); } catch { return json({ error: "Invalid JSON" }, 400); }

  // Honeypot: real people leave this empty. Pretend success so bots learn nothing.
  if (typeof b.website === "string" && b.website.length > 0) return json({ ok: true });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const stopId = String(b.stop_id ?? "");
  const what = String(b.what_happened ?? "");
  if (!OUTCOMES.includes(what)) return json({ error: "Unknown outcome" }, 400);

  const { data: stop } = await db.from("stops").select("stop_id").eq("stop_id", stopId).eq("active", true).maybeSingle();
  if (!stop) return json({ error: "Unknown stop" }, 400);

  let scheduled: string | null = null;
  if (b.scheduled_time != null && b.scheduled_time !== "") {
    const t = new Date(String(b.scheduled_time));
    const ageH = (Date.now() - t.getTime()) / 3.6e6;
    if (isNaN(t.getTime()) || ageH > 36 || ageH < -12) return json({ error: "Bad scheduled time" }, 400);
    scheduled = t.toISOString();
  }

  let minutes: number | null = null;
  if (b.minutes_waited != null && b.minutes_waited !== "") {
    minutes = Math.round(Number(b.minutes_waited));
    if (!Number.isFinite(minutes) || minutes < 0 || minutes > 240) return json({ error: "Bad minutes" }, 400);
  }

  let alternative: string | null = null;
  if (b.alternative != null && b.alternative !== "") {
    alternative = String(b.alternative);
    if (!ALTERNATIVES.includes(alternative)) return json({ error: "Bad alternative" }, 400);
  }

  const note = typeof b.note === "string" ? b.note.trim().slice(0, 500) || null : null;
  const label = typeof b.reporter_label === "string" ? b.reporter_label.trim().slice(0, 60) || null : null;

  // Rate limit on a salted hash of the caller's IP
  const ip = (req.headers.get("x-forwarded-for") ?? "unknown").split(",")[0].trim();
  const ipHash = await sha256(`${ip}|${Deno.env.get("SUPABASE_URL")}`);
  const hourAgo = new Date(Date.now() - 3.6e6).toISOString();
  const dayAgo = new Date(Date.now() - 864e5).toISOString();
  const [{ count: h }, { count: d }] = await Promise.all([
    db.from("report_rate").select("*", { count: "exact", head: true }).eq("ip_hash", ipHash).gte("at", hourAgo),
    db.from("report_rate").select("*", { count: "exact", head: true }).eq("ip_hash", ipHash).gte("at", dayAgo),
  ]);
  if ((h ?? 0) >= HOURLY_LIMIT || (d ?? 0) >= DAILY_LIMIT) return json({ error: "Too many reports, try later" }, 429);
  await db.from("report_rate").insert({ ip_hash: ipHash });
  await db.from("report_rate").delete().lt("at", dayAgo);

  // Service date is the Pacific calendar day of the trip (or of now, for a give-up with no trip)
  const ref = scheduled ? new Date(scheduled) : new Date();
  const serviceDate = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles" }).format(ref);

  const { error } = await db.from("rider_reports").insert({
    service_date: serviceDate, stop_id: stopId, scheduled_time: scheduled, what_happened: what,
    minutes_waited: minutes, alternative, note, reporter_label: label,
  });
  if (error) return json({ error: "Could not save" }, 500);
  return json({ ok: true });
});
