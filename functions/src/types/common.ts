// api-spec-v2 §6.1 common.d.ts 전사
import type {
  Timestamp as FirestoreTimestamp,
  GeoPoint as FirestoreGeoPoint
} from "firebase-admin/firestore";

export type UserId = string;
export type Timestamp = FirestoreTimestamp;
export type GeoPoint = FirestoreGeoPoint;

export interface BankAccount {
  bankName: string;
  accountNumber: string;
  accountHolder: string;
}

export interface ApiSuccess<T = void> {
  success: true;
  data?: T;
}
