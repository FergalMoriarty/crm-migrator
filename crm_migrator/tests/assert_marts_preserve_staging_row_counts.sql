/*
    A SINGULAR TEST — marts must not lose rows either.

    The companion to assert_staging_preserves_source_row_counts. That one
    guards raw -> staging; this one guards staging -> marts, allowing exactly
    one extra row per dimension for the synthetic Unknown member.

    WHY THIS IS THE TEST THAT MATTERS MOST IN THE MARTS LAYER
        Every dimension join here is a LEFT JOIN with a coalesce to 'UNKNOWN'.
        Change any one of them to an inner join and rows disappear silently:
        the model builds, every other test passes, and the totals are quietly
        wrong. Six tenancies and five properties are one keystroke from
        vanishing at any time.

        It also catches the opposite failure. If a join fans out - a duplicate
        key in a dimension causing one fact row to become two - the count goes
        UP and this fails just as loudly. On a fact table carrying money, a
        silent fan-out is the more expensive of the two.
*/

with counts as (

    select 'dim_landlord' as model,
           (select count(*) from {{ ref('dim_landlord') }}) as mart_rows,
           (select count(*) from {{ ref('stg_crm__landlords') }}) + 1 as expected_rows
    union all
    select 'dim_property',
           (select count(*) from {{ ref('dim_property') }}),
           (select count(*) from {{ ref('stg_crm__properties') }}) + 1
    union all
    select 'dim_tenancy',
           (select count(*) from {{ ref('dim_tenancy') }}),
           (select count(*) from {{ ref('stg_crm__tenancies') }}) + 1
    union all
    -- No +1: a fact table has no unknown member. The Unknown rows exist so
    -- facts can point AT something, not so facts can be invented.
    select 'fct_payment',
           (select count(*) from {{ ref('fct_payment') }}),
           (select count(*) from {{ ref('stg_crm__payments') }})

)

select * from counts where mart_rows <> expected_rows
