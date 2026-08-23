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

        {{ clean_null_placeholders('paidon') }} as paidon,
        {{ clean_null_placeholders('amount') }} as amount,
        {{ clean_null_placeholders('method') }} as method,

        {{ clean_free_text('reference') }} as reference,

        _source_file,
        _loaded_at,
        payment_reference_raw

    from repaired

),

parsed as (

    select
        paymentref as payment_id,
        tenancyref as tenancy_id,

        {{ parse_uk_date('paidon') }} as paid_on,
        {{ keep_if_unparsed('paidon', parse_uk_date('paidon')) }} as paid_on_unparsed,

        /*
            Negatives arrive two ways: '-£120.00' and '(120.00)'. The second
            is accounting notation and is the dangerous one — strip the
            non-numeric characters and it becomes a positive, booking a refund
            as income. parse_currency detects the bracket on the original
            string before stripping. That single ordering decision is why it
            is a macro rather than four hand-written copies.
        */
        {{ parse_currency('amount') }} as amount,
        {{ keep_if_unparsed('amount', parse_currency('amount')) }} as amount_unparsed,

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

    from nulled

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
