/*
    stg_crm__payments

    One clean row per source row, 1,800 in and 1,800 out. The shared reasoning
    is in stg_crm__landlords.sql and not repeated.

    THE INTERESTING FIELD HERE IS amount, because this export writes negatives
    two different ways and one of them is invisible to a naive parse. See the
    comment on that column.

    WHICH ORIGINALS ARE KEPT
        payment_reference_raw, because cleaning it strips markup and collapses
        whitespace.
        amount_unparsed and paid_on_unparsed, populated only when the parse
        failed. On 1,800 rows a full twin for every column would be mostly
        duplicate storage of values nothing needs.
*/

with source as (

    select * from {{ source('raw_crm', 'payments') }}

),

repaired as (

    select
        paymentref,
        tenancyref,
        paidon,
        amount,
        method,
        {{ repair_mojibake('reference') }} as reference,
        _source_file,
        _loaded_at,
        reference as payment_reference_raw

    from source

),

nulled as (

    select
        paymentref,
        tenancyref,

        {%- set nothing = "('', 'n/a', 'na', 'none', 'null', '-', '.', 'unknown', 'not known', 'tbc')" %}

        case when lower(trim(paidon)) in {{ nothing }} then null else trim(paidon) end as paidon,
        case when lower(trim(amount)) in {{ nothing }} then null else trim(amount) end as amount,
        case when lower(trim(method)) in {{ nothing }} then null else trim(method) end as method,

        nullif(
            trim(
                regexp_replace(
                    regexp_replace(
                        replace(replace(replace(replace(replace(
                            reference,
                            '&nbsp;', ' '), '&amp;', '&'), '&lt;', '<'), '&gt;', '>'), '&#39;', ''''),
                        '<[^>]*>', ' ', 'g'),
                    '\s+', ' ', 'g')
            ),
            ''
        ) as reference,

        _source_file,
        _loaded_at,
        payment_reference_raw

    from repaired

),

prepared as (

    select
        *,
        /*
            NEGATIVES ARRIVE TWO WAYS.
            '-£120.00' is obvious. '(120.00)' is accounting notation for the
            same thing, and it is the dangerous one: strip the non-numeric
            characters and it becomes '120.00', a refund silently recorded as
            income. Every total in every downstream report would be wrong by
            twice the refund and nothing would look broken.

            So the bracket form is detected on the ORIGINAL string, before any
            stripping, and applied as a sign afterwards.
        */
        (amount ~ '^\s*\(.*\)\s*$')                             as amount_is_bracketed,
        nullif(regexp_replace(amount, '[^0-9.\-]', '', 'g'), '') as amount_digits
    from nulled

),

parsed as (

    select
        paymentref as payment_id,
        tenancyref as tenancy_id,

        case
            when paidon is null                     then null
            when paidon ~ '^\d{4}-\d{2}-\d{2}'      then to_date(left(paidon, 10), 'YYYY-MM-DD')
            when paidon ~ '^\d{2}/\d{2}/\d{4}'      then to_date(left(paidon, 10), 'DD/MM/YYYY')
            when paidon ~ '^\d{2}-\d{2}-\d{4}$'     then to_date(paidon, 'DD-MM-YYYY')
            when paidon ~ '^\d{1,2}/\d{1,2}/\d{2}$' then to_date(paidon, 'FMDD/FMMM/YY')
            when paidon ~ '^\d{5}$'                 then date '1899-12-30' + paidon::int
            else null
        end as paid_on,

        case
            when paidon is null then null
            when paidon ~ '^\d{4}-\d{2}-\d{2}|^\d{2}/\d{2}/\d{4}|^\d{2}-\d{2}-\d{4}$|^\d{1,2}/\d{1,2}/\d{2}$|^\d{5}$'
                then null
            else paidon
        end as paid_on_unparsed,

        case
            when amount_digits is null                        then null
            when amount_digits !~ '^-?[0-9]+(\.[0-9]+)?$'     then null
            when amount_is_bracketed then -1 * amount_digits::numeric(12,2)
            else amount_digits::numeric(12,2)
        end as amount,

        case
            when amount is null                           then null
            when amount_digits ~ '^-?[0-9]+(\.[0-9]+)?$'  then null
            else amount
        end as amount_unparsed,

        /*
            METHOD — nine spellings of five things. 'S/O' and 'Standing Order'
            are the same instruction; BACS and a standing order are not, even
            though a standing order is executed over BACS, because the agency
            uses them to mean "one-off transfer" and "recurring mandate".
            Merging them would lose that distinction, so they stay apart.
        */
        case
            when method is null                                  then null
            when lower(method) in ('s/o', 'standing order', 'so') then 'standing_order'
            when lower(method) = 'bacs'                          then 'bacs'
            when lower(method) = 'cash'                          then 'cash'
            when lower(method) = 'card'                          then 'card'
            when lower(method) = 'cheque'                        then 'cheque'
            else 'unknown'
        end as payment_method,

        reference as payment_reference,
        payment_reference_raw,

        split_part(_source_file, '/', 1) as source_agency,
        _source_file                     as source_file,
        _loaded_at                       as loaded_at

    from prepared

)

select
    payment_id,
    tenancy_id,
    paid_on,
    paid_on_unparsed,
    amount,
    amount_unparsed,
    (amount < 0) as is_refund,
    payment_method,
    payment_reference,
    source_agency,
    source_file,
    loaded_at,
    payment_reference_raw
from parsed
