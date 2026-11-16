import { assertEquals } from "jsr:@std/assert@1";
import { addressKey, decideMatch, normalizeEmail, normalizePhone } from "./matching.ts";

Deno.test("normalizeEmail trims and lowercases, empty becomes null", () => {
  assertEquals(normalizeEmail("  Foo@Bar.DE "), "foo@bar.de");
  assertEquals(normalizeEmail("   "), null);
  assertEquals(normalizeEmail(undefined), null);
});

Deno.test("normalizePhone keeps digits and +, drops formatting", () => {
  assertEquals(normalizePhone("+49 (171) 123-45"), "+4917112345");
  assertEquals(normalizePhone("n/a"), null);
});

Deno.test("addressKey needs street and postal code, ignores case and spaces", () => {
  assertEquals(addressKey("Haupt Str. 1", "20095"), "hauptstr.1|20095");
  assertEquals(addressKey("Haupt Str. 1", ""), null);
  assertEquals(addressKey(null, "20095"), null);
});

Deno.test("one customer behind e-mail -> matched", () => {
  const r = decideMatch([{ customerId: "c1", signal: "email" }]);
  assertEquals(r, { status: "matched", customerId: "c1", candidateIds: ["c1"] });
});

Deno.test("same customer by e-mail and phone -> matched once", () => {
  const r = decideMatch([
    { customerId: "c1", signal: "email" },
    { customerId: "c1", signal: "phone" },
  ]);
  assertEquals(r.status, "matched");
  assertEquals(r.candidateIds, ["c1"]);
});

Deno.test("e-mail and phone point to different customers -> ambiguous", () => {
  const r = decideMatch([
    { customerId: "c1", signal: "email" },
    { customerId: "c2", signal: "phone" },
  ]);
  assertEquals(r, { status: "ambiguous", customerId: null, candidateIds: ["c1", "c2"] });
});

Deno.test("address alone never auto-matches", () => {
  const r = decideMatch([{ customerId: "c1", signal: "address" }]);
  assertEquals(r, { status: "ambiguous", customerId: null, candidateIds: ["c1"] });
});

Deno.test("strong signal plus extra address candidate still matches the strong one", () => {
  const r = decideMatch([
    { customerId: "c1", signal: "email" },
    { customerId: "c2", signal: "address" },
  ]);
  assertEquals(r.status, "matched");
  assertEquals(r.customerId, "c1");
  assertEquals(r.candidateIds, ["c1", "c2"]);
});

Deno.test("no signal -> new", () => {
  assertEquals(decideMatch([]), { status: "new", customerId: null, candidateIds: [] });
});
