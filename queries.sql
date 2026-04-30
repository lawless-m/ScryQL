-- ScryQL queries for the invoice lifecycle diagnostic.
--
-- Section markers:
--   -- @setup   runs once at startup. Use for INSTALL/LOAD/ATTACH/CREATE VIEW.
--   -- @row     runs per invocation. The single ? is bound to the CLI argument.
--              Each row query must return ONE column of pre-formatted Prolog clauses
--              (e.g. "invoice('1205542', '992565', '2026-01-05').").
--
-- Multiple statements within a section are separated by `;` and run in order.

-- @setup
INSTALL postgres;
LOAD postgres;
ATTACH 'host=/var/run/postgresql port=5432 dbname=x3rocs user=jordan' AS pg (TYPE postgres, READ_ONLY);
CREATE OR REPLACE VIEW upl AS SELECT document_number, location FROM pg.x3.uploaded_invoices;

-- @row
SELECT DISTINCT
    'invoice(''' || sainv || ''', ''' || sacust || ''', ''' || strftime(sadate, '%Y-%m-%d') || ''').' AS fact
FROM read_parquet('/mnt/prod02_ri_services/Outputs/Parquets/em/analysis.parquet')
WHERE sainv = ?;

-- @row
SELECT 'uploaded(''' || document_number || ''', ''' || location || ''').' AS fact
FROM upl
WHERE document_number = ?;

-- @row
WITH lines AS (
    SELECT ref, bool_or(quantity > 0) AS any_nonzero
    FROM read_parquet('/mnt/prod02_ri_services/Outputs/Parquets/em/orderi.parquet')
    GROUP BY ref
)
SELECT 'nonzerolines(''' || oh.ohinvref || ''').' AS fact
FROM read_parquet('/mnt/prod02_ri_services/Outputs/Parquets/em/orderh.parquet') oh
LEFT JOIN lines ON oh.ref = lines.ref
WHERE oh.ohinvref = ? AND lines.any_nonzero;
