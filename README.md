# crm-migrator

A dbt project that cleans and models messy CRM data from acquired  lettings
agencies, for Meridian — a fictional lettings roll-up.

It is the counterpart to [`crm-migration-validator`](../crm-migration-validator),
which *detects* problems in a migration and deliberately refuses to fix any of
them. This project fixes them. The validator can then be re-run against the
result to check that the cleaning did what it claimed. The two repos stay
separate on purpose: a tool that both cleans data and certifies its own
cleaning is not evidence of anything.

**What this does not do.** It does not decide whether a migration is fit to
ship — that is the validator's job. It does not do entity resolution across
agencies yet (phase 2). It does not touch a production system: the target here
is a local Postgres in Docker, and the data is generated.

> Status: increment 1 of 12. This README grows with the project; the sections
> the finished repo needs — the model table, honest limitations, a run that
> fails — arrive as the things they describe do.

---

## Increment 1 — the ground truth

No dbt yet. Increment 1 stands up the database and gets one acquired agency's
export into it, unaltered, so that everything dbt does afterwards can be
compared against something known.

The agency is **Harcourt & Vine** (`HV`), Meridian's first acquisition. Its
export is generated, not real, and generated *messily*: UK postcodes in five
spacings, phone numbers as `+44` / `0044` / leading-zero-eaten-by-Excel, names
as both `SURNAME, First` and `First Surname`, dates in six formats including
Excel serial numbers, currency as `£1,250.00` text with accounting negatives in
brackets, mojibake from a UTF-8 file read back as cp1252, and free-text notes
carrying HTML, smart quotes, tabs, embedded newlines and eleven different ways
of writing "nothing here".

### From clean clone to populated database

```bash
pip install -r requirements.txt

# 1. Start Postgres 16.4 on host port 5433 (not 5432 — you probably have one)
docker compose up -d

# 2. Create the raw schema and landing tables
docker compose exec -T postgres \
  psql -U meridian -d meridian_crm -v ON_ERROR_STOP=1 < db/ddl/01_raw_schema.sql

# 3. Generate the agency export to data/source/harcourt_vine/
python db/generate_source.py

# 4. Load it
python db/load_source.py
```

Steps 3 and 4 are separate commands so you can regenerate without reloading and
reload without regenerating.

```
$ python db/generate_source.py
agency : Harcourt & Vine (harcourt_vine)
seed   : 20260819
output : /path/to/crm-mgrator/data/source/harcourt_vine
  landlords.csv       154 rows
  properties.csv      300 rows
  tenancies.csv       340 rows
  payments.csv      1,800 rows
  TOTAL             2,594 rows

$ python db/load_source.py
loaded : /path/to/crm-migrator/data/source/harcourt_vine
  raw.landlords       154 rows
  raw.properties      300 rows
  raw.tenancies       340 rows
  raw.payments      1,800 rows
  TOTAL              2,594 rows
```

`landlords.csv` holds 154 rows for 150 landlords: four of them exist twice in
Harcourt & Vine's own CRM under different refs, with contact details differing
only in case and whitespace. That is the within-agency version of the problem
the intermediate layer exists to solve.

### Verify before running dbt

```bash
docker compose exec -T postgres psql -U meridian -d crm_migrator < db/verify_load.sql
```

It checks three things: the row counts match the generator, every column is
still `text`, and the mess survived the trip. That last one matters — a load
that silently repairs encoding damage has done the cleaning for you, and the
project would be measuring nothing.

```
== the mess should have survived ==
 mojibake | embedded_newline | placeholder_nulls | empty_string | real_nulls
----------+------------------+-------------------+--------------+------------
        5 |                1 |                 8 |            3 |          5
```

`empty_string` and `real_nulls` being separate is the point. An unquoted empty
field in a CSV becomes `NULL` in Postgres; a quoted `""` becomes a zero-length
string. Both are in this export, from different code paths, and they mean the
same thing to a human and different things to SQL.

### When it fails

The loader derives its `COPY` column list from the CSV header and checks it
against the table, rather than letting `COPY` match columns by position:

```
$ python db/load_source.py
landlords.csv has columns not present in raw.landlords: ['vatnumber'].
Update db/ddl/01_raw_schema.sql.
$ echo $?
1
```

Positional matching would have loaded successfully and put VAT numbers in the
`name` column.

### Teardown

```bash
docker compose down -v     # -v also destroys the data volume
```

Without `-v` the volume survives and the next `docker compose up -d` starts
with the old data still in it.

---

## Layout

```
docker-compose.yml           Postgres 16.4, pinned, host port 5433
db/
  ddl/01_raw_schema.sql      raw schema + landing tables, every column text
  generate_source.py         messy agency export -> data/source/, fixed seed
  load_source.py             COPY each CSV into its raw table
  verify_load.sql            checks to run before pointing dbt at the database
data/source/                 generated, gitignored
```

---

## Known limitations

- **The generated data is synthetic.** The schema models a  lettings CRM and
  the defects are drawn from real ones, but no real agency's data is here.
- **Raw is single-tenant by design.** The loader truncates before loading, so
  only one agency's export is resident at a time. Phase 2 changes which export
  is loaded, not how many are loaded at once.
- **The raw schema is hardcoded.** Adding an agency with different column names
  means editing `db/ddl/01_raw_schema.sql`, not passing a flag.

---

Built with AI assistance, under manual review.
