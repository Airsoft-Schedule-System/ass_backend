// ERD-v2 §5 엔티티 명세 전사 (11개 엔티티)
import type { BankAccount, GeoPoint, Timestamp, UserId } from "./common";
import type {
  EntryPassStatus,
  FcmTokenPlatform,
  GameSessionStatus,
  ParticipationStatus,
  PaymentSubmissionStatus,
  RefundRequestStatus
} from "./status";

// §5.1 — role/noShowCount/cancelCount 없음 (세션 단위 권한 모델)
export interface User {
  id?: string;
  email: string | null;
  displayName: string;
  phoneNumber: string | null;
  teamId: string | null;
  createdAt: Timestamp;
  lastActiveAt: Timestamp;
}

// §5.2
export interface UserFcmToken {
  installationId: string;
  userId: UserId;
  token: string;
  platform: FcmTokenPlatform;
  createdAt: Timestamp;
  lastSeenAt: Timestamp;
}

// §5.3
export interface Team {
  id?: string;
  name: string;
  createdAt: Timestamp;
}

// §5.4
export interface Field {
  id?: string;
  name: string;
  address: string | null;
  geoPoint: GeoPoint | null;
  createdAt: Timestamp;
}

// §5.5
export interface GameRulePreset {
  id?: string;
  name: string;
  description: string | null;
  rules: Record<string, unknown>;
  ownerId: UserId | null;
  isPublic: boolean;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

// §5.6 — 운영자 식별 기준은 createdByUserId
export interface GameSession {
  id?: string;
  title: string;
  createdByUserId: UserId;
  hostTeamId: string | null;
  fieldId: string | null;
  fieldName: string | null;
  startsAt: Timestamp;
  endsAt: Timestamp | null;
  capacity: number;
  confirmedCount: number;
  gameFee: number;
  paymentMethod: "pre_transfer";
  bankAccount: BankAccount;
  presetId: string | null;
  customRules: Record<string, unknown> | null;
  cancelDeadline: Timestamp;
  status: GameSessionStatus;
  reminderSent?: boolean;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

// §5.7 — unique (gameSessionId, userId)
export interface Participation {
  id?: string;
  gameSessionId: string;
  userId: UserId;
  status: ParticipationStatus;
  gameStartsAt: Timestamp;
  entryPassId: string | null;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

// §5.8
export interface PaymentSubmission {
  id?: string;
  participationId: string;
  gameSessionId: string;
  userId: UserId;
  senderName: string;
  amount: number;
  receiptImageUrl: string;
  status: PaymentSubmissionStatus;
  submittedAt: Timestamp;
  reviewedBy: UserId | null;
  reviewedAt: Timestamp | null;
  rejectionReason: string | null;
}

// §5.9 — accountNumber 는 암호화 저장
export interface RefundRequest {
  id?: string;
  participationId: string;
  gameSessionId: string;
  userId: UserId;
  bankName: string;
  accountNumber: string;
  accountHolder: string;
  reason: string | null;
  status: RefundRequestStatus;
  requestedAt: Timestamp;
  processedBy: UserId | null;
  processedAt: Timestamp | null;
  note: string | null;
}

// §5.10 — qrTokenHash 만 저장 (원문 미저장)
export interface EntryPass {
  id?: string;
  participationId: string;
  gameSessionId: string;
  userId: UserId;
  status: EntryPassStatus;
  qrTokenHash: string;
  qrSecretVersion: string;
  issuedAt: Timestamp;
  expiresAt: Timestamp;
  usedAt: Timestamp | null;
  scannedBy: UserId | null;
}

// §5.11 — 인앱 알림함 데이터 소스
export interface Notification {
  id?: string;
  userId: UserId;
  type: string;
  title: string;
  body: string;
  actionUrl: string;
  data: Record<string, string> | null;
  gameSessionId: string | null;
  participationId: string | null;
  isRead: boolean;
  createdAt: Timestamp;
}
