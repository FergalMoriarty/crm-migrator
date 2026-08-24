/*
    dim_tenancy

    GRAIN
        One row per tenancy, plus one Unknown row. 340 + 1 = 341.

    WHY A TENANCY IS A DIMENSION HERE AND NOT A FACT
        This is the most arguable decision in the marts layer and it deserves
        the argument rather than an assertion.

        A tenancy has dates, a rent and a deposit, which makes it look like a
        fact - specifically an accumulating snapshot, the Kimball pattern for
        a process with a defined lifecycle and milestone dates that fill in
        over time (agreed, started, renewed, ended).

        It is a dimension here because of what the business measures. The
        measurable event in a lettings agency is money moving: rent received,
        fees charged, deposits returned. That is fct_payment. A tenancy is the
        CONTEXT in which those events happen - the thing you group payments
        by. Context is a dimension.

        The case for the other choice, honestly: if the questions were about
        the lifecycle itself - how long from listing to first payment, what
        proportion of tenancies renew, how long properties sit empty - then an
        accumulating snapshot fact with one row per tenancy and a column per
        milestone would be the right model, and this dimension would be
        awkward. Those are real lettings questions.
        The deciding factor is that this export has exactly two milestone
        dates and no renewal history, so an accumulating snapshot would have
        almost nothing to accumulate. If a later export carries the full
        lifecycle, revisit this.

    THERE IS NO is_active FLAG, STILL
        Whether a tenancy is current depends on comparing end_date to today,
        which makes the answer change without the data changing - a table that
        is true on Monday and false on Tuesday with no run in between. The
        model exposes start_date and end_date and lets the question be asked
        against an explicit date.
        NULL end_date is genuinely ambiguous: either open-ended, or never
        recorded. The export does not distinguish and neither does this model.
        Anything that treats NULL as "still running" is making an assumption,
        and it should make it where a reader can see it.
*/

with tenancies as (

    select * from {{ ref('stg_crm__tenancies') }}

),

properties as (

    select property_key, property_id, source_agency
    from {{ ref('dim_property') }}
    where not is_unknown_member

),

joined as (

    select
        {{ dbt_utils.generate_surrogate_key(['t.source_agency', 't.tenancy_id']) }} as tenancy_key,
        coalesce(p.property_key, 'UNKNOWN') as property_key,

        t.tenancy_id,
        t.property_id as property_id_as_supplied,
        t.source_agency,

        /*
            TENANT DETAILS ARE ATTRIBUTES OF THE TENANCY, NOT A dim_tenant.

            A separate tenant dimension would be the textbook answer, and it
            would be wrong on this data. The export gives one free-text name
            per tenancy with no tenant identifier of any kind, so a
            dim_tenant could only be built by matching on name - which would
            merge every Fiona McAllister in Belfast into one person and split
            anyone who moved and changed their email.
            Inventing an entity the source cannot support produces a
            dimension that looks authoritative and is fiction. The details
            stay here, at a grain the data actually justifies.
        */
        t.tenant_name,
        t.tenant_email,
        t.is_valid_email,
        t.tenant_phone,
        t.is_valid_phone,

        t.start_date,
        t.end_date,
        t.rent,
        t.deposit_held,
        t.comments,

        (p.property_key is null) as has_unknown_property,
        false as is_unknown_member,
        t.loaded_at

    from tenancies t
    left join properties p
      on  p.property_id   = t.property_id
      and p.source_agency = t.source_agency

),

unknown_member as (

    select
        'UNKNOWN'           as tenancy_key,
        'UNKNOWN'           as property_key,
        'UNKNOWN'           as tenancy_id,
        null::text          as property_id_as_supplied,
        'unknown'           as source_agency,
        'Unknown tenant'    as tenant_name,
        null::text          as tenant_email,
        null::boolean       as is_valid_email,
        null::text          as tenant_phone,
        null::boolean       as is_valid_phone,
        null::date          as start_date,
        null::date          as end_date,
        null::numeric(12,2) as rent,
        null::numeric(12,2) as deposit_held,
        'Synthetic row. Payments referencing a tenancy absent from the export point here.' as comments,
        false               as has_unknown_property,
        true                as is_unknown_member,
        null::timestamptz   as loaded_at

)

select * from joined
union all
select * from unknown_member
