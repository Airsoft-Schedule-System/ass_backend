import { createClient } from "npm:@supabase/supabase-js@2";

type JsonObject = Record<string, unknown>;

interface NotificationRow {
  user_id: string;
  type: string;
  title: string;
  body: string;
  action_url: string;
  data: JsonObject | null;
}

interface EmailSender {
  email: string;
  name?: string;
}

const LOCAL_WEBHOOK_SECRET = "local-dev-secret";
const MAX_BODY_BYTES = 16 * 1024;

// 배포 환경에서는 WEBHOOK_SECRET 미설정 시 fail-closed 한다.
// 이 저장소는 public 이라 LOCAL_WEBHOOK_SECRET 값이 공개돼 있고
// verify_jwt = false 라 함수가 인터넷에 열려 있다. 폴백을 그대로 두면
// 누구나 등록 사용자에게 임의 제목·본문으로 메일을 보낼 수 있다.
function isHostedEnvironment(): boolean {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  return url.includes(".supabase.co") || url.includes(".supabase.in");
}

// action_url 은 알림 행에서 오며, 폴백 시크릿이 통하는 상황에서는
// 공격자가 정할 수 있다. 절대 URL 을 허용하면 신뢰 발신자 명의의
// 피싱 링크가 되므로 상대 경로만 받는다.
function toAbsoluteActionUrl(actionUrl: string): string | null {
  if (!actionUrl.startsWith("/") || actionUrl.startsWith("//")) {
    return null;
  }

  const base = Deno.env.get("APP_BASE_URL");
  if (!base) {
    return actionUrl;
  }

  return `${base.replace(/\/+$/, "")}${actionUrl}`;
}
const NEUTRAL_REJECTION_SUBJECT = "참가 신청 결과 안내";
const BREVO_SEND_URL = "https://api.brevo.com/v3/smtp/email";
const EMAIL_REQUEST_TIMEOUT_MS = 3_000;

const ALWAYS_EMAIL_TYPES = new Set([
  "session.upcoming_reminder",
  "session.changed",
]);

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseNotification(payload: unknown): NotificationRow | null {
  if (!isJsonObject(payload)) {
    return null;
  }

  // The 4b pg_net trigger sends the row directly. Accepting the standard
  // Database Webhook envelope as well keeps the adapter easy to rewire.
  const source = isJsonObject(payload.record) ? payload.record : payload;
  const { user_id, type, title, body, action_url, data } = source;

  if (
    typeof user_id !== "string" ||
    typeof type !== "string" ||
    typeof title !== "string" ||
    typeof body !== "string" ||
    typeof action_url !== "string"
  ) {
    return null;
  }

  return {
    user_id,
    type,
    title,
    body,
    action_url,
    data: isJsonObject(data) ? data : null,
  };
}

function emailSubject(notification: NotificationRow): string | null {
  if (notification.type === "participation.decision") {
    // 선입금 폐기로 payment.requested가 사라졌다. 이제 승인 자체가
    // 앱 밖으로 나가야 할 유일한 확정 신호이므로 승인도 메일로 보낸다.
    // 반려는 제3자가 제목만 봐도 알 수 없도록 중립 문구를 쓴다.
    return notification.data?.decision === "rejected"
      ? NEUTRAL_REJECTION_SUBJECT
      : notification.title;
  }

  if (!ALWAYS_EMAIL_TYPES.has(notification.type)) {
    // participation.confirmed는 승인과 같은 순간에 발생해 위 메일과 중복이므로
    // 인앱 전용으로 남긴다. 목록에 없는 타입도 마찬가지.
    return null;
  }

  return notification.title;
}

function jsonResponse(status: number, body: JsonObject): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function success(reason: string): Response {
  return jsonResponse(200, { ok: true, reason });
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function parseSender(value: string): EmailSender {
  const namedSender = value.match(/^\s*(.*?)\s*<\s*([^<>]+)\s*>\s*$/);

  if (namedSender) {
    const name = namedSender[1].trim();
    const email = namedSender[2].trim();
    return name ? { email, name } : { email };
  }

  return { email: value.trim() };
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  // Supabase/PostgREST errors are plain objects (message/code/hint), not Error
  // instances — String() would flatten them to "[object Object]".
  if (isJsonObject(error)) {
    return JSON.stringify(error);
  }
  return String(error);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "method-not-allowed" });
  }

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    return jsonResponse(413, { ok: false, error: "payload-too-large" });
  }

  const configuredSecret = Deno.env.get("WEBHOOK_SECRET");

  if (!configuredSecret && isHostedEnvironment()) {
    // 로컬 폴백으로 조용히 동작하면 안 된다. 설정 누락을 드러낸다.
    console.error("send-email refused: WEBHOOK_SECRET is not configured");
    return jsonResponse(503, { ok: false, error: "not-configured" });
  }

  const expectedSecret = configuredSecret || LOCAL_WEBHOOK_SECRET;
  const suppliedSecret = request.headers.get("x-webhook-secret");

  if (suppliedSecret !== expectedSecret) {
    return jsonResponse(401, { ok: false, error: "unauthorized" });
  }

  try {
    const notification = parseNotification(await request.json());

    if (!notification) {
      console.error("send-email ignored an invalid notification payload");
      return success("invalid-payload");
    }

    const subject = emailSubject(notification);

    if (!subject) {
      return success("filtered");
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error("Supabase service-role environment is not configured");
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    const { data: user, error: userError } = await supabase
      .from("users")
      .select("email")
      .eq("id", notification.user_id)
      .maybeSingle();

    if (userError) {
      throw userError;
    }

    const recipientEmail = typeof user?.email === "string"
      ? user.email.trim()
      : "";

    if (!recipientEmail) {
      return success("no-email");
    }

    const emailApiKey = Deno.env.get("EMAIL_API_KEY");
    const dryRun = !emailApiKey || Deno.env.get("EMAIL_DRY_RUN") === "1";

    if (dryRun) {
      console.log(`would email ${recipientEmail}: ${subject}`);
      return success("dry-run");
    }

    const emailFrom = Deno.env.get("EMAIL_FROM");

    if (!emailFrom) {
      throw new Error("EMAIL_FROM is not configured");
    }

    const actionUrl = toAbsoluteActionUrl(notification.action_url);

    if (!actionUrl) {
      // 상대 경로가 아닌 링크는 신뢰 발신자 명의의 외부 유도가 된다.
      console.error(`send-email rejected a non-relative action_url: ${notification.action_url}`);
      return success("invalid-action-url");
    }

    const escapedBody = escapeHtml(notification.body).replaceAll("\n", "<br>");
    const escapedActionUrl = escapeHtml(actionUrl);
    const response = await fetch(BREVO_SEND_URL, {
      method: "POST",
      signal: AbortSignal.timeout(EMAIL_REQUEST_TIMEOUT_MS),
      headers: {
        "Content-Type": "application/json",
        "api-key": emailApiKey,
      },
      body: JSON.stringify({
        sender: parseSender(emailFrom),
        to: [{ email: recipientEmail }],
        subject,
        textContent: `${notification.body}\n\n앱에서 확인하기: ${actionUrl}`,
        htmlContent: [
          `<p>${escapedBody}</p>`,
          `<p><a href="${escapedActionUrl}">앱에서 확인하기</a></p>`,
        ].join(""),
      }),
    });

    if (!response.ok) {
      const responseBody = (await response.text()).slice(0, 500);
      throw new Error(`Brevo request failed (${response.status}): ${responseBody}`);
    }

    return success("sent");
  } catch (error) {
    console.error(`send-email failed: ${errorMessage(error)}`);
    return success("failed");
  }
});
