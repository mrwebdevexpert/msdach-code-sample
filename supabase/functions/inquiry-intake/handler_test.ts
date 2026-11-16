import { assertEquals } from "jsr:@std/assert@1";
import type { Candidate } from "../_shared/matching.ts";
import {
  createHandler,
  type InquiryInput,
  type IntakeStore,
  type StoredInquiry,
} from "./handler.ts";

const API_KEY = "test-key";

/** In-memory store; records what the handler asked for. */
function fakeStore(candidates: Candidate[] = []) {
  const rows = new Map<string, StoredInquiry>();
  const calls = { findCandidates: 0, insert: 0 };
  let seq = 0;

  const store: IntakeStore = {
    findInquiry(source, externalId) {
      return Promise.resolve(rows.get(`${source}:${externalId}`) ?? null);
    },
    findCandidates() {
      calls.findCandidates++;
      return Promise.resolve(candidates);
    },
    insertInquiry(input: InquiryInput, match) {
      calls.insert++;
      const inquiry: StoredInquiry = {
        id: `inq-${++seq}`,
        matchStatus: match.status,
        customerId: match.customerId,
        candidateIds: match.candidateIds,
      };
      rows.set(`${input.source}:${input.externalId}`, inquiry);
      return Promise.resolve({ inquiry, created: true });
    },
  };
  return { store, calls, rows };
}

function request(body: unknown, init: { key?: string | null; method?: string } = {}) {
  const headers = new Headers({ "content-type": "application/json" });
  if (init.key !== null) headers.set("authorization", `Bearer ${init.key ?? API_KEY}`);
  return new Request("http://localhost/inquiry-intake", {
    method: init.method ?? "POST",
    headers,
    body: init.method === "GET"
      ? undefined
      : typeof body === "string"
      ? body
      : JSON.stringify(body),
  });
}

const validBody = {
  source: "form",
  external_id: "drr-1001",
  contact_email: "Kunde@Example.de",
  contact_phone: "+49 171 123456",
  street: "Hauptstr. 1",
  postal_code: "20095",
  click_url: "https://dachrinnen-reinigen.de/?utm_source=google",
};

Deno.test("rejects non-POST", async () => {
  const { store } = fakeStore();
  const res = await createHandler({ store, apiKey: API_KEY })(request({}, { method: "GET" }));
  assertEquals(res.status, 405);
});

Deno.test("rejects missing or wrong bearer key without touching the store", async () => {
  const { store, calls } = fakeStore();
  const handler = createHandler({ store, apiKey: API_KEY });
  assertEquals((await handler(request(validBody, { key: null }))).status, 401);
  assertEquals((await handler(request(validBody, { key: "wrong" }))).status, 401);
  assertEquals(calls.findCandidates + calls.insert, 0);
});

Deno.test("rejects invalid JSON and invalid payloads with details", async () => {
  const { store } = fakeStore();
  const handler = createHandler({ store, apiKey: API_KEY });

  assertEquals((await handler(request("{not json"))).status, 400);

  const res = await handler(request({ source: "fax", contact_email: "nope" }));
  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error, "invalid_request");
  assertEquals(body.details.length >= 3, true); // source, external_id, contact_email
});

Deno.test("requires at least one contact signal", async () => {
  const { store } = fakeStore();
  const res = await createHandler({ store, apiKey: API_KEY })(
    request({ source: "phone", external_id: "call-1" }),
  );
  assertEquals(res.status, 400);
});

Deno.test("rejects non-http click_url", async () => {
  const { store } = fakeStore();
  const res = await createHandler({ store, apiKey: API_KEY })(
    request({ ...validBody, click_url: "javascript:alert(1)" }),
  );
  assertEquals(res.status, 400);
});

Deno.test("unknown contact -> 201 with match status new and no customer", async () => {
  const { store, rows } = fakeStore([]);
  const res = await createHandler({ store, apiKey: API_KEY })(request(validBody));
  assertEquals(res.status, 201);
  const body = await res.json();
  assertEquals(body.created, true);
  assertEquals(body.match, { status: "new", customer_id: null, candidate_ids: [] });
  assertEquals(rows.size, 1);
});

Deno.test("known e-mail -> matched to that customer", async () => {
  const { store } = fakeStore([{ customerId: "cust-1", signal: "email" }]);
  const res = await createHandler({ store, apiKey: API_KEY })(request(validBody));
  assertEquals(res.status, 201);
  assertEquals((await res.json()).match.customer_id, "cust-1");
});

Deno.test("shared address only -> ambiguous, office decides", async () => {
  const { store } = fakeStore([
    { customerId: "cust-1", signal: "address" },
    { customerId: "cust-2", signal: "address" },
  ]);
  const res = await createHandler({ store, apiKey: API_KEY })(request(validBody));
  const body = await res.json();
  assertEquals(body.match.status, "ambiguous");
  assertEquals(body.match.customer_id, null);
  assertEquals(body.match.candidate_ids, ["cust-1", "cust-2"]);
});

Deno.test("retry with the same external_id is idempotent (200, no second insert)", async () => {
  const { store, calls } = fakeStore();
  const handler = createHandler({ store, apiKey: API_KEY });

  const first = await handler(request(validBody));
  const second = await handler(request(validBody));

  assertEquals(first.status, 201);
  assertEquals(second.status, 200);
  const a = await first.json();
  const b = await second.json();
  assertEquals(b.inquiry_id, a.inquiry_id);
  assertEquals(b.created, false);
  assertEquals(calls.insert, 1);
});
