/*
    stg_crm__tenancies

    One clean row per source row, 340 in and 340 out. The shared reasoning is
    in stg_crm__landlords.sql and not repeated.

    WHICH ORIGINALS ARE KEPT
        tenant_name_raw and comments_raw — the title is dropped from the name
        and the comments lose HTML and line structure, and neither can be
        reconstructed.
        Everything else is either cosmetic or covered by a *_unparsed column.

    A NOTE ON WHAT IS NOT HERE
        There is no is_active flag. Whether a tenancy is current depends on
        comparing end_date to today, which makes the answer change without the
        data changing — a model that is true on Monday and false on Tuesday
        with no run in between. That belongs in a mart, computed against an
        explicit as-of date, not baked into staging.
*/

with source as (

    select * from {{ source('raw_crm', 'tenancies') }}

),

repaired as (

    select
        tenancyref,
        propref,
        {{ repair_mojibake('tenantname') }}  as tenantname,
        {{ repair_mojibake('tenantemail') }} as tenantemail,
        {{ repair_mojibake('tenantphone') }} as tenantphone,
        {{ repair_mojibake('comments') }}    as comments,
        startdate,
        enddate,
        rent,
        depositheld,
        _source_file,
        _loaded_at,
        tenantname as tenant_name_raw,
        comments   as comments_raw

    from source

),

nulled as (

    select
        tenancyref,
        propref,

        {%- set nothing = "('', 'n/a', 'na', 'none', 'null', '-', '.', 'unknown', 'not known', 'tbc')" %}

        case when lower(trim(tenantname))  in {{ nothing }} then null else trim(tenantname)  end as tenantname,
        case when lower(trim(tenantemail)) in {{ nothing }} then null else trim(tenantemail) end as tenantemail,
        case when lower(trim(tenantphone)) in {{ nothing }} then null else trim(tenantphone) end as tenantphone,
        case when lower(trim(startdate))   in {{ nothing }} then null else trim(startdate)   end as startdate,
        case when lower(trim(enddate))     in {{ nothing }} then null else trim(enddate)     end as enddate,
        case when lower(trim(rent))        in {{ nothing }} then null else trim(rent)        end as rent,
        case when lower(trim(depositheld)) in {{ nothing }} then null else trim(depositheld) end as depositheld,

        nullif(
            trim(
                regexp_replace(
                    regexp_replace(
                        replace(replace(replace(replace(replace(
                            comments,
                            '&nbsp;', ' '), '&amp;', '&'), '&lt;', '<'), '&gt;', '>'), '&#39;', ''''),
                        '<[^>]*>', ' ', 'g'),
                    '\s+', ' ', 'g')
            ),
            ''
        ) as comments,

        _source_file,
        _loaded_at,
        tenant_name_raw,
        comments_raw

    from repaired

),

prepared as (

    select
        *,
        regexp_replace(tenantphone, '[^0-9]', '', 'g')          as phone_digits,
        nullif(regexp_replace(rent, '[^0-9.\-]', '', 'g'), '')        as rent_digits,
        nullif(regexp_replace(depositheld, '[^0-9.\-]', '', 'g'), '') as deposit_digits
    from nulled

),

parsed as (

    select
        tenancyref as tenancy_id,
        propref    as property_id,

        -- Same two name forms as landlords: 'SURNAME, First' and
        -- 'First Surname'. Case is left alone for the same reason.
        case
            when tenantname is null then null
            when tenantname like '%,%' then
                trim(regexp_replace(split_part(tenantname, ',', 2), '\s+', ' ', 'g'))
                || ' ' ||
                trim(regexp_replace(split_part(tenantname, ',', 1), '\s+', ' ', 'g'))
            else trim(regexp_replace(tenantname, '\s+', ' ', 'g'))
        end as name_ordered,

        case
            when tenantemail is null then null
            else lower(trim(trim(trailing ';' from trim(split_part(tenantemail, '/', 1)))))
        end as tenant_email,

        case
            when phone_digits is null or phone_digits = '' then null
            when phone_digits like '0044%'          then '+44' || substring(phone_digits from 5)
            when phone_digits like '44%' and length(phone_digits) >= 12
                                                    then '+44' || substring(phone_digits from 3)
            when phone_digits like '0%'             then '+44' || substring(phone_digits from 2)
            when phone_digits ~ '^[1-9][0-9]{8,9}$' then '+44' || phone_digits
            else null
        end as tenant_phone,

        case
            when startdate is null                     then null
            when startdate ~ '^\d{4}-\d{2}-\d{2}'      then to_date(left(startdate, 10), 'YYYY-MM-DD')
            when startdate ~ '^\d{2}/\d{2}/\d{4}'      then to_date(left(startdate, 10), 'DD/MM/YYYY')
            when startdate ~ '^\d{2}-\d{2}-\d{4}$'     then to_date(startdate, 'DD-MM-YYYY')
            when startdate ~ '^\d{1,2}/\d{1,2}/\d{2}$' then to_date(startdate, 'FMDD/FMMM/YY')
            when startdate ~ '^\d{5}$'                 then date '1899-12-30' + startdate::int
            else null
        end as start_date,

        /*
            END DATE. A NULL here is genuinely ambiguous and worth naming: it
            means either "the tenancy is open-ended and still running" or "the
            agency never recorded an end date". The export does not
            distinguish them and neither can this model. Anything downstream
            that treats NULL as "still running" is making an assumption that
            belongs in a mart, stated out loud, not here.
        */
        case
            when enddate is null                     then null
            when enddate ~ '^\d{4}-\d{2}-\d{2}'      then to_date(left(enddate, 10), 'YYYY-MM-DD')
            when enddate ~ '^\d{2}/\d{2}/\d{4}'      then to_date(left(enddate, 10), 'DD/MM/YYYY')
            when enddate ~ '^\d{2}-\d{2}-\d{4}$'     then to_date(enddate, 'DD-MM-YYYY')
            when enddate ~ '^\d{1,2}/\d{1,2}/\d{2}$' then to_date(enddate, 'FMDD/FMMM/YY')
            when enddate ~ '^\d{5}$'                 then date '1899-12-30' + enddate::int
            else null
        end as end_date,

        case
            when rent_digits ~ '^-?[0-9]+(\.[0-9]+)?$' then rent_digits::numeric(12,2)
            else null
        end as rent,

        case
            when rent is null                          then null
            when rent_digits ~ '^-?[0-9]+(\.[0-9]+)?$' then null
            else rent
        end as rent_unparsed,

        case
            when deposit_digits ~ '^-?[0-9]+(\.[0-9]+)?$' then deposit_digits::numeric(12,2)
            else null
        end as deposit_held,

        comments,
        comments_raw,
        tenant_name_raw,

        split_part(_source_file, '/', 1) as source_agency,
        _source_file                     as source_file,
        _loaded_at                       as loaded_at

    from prepared

)

select
    tenancy_id,
    property_id,
    trim(regexp_replace(name_ordered, '^(MR|MRS|MS|MISS|DR|PROF)\.?\s+', '', 'i')) as tenant_name,
    tenant_email,
    (tenant_email is not null and tenant_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$')
        as is_valid_email,
    tenant_phone,
    (tenant_phone is not null) as is_valid_phone,
    start_date,
    end_date,
    rent,
    rent_unparsed,
    deposit_held,
    comments,
    source_agency,
    source_file,
    loaded_at,
    tenant_name_raw,
    comments_raw
from parsed
