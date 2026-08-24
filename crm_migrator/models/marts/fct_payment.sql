/*
    fct_payment

    GRAIN
        One row per payment transaction. 1,800 rows in, 1,800 rows out.

        Declaring the grain in one sentence, before writing any SQL, is the
        discipline that keeps a fact table honest. Every column below is
        either a key at that grain, a measure at that grain, or a degenerate
        dimension at that grain. Anything that is none of those does not
        belong.

    THE MEASURE
        amount, and it is fully additive: sum it across any combination of
        payment method, tenancy, property, landlord and date and the answer is
        meaningful. Refunds are negative, so a SUM is a net figure and
        needs no special handling - which is the entire reason the bracketed
        accounting negatives had to be parsed correctly in staging. 42 rows
        written '(400.00)' would otherwise add rather than subtract, and the
        error would be twice the refund total, in the wrong direction, on
        every report.

    WHY THE DIMENSION KEYS ARE FLATTENED ONTO THE FACT
        landlord_key and property_key are here as well as tenancy_key, even
        though both could be reached by joining through dim_tenancy. That is
        deliberate: a star schema is meant to answer "payments by landlord"
        with one join, not three. Snowflaking - making the query walk the
        chain - saves storage nobody is short of and costs a join on every
        query anyone writes.
        The keys are resolved through the dimensions, so a payment on an
        orphaned tenancy carries 'UNKNOWN' the whole way up rather than
        dropping out.

    DEGENERATE DIMENSIONS
        payment_id and payment_reference sit on the fact with no dimension
        table behind them. That is the correct treatment for an attribute at
        the fact's own grain: a dim_payment_reference would have exactly as
        many rows as the fact and contain one column, which is a join for
        nothing.
        payment_method is different - six values, repeated 1,800 times. It is
        also left on the fact, because a dimension with six rows and no other
        attributes buys nothing but a join. If it later gains attributes -
        settlement lag, whether it is a mandate, which processor - it earns a
        dimension.

    NO dim_date, DELIBERATELY
        The textbook answer is a date dimension with fiscal periods, holidays
        and named day parts, joined by a date key. It is not here because
        nothing in this project needs it: Postgres date functions answer every
        question this data supports, and a dim_date built from a generated
        series with no fiscal calendar in it is scaffolding that looks like
        modelling. It earns its place the moment someone asks for figures by
        UK tax year or wants to exclude bank holidays from an arrears
        calculation. Recorded in the README as a limitation rather than built
        speculatively.
*/

with payments as (

    select * from {{ ref('stg_crm__payments') }}

),

tenancies as (

    select tenancy_key, tenancy_id, property_key, source_agency
    from {{ ref('dim_tenancy') }}
    where not is_unknown_member

),

properties as (

    select property_key, landlord_key
    from {{ ref('dim_property') }}

)

select
    -- Surrogate key for the fact itself. Not strictly required - payment_id
    -- is unique - but it keeps every table in the mart joinable the same way,
    -- and it survives the day two agencies both number a payment R000001.
    {{ dbt_utils.generate_surrogate_key(['p.source_agency', 'p.payment_id']) }} as payment_key,

    -- FOREIGN KEYS
    coalesce(t.tenancy_key, 'UNKNOWN')     as tenancy_key,
    coalesce(t.property_key, 'UNKNOWN')    as property_key,
    coalesce(pr.landlord_key, 'UNKNOWN')   as landlord_key,

    -- DEGENERATE DIMENSIONS
    p.payment_id,
    p.tenancy_id as tenancy_id_as_supplied,
    p.payment_reference,
    p.payment_method,
    p.source_agency,

    -- DATE
    p.paid_on,

    -- MEASURE
    p.amount,

    -- FLAGS
    p.is_refund,
    (t.tenancy_key is null) as has_unknown_tenancy,
    (p.amount is null)      as amount_failed_to_parse,

    p.loaded_at

from payments p
left join tenancies t
  on  t.tenancy_id   = p.tenancy_id
  and t.source_agency = p.source_agency
left join properties pr
  on  pr.property_key = t.property_key
