// Request handling for inquiry-intake, free of Deno/Supabase globals so it can
// be unit-tested with a fake store (see handler_test.ts).

import {
  addressKey,
  type Candidate,
  decideMatch,
  type MatchResult,
  normalizeEmail,
  normalizePhone,
} from "../_shared/matching.ts";

export const SOURCES = ["email", "phone", "form", "kipanel"] as const;
export type Source = (typeof SOURCES)[number];

export interface InquiryInput {
  source: Source;
  externalId: string;
  clickUrl: string | null;
  contactName: string | null;
  contactEmail: string | null;
  contactPhone: string | null;
  street: string | null;
  postalCode: string | null;
  raw: Record<string, unknown>;
}

export interface StoredInquiry {
  id: string;
  matchStatus: MatchResult["status"];
  customerId: string | null;
  candidateIds: string[];
}

export interface IntakeStore {
  findInquiry(source: Source, externalId: string): Promise<StoredInquiry | null>;
  findCandidates(query: {
    emailNormalized: string | null;
    phoneNormalized: string | null;
    addressKey: string | null;
  }): Promise<Candidate[]>;
  /** Returns the existing row (created = false) when (source, external_id) already exists. */
  insertInquiry(
    input: InquiryInput,
    match: MatchResult,
  ): Promise<{ inquiry: StoredInquiry; created: boolean }>;
}

export interface HandlerDeps {
  store: IntakeStore;
  apiKey: string;
}

const MAX_BODY_BYTES = 64 * 1024;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Constant-time comparison: hash both sides so lengths always match. */
export async function secretsMatch(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(ha);
  const vb = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
  return diff === 0;
}

function optionalString(
  body: Record<string, unknown>,
  key: string,
  errors: string[],
  maxLength = 500,
): string | null {
  const v = body[key];
  if (v === undefined || v === null || v === "") return null;
  if (typeof v !== "string" || v.length > maxLength) {
    errors.push(`${key}: must be a string of at most ${maxLength} characters`);
    return null;
  }
  return v.trim() || null;
}

export function validateInput(
  body: unknown,
): { ok: true; value: InquiryInput } | { ok: false; errors: string[] } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, errors: ["body: must be a JSON object"] };
  }
  const b = body as Record<string, unknown>;
  const errors: string[] = [];

  const source = b.source;
  if (typeof source !== "string" || !(SOURCES as readonly string[]).includes(source)) {
    errors.push(`source: must be one of ${SOURCES.join(", ")}`);
  }

  const externalId = optionalString(b, "external_id", errors, 200);
  if (!externalId) errors.push("external_id: required");

  const contactEmail = optionalString(b, "contact_email", errors, 254);
  if (contactEmail && !EMAIL_RE.test(contactEmail)) {
    errors.push("contact_email: not a valid e-mail address");
  }

  const clickUrl = optionalString(b, "click_url", errors, 2000);
  if (clickUrl) {
    try {
      const u = new URL(clickUrl);
      if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error();
    } catch {
      errors.push("click_url: must be an http(s) URL");
    }
  }

  const value: InquiryInput = {
    source: source as Source,
    externalId: externalId ?? "",
    clickUrl,
    contactName: optionalString(b, "contact_name", errors),
    contactEmail,
    contactPhone: optionalString(b, "contact_phone", errors, 50),
    street: optionalString(b, "street", errors),
    postalCode: optionalString(b, "postal_code", errors, 10),
    raw: typeof b.raw === "object" && b.raw !== null && !Array.isArray(b.raw)
      ? (b.raw as Record<string, unknown>)
      : {},
  };

  if (!value.contactEmail && !value.contactPhone && !value.street) {
    errors.push("contact: at least one of contact_email, contact_phone, street is required");
  }

  return errors.length > 0 ? { ok: false, errors } : { ok: true, value };
}

export function createHandler({ store, apiKey }: HandlerDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

    const auth = req.headers.get("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!token || !(await secretsMatch(token, apiKey))) {
      return json(401, { error: "unauthorized" });
    }

    const text = await req.text();
    if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) {
      return json(413, { error: "payload_too_large" });
    }
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      return json(400, { error: "invalid_request", details: ["body: not valid JSON"] });
    }

    const parsed = validateInput(body);
    if (!parsed.ok) return json(400, { error: "invalid_request", details: parsed.errors });
    const input = parsed.value;

    // Idempotent: the sender may retry; the same (source, external_id) returns the first result.
    const existing = await store.findInquiry(input.source, input.externalId);
    if (existing) return json(200, toResponse(existing, false));

    const candidates = await store.findCandidates({
      emailNormalized: normalizeEmail(input.contactEmail),
      phoneNormalized: normalizePhone(input.contactPhone),
      addressKey: addressKey(input.street, input.postalCode),
    });
    const match = decideMatch(candidates);

    const { inquiry, created } = await store.insertInquiry(input, match);
    return json(created ? 201 : 200, toResponse(inquiry, created));
  };
}

function toResponse(inquiry: StoredInquiry, created: boolean) {
  return {
    inquiry_id: inquiry.id,
    created,
    match: {
      status: inquiry.matchStatus,
      customer_id: inquiry.customerId,
      candidate_ids: inquiry.candidateIds,
    },
  };
}
