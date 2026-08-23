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

        {{ clean_null_placeholders('tenantname') }}  as tenantname,
        {{ clean_null_placeholders('tenantemail') }} as tenantemail,
        {{ clean_null_placeholders('tenantphone') }} as tenantphone,
        {{ clean_null_placeholders('startdate') }}   as startdate,
        {{ clean_null_placeholders('enddate') }}     as enddate,
        {{ clean_null_placeholders('rent') }}        as rent,
        {{ clean_null_placeholders('depositheld') }} as depositheld,

        {{ clean_free_text('comments') }} as comments,

        _source_file,
        _loaded_at,
        tenant_name_raw,
        comments_raw

    from repaired

),

parsed as (

    select
        tenancyref as tenancy_id,
        propref    as property_id,

        {{ normalise_person_name('tenantname') }} as tenant_name,

        case
            when tenantemail is null then null
            else lower(trim(trim(trailing ';' from trim(split_part(tenantemail, '/', 1)))))
        end as tenant_email,
        (tenantemail is not null) as tenant_email_supplied,

        {{ parse_uk_phone('tenantphone') }} as tenant_phone,
        (tenantphone is not null) as tenant_phone_supplied,

        {{ parse_uk_date('startdate') }} as start_date,
        {{ keep_if_unparsed('startdate', parse_uk_date('startdate')) }} as start_date_unparsed,

        /*
            END DATE. A NULL here is genuinely ambiguous and worth naming: it
            means either "the tenancy is open-ended and still running" or "the
            agency never recorded an end date". The export does not
            distinguish them and neither can this model. Anything downstream
            that treats NULL as "still running" is making an assumption that
            belongs in a mart, stated out loud, not here.
        */
        {{ parse_uk_date('enddate') }} as end_date,
        {{ keep_if_unparsed('enddate', parse_uk_date('enddate')) }} as end_date_unparsed,

        {{ parse_currency('rent') }} as rent,
        {{ keep_if_unparsed('rent', parse_currency('rent')) }} as rent_unparsed,

        {{ parse_currency('depositheld') }} as deposit_held,
        {{ keep_if_unparsed('depositheld', parse_currency('depositheld')) }} as deposit_held_unparsed,

        comments,
        comments_raw,
        tenant_name_raw,

        split_part(_source_file, '/', 1) as source_agency,
        _source_file                     as source_file,
        _loaded_at                       as loaded_at

    from nulled

)

select
    tenancy_id,
    property_id,
    tenant_name,
    tenant_email,
    -- Three-valued, as in stg_crm__landlords: NULL means nothing was supplied
    -- to judge, false means something unusable was.
    case when not tenant_email_supplied then null
         else tenant_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$' end as is_valid_email,
    tenant_phone,
    case when not tenant_phone_supplied then null
         else tenant_phone is not null end as is_valid_phone,
    start_date,
    start_date_unparsed,
    end_date,
    end_date_unparsed,
    rent,
    rent_unparsed,
    deposit_held,
    deposit_held_unparsed,
    comments,
    source_agency,
    source_file,
    loaded_at,
    tenant_name_raw,
    comments_raw
from parsed
