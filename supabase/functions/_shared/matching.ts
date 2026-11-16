// Customer matching for incoming inquiries (M0a-019).
//
// The normalisation here MUST stay identical to the generated columns in
// supabase/migrations/20261112000000_m0a_customer_core_sample.sql
// (customers.email_normalized / phone_normalized, objects.address_key).

export type MatchSignal = "email" | "phone" | "address";

export interface Candidate {
  customerId: string;
  signal: MatchSignal;
}

export type MatchStatus = "matched" | "ambiguous" | "new";

export interface MatchResult {
  status: MatchStatus;
  /** Set only when status = "matched". */
  customerId: string | null;
  /** Every customer that produced any signal, for the office to review. */
  candidateIds: string[];
}

export function normalizeEmail(value: string | null | undefined): string | null {
  const v = (value ?? "").trim().toLowerCase();
  return v === "" ? null : v;
}

export function normalizePhone(value: string | null | undefined): string | null {
  const v = (value ?? "").replace(/[^0-9+]/g, "");
  return v === "" ? null : v;
}

export function addressKey(
  street: string | null | undefined,
  postalCode: string | null | undefined,
): string | null {
  if (!street?.trim() || !postalCode?.trim()) return null;
  return `${street}|${postalCode}`.toLowerCase().replace(/\s+/g, "");
}

/**
 * Decide what to do with the signals found for one inquiry.
 *
 * - E-mail and phone are strong signals: exactly one customer behind them -> matched.
 * - Several customers behind strong signals -> ambiguous (office decides).
 * - An address alone is never enough: many customers share one address
 *   (property managements, owners' associations) -> ambiguous, office decides.
 * - No signal -> new. No customer number is assigned (LUNDS rule): the inquiry
 *   only carries its internal ID until the office confirms.
 */
export function decideMatch(candidates: Candidate[]): MatchResult {
  const candidateIds = [...new Set(candidates.map((c) => c.customerId))];
  const strongIds = [
    ...new Set(
      candidates.filter((c) => c.signal !== "address").map((c) => c.customerId),
    ),
  ];

  if (strongIds.length === 1) {
    return { status: "matched", customerId: strongIds[0], candidateIds };
  }
  if (candidateIds.length > 0) {
    return { status: "ambiguous", customerId: null, candidateIds };
  }
  return { status: "new", customerId: null, candidateIds: [] };
}
