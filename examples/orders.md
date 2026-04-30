# Example: order-fulfillment diagnostic

A complete, self-contained ScryQL walkthrough. No external services, no
production data — DuckDB's in-memory engine is seeded directly from the
`@setup` block in `orders.sql`, so `cargo run` is enough to reproduce
every output below.

The scenario: an e-commerce backend where an order moves through several
gates before it ships. Five orders are seeded, each one stuck (or not)
at a different gate, so a single rule can demonstrate every distinct
failure mode side-by-side.

## The pipeline

```
order placed  ──▶  customer must be active
              ──▶  every line item must be in stock
              ──▶  payment must cover the full total
              ──▶  shipment must be created and marked "shipped"
```

## The data

| Order      | Customer        | Total  | What's wrong                  |
| ---------- | --------------- | -----: | ----------------------------- |
| `ORD-1001` | Anna (active)   |  89.50 | nothing — happy path          |
| `ORD-1002` | Bert (INACTIVE) | 120.00 | customer is inactive          |
| `ORD-1003` | Anna            |  45.00 | only 30.00 captured           |
| `ORD-1004` | Cara            | 200.00 | SPROCKET out of stock         |
| `ORD-1005` | Anna            |  60.00 | shipment never created        |

## Files

```
examples/
├── orders.sql   ── DuckDB schema + seed data + per-row fact queries
├── orders.pl    ── diag/1 (printer) and classify/2 (returns reason atom)
└── orders.md    ── this document
```

## Running

From the repo root:

```sh
cargo run --quiet -- \
    --rules examples/orders.pl \
    --sql   examples/orders.sql \
    --entry diag/1 ORD-1001
```

(`scryql` after `cargo install --path .`, or `./target/debug/scryql`
after `cargo build`. Examples below use `scryql` for brevity.)

## `diag/1` — side-effect mode

`diag/1` prints one line per stage of the order, marking each stage
explicitly as ok, missing, or wrong.

```text
$ scryql ... --entry diag/1 ORD-1001
ORD-1001:
  order      cust=CUST-A total=89.5 placed=2026-04-20
  customer   Anna Andrews (active)
  line       WIDGET qty=1 (stock=100 ok)
  line       GIZMO qty=2 (stock=50 ok)
  payment    89.5 (captured)
  shipment   TRK-AAA (shipped)

$ scryql ... --entry diag/1 ORD-1002
ORD-1002:
  order      cust=CUST-B total=120.0 placed=2026-04-21
  customer   Bert Brown (INACTIVE)
  line       GIZMO qty=1 (stock=50 ok)
  payment    120.0 (captured)
  shipment   TRK-BBB (shipped)

$ scryql ... --entry diag/1 ORD-1003
ORD-1003:
  order      cust=CUST-A total=45.0 placed=2026-04-22
  customer   Anna Andrews (active)
  line       WIDGET qty=1 (stock=100 ok)
  payment    30.0 of 45.0 (SHORT, captured)
  shipment   TRK-CCC (pending, NOT SHIPPED)

$ scryql ... --entry diag/1 ORD-1004
ORD-1004:
  order      cust=CUST-C total=200.0 placed=2026-04-23
  customer   Cara Clarke (active)
  line       SPROCKET qty=5 (stock=0 SHORT)
  payment    200.0 (captured)
  shipment   NONE

$ scryql ... --entry diag/1 ORD-1005
ORD-1005:
  order      cust=CUST-A total=60.0 placed=2026-04-24
  customer   Anna Andrews (active)
  line       WIDGET qty=1 (stock=100 ok)
  payment    60.0 (captured)
  shipment   NONE

$ scryql ... --entry diag/1 ORD-9999
ORD-9999:
  order      MISSING
  customer   MISSING
  line       NO LINES
  payment    MISSING
  shipment   NONE
```

Notice the structure stays the same regardless of which gate failed.
The point is to read the lifecycle of one record at a glance, not to
short-circuit at the first problem.

## `classify/2` — capture-result mode

`classify/2` short-circuits at the first failure in priority order
and returns a structured atom; `ok` if everything passes.

```text
$ scryql ... --entry classify/2 ORD-1001
ok

$ scryql ... --entry classify/2 ORD-1002
fail(inactive_customer, ORD-1002)

$ scryql ... --entry classify/2 ORD-1003
fail(underpaid, 30.0, 45.0)

$ scryql ... --entry classify/2 ORD-1004
fail(insufficient_stock, SPROCKET, 5, 0)

$ scryql ... --entry classify/2 ORD-1005
fail(not_shipped, ORD-1005)

$ scryql ... --entry classify/2 ORD-9999
fail(no_order, ORD-9999)
```

The priority order in the rule (no_order ▶ inactive_customer ▶
insufficient_stock ▶ underpaid ▶ not_shipped) is what makes `ORD-1004`
classify as `insufficient_stock` rather than `not_shipped`, even though
both failures are present.

## Why two modes?

| Mode         | Output           | Useful when                                          |
| ------------ | ---------------- | ---------------------------------------------------- |
| `diag/1`     | human-readable text | reading one record at a time during investigation |
| `classify/2` | a Prolog atom    | feeding many subjects into ScryQL and grouping by result to count where records get stuck |

## Extending it

The rule is a chain of disjunctive cases. Add a new gate by:

1. Add the table and seed data, plus an `-- @row` query that emits a
   fact for it.
2. Declare the new fact predicate `:- dynamic(...)`.
3. Add a clause to `diag/1`'s walker and a guard to `classify/2`'s
   priority chain.

For example, to add a fraud-check gate:

```sql
-- @setup additions
CREATE TABLE fraud_checks (order_id VARCHAR, status VARCHAR);
INSERT INTO fraud_checks VALUES ('ORD-1001', 'approved'), ('ORD-1006', 'flagged');

-- @row
SELECT 'fraud(''' || status || ''').' FROM fraud_checks WHERE order_id = ?;
```

```prolog
:- dynamic(fraud/1).

% in diag/1's walker:
show_fraud :-
    ( fraud(approved) -> format("  fraud      ok~n", [])
    ; fraud(Status)   -> format("  fraud      ~w (BLOCKED)~n", [Status])
    ; format("  fraud      not yet checked~n", []) ).

% in classify/2's priority chain (above 'not_shipped'):
;  fraud(flagged) -> R = fail(fraud_flagged, Order)
```
