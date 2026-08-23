/*
    A SINGULAR TEST — staging must not lose or invent rows.

    WHAT A SINGULAR TEST IS
        One .sql file, one specific assertion, no parameters. It lives in
        tests/ and returns the rows that fail. Unlike a generic test it is not
        attached to anything in YAML — its existence in this directory is
        enough, and dbt runs it as part of `dbt test` and `dbt build`.

    WHY THIS IS SINGULAR AND NOT GENERIC
        There is exactly one of it. It compares four specific models against
        four specific sources and there is no second place it could be
        applied. Making it generic would mean inventing an argument nobody
        will ever pass a second value to.

    WHAT IT PROTECTS
        The rule that staging is row-preserving: 154 landlords in, 154 out.
        This is not housekeeping. The crm-migration-validator's first check
        compares source row count against target row count. If staging quietly
        dropped the five properties whose landlordref does not resolve, the
        validator would report five rows missing from the target — correctly,
        by its own rules, because it cannot know the loss was deliberate.
        The two repos only pair up if this holds.

        It also catches the subtler failure: a join accidentally introduced
        into a staging model, fanning rows out. Row counts going UP is caught
        here just as loudly as row counts going down.

    WHY IT COMPARES AGAINST source() AND NOT A HARDCODED NUMBER
        Writing `= 154` would freeze the current seed rather than the rule.
        Regenerate the data with a different row count and a correct model
        would fail. The invariant is "same as the source", not "154".
*/

with counts as (

    select 'stg_crm__landlords'  as model,
           (select count(*) from {{ ref('stg_crm__landlords') }})  as model_rows,
           (select count(*) from {{ source('raw_crm', 'landlords') }}) as source_rows
    union all
    select 'stg_crm__properties',
           (select count(*) from {{ ref('stg_crm__properties') }}),
           (select count(*) from {{ source('raw_crm', 'properties') }})
    union all
    select 'stg_crm__tenancies',
           (select count(*) from {{ ref('stg_crm__tenancies') }}),
           (select count(*) from {{ source('raw_crm', 'tenancies') }})
    union all
    select 'stg_crm__payments',
           (select count(*) from {{ ref('stg_crm__payments') }}),
           (select count(*) from {{ source('raw_crm', 'payments') }})

)

select *
from counts
where model_rows <> source_rows
