# Plan: M0a customer core (sample)

The plan format every module starts with (development rules, file 00). Building
starts after approval. This sample covers only a slice of M0a.

## Scope (Decided lines only)
| ID | Line | Built in |
|---|---|---|
| M0a-007, M0a-008 | Users and roles once, six roles | `user_roles`, `has_any_role()` |
| M0a-019 | Inquiry = internal ID + matching until LUNDS ends | `inquiries`, `inquiry-intake` |
| M0a-020 | Archive instead of delete, every change logged | no DELETE grant, `forbid_delete`, `audit_log` |
| M0a-092 | Invoice address never guessed | `confirm_invoice_address()`, status view |
| Map §2 | Customer numbers from 12,883 after LUNDS, reserved ranges skipped | `assign_customer_number()` |

## Tables
`user_roles`, `app_settings`, `reserved_customer_numbers`, `customers`, `objects`,
`invoice_recipients` (+ view `invoice_recipients_with_status`), `inquiries`, `audit_log`.
RLS on all eight; 20 policies; each has a pgTAP test (`supabase/tests/02_policies.test.sql`).

## Rights matrix
| | admin | teamlead | backoffice | dispo | vertrieb | monteur |
|---|---|---|---|---|---|---|
| customers / objects: read | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| customers / objects: create | ✓ | ✓ | ✓ | – | ✓ | – |
| customers / objects: change | ✓ | ✓ | ✓ | – | – | – |
| invoice recipients: create / change | ✓ | ✓ | ✓ | – | – | – |
| assign customer number | ✓ | ✓ | – | – | – | – |
| audit log: read | ✓ | ✓ | – | – | – | – |

## Events and flows
- E: inquiry received (intake Edge Function, idempotent on `source` + `external_id`).
- F: inquiry → matching (`matched` / `ambiguous` / `new`) → office review for `ambiguous`.

## Check step (acceptance, automated)
- pgTAP: RLS guard (5), behaviour (23), every policy allowed + denied (45).
- Deno: matching rules and HTTP handler (18).
- CI runs all of them on every pull request.

## Effort
Sample only; in the offer this slice is part of the M0a line.
