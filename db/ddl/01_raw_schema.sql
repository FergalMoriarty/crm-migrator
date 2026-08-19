-- 01_raw_schema.sql — the landing zone.
--
-- WHAT THIS IS
--     One table per source CSV, column names matching the CSV headers
--     (lowercased, because Postgres folds unquoted identifiers), every column
--     typed text.
--
-- WHY EVERY COLUMN IS text
--     Because that is what a CSV load actually gives you. A CSV has no types.
--     The moment you type a column here you have made a decision — "DateAdded
--     is a date" — and you have made it in a place with no tests, no lineage
--     and no way to see what was rejected. If a row fails the cast it does not
--     land at all, and you are debugging an absence.
--     Casting is the staging layer's job, where it is version controlled,
--     testable, and visible in the DAG. Raw's only job is: get the bytes in,
--     losing nothing.
--     ALTERNATIVE CONSIDERED: type the columns and let COPY reject bad rows.
--     Rejected — that is a data quality gate placed before the data quality
--     tooling, and it fails closed and silently.
--
-- WHY THERE ARE NO CONSTRAINTS
--     No primary keys, no not-null, no foreign keys. Same reasoning. A
--     duplicate landlord ref in the export is a *finding*, and a finding you
--     want to model and report on, not a load error at 2am. Constraints here
--     would mean the messiest exports — the ones most worth studying — are the
--     ones that never make it into the database.
--
-- THE TWO UNDERSCORE-PREFIXED COLUMNS
--     _loaded_at    when this row landed. dbt's source freshness needs a
--                   timestamp column to look at, and this is it. It is
--                   defaulted rather than supplied by the loader so it cannot
--                   be forgotten or faked.
--     _source_file  which agency's export this row came from. Only one
--                   agency's data is resident at a time, but stamping the row
--                   means staging never has to infer provenance, and phase 2
--                   does not require a schema change.
--     The underscore prefix marks them as warehouse metadata rather than
--     anything the agency sent. That convention carries through to staging.

CREATE SCHEMA IF NOT EXISTS raw;

DROP TABLE IF EXISTS raw.landlords;
CREATE TABLE raw.landlords (
    landlordref   text,
    name          text,
    email         text,
    phone         text,
    addrline1     text,
    addrline2     text,
    town          text,
    postcode      text,
    dateadded     text,
    notes         text,
    status        text,
    _loaded_at    timestamptz NOT NULL DEFAULT now(),
    _source_file  text
);

DROP TABLE IF EXISTS raw.properties;
CREATE TABLE raw.properties (
    propref       text,
    landlordref   text,
    addr1         text,
    addr2         text,
    town          text,
    postcode      text,
    beds          text,
    proptype      text,
    description   text,
    monthlyrent   text,
    datelisted    text,
    _loaded_at    timestamptz NOT NULL DEFAULT now(),
    _source_file  text
);

DROP TABLE IF EXISTS raw.tenancies;
CREATE TABLE raw.tenancies (
    tenancyref    text,
    propref       text,
    tenantname    text,
    tenantemail   text,
    tenantphone   text,
    startdate     text,
    enddate       text,
    rent          text,
    depositheld   text,
    comments      text,
    _loaded_at    timestamptz NOT NULL DEFAULT now(),
    _source_file  text
);

DROP TABLE IF EXISTS raw.payments;
CREATE TABLE raw.payments (
    paymentref    text,
    tenancyref    text,
    paidon        text,
    amount        text,
    method        text,
    reference     text,
    _loaded_at    timestamptz NOT NULL DEFAULT now(),
    _source_file  text
);

-- A read-only role for anything that only needs to look. The validator repo
-- connects as exactly this kind of user: the tool never issues a write, but
-- the credential should enforce that rather than the application promising to
-- behave. Defence at the database is stronger than defence in code.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meridian_readonly') THEN
        CREATE ROLE meridian_readonly LOGIN PASSWORD 'readonly';
    END IF;
END
$$;

GRANT USAGE ON SCHEMA raw TO meridian_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA raw TO meridian_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw GRANT SELECT ON TABLES TO meridian_readonly;
