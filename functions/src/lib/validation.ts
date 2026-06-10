// B1-6 프로필 필수값 서버 검증 + 입력 검증 헬퍼 (순수 함수)
import { errFailedPrecondition, errInvalidArgument } from "./errors";
import { IMMUTABLE_SESSION_FIELDS } from "./seams";

const UPDATE_SESSION_FIELDS = new Set([
  "title",
  "customRules",
  "cancelDeadline",
  "capacity",
  "gameFee",
  "endsAt"
]);
const ONE_DAY_MS = 24 * 60 * 60 * 1000;
const SEVEN_DAYS_MS = 7 * ONE_DAY_MS;

// ERD §5.1: displayName required, phoneNumber nullable → 필수값은 displayName
export const REQUIRED_PROFILE_FIELDS = ["displayName"] as const;

export interface ProfileView {
  displayName?: string | null;
}

export function isProfileComplete(user: ProfileView): boolean {
  return typeof user.displayName === "string" && user.displayName.trim().length > 0;
}

export function assertProfileComplete(user: ProfileView): void {
  if (!isProfileComplete(user)) {
    throw errFailedPrecondition("프로필(닉네임)을 먼저 완성해주세요");
  }
}

export function asNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw errInvalidArgument(`${field}는 필수 문자열입니다`);
  }
  return value;
}

export function optionalString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

export interface CreateGameSessionRaw {
  title?: unknown;
  capacity?: unknown;
  gameFee?: unknown;
  fieldId?: unknown;
  fieldName?: unknown;
  presetId?: unknown;
  customRules?: unknown;
}

/**
 * createGameSession 입력 검증 (api-spec §2.2). startsAt 미래 검증은 Timestamp 변환이 필요해
 * 콜러블에서 별도 수행한다. 본 함수는 동기·순수 규칙만 검사한다.
 */
export function validateCreateGameSessionInput(data: CreateGameSessionRaw): void {
  asNonEmptyString(data.title, "title");

  // 1) fieldId XOR fieldName
  const hasFieldId = typeof data.fieldId === "string" && data.fieldId.length > 0;
  const hasFieldName = typeof data.fieldName === "string" && data.fieldName.length > 0;
  if (hasFieldId === hasFieldName) {
    throw errInvalidArgument("fieldId 또는 fieldName 중 정확히 하나를 제공해야 합니다");
  }

  // 3) capacity > 0, gameFee >= 0
  if (typeof data.capacity !== "number" || !Number.isInteger(data.capacity) || data.capacity < 1) {
    throw errInvalidArgument("capacity는 1 이상의 정수여야 합니다");
  }
  if (typeof data.gameFee !== "number" || Number.isNaN(data.gameFee) || data.gameFee < 0) {
    throw errInvalidArgument("gameFee는 0 이상이어야 합니다");
  }

  // 4) presetId XOR customRules
  const hasPreset = typeof data.presetId === "string" && data.presetId.length > 0;
  const hasCustom = data.customRules != null && typeof data.customRules === "object";
  if (hasPreset === hasCustom) {
    throw errInvalidArgument("presetId 또는 customRules 중 정확히 하나를 제공해야 합니다");
  }
}

function hasToMillis(value: unknown): value is { toMillis(): number } {
  return (
    value != null &&
    typeof value === "object" &&
    typeof (value as { toMillis?: unknown }).toMillis === "function"
  );
}

export function validateSessionUpdates(
  updates: Record<string, unknown>,
  session: {
    capacity: number;
    confirmedCount: number;
    presetId: string | null;
    startsAtMs: number;
  },
  cancelDeadlineMs?: number
): string[] {
  const updatedFields = Object.keys(updates);
  if (updatedFields.length === 0) {
    throw errInvalidArgument("updates에 변경할 필드가 없습니다");
  }

  for (const field of updatedFields) {
    if (
      (IMMUTABLE_SESSION_FIELDS as readonly string[]).includes(field) ||
      !UPDATE_SESSION_FIELDS.has(field)
    ) {
      throw errInvalidArgument(`${field}는 변경할 수 없는 필드입니다`);
    }
  }

  if ("title" in updates) {
    asNonEmptyString(updates.title, "updates.title");
  }

  if ("customRules" in updates) {
    if (session.presetId != null) {
      throw errFailedPrecondition("프리셋 세션은 customRules를 변경할 수 없습니다");
    }
    if (
      updates.customRules == null ||
      typeof updates.customRules !== "object" ||
      Array.isArray(updates.customRules)
    ) {
      throw errInvalidArgument("updates.customRules는 객체여야 합니다");
    }
  }

  if ("capacity" in updates) {
    if (
      typeof updates.capacity !== "number" ||
      !Number.isInteger(updates.capacity) ||
      updates.capacity < 1
    ) {
      throw errInvalidArgument("updates.capacity는 1 이상의 정수여야 합니다");
    }
    if (updates.capacity <= session.capacity) {
      throw errFailedPrecondition("capacity는 현재 값보다 크게만 변경할 수 있습니다");
    }
    if (updates.capacity < session.confirmedCount) {
      throw errFailedPrecondition("capacity는 확정 인원보다 작을 수 없습니다");
    }
  }

  if ("gameFee" in updates) {
    if (
      typeof updates.gameFee !== "number" ||
      Number.isNaN(updates.gameFee) ||
      updates.gameFee < 0
    ) {
      throw errInvalidArgument("updates.gameFee는 0 이상이어야 합니다");
    }
    if (session.confirmedCount > 0) {
      throw errFailedPrecondition("확정 참가자가 있으면 gameFee를 변경할 수 없습니다");
    }
  }

  if ("cancelDeadline" in updates) {
    if (typeof cancelDeadlineMs !== "number") {
      throw errInvalidArgument("updates.cancelDeadline는 유효한 시각이어야 합니다");
    }
    const min = session.startsAtMs - SEVEN_DAYS_MS;
    const max = session.startsAtMs - ONE_DAY_MS;
    if (cancelDeadlineMs < min || cancelDeadlineMs > max) {
      throw errInvalidArgument("cancelDeadline은 시작 7일 전부터 24시간 전 사이여야 합니다");
    }
  }

  if ("endsAt" in updates) {
    if (!hasToMillis(updates.endsAt)) {
      throw errInvalidArgument("updates.endsAt는 유효한 시각이어야 합니다");
    }
    if (updates.endsAt.toMillis() <= session.startsAtMs) {
      throw errInvalidArgument("endsAt은 startsAt 이후여야 합니다");
    }
  }

  return updatedFields;
}
