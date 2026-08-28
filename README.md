# crm-migrator

A dbt project that cleans and models messy CRM exports from acquired UK
lettings agencies, for Meridian — a fictional lettings roll-up.

It is the remediation counterpart to
[`crm-migration-validator`](https://github.com/FergalMoriarty/crm-migration-validator),
which *detects* defects in a migration and deliberately refuses to fix any of
them. This project fixes them. The validator can then be re-run against the
result to check that the cleaning did what it claimed.

The two repos stay separate on purpose. A tool that both cleans data and
certifies its own cleaning is not evidence of anything.

**What this does not do.** It does not decide whether a migration is fit to
ship — that is the validator's job. It does not resolve landlord identity
across agencies yet; phase 2 is not built. It does not touch a production
system: the target is a local Postgres in Docker and the data is generated.

---

## The problem it models

An acquired agency hands over a CSV export from a CRM that humans have typed
into for a decade. In this one:

- Postcodes as `BT7 1NN`, `bt7 1nn`, `BT71NN`, `BT7  1NN`, and truncated `BT27 7R`
- Phone numbers as `07700 900123`, `+44 7700 900123`, `0044 7700900123`,
  `(028) 9649 612`, and bare `7700900123` where Excel treated the cell as a
  number and ate the leading zero
- Names as both `MCALLISTER, Fiona` and `Mrs Fiona McAllister`
- Dates in six formats, including `45292` — an Excel serial number
- Currency as `£1,250.00` text, with refunds in accounting brackets: `(400.00)`
- Encoding damage from a UTF-8 file read back as Windows-1252, so `Sinéad`
  arrives as `SinÃ©ad`
- Eleven spellings of "nothing": `''`, `'  '`, `N/A`, `n/a`, `-`, `.`, `none`,
  `NONE`, `NULL`, `unknown`, and a genuinely absent value
- Free-text notes carrying HTML tags, entities, tabs and embedded newlines
- Five properties owned by a landlord who is not in the export, six tenancies
  on a property that is not in the export
- Four landlords recorded twice under different references

None of it is random noise. Every defect is a real convention or a real failure
mode, which matters because cleaning rules written against random corruption do
not transfer to anything.

---

## Quick start

Requires Docker and Python 3.9–3.12.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 1. Postgres 16.4 on host port 5433 (not 5432 — you probably have one)
docker compose up -d

# 2. Create the raw schema and landing tables
docker compose exec -T postgres \
  psql -U meridian -d meridian_crm -v ON_ERROR_STOP=1 < db/ddl/01_raw_schema.sql

# 3. Generate one agency's deliberately messy export
python db/generate_source.py

# 4. Load it
python db/load_source.py

# 5. Verify the load before dbt touches it
docker compose exec -T postgres psql -U meridian -d meridian_crm < db/verify_load.sql

# 6. Build everything
cd crm_migrator
dbt deps
dbt build
```

Teardown: `docker compose down -v`. Without `-v` the data volume survives and
the next `up` starts with the old data still in it.

Generating and loading are separate commands so you can regenerate without
reloading and reload without regenerating.

```
$ python db/generate_source.py
agency : Harcourt & Vine (harcourt_vine)
seed   : 20260819
  landlords.csv       154 rows
  properties.csv      300 rows
  tenancies.csv       340 rows
  payments.csv      1,800 rows
  TOTAL             2,594 rows
```

154 rows for 150 landlords: four exist twice under different references, with
contact details differing only in case and whitespace.

---

## What a run looks like

```
$ dbt build
Found 64 data tests, 8 models, 1 snapshot, 4 sources, 604 macros

 1 of 73 OK created sql view model dbt_meridian_staging.stg_crm__landlords .. [CREATE VIEW in 0.49s]
 5 of 73 OK snapshotted dbt_meridian_snapshots.landlord_contact_snapshot .... [INSERT 0 0 in 1.23s]
...
35 of 73 WARN 5 relationships_stg_crm__properties_landlord_id__..._stg_crm__landlords_
36 of 73 WARN 6 relationships_stg_crm__tenancies_property_id__..._stg_crm__properties_
...
42 of 73 OK created sql table model dbt_meridian_marts.dim_landlord ........ [SELECT 155 in 0.29s]
61 of 73 OK created sql table model dbt_meridian_marts.fct_payment ......... [SELECT 1800 in 0.22s]

Done. PASS=71 WARN=2 ERROR=0 SKIP=0 TOTAL=73
```

The two warnings are the point, not noise: the orphaned foreign keys in the
agency's own export. They warn rather than error deliberately — see
[Two layers, two verdicts](#two-layers-two-verdicts).

### And a run that fails

Deleting a single sequence from the mojibake repair macro:

```
$ dbt build
 8 of 73 FAIL 2 not_mojibaked_stg_crm__payments_payment_reference ... [FAIL 2 in 0.23s]
20 of 73 FAIL 1 not_mojibaked_stg_crm__landlords_notes .............. [FAIL 1 in 0.08s]
21 of 73 FAIL 1 not_mojibaked_stg_crm__properties_description ....... [FAIL 1 in 0.06s]
31 of 73 FAIL 2 not_mojibaked_stg_crm__tenancies_comments ........... [FAIL 2 in 0.06s]
37 of 73 SKIP relation dbt_meridian_marts.dim_landlord .............. [SKIP]
...
Done. PASS=30 WARN=2 ERROR=4 SKIP=32 TOTAL=73
```

Four failures, thirty-two nodes skipped. The marts were never built from data
dbt had just proven was dirty.

`dbt run && dbt test` on the same fault builds them anyway and reports **six**
failures rather than four, because the damage has propagated downstream — and
leaves four tables in the marts schema that someone could query. That contrast
is the whole argument for `dbt build`, and it is invisible until a project has
more than one layer.

---

## The models

| Model | Layer | Materialised | Responsible for |
|---|---|---|---|
| `stg_crm__landlords` | staging | view | Encoding repair, placeholder collapse, name reordering, E.164 phones, postcode formatting, six date formats. 154 in, 154 out. |
| `stg_crm__properties` | staging | view | Same, plus bedroom parsing (`Studio` → 0) and property type canonicalisation. |
| `stg_crm__tenancies` | staging | view | Same, plus tenant contact details and tenancy dates. |
| `stg_crm__payments` | staging | view | Same, plus currency parsing including bracketed accounting negatives. |
| `landlord_contact_snapshot` | snapshot | table | SCD Type 2 history of landlord contact details, taken from raw *before* cleaning. |
| `dim_landlord` | marts | table | One row per landlord **record**, plus an Unknown member. 155 rows. |
| `dim_property` | marts | table | One row per property, plus an Unknown member. 301 rows. |
| `dim_tenancy` | marts | table | One row per tenancy, plus an Unknown member. 341 rows. |
| `fct_payment` | marts | table | One row per payment. 1,800 rows. Additive `amount`, refunds negative. |

Materialisation is set per layer in `dbt_project.yml`, not per model. Staging is
a view because the work is thin and there should be exactly one copy of the
truth. Marts are tables because they are queried repeatedly and joined across.

Every model and macro carries a comment block covering what it does, why it is
at that layer, and what the alternative was. Those comments are the
documentation; this README is the map.

---

## Design decisions worth arguing with

### Cleaned columns keep their original, but only where cleaning is lossy

`landlord_name_raw`, `email_raw` and `notes_raw` exist because the title is
dropped, a second email address is discarded, and free text loses HTML and line
structure. None of that can be reconstructed.

Postcode gets no twin — unparseable input passes through unchanged, so the
cleaned column already tells you everything. Parsed numerics and dates get a
`*_unparsed` column populated **only** when the parse failed. A full twin of
every parsed column would store 1,800 copies of `£750.00` to preserve the four
values that failed.

### Bad values are flagged, not nulled

`is_valid_email`, `is_valid_phone` and `is_valid_postcode` are three-valued:

- `true` — supplied, and it parses
- `false` — supplied, and it does not
- `NULL` — nothing was supplied, so there is nothing to judge

"Never recorded" and "recorded wrongly" send you to two different people. The
cost: `WHERE NOT is_valid_phone` does not return the missing ones.
`WHERE is_valid_phone IS NOT TRUE` does.

### Name case is not normalised

`initcap('MCALLISTER')` gives `Mcallister`. It also gives `O'neill`, and turns
`Ó Súilleabháin` into `Ó SúIlleabháin`. No case rule survives Irish and
Scottish surnames, so display names come out with the agency's own letters —
which looks odd in a report and is less wrong than the alternative.

Matching uses a separate `landlord_name_key`: lowercased, accents folded,
punctuation stripped. **Normalise for comparison, never for display.**

### Two layers, two verdicts

The `relationships` tests on staging are `severity: warn`. The same tests on the
marts are errors, and they pass.

Nothing about the data differs. The staging test reports what the agency sent —
orphans that exist in their CRM, that staging is forbidden from filtering out,
and that nobody can fix from inside this repo. A permanently red build trains
people to stop reading output, which also hides the failures that matter.

The mart test reports whether the warehouse is internally consistent, and it is
by construction, because every orphan is routed to a synthetic **Unknown**
dimension member rather than dropped or left NULL. A failure there means a
`coalesce` was removed — a bug in this project rather than a defect in the
source.

Note the contrast with the validator, which **fails** on an orphaned foreign
key. There it means the migration lost a parent row. Here it means the agency
did. Same query, different question.

### Staging is row-preserving, and that is load-bearing

154 in, 154 out. 1,800 in, 1,800 out. Asserted as a test.

Not housekeeping: the validator's first check compares source row count against
target row count. If staging quietly dropped the orphans, the validator would
report rows missing from the target — correctly, by its own rules, because it
cannot know the loss was deliberate. The two repos only pair up if this holds.

### The snapshot targets the source, not the mart

Snapshotting a model records changes to the *model*. Edit a cleaning rule and
every affected row appears to have changed, manufacturing fake history that
cannot afterwards be told from real history. Models are rebuildable; history is
not.

The cost, accepted knowingly: this snapshot records the mess. A phone number
reformatted from `07700 900123` to `+44 7700 900123` looks like a change when
nothing changed. Spurious versions can be filtered out later; invented ones
cannot be identified at all.

---

## Tests

64 data tests: 6 singular, 1 custom generic applied 10 times, 6 `dbt_utils`
generics, the rest built-in.

| Kind | Where | Used for |
|---|---|---|
| Built-in generic | YAML | structural claims a table makes about itself |
| `dbt_utils` generic | YAML | checks generic across every industry — ranges, expressions, proportions |
| Custom generic | `tests/generic/` | specific to this data, applied to many columns |
| Singular | `tests/` | spans models, reaches back to a source, or could never take an argument |

A generic test asks *is this column well-formed*. A singular test asks *is this
specific thing true about my warehouse*.

`not_mojibaked` is the custom one. It checks for unrepaired damage (`Ã`, `â€`,
`Â`) **and** for fragments (`™`, `€`) — the residue left when a short sequence
eats the front of a longer one. The second is the failure that survives a
careless fix, so it is the one worth having. It exists because the mojibake
macro was wrong twice and both faults were found by hand.

### Tests assert rules, not snapshots of rules

Row counts compare against `source()` rather than hardcoding 154. Hardcoding
freezes the fixture, not the invariant: regenerate the data and a correct model
fails, and the natural "fix" is to update the number — at which point the rule
is gone and nothing says so.

An earlier version had a `not_null_proportion` on email at `at_least: 0.85`.
Coverage was 90%, so it passed. That is a threshold reverse-engineered from the
data it tests, asserting nothing except "roughly as many emails as there are
today". It would fail a perfectly good second agency that holds fewer emails,
and it reads as rigour on a green run. It was replaced with
`assert_cleaning_does_not_discard_contact_details`, which compares the model
against the source; the threshold dropped to 0.4 as a pure collapse detector
with a comment saying so.

### Limitations asserted as passing tests

Where a limitation can be written as an executable assertion, it is, so nobody
reads a green run and concludes more than it proves.

`assert_dim_landlord_grain_is_record_not_person` asserts that duplicate
landlord records **exist**. It passes today and is meant to be deleted in phase
2 — when entity resolution lands, it fails, and its failure is the signal to
replace it with a `unique` test. The file says so.

The validator uses the same technique from the other direction, asserting a
**PASS** against a target that is demonstrably wrong, to freeze the fact that
row-count reconciliation cannot see offsetting errors.

---

## Documentation and lineage

```bash
cd crm_migrator
dbt docs generate
dbt docs serve       # http://localhost:8080
```

The lineage graph shows four raw sources feeding staging, staging feeding the
marts, and the snapshot hanging off `raw.landlords` rather than off
`dim_landlord` — the visual version of the argument above.

---

## Known limitations

- **The data is synthetic.** The schema models a UK lettings CRM and the
  defects are drawn from real ones, but no real agency's data is here.
- **Phase 2 is not built.** Entity resolution, the intermediate layer and the
  incremental `fct_payment` are planned, not written. The `intermediate` config
  path points at an empty directory and dbt says so on every run.
- **`dim_landlord`'s grain is one row per record, not per person.** 154 records
  describe 150 people. Anything counting rows there is counting records, and a
  "landlords by town" report will double-count four of them.
- **Entity resolution will be a heuristic.** Matching on a normalised name and
  email cannot find the same landlord under two different email addresses, and
  will merge two different people who share a name. Same limitation the
  validator states for its duplicate business key check.
- **Mojibake repair only fixes enumerated sequences.** The correct general
  solution — `convert_from(convert_to(txt, 'WIN1252'), 'UTF8')` — raises on any
  string that is *not* mojibaked but contains an accent, and plain SQL has no
  way to catch it. Characters Windows-1252 does not define are destroyed rather
  than mangled, and no repair recovers them.
- **Address parsing is not attempted.** Flat numbers appear in line 1, line 2,
  or as `2/14`, and no rule recovers them all without a Royal Mail PAF lookup.
  A best-effort split presented as a clean one is worse than no split.
- **Postcode validation checks shape, not existence.** `BT99 9ZZ` is
  well-formed and is not a real postcode.
- **The UK date convention is assumed and cannot be proven.** `03/04/2024` is 3
  April here. A US-configured export would parse silently and wrongly, and no
  test can catch it, because the information is not in the data. A validation
  suite can prove data is internally inconsistent; it cannot prove data means
  what you assumed.
- **Counting is not verifying.** The contact-details test asserts 138 emails in
  and 138 out. All 138 could be mangled and it would still pass.
- **`raw` is single-tenant.** The loader truncates before loading, so only one
  agency's export is resident at a time.
- **The snapshot's `unique_key` is agency-naive.** `landlordref` is unique
  within Harcourt & Vine and will collide with a second agency's numbering.
  This must be fixed *before* agency B is ever snapshotted: once two identities
  are merged into one history they cannot be unpicked, and that table is the
  one thing here that cannot be rebuilt.
- **No `dim_date`.** Postgres date functions answer everything this data
  supports. A generated date spine with no fiscal calendar in it is scaffolding
  that looks like modelling.
- **No `dim_tenant`.** The export has no tenant identifier, only a free-text
  name. A tenant dimension could only be built by matching on name, which would
  merge every Fiona McAllister in Belfast into one person.
- **Source freshness is configured on a one-off export**, which is not what the
  feature is for. It detects that you are about to run against yesterday's
  load, not that a feed has broken.
- **Credentials here are local-development defaults only.** `profiles.yml` uses
  `env_var` with a throwaway container password as the default. The rule it
  documents is that anything real goes in the environment with no default, so
  it fails loudly at parse time when missing.
- **`db/verify_load.sql` duplicates the placeholder list** from the
  `clean_null_placeholders` macro and has already drifted from it. It is a
  hand-run script rather than a test, so nothing catches the drift — itself a
  small illustration of why the equivalent list inside a *test* is duplicated
  deliberately.

---

## Layout

```
docker-compose.yml            Postgres 16.4, pinned, host port 5433
db/
  ddl/01_raw_schema.sql       raw schema, every column text, no constraints
  generate_source.py          messy agency export -> data/source/, fixed seed
  load_source.py              COPY one agency's CSVs into raw
  verify_load.sql             run before pointing dbt at the database
  verify_refactor.sql         checkpoint/diff pattern for behaviour-preserving refactors
crm_migrator/                 the dbt project
  models/staging/             one model per source table
  models/marts/               dimensional models
  models/intermediate/        empty until phase 2
  macros/                     authored cleaning macros
  snapshots/                  SCD Type 2 on landlord contact details
  tests/                      six singular tests
  tests/generic/              one custom generic test
docs/working-with-ai.md       how the AI assistance was directed and reviewed
data/source/                  generated, gitignored
```

`db/` is everything that exists before dbt does. `crm_migrator/` consumes what
`db/` produces, and never the reverse.

---

## Roadmap

Phase 1 is complete: landing zone, staging, macros, tests, marts, snapshot,
docs.

Phase 2, not yet built:

1. A second agency's export with genuinely incompatible conventions
2. An intermediate layer performing entity resolution across agencies
3. `fct_payment` as an incremental model with an explicit strategy choice
4. Re-running `crm-migration-validator` against the cleaned output

---

## A note on what this is and is not

Built in about a week, in planned increments, as a way of working through dbt's
specifics — project structure, `ref`/`source` resolution, macro authoring,
snapshot mechanics, materialisation choices, and the failure modes of each. The
commit history shows exactly that.

It is evidence of dimensional modelling and data quality judgement, and of
picking dbt up quickly. It is not a year of production dbt experience and is
not offered as one.

Built with AI assistance under manual review. The method, and four cases where
review caught something wrong, are in
[`docs/working-with-ai.md`](docs/working-with-ai.md).
