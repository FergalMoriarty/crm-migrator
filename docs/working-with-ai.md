# Working with AI on this project

The models and macros here were largely drafted by an AI assistant and reviewed
before landing. This note records the working method and what review caught,
because "built with AI assistance" says nothing on its own about whether the
output was checked.

The method is the transferable part. Generating four dbt models takes an
afternoon; the engineering problem is what stops the wrong ones reaching
production.

---

## Constraints the assistant worked under

**Reasoning goes inline, in the code.** Every model and macro carries a comment
block covering what it does, why it sits at that layer, and what alternative
was rejected. A comment saying "materialised as a view" cannot be argued with.
One saying "views here because staging is thin and there should be one copy of
the truth; a table trades a stale window for query speed we do not need" can be
— and that is the difference between a comment and documentation.

**One layer or one concept per change, then stop.** Twelve increments were
planned before any code was written; eight are built. Each increment ends with
a build against real data and a result checked before the next begins. Most of
the faults below were found because there was a point at which the only task
was verifying the previous step.

**Rejected alternatives are stated, not implied.** Where a decision could
reasonably have gone the other way — `dim_tenancy` as a dimension rather than
an accumulating snapshot fact, no `dim_date`, no `dim_tenant`, `Studio` mapped
to 0 bedrooms rather than NULL — the model says what the alternative was and
why it lost. Those are the comments worth reading in six months.

**Behaviour-preserving changes are diffed, not trusted.** Any refactor that
should not change output gets a checkpoint of every affected model before, and
`EXCEPT` in both directions after. The pattern is kept in
`db/verify_refactor.sql`.

---

## Four things review caught

Each is a different failure mode of AI-drafted work.

### 1. A loop that ran backwards — logic correct, output wrong

The mojibake repair macro builds eighteen nested `replace()` calls with a Jinja
loop. The generated SQL applied the replacement list bottom-up, the opposite of
what the macro's own comment claimed.

It produced correct output on this data by luck. It breaks the moment a short
sequence is a prefix of a longer one — and `'Â'` on its own already is a prefix
of `'Â£'` and `'Â€“'`:

```sql
-- short first: leaves a fragment
replace(replace('â€™', 'â€', '-'), 'â€™', '’')   -->  '-™'
-- long first: correct
replace(replace('â€™', 'â€™', '’'), 'â€', '-')   -->  '’'
```

**Failure mode:** code that works for the wrong reason. Found by reading the
compiled SQL rather than the macro source — the ordering is only visible after
Jinja renders.

### 2. Five missing cases that no amount of reasoning would find

The same macro was missing five sequences. Some notes had been uppercased
*after* the encoding damage, and `'â'.upper()` is `'Â'` — so `â€“` becomes
`Â€“`, a sequence that appears in no encoding table.

Found by querying the built model for leftover `™` and `€` fragments, not by
reasoning harder about UTF-8.

**Failure mode:** a plausible, complete-looking enumeration that is incomplete.
The fix was a custom generic test, `not_mojibaked`, so the next missing sequence
is caught by `dbt build` rather than by someone reading a report.

### 3. A threshold reverse-engineered from the data

A `dbt_utils.not_null_proportion` test on email was set to `at_least: 0.85`.
Actual coverage was 90%, so it passed.

The number came from nowhere. No agency agreed to 85% email coverage. The test
could only fail for the wrong reason — a second agency holding fewer emails
would trip it — and a green run read as "coverage is fine" when it meant
"coverage is above a number chosen to make this pass".

Replaced with a test comparing the model against the source: however many
non-placeholder emails arrive in raw, exactly that many must appear in staging.
That holds at any coverage level, for any agency, and fails only when cleaning
is genuinely destructive.

**Failure mode:** output that looks like rigour and asserts nothing. The most
likely of the four to survive review, because it is green and has a number in
it.

### 4. A regression visible only in a diff

Extracting the cleaning logic into macros left row counts identical and every
test passing, while silently changing two rows out of 154: landlords whose
email ended in a semicolon were now flagged invalid, because one of three
inline copies of the cleaning tested the address before the semicolon was
stripped.

Caught by the checkpoint diff. The fix — derive the value once in a CTE and
reference the name — is also the general lesson: every repetition of an
expression is somewhere it can be repeated slightly wrong.

The verification script itself needed a second pass. Its first version tested
two flags in one query while displaying the column for only one of them, so ten
rows that had changed on *phone* appeared beside a valid email address and read
as regressions. **One query per claim; show the column the claim is about.**

---

## What the method comes down to

**Read the compiled SQL.** dbt renders Jinja before Postgres sees anything.
Both macro faults above were invisible in the macro and obvious in
`target/compiled/`.

**Query the output rather than reasoning about it.** The missing sequences came
from looking for fragments in a built model. No amount of thinking about
encodings would have produced that list.

**Diff refactors against a checkpoint.** Behaviour-preserving changes are where
an assistant is most useful and where silent damage is hardest to see, because
the tests that would catch it are usually the ones being refactored.

**Distrust anything with a threshold in it.** Numbers that make a test pass on
today's data are the most confident-looking thing an assistant produces.

**Make it stop between layers.** Nothing above would have been found in a single
pass that generated the whole project.

---

## What was not delegated

The increment plan and layer boundaries. The grain of every dimensional model
and the argument for it. The decision to route orphaned foreign keys to an
Unknown member rather than drop them, and the reason staging must stay
row-preserving for the validator to remain meaningful. Which limitations were
acceptable and which had to be fixed. Every judgement recorded in a model
comment as a decision rather than a fact.

The assistant wrote most of the SQL. It did not decide what the SQL was for.
