// 5분마다 호출: 만료 정리 → 미입금 안내 예약 → 발송 대기열 처리.
// 실제 발송은 세 조건이 모두 맞아야 합니다.
//   1) 환경변수 SMS_MODE=live  2) 업체 키·발신번호 설정  3) 해당 행사에서 호스트가 '실발송'을 켬(sms_live)
// 하나라도 아니면 문구를 만들어 rsvp_outbox에 test_logged로만 기록하고 어디에도 보내지 않습니다.
import { createClient } from "npm:@supabase/supabase-js@2";
import { getProvider } from "../_shared/sms.ts";

const MAX_ATTEMPTS = 3;
const RETRY_MINUTES = [5, 15, 60];

function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET") ?? "";
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!secret || !safeEqual(secret, given)) return new Response("unauthorized", { status: 401 });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const provider = getProvider();
  const modeLive = (Deno.env.get("SMS_MODE") ?? "test") === "live" && provider.configured();
  const from = Deno.env.get("SMS_FROM") ?? "";

  const tick = await sb.rpc("rsvp_tick");
  if (tick.error) return Response.json({ error: tick.error.message }, { status: 500 });

  const claimed = await sb.rpc("rsvp_claim_outbox", { p_limit: 50 });
  if (claimed.error) return Response.json({ error: claimed.error.message }, { status: 500 });

  const stats = { sent: 0, test_logged: 0, skipped: 0, retry: 0, failed: 0 };
  for (const row of claimed.data ?? []) {
    // 발송 직전에 최신 입금·취소 상태를 다시 확인
    const prep = await sb.rpc("rsvp_outbox_prepare", { p_id: row.id });
    if (prep.error) { await sb.rpc("rsvp_outbox_finish", { p_id: row.id, p_status: "retry", p_error: prep.error.message, p_retry_minutes: 5 }); stats.retry++; continue; }
    const p = prep.data as { action: string; reason?: string; live?: boolean; to?: string; body?: string };

    if (p.action === "skip") {
      await sb.rpc("rsvp_outbox_finish", { p_id: row.id, p_status: "skipped", p_reason: p.reason });
      stats.skipped++; continue;
    }

    if (!(modeLive && p.live)) {
      await sb.rpc("rsvp_outbox_finish", {
        p_id: row.id, p_status: "test_logged", p_provider: "test", p_provider_status: "not_sent",
        p_body: p.body, p_to: p.to,
      });
      stats.test_logged++; continue;
    }

    try {
      const r = await provider.send({ to: p.to!, text: p.body!, from });
      await sb.rpc("rsvp_outbox_finish", {
        p_id: row.id, p_status: "sent", p_provider: provider.name, p_msg_id: r.id,
        p_provider_status: r.status, p_body: p.body, p_to: p.to,
      });
      stats.sent++;
    } catch (err) {
      const msg = String((err as Error).message ?? err).slice(0, 500);
      if (row.attempts >= MAX_ATTEMPTS) {
        await sb.rpc("rsvp_outbox_finish", { p_id: row.id, p_status: "failed", p_provider: provider.name, p_error: msg, p_body: p.body, p_to: p.to });
        stats.failed++;
      } else {
        await sb.rpc("rsvp_outbox_finish", {
          p_id: row.id, p_status: "retry", p_provider: provider.name, p_error: msg,
          p_retry_minutes: RETRY_MINUTES[Math.min(row.attempts - 1, RETRY_MINUTES.length - 1)],
        });
        stats.retry++;
      }
    }
  }
  return Response.json({ mode: modeLive ? "live" : "test", tick: tick.data, ...stats });
});
