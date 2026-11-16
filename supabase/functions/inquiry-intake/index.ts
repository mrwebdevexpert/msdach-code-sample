// inquiry-intake: receives inquiries (mail, phone, form, KI-Panel) from the
// intake workflows, matches them against existing customers and stores them.
// Deployed with verify_jwt = false (see config.toml): callers authenticate with
// a shared bearer key, not a user JWT.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import type { Candidate } from "../_shared/matching.ts";
import {
  createHandler,
  type InquiryInput,
  type IntakeStore,
  type StoredInquiry,
} from "./handler.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const secretKey = Deno.env.get("SB_SECRET_KEY");
const intakeKey = Deno.env.get("INTAKE_API_KEY");
if (!supabaseUrl || !secretKey || !intakeKey) {
  throw new Error("SUPABASE_URL, SB_SECRET_KEY and INTAKE_API_KEY must be set");
}

const db = createClient(supabaseUrl, secretKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type InquiryRow = {
  id: string;
  match_status: StoredInquiry["matchStatus"];
  customer_id: string | null;
  match_candidates: string[];
};

const toStored = (r: InquiryRow): StoredInquiry => ({
  id: r.id,
  matchStatus: r.match_status,
  customerId: r.customer_id,
  candidateIds: r.match_candidates,
});

const COLUMNS = "id, match_status, customer_id, match_candidates";

const store: IntakeStore = {
  async findInquiry(source, externalId) {
    const { data, error } = await db
      .from("inquiries")
      .select(COLUMNS)
      .eq("source", source)
      .eq("external_id", externalId)
      .maybeSingle();
    if (error) throw error;
    return data ? toStored(data as InquiryRow) : null;
  },

  async findCandidates({ emailNormalized, phoneNormalized, addressKey }) {
    const candidates: Candidate[] = [];

    const byCustomerColumn = async (
      column: "email_normalized" | "phone_normalized",
      value: string | null,
      signal: "email" | "phone",
    ) => {
      if (!value) return;
      const { data, error } = await db.from("customers").select("id").eq(column, value);
      if (error) throw error;
      for (const row of data ?? []) candidates.push({ customerId: row.id, signal });
    };

    await byCustomerColumn("email_normalized", emailNormalized, "email");
    await byCustomerColumn("phone_normalized", phoneNormalized, "phone");

    if (addressKey) {
      const { data, error } = await db
        .from("objects")
        .select("customer_id")
        .eq("address_key", addressKey);
      if (error) throw error;
      for (const row of data ?? []) {
        candidates.push({ customerId: row.customer_id, signal: "address" });
      }
    }
    return candidates;
  },

  async insertInquiry(input: InquiryInput, match) {
    const { data, error } = await db
      .from("inquiries")
      .insert({
        source: input.source,
        external_id: input.externalId,
        click_url: input.clickUrl,
        contact_name: input.contactName,
        contact_email: input.contactEmail,
        contact_phone: input.contactPhone,
        street: input.street,
        postal_code: input.postalCode,
        raw: input.raw,
        match_status: match.status,
        customer_id: match.customerId,
        match_candidates: match.candidateIds,
      })
      .select(COLUMNS)
      .single();

    if (!error) return { inquiry: toStored(data as InquiryRow), created: true };

    // Lost a race with a parallel retry: return the row that won.
    if (error.code === "23505") {
      const existing = await store.findInquiry(input.source, input.externalId);
      if (existing) return { inquiry: existing, created: false };
    }
    throw error;
  },
};

Deno.serve(createHandler({ store, apiKey: intakeKey }));
