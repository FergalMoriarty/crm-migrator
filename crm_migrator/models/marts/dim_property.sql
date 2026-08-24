/*
    dim_property

    GRAIN
        One row per property in the agency's export, plus one Unknown row.
        300 + 1 = 301.

    THE FOREIGN KEY IS A SURROGATE KEY, NOT THE AGENCY'S REF
        landlord_key resolves through dim_landlord. Five properties reference
        a landlordref that never arrived, and those get 'UNKNOWN' rather than
        NULL and rather than being dropped. See dim_landlord for the reasoning
        and for why option 3 is the only honest one.

        The consequence worth noticing: the relationships test on this model
        PASSES, where the equivalent test on stg_crm__properties WARNS. Nothing
        about the data changed. The staging test reports what the agency sent;
        the mart test reports whether the warehouse is internally consistent.
        Both are true, and a project that only had one of them would be
        missing something.

    monthly_rent IS AN ATTRIBUTE HERE, AND THAT IS ARGUABLE
        A rent is a number that changes over time, which makes it feel like a
        fact. It is here as a dimension attribute because it is the rent
        CURRENTLY ADVERTISED for the property - a property characteristic at a
        point in time - and because the export gives one value with no history
        to model. Type 1: it is overwritten every run and yesterday's figure
        is gone.
        The rent actually CHARGED under a tenancy is a different number and
        lives on dim_tenancy. The rent actually PAID is fct_payment. Three
        rents, three grains, and conflating any two of them is how a lettings
        report ends up wrong in a way nobody can explain.

    NO ADDRESS PARSING
        address_line_1 and address_line_2 are passed through as the agency
        wrote them, with the flat number sometimes in one and sometimes in the
        other. Splitting them into a structured address is best-effort without
        a Royal Mail PAF lookup, and a best-effort split presented as a clean
        one is worse than no split. Stated in the README as a limitation.
*/

with properties as (

    select * from {{ ref('stg_crm__properties') }}

),

landlords as (

    select landlord_key, landlord_id, source_agency
    from {{ ref('dim_landlord') }}
    where not is_unknown_member

),

joined as (

    select
        {{ dbt_utils.generate_surrogate_key(['p.source_agency', 'p.property_id']) }} as property_key,

        -- coalesce, not an inner join. An inner join here would silently drop
        -- the five orphans and change the row count, which is exactly what
        -- assert_marts_preserve_staging_row_counts exists to catch.
        coalesce(l.landlord_key, 'UNKNOWN') as landlord_key,

        p.property_id,
        p.landlord_id as landlord_id_as_supplied,
        p.source_agency,

        p.address_line_1,
        p.address_line_2,
        p.town,
        p.postcode,
        p.is_valid_postcode,

        p.bedrooms,
        p.property_type,
        p.monthly_rent,
        p.date_listed,
        p.description,

        (l.landlord_key is null) as has_unknown_landlord,
        false as is_unknown_member,
        p.loaded_at

    from properties p
    left join landlords l
      on  l.landlord_id    = p.landlord_id
      and l.source_agency  = p.source_agency

),

unknown_member as (

    select
        'UNKNOWN'          as property_key,
        'UNKNOWN'          as landlord_key,
        'UNKNOWN'          as property_id,
        null::text         as landlord_id_as_supplied,
        'unknown'          as source_agency,
        null::text         as address_line_1,
        null::text         as address_line_2,
        null::text         as town,
        null::text         as postcode,
        null::boolean      as is_valid_postcode,
        null::int          as bedrooms,
        null::text         as property_type,
        null::numeric(12,2) as monthly_rent,
        null::date         as date_listed,
        'Synthetic row. Tenancies referencing a property absent from the export point here.' as description,
        false              as has_unknown_landlord,
        true               as is_unknown_member,
        null::timestamptz  as loaded_at

)

select * from joined
union all
select * from unknown_member
