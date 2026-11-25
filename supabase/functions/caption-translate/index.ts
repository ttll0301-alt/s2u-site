// /captions 실시간 자막용 상황별 번역 (Gemini 무료 등급).
// 필요한 비밀값: GEMINI_API_KEY (Google AI Studio에서 무료 발급). 선택: GEMINI_MODEL.
// 키가 없으면 503을 돌려주고, 페이지는 기본 번역(Google)으로 자동 전환합니다.

const ALLOWED = ["https://sustaintoyou.com", "https://www.sustaintoyou.com"];

const TONES: Record<string, string> = {
  formal:
    "A formal setting: business meeting, ceremony, official event, or speaking to elders, clients or partners. " +
    "Use the polite/honorific register that a native speaker would naturally use there " +
    "(e.g. Japanese 敬語・です/ます, French vous, German Sie, Spanish usted, Chinese 您). Polished but still spoken, not written-document style.",
  daily:
    "Everyday situations with people you don't know well: shops, cafes, restaurants, taxis, hotels, travel, meeting someone new. " +
    "Friendly and polite, exactly how locals really talk day to day. Avoid stiff textbook phrasing.",
  friend:
    "Talking with close friends or peers of a similar age. Casual and warm, with the contractions and everyday colloquial " +
    "expressions locals actually use (e.g. Japanese タメ口, French tu, Spanish tú, Chinese 你). No vulgarity unless the speaker used it.",
  coach:
    "A running / workout session led by a coach: short, energetic, clear cues a native-speaking coach would actually shout or say " +
    "(pace, breathing, form, encouragement). Keep it punchy.",
};

function cors(origin: string) {
  const ok = ALLOWED.includes(origin) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  return {
    "Access-Control-Allow-Origin": ok ? origin : ALLOWED[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get("origin") ?? "");
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { ...h, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) return json({ error: "no_key" }, 503);

  let body: { text?: string; lang?: string; langName?: string; tone?: string; context?: string[] };
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const text = String(body.text ?? "").trim().slice(0, 600);
  const langName = String(body.langName ?? body.lang ?? "English").slice(0, 60);
  const tone = TONES[String(body.tone)] ? String(body.tone) : "daily";
  const context = (Array.isArray(body.context) ? body.context : []).slice(-2).map((s) => String(s).slice(0, 300));
  if (!text) return json({ text: "" });

  const system =
    `You are a live interpreter. Translate a Korean speech-recognition transcript into ${langName}.\n` +
    `Setting: ${TONES[tone]}\n` +
    "Rules: The transcript may lack punctuation or contain recognition errors; infer what the speaker meant. " +
    "Say it the way a native speaker in this setting really would, not word for word. Keep names of people, brands and places. " +
    "Output ONLY the translation as one line: no quotes, romanization, notes or alternatives.";
  const user = (context.length ? `Earlier (for context only, do not translate): ${context.join(" / ")}\n` : "") +
    `Translate: ${text}`;

  const model = Deno.env.get("GEMINI_MODEL") || "gemini-flash-lite-latest";
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": key },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: system }] },
      contents: [{ role: "user", parts: [{ text: user }] }],
      generationConfig: { temperature: 0.3, maxOutputTokens: 400 },
    }),
  });
  if (r.status === 429) return json({ error: "rate" }, 429);
  if (!r.ok) return json({ error: "upstream", status: r.status }, 502);
  const j = await r.json();
  const out = (j?.candidates?.[0]?.content?.parts ?? []).map((p: { text?: string }) => p.text ?? "").join("").trim();
  return json({ text: out.replace(/^["“]|["”]$/g, "") });
});
