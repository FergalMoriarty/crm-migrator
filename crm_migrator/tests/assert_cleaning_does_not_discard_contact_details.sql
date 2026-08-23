/*
    A SINGULAR TEST — cleaning must not eat contact details.

    WHAT IT ASSERTS
        The number of landlords with a usable email in staging equals the
        number whose raw email is neither blank nor one of the placeholder
        spellings. Same for phone. Cleaning is allowed to REFORMAT a value; it
        is not allowed to lose one.

    WHY THIS REPLACES A THRESHOLD
        The first version of this check was a dbt_utils.not_null_proportion
        with at_least: 0.85. That number was reverse-engineered from the
        current data — coverage is about 90%, so 85% passes — which means it
        asserted nothing except "roughly as many emails as there are today".

        It had three specific problems worth naming, because the shape recurs:
          1. No authority. Harcourt & Vine never agreed to 85% coverage. The
             number came from nowhere.
          2. It can only fail for the wrong reason. A genuine collapse would
             trip it, but so would a perfectly good second agency that holds
             emails for 80% of its landlords — which is likely in phase 2.
             The test cannot tell "something broke" from "this one differs".
          3. It reads as rigour. A green run looks like "email coverage is
             fine". It meant "coverage is above a number I picked to pass".

        This version compares the model against the SOURCE instead, which is
        the same move as assert_staging_preserves_source_row_counts: assert
        the rule, not a snapshot of the rule's current output. It holds for
        any agency at any coverage level, and fails only when the cleaning
        itself is destructive — which is the thing actually worth catching.

    WHAT IT CANNOT CATCH
        A value that survives but is mangled. 138 emails in, 138 out, all of
        them wrong, and this passes. Counting is not verifying. The
        not_mojibaked tests and the _raw columns cover different parts of that
        gap, and neither closes it completely.

    THE PLACEHOLDER LIST IS DUPLICATED HERE
        It also lives in the clean_null_placeholders macro. That duplication
        is deliberate: a test that imports the implementation it is testing
        proves only that the implementation equals itself. If someone adds a
        spelling to the macro and not to this file, the test fails and asks
        them whether they meant to. That is the test doing its job.
*/

with source_counts as (

    select
        count(*) filter (
            where lower(trim(coalesce(email, ''))) not in
                ('', 'n/a', 'na', 'none', 'null', '-', '.', 'unknown', 'not known', 'tbc')
        ) as emails_supplied,
        count(*) filter (
            where lower(trim(coalesce(phone, ''))) not in
                ('', 'n/a', 'na', 'none', 'null', '-', '.', 'unknown', 'not known', 'tbc')
        ) as phones_supplied
    from {{ source('raw_crm', 'landlords') }}

),

model_counts as (

    select
        count(email) as emails_present,
        -- phone_raw survives in the model, so a number that was supplied but
        -- failed to parse still counts as "not discarded": it is recorded as
        -- invalid rather than thrown away. Counting the parsed column alone
        -- would fail this test for numbers we deliberately kept and flagged.
        count(*) filter (where is_valid_phone is not null) as phones_present
    from {{ ref('stg_crm__landlords') }}

)

select
    'email' as field, emails_supplied as supplied, emails_present as present
from source_counts, model_counts
where emails_supplied <> emails_present

union all

select
    'phone', phones_supplied, phones_present
from source_counts, model_counts
where phones_supplied <> phones_present
