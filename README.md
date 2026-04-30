# ScryQL

A Rust binary that embeds [Scryer Prolog](https://github.com/mthom/scryer-prolog) and [DuckDB](https://duckdb.org) so you can write **cross-system data diagnostics in Prolog** while DuckDB does the multi-source query work.

The shape of the problem: pick a single record (an invoice, an order, an account) and explain why it does or doesn't make it through some multi-step pipeline. DuckDB joins across the relevant sources, returns the rows as Prolog facts, and a rule walks them stage by stage to attribute success or failure.

For a runnable end-to-end walkthrough, see [`examples/orders.md`](examples/orders.md).

## Architecture

```
                   +---------------------+
   subject  ---->  | Rust harness        |
                   |   - parse argv      |
                   |   - load rules.pl   |
                   |   - load queries.sql|
                   +----+--------+-------+
                        |        |
                        v        v
                   +--------+  +---------------+
                   | DuckDB |  | Scryer Prolog |
                   | (1.x,  |  |  (0.10,       |
                   |bundled)|  |   embedded)   |
                   +--+-----+  +-------+-------+
                      |                ^
                      |  facts (text)  |
                      +----------------+
```

DuckDB is the cross-DB orchestrator: ATTACH live Postgres, read Parquet, do joins. It returns rows formatted as Prolog clauses (one column of pre-quoted text per query). Those clauses are consulted into the Scryer `Machine`. The rule defined in `rules.pl` runs against the resulting fact base.

DuckDB's `format/2` output goes through Scryer's stdio streams, so any `format/2` calls in the rules appear directly in the host terminal.

## Build

```
cargo build
```

Both DuckDB and Scryer are statically linked. First build is slow (DuckDB's bundled C++ takes ~8 minutes). Incremental rebuilds are seconds.

## Files

ScryQL is a generic engine. Domain logic lives in two files; the binary doesn't know what they contain.

- **`rules.pl`** — Prolog. Declares `:- dynamic` for each fact predicate that will be injected. Defines the entry predicate (any name, arity 1 or 2). Output is whatever the rule writes (`format/2`) or returns in its second arg.
- **`queries.sql`** — DuckDB SQL with simple section markers. Each `-- @row` block produces one column of pre-formatted Prolog clauses for one fact predicate.

### `queries.sql` format

```sql
-- @setup           runs once at startup. Use for INSTALL / LOAD / ATTACH / CREATE VIEW
--                  or for in-memory CREATE TABLE / INSERT, as the orders example does.

-- @setup
INSTALL postgres;
LOAD postgres;
ATTACH 'host=db.example.com dbname=mydb user=ro' AS pg (TYPE postgres, READ_ONLY);

-- @row              runs once per invocation. The single ? is bound to the CLI subject.
--                   Must return ONE column: a fully-formatted Prolog clause.

-- @row
SELECT 'customer(''' || id || ''', ''' || name || ''').'
FROM pg.public.customers WHERE id = ?;
```

The pre-formatted-clause trick comes from a typical DuckDB pattern: `SELECT 'pred(''' || col || ''').'` — DuckDB does the string concatenation and quoting, the Rust harness just appends each row to a `consult_module_string` buffer. No Rust-side templates or schema mapping.

### `rules.pl` shape

```prolog
:- use_module(library(format)).

:- dynamic(order/4).
:- dynamic(customer/3).
:- dynamic(payment/2).

% Side-effect mode: rule emits via format/2.
diag(Order) :-
    format("~w:~n", [Order]),
    ( order(Order, C, T, D) -> format("  order    cust=~w total=~w date=~w~n", [C, T, D])
    ;                          format("  order    MISSING~n", []) ),
    ...

% Capture-result mode: rule binds R; harness prints R.
classify(Order, R) :-
    ( \+ order(Order, _, _, _) -> R = fail(no_order, Order)
    ; customer(_, _, inactive) -> R = fail(inactive_customer, Order)
    ; underpaid                -> R = fail(underpaid, Order)
    ; R = ok ).
```

See [`examples/orders.pl`](examples/orders.pl) for the full version.

## CLI

```
scryql --rules PATH --sql PATH --entry NAME/ARITY [--repl] [<subject>]
```

`--entry` is required. ARITY is 1 or 2:
- **`name/1`** — side-effect mode. Rule writes via `format/2`. No result captured.
- **`name/2`** — capture-result mode. Harness calls `name(Subject, R)` and prints `R` in canonical Prolog notation.

### Modes

| Invocation | Behaviour |
|---|---|
| `scryql ... --entry e/N <subject>` | one-shot: fetch facts, run, exit |
| `scryql ... --entry e/N --repl <subject>` | run once, then drop into REPL with facts loaded |
| `scryql ... --entry e/N` (no subject) | REPL only, rules loaded, no facts |

In the REPL, typing `e('XINV').` (or `e('XINV', R).` for arity 2) is intercepted: the harness fetches facts for `XINV` first, then runs the query. Other queries pass straight through to Scryer.

## Examples

[`examples/orders.md`](examples/orders.md) is a self-contained walkthrough
that needs no external services or production data — five seeded orders
hitting five distinct failure modes, both side-effect and capture-result
modes demonstrated, all output captured from real runs.

```sh
cargo run --quiet -- \
    --rules examples/orders.pl \
    --sql   examples/orders.sql \
    --entry diag/1 ORD-1001
```

## Limitations

- **No foreign predicates in scryer-prolog 0.10.** The DB seam is facts-injection only — every rule sees ground unit clauses, never live DB calls. For one-row-at-a-time diagnostic this is the right shape.
- **Naive single-quote handling.** Subjects containing single quotes break the format-string injection. Subjects in practice are alphanumeric IDs; not yet a problem.
- **Setup is a one-shot batch.** Re-running with different `--sql` re-executes setup against a fresh in-memory DuckDB; there's no caching of attaches between invocations.
- **Bundled DuckDB ≠ system DuckDB.** Extensions installed by the bundled binary live separately from `~/.duckdb/extensions/`. Currently only `INSTALL postgres` is used; that fetches at first run and caches.

## Pinned versions

- `scryer-prolog = "0.10.0"` (Sept 2025)
- `duckdb = "1"` with `bundled` feature (Apr 2026; bundled DuckDB 1.5.2)
