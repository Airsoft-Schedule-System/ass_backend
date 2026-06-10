// ERD §7 컬렉션 레이아웃 — 컬렉션명 단일 출처
export const COLLECTIONS = {
  USERS: "users",
  TEAMS: "teams",
  FIELDS: "fields",
  GAME_RULE_PRESETS: "gameRulePresets",
  GAME_SESSIONS: "gameSessions",
  PARTICIPATIONS: "participations",
  PAYMENT_SUBMISSIONS: "paymentSubmissions",
  REFUND_REQUESTS: "refundRequests",
  ENTRY_PASSES: "entryPasses",
  NOTIFICATIONS: "notifications"
} as const;

export const SUBCOLLECTIONS = {
  FCM_TOKENS: "fcmTokens"
} as const;
