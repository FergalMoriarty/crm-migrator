-- Run this before pointing dbt at the database. It answers three questions:
-- did the rows land, is everything still text, and did the mess survive the
-- trip. A load that silently drops encoding damage has cleaned the data
-- already, which would make the whole project pointless.

\echo '== row counts =='
SELECT 'landlords' AS table, count(*) FROM raw.landlords
UNION ALL SELECT 'properties', count(*) FROM raw.properties
UNION ALL SELECT 'tenancies',  count(*) FROM raw.tenancies
UNION ALL SELECT 'payments',   count(*) FROM raw.payments
ORDER BY 1;

\echo '== every column should be text (plus the two metadata columns) =='
SELECT table_name, data_type, count(*) AS columns
FROM   information_schema.columns
WHERE  table_schema = 'raw'
GROUP  BY 1, 2
ORDER  BY 1, 2;

\echo '== the mess should have survived =='
SELECT count(*) FILTER (WHERE notes LIKE '%Ã%' OR notes LIKE '%â€%') AS mojibake,
       count(*) FILTER (WHERE notes LIKE E'%\n%')                    AS embedded_newline,
       count(*) FILTER (WHERE notes IN ('N/A','n/a','-','none','NONE','NULL','.')) AS placeholder_nulls,
       count(*) FILTER (WHERE notes = '')                            AS empty_string,
       count(*) FILTER (WHERE notes IS NULL)                         AS real_nulls
FROM   raw.landlords;

\echo '== provenance and freshness columns are populated =='
SELECT _source_file, count(*), min(_loaded_at) AS loaded_at
FROM   raw.landlords GROUP BY 1;

\echo '== eyeball five landlords =='
SELECT landlordref, name, email, phone, postcode, dateadded
FROM   raw.landlords ORDER BY landlordref LIMIT 5;
