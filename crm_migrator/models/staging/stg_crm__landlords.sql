/*
    stg_crm__landlords

    WHAT THIS DOES
        Points at raw.landlords, renames the agency's column names to ones a
        person can read, and records which export each row came from. That is
        all it does. It does not cast, clean, deduplicate or parse anything
        yet — that is increment 3, and this model is deliberately incomplete so
        the difference is visible in a diff.

    WHY IT IS AT THIS LAYER
        Staging is one model per source table, and its job is to make the
        source *usable* without making it *interpreted*. Renaming is usable:
        `landlord_id` means the same thing `landlordref` did. Deduplicating
        would be interpreted — it decides that two rows are one landlord, which
        is a business judgement, needs evidence, and belongs in intermediate
        where it can be seen and argued with.
        The test for whether something belongs here: could a reasonable person
        disagree with it? Renaming, no. Merging two landlords, yes.

    WHY THE RAW VALUES SURVIVE
        Every column is still text and still carries exactly what the agency
        sent. `landlord_name` will be cleaned in increment 3, but the cleaned
        value will sit *alongside* the original rather than replacing it. A
        Data Quality Analyst gets asked "what did the source actually say?" and
        "we normalised it" is not an answer.

    MATERIALISED AS A VIEW
        Set in dbt_project.yml for the whole staging directory rather than here,
        because it is a layer-wide decision. A config block in this file would
        imply this model is special. It is not.
*/

with source as (

    -- source() resolves to meridian_crm.raw.landlords, from _sources.yml.
    -- Two things are happening that plain SQL does not do: dbt records an edge
    -- in the lineage graph from that table to this model, and if the schema is
    -- ever renamed, the change is made in one YAML file rather than in every
    -- model that reads it.
    -- Run `dbt compile` and read target/compiled/... to see what this becomes.
    select * from {{ source('raw_crm', 'landlords') }}

),

renamed as (

    select
        -- IDENTIFIERS
        -- Renamed, not cast. It is text in the source and it stays text: a
        -- landlord reference is an identifier, not a number, and casting
        -- identifiers to integers is how leading zeros get lost.
        landlordref                             as landlord_id,

        -- NAME AND CONTACT — all still exactly as exported.
        -- 'SURNAME, First' and 'First Surname' both live in this column, some
        -- with titles, some mojibaked. Untouched here on purpose.
        name                                    as landlord_name,
        email                                   as email,
        phone                                   as phone,

        -- ADDRESS
        addrline1                               as address_line_1,
        addrline2                               as address_line_2,
        town                                    as town,
        postcode                                as postcode,

        -- DATES AND FREE TEXT — text, in six formats and eleven kinds of
        -- nothing respectively. Increment 3's problem.
        dateadded                               as date_added,
        notes                                   as notes,
        status                                  as status,

        -- PROVENANCE
        -- Which agency this row came from, derived from the loader's stamp
        -- rather than hardcoded, so phase 2 needs no change here. split_part
        -- is Postgres-specific; that is fine, this project is Postgres-only
        -- and pretending otherwise would mean a macro nobody needs.
        split_part(_source_file, '/', 1)        as source_agency,
        _source_file                            as source_file,
        _loaded_at                              as loaded_at

    from source

)

select * from renamed
