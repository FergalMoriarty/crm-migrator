/*
    A SINGULAR TEST — accounting notation must survive parsing.

    WHAT IT ASSERTS
        Every payment whose source amount was written in brackets — '(400.00)',
        the accounting convention for a negative — is negative in the model.

    WHY THIS IS WORTH A TEST OF ITS OWN
        It is the single most consequential line of SQL in the staging layer
        and the one most likely to be lost in a refactor. Strip the
        non-numeric characters before checking for the bracket and '(400.00)'
        becomes 400.00: a refund booked as income, every downstream total
        wrong by twice the refund, and nothing anywhere looking broken.
        42 of the 1,800 payments are written this way.

        This is a test that freezes a DECISION rather than covering a branch.
        If someone simplifies parse_currency and drops the bracket detection,
        the model still builds, the row counts still match, every other test
        still passes, and this one fails. That is exactly what it is for.

    WHY SINGULAR
        It reaches back to raw.payments to compare against the original text,
        which is specific to this one model and this one column. A generic
        test attached to a column cannot see a different table.
*/

select
    r.paymentref,
    r.amount   as source_text,
    p.amount   as parsed_amount
from {{ source('raw_crm', 'payments') }} r
join {{ ref('stg_crm__payments') }} p
  on p.payment_id = r.paymentref
where r.amount ~ '^\s*\(.*\)\s*$'
  and (p.amount is null or p.amount >= 0)
