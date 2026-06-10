// B3-1: 권한 판단 중앙화 (BE 측 단일 출처).
// 고정 역할 없음 — 권한은 오직 세션과의 관계로 판단한다 (ERD §2, api-spec §1.2).
// 추후 admin/FM/전역GM 역할 도입 시 이 파일 + firestore.rules 두 곳만 수정.
import { errPermissionDenied, errUnauthenticated } from "./errors";
import type { UserId } from "../types/common";

export interface SessionOwnerView {
  createdByUserId: UserId;
}

export interface ParticipantView {
  userId: UserId;
}

export interface AuthLike {
  uid?: string;
}

/** 세션 운영자 여부: gameSession.createdByUserId === uid */
export function isSessionOwner(session: SessionOwnerView, uid: UserId): boolean {
  return session.createdByUserId === uid;
}

/** 본인(참가자) 여부: participation.userId === uid */
export function isParticipant(participation: ParticipantView, uid: UserId): boolean {
  return participation.userId === uid;
}

/** 콜러블 진입부 표준 인증 가드. 미인증이면 unauthenticated. */
export function requireAuth(auth: AuthLike | undefined | null): UserId {
  if (!auth || !auth.uid) {
    throw errUnauthenticated();
  }
  return auth.uid;
}

/** 세션 운영자가 아니면 permission-denied. */
export function assertSessionOwner(session: SessionOwnerView, uid: UserId): void {
  if (!isSessionOwner(session, uid)) {
    throw errPermissionDenied("세션 운영자만 수행할 수 있습니다");
  }
}

/** 본인도 세션 운영자도 아니면 permission-denied. */
export function assertParticipantOrOwner(
  participation: ParticipantView,
  session: SessionOwnerView,
  uid: UserId
): void {
  if (!isParticipant(participation, uid) && !isSessionOwner(session, uid)) {
    throw errPermissionDenied("본인 또는 세션 운영자만 수행할 수 있습니다");
  }
}
