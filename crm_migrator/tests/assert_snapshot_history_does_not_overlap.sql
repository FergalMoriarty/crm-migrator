/*
    A SINGULAR TEST — no landlord may be two things at once.

    WHAT IT ASSERTS
        For any landlordref, no two versions have overlapping validity
        windows, and there is at most one open version (dbt_valid_to IS NULL).

    WHY THIS IS WORTH TESTING WHEN DBT WRITES THE MERGE ITSELF
        Because the thing most likely to break it is not dbt. It is a change
        to unique_key. Point a snapshot at a key that is not actually unique
        in the source — or at a natural key that stops being unique when a
        second agency arrives with its own numbering — and dbt will happily
        maintain two interleaved histories under one key, each closing the
        other off. The result looks like a landlord who changed their phone
        number forty times.

        That failure is silent. Row counts look plausible, dbt reports
        success, and the damage only shows when someone asks "what was this
        landlord's number in March" and gets two answers.

    WHY IT MATTERS MORE HERE THAN IN A NORMAL PROJECT
        A snapshot cannot be rebuilt. Every other model in this project can be
        dropped and regenerated from raw; this one records history the source
        does not keep. A corruption here is permanent, so it is worth catching
        on the run that introduces it rather than the quarter that reports on
        it.

    THE OVERLAP CONDITION
        Two windows [a_from, a_to) and [b_from, b_to) overlap when
        a_from < b_to and b_from < a_to. NULL dbt_valid_to means "still open",
        treated as infinity via coalesce. The self-join uses < on dbt_scd_id
        rather than <> so each pair is examined once rather than twice.
*/

with versions as (

    select
        landlordref,
        dbt_scd_id,
        dbt_valid_from,
        coalesce(dbt_valid_to, 'infinity'::timestamp) as dbt_valid_to
    from {{ ref('landlord_contact_snapshot') }}

),

overlapping as (

    select
        a.landlordref,
        a.dbt_valid_from as window_a_from,
        a.dbt_valid_to   as window_a_to,
        b.dbt_valid_from as window_b_from,
        b.dbt_valid_to   as window_b_to
    from versions a
    join versions b
      on  a.landlordref = b.landlordref
      and a.dbt_scd_id  < b.dbt_scd_id
      and a.dbt_valid_from < b.dbt_valid_to
      and b.dbt_valid_from < a.dbt_valid_to

),

multiple_open as (

    select
        landlordref,
        null::timestamp as window_a_from, null::timestamp as window_a_to,
        null::timestamp as window_b_from, null::timestamp as window_b_to
    from {{ ref('landlord_contact_snapshot') }}
    where dbt_valid_to is null
    group by landlordref
    having count(*) > 1

)

select * from overlapping
union all
select * from multiple_open
