// 문자 발송 업체 어댑터. 업체를 바꾸려면 SmsProvider를 구현하고 getProvider()에 등록하세요.
export interface SmsMessage { to: string; text: string; from: string }
export interface SmsResult { id: string; status: string }   // status = 업체가 접수한 상태 (단말기 수신을 보장하지 않음)
export interface SmsProvider {
  name: string;
  configured(): boolean;
  send(msg: SmsMessage): Promise<SmsResult>;
}

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

// Solapi (https://developers.solapi.com) — HMAC-SHA256 인증, POST /messages/v4/send
// 실제 계정으로 아직 검증하지 않았습니다. 연동 시 먼저 SMS_MODE=test 로 기록만 확인한 뒤 본인 번호로 1건 테스트하세요.
class SolapiProvider implements SmsProvider {
  name = "solapi";
  private key = Deno.env.get("SOLAPI_API_KEY") ?? "";
  private secret = Deno.env.get("SOLAPI_API_SECRET") ?? "";
  configured() { return !!this.key && !!this.secret && !!Deno.env.get("SMS_FROM"); }
  async send(m: SmsMessage): Promise<SmsResult> {
    const date = new Date().toISOString();
    const salt = crypto.randomUUID().replaceAll("-", "");
    const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(this.secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sig = hex(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(date + salt)));
    // 한글은 2바이트로 계산해 90바이트 초과 시 LMS
    const bytes = [...m.text].reduce((n, c) => n + (c.charCodeAt(0) > 127 ? 2 : 1), 0);
    const res = await fetch("https://api.solapi.com/messages/v4/send", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `HMAC-SHA256 apiKey=${this.key}, date=${date}, salt=${salt}, signature=${sig}`,
      },
      body: JSON.stringify({ message: { to: m.to, from: m.from, text: m.text, type: bytes > 90 ? "LMS" : "SMS" } }),
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`solapi ${res.status}: ${j.errorMessage ?? j.errorCode ?? "unknown"}`);
    return { id: String(j.messageId ?? j.groupId ?? ""), status: "accepted" };
  }
}

// 개발용: 아무 곳에도 보내지 않고 로그만 남깁니다.
class ConsoleProvider implements SmsProvider {
  name = "console";
  configured() { return true; }
  send(m: SmsMessage): Promise<SmsResult> {
    console.log(`[console-sms] to=${m.to}\n${m.text}`);
    return Promise.resolve({ id: "console", status: "logged" });
  }
}

export function getProvider(): SmsProvider {
  switch ((Deno.env.get("SMS_PROVIDER") ?? "solapi").toLowerCase()) {
    case "console": return new ConsoleProvider();
    case "solapi":
    default: return new SolapiProvider();
  }
}
