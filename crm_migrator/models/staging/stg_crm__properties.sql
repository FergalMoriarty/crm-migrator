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

        {%- set nothing = "('', 'n/a', 'na', 'none', 'null', '-', '.', 'unknown', 'not known', 'tbc')" %}

        case when lower(trim(addr1))       in {{ nothing }} then null else trim(addr1)       end as addr1,
        case when lower(trim(addr2))       in {{ nothing }} then null else trim(addr2)       end as addr2,
        case when lower(trim(town))        in {{ nothing }} then null else trim(town)        end as town,
        case when lower(trim(postcode))    in {{ nothing }} then null else trim(postcode)    end as postcode,
        case when lower(trim(beds))        in {{ nothing }} then null else trim(beds)        end as beds,
        case when lower(trim(proptype))    in {{ nothing }} then null else trim(proptype)    end as proptype,
        case when lower(trim(monthlyrent)) in {{ nothing }} then null else trim(monthlyrent) end as monthlyrent,
        case when lower(trim(datelisted))  in {{ nothing }} then null else trim(datelisted)  end as datelisted,

        -- Same three-step free-text treatment as landlord notes: decode
        -- entities, strip tags to a SPACE, collapse whitespace runs.
        -- Descriptions carry heavier markup than notes did — <p> and <br/>
        -- from a listings system — which is why the tag strip matters more
        -- here than anywhere else in the project.
        nullif(
            trim(
                regexp_replace(
                    regexp_replace(
                        replace(replace(replace(replace(replace(
                            description,
                            '&nbsp;', ' '), '&amp;', '&'), '&lt;', '<'), '&gt;', '>'), '&#39;', ''''),
                        '<[^>]*>', ' ', 'g'),
                    '\s+', ' ', 'g')
            ),
            ''
        ) as description,

        _source_file,
        _loaded_at,
        description_raw

    from repaired

),

prepared as (

    select
        *,
        regexp_replace(upper(postcode), '[^A-Z0-9]', '', 'g') as postcode_compact,
        /*
            CURRENCY AS TEXT. The export writes rent as '£1,250.00', '1250',
            '1,250.00', '£ 1,250.00', 'GBP 1,250.00' and '£1250'. Stripping
            everything that is not a digit, a dot or a minus handles all six.
            Negatives are not possible for rent but the same expression is
            reused for payments, where they are — see that model.
        */
        nullif(regexp_replace(monthlyrent, '[^0-9.\-]', '', 'g'), '') as rent_digits
    from nulled

),

parsed as (

    select
        propref     as property_id,
        landlordref as landlord_id,

        addr1 as address_line_1,
        addr2 as address_line_2,
        initcap(town) as town,

        case
            when postcode is null then null
            when postcode_compact ~ '^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$'
                then left(postcode_compact, length(postcode_compact) - 3)
                     || ' ' || right(postcode_compact, 3)
            else upper(trim(regexp_replace(postcode, '\s+', ' ', 'g')))
        end as postcode,

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

        case
            when rent_digits is null                     then null
            when rent_digits ~ '^-?[0-9]+(\.[0-9]+)?$'   then rent_digits::numeric(12,2)
            else null
        end as monthly_rent,

        case
            when monthlyrent is null                     then null
            when rent_digits ~ '^-?[0-9]+(\.[0-9]+)?$'   then null
            else monthlyrent
        end as monthly_rent_unparsed,

        -- Six date formats, guarded by shape first. See stg_crm__landlords
        -- for why to_date() cannot be trusted without the regex, and for the
        -- Excel 1899-12-30 epoch.
        case
            when datelisted is null                     then null
            when datelisted ~ '^\d{4}-\d{2}-\d{2}'      then to_date(left(datelisted, 10), 'YYYY-MM-DD')
            when datelisted ~ '^\d{2}/\d{2}/\d{4}'      then to_date(left(datelisted, 10), 'DD/MM/YYYY')
            when datelisted ~ '^\d{2}-\d{2}-\d{4}$'     then to_date(datelisted, 'DD-MM-YYYY')
            when datelisted ~ '^\d{1,2}/\d{1,2}/\d{2}$' then to_date(datelisted, 'FMDD/FMMM/YY')
            when datelisted ~ '^\d{5}$'                 then date '1899-12-30' + datelisted::int
            else null
        end as date_listed,

        description,
        description_raw,

        split_part(_source_file, '/', 1) as source_agency,
        _source_file                     as source_file,
        _loaded_at                       as loaded_at,
        postcode_compact

    from prepared

)

select
    property_id,
    landlord_id,
    address_line_1,
    address_line_2,
    town,
    postcode,
    (postcode ~ '^[A-Z]{1,2}[0-9][A-Z0-9]? [0-9][A-Z]{2}$') as is_valid_postcode,
    bedrooms,
    bedrooms_unparsed,
    property_type,
    monthly_rent,
    monthly_rent_unparsed,
    date_listed,
    description,
    description_raw,
    source_agency,
    source_file,
    loaded_at
from parsed
