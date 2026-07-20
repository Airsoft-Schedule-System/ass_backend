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
const NEUTRAL_REJECTION_SUBJECT = "참가 신청 결과 안내";
const BREVO_SEND_URL = "https://api.brevo.com/v3/smtp/email";
const EMAIL_REQUEST_TIMEOUT_MS = 3_000;

const ALWAYS_EMAIL_TYPES = new Set([
  "payment.requested",
  "payment.decision",
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
    // approve_participation also creates payment.requested. That notification
    // is the single canonical approval email; only rejections are sent here.
    if (notification.data?.decision !== "rejected") {
      return null;
    }

    return NEUTRAL_REJECTION_SUBJECT;
  }

  if (!ALWAYS_EMAIL_TYPES.has(notification.type)) {
    // participation.confirmed and every unlisted type remain in-app only.
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
  return error instanceof Error ? error.message : String(error);
}

Deno.serve(async (request) => {
  const expectedSecret = Deno.env.get("WEBHOOK_SECRET") || LOCAL_WEBHOOK_SECRET;
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

    const escapedBody = escapeHtml(notification.body).replaceAll("\n", "<br>");
    const escapedActionUrl = escapeHtml(notification.action_url);
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
        textContent: `${notification.body}\n\n앱에서 확인하기: ${notification.action_url}`,
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
