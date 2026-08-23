/*
    stg_crm__properties

    One clean row per source row, 300 in and 300 out. Renames, casts,
    normalises. No joins, no deduplication, no filtering.

    The reasoning behind the shared techniques — why encoding repair runs
    first, why the eleven placeholder spellings are collapsed, why bad values
    are flagged rather than nulled — is written out once in
    stg_crm__landlords.sql and not repeated here.

    WHICH ORIGINALS ARE KEPT
        description_raw, because cleaning it strips HTML and collapses line
        breaks, and that content cannot be reconstructed.
        bedrooms_unparsed and monthly_rent_unparsed hold the source text ONLY
        when the parse failed, so the evidence exists exactly where there is
        something to explain and nowhere else.
        Postcode, town and property type get no twin: nothing is destroyed
        that the cleaned value does not already tell you.
*/

with source as (

    select * from {{ source('raw_crm', 'properties') }}

),

repaired as (

    select
        propref,
        landlordref,
        {{ repair_mojibake('addr1') }}       as addr1,
        {{ repair_mojibake('addr2') }}       as addr2,
        {{ repair_mojibake('town') }}        as town,
        {{ repair_mojibake('postcode') }}    as postcode,
        {{ repair_mojibake('description') }} as description,
        beds,
        proptype,
        monthlyrent,
        datelisted,
        _source_file,
        _loaded_at,
        description as description_raw

    from source

),

nulled as (

    select
        propref,
        landlordref,

        {{ clean_null_placeholders('addr1') }}       as addr1,
        {{ clean_null_placeholders('addr2') }}       as addr2,
        {{ clean_null_placeholders('town') }}        as town,
        {{ clean_null_placeholders('postcode') }}    as postcode,
        {{ clean_null_placeholders('beds') }}        as beds,
        {{ clean_null_placeholders('proptype') }}    as proptype,
        {{ clean_null_placeholders('monthlyrent') }} as monthlyrent,
        {{ clean_null_placeholders('datelisted') }}  as datelisted,

        {{ clean_free_text('description') }} as description,

        _source_file,
        _loaded_at,
        description_raw

    from repaired

),

parsed as (

    select
        propref     as property_id,
        landlordref as landlord_id,

        addr1 as address_line_1,
        addr2 as address_line_2,
        initcap(town) as town,

        {{ format_uk_postcode('postcode') }} as postcode,

        /*
            BEDROOMS — '1', '2', 'Studio', '2 bed', '3.0' and ''.
            'Studio' is mapped to 0 rather than NULL: a studio genuinely has
            no separate bedroom, and 0 is the honest number. NULL would mean
            "we do not know", which is a different claim and would make the
            average bedroom count quietly wrong.
            Anything that does not yield a leading integer becomes NULL and
            keeps its source text in bedrooms_unparsed.
        */
        case
            when beds is null                     then null
            when lower(beds) like 'studio%'       then 0
            when beds ~ '^[0-9]+'                 then substring(beds from '^[0-9]+')::int
            else null
        end as bedrooms,

        case
            when beds is null                then null
            when lower(beds) like 'studio%'  then null
            when beds ~ '^[0-9]+'            then null
            else beds
        end as bedrooms_unparsed,

        /*
            PROPERTY TYPE — nine spellings of four types.
            'Semi-Detached' and 'semi' must be tested BEFORE 'Detached', or a
            LIKE on 'detached' claims both. Flat and Apartment are merged
            because in a UK lettings context they are the same thing and
            keeping them apart would split every count by which staff member
            typed the record.
        */
        case
            when proptype is null                       then null
            when lower(proptype) like 'semi%'           then 'semi_detached'
            when lower(proptype) like 'terrace%'        then 'terrace'
            when lower(proptype) like 'detached%'       then 'detached'
            when lower(proptype) in ('apartment', 'apt', 'flat') then 'apartment'
            else 'unknown'
        end as property_type,

        {{ parse_currency('monthlyrent') }} as monthly_rent,
        {{ keep_if_unparsed('monthlyrent', parse_currency('monthlyrent')) }} as monthly_rent_unparsed,

        {{ parse_uk_date('datelisted') }} as date_listed,
        {{ keep_if_unparsed('datelisted', parse_uk_date('datelisted')) }} as date_listed_unparsed,

        description,
        description_raw,

        split_part(_source_file, '/', 1) as source_agency,
        _source_file                     as source_file,
        _loaded_at                       as loaded_at

    from nulled

)

select
    property_id,
    landlord_id,
    address_line_1,
    address_line_2,
    town,
    postcode,
    case when postcode is null then null else {{ is_valid_uk_postcode('postcode') }} end as is_valid_postcode,
    bedrooms,
    bedrooms_unparsed,
    property_type,
    monthly_rent,
    monthly_rent_unparsed,
    date_listed,
    date_listed_unparsed,
    description,
    description_raw,
    source_agency,
    source_file,
    loaded_at
from parsed
