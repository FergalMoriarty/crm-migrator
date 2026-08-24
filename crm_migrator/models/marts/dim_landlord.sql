/*
    dim_landlord

    GRAIN
        One row per landlord RECORD as supplied by the agency, plus one
        synthetic Unknown row.

        Read that carefully: it is one row per record, NOT one row per person.
        154 records describe 150 people — four landlords appear twice under
        different refs. A dimension whose grain is not the entity it names is
        a compromise, and this one is temporary: entity resolution arrives in
        the intermediate layer in phase 2, at which point this model's grain
        becomes one row per landlord and its row count drops.
        Until then, anything that counts rows here is counting records. A
        "landlords by town" report will double-count those four.
        That limitation is asserted as a passing test in _marts__models.yml
        rather than left as a comment, so nobody reads a green run and
        concludes more than it proves.

    WHY table AND NOT view
        Set for the whole marts directory in dbt_project.yml. Marts are what
        people query, repeatedly, joining across them; paying the build cost
        once beats paying view expansion on every query. A mart is also the
        thing you most want to stay still while someone reads a report off it.

    TYPE 1, DELIBERATELY
        A landlord who changes their phone number simply has a new phone
        number here. The old one is gone. That is Type 1 — overwrite — and it
        is right for a dimension rebuilt from a full export every run, because
        the export has no history in it to preserve.
        Where history IS wanted, it comes from a snapshot, which captures
        changes between runs rather than inventing them from a single load.
        That is increment 7, and it targets the source rather than this model.

    THE UNKNOWN MEMBER
        Five properties reference a landlordref that is not in the export.
        There are three ways to handle that in a mart, and only one of them is
        honest:
          1. Drop the properties. Loses rows, and the validator would report
             them missing from the target - correctly, by its own rules.
          2. Leave landlord_key NULL. Every join downstream becomes an outer
             join or silently loses the row, and the reason is invisible.
          3. Point them at a real dimension row that says "we do not know".
        Option 3 is the Kimball answer and it is the one taken. The fact and
        dimension rows both survive, referential integrity actually holds
        (the relationships tests on the marts PASS where the staging ones
        WARN), and the count of unknowns is a number someone can report on
        rather than a gap they have to go looking for.
*/

with landlords as (

    select * from {{ ref('stg_crm__landlords') }}

),

keyed as (

    select
        /*
            SURROGATE KEY. A hash of the business key, not a sequence.

            WHY A HASH AND NOT AN IDENTITY COLUMN
                It is deterministic. Rebuild this table from scratch on a
                different machine and every key is identical, so a fact table
                built yesterday still joins to a dimension rebuilt today. A
                sequence would renumber on every full refresh and silently
                break every fact row that referenced it.

            WHY THE AGENCY CODE IS PART OF THE KEY
                'HV-00001' is unique within Harcourt & Vine and means nothing
                across agencies. In phase 2 a second agency will have its own
                numbering and the two will collide. Including source_agency
                now costs nothing and avoids a migration later.

            WHY A SURROGATE KEY AT ALL, given the natural key is right there
                Two reasons that matter here. It is a single column, so every
                downstream join is one predicate rather than two. And it
                insulates the fact table from the agency's numbering: when
                entity resolution merges two landlord records into one person,
                the surrogate key of the survivor is what facts point at, and
                the natural keys become attributes of it.
        */
        {{ dbt_utils.generate_surrogate_key(['source_agency', 'landlord_id']) }} as landlord_key,

        landlord_id,
        source_agency,

        landlord_name,
        landlord_name_key,

        email,
        is_valid_email,
        email_had_multiple_values,
        phone,
        phone_type,
        is_valid_phone,

        address_line_1,
        address_line_2,
        town,
        postcode,
        is_valid_postcode,

        status,
        date_added,
        notes,

        false as is_unknown_member,
        loaded_at

    from landlords

),

/*
    THE UNKNOWN ROW.

    Its key is the literal 'UNKNOWN' rather than a hash, so that anyone
    reading a fact table can see immediately why a row has no landlord. A
    hashed key would be indistinguishable from a real one at a glance, which
    defeats the purpose - the whole point of the unknown member is that the
    gap is visible.

    is_unknown_member exists so filtering it out is explicit. A report that
    should exclude unknowns says so in its WHERE clause; a report that
    forgets will show 'Unknown' by name in its output, which is the failure
    mode you want. Silently dropping them is the one you do not.
*/
unknown_member as (

    select
        'UNKNOWN'           as landlord_key,
        'UNKNOWN'           as landlord_id,
        'unknown'           as source_agency,
        'Unknown landlord'  as landlord_name,
        'unknownlandlord'   as landlord_name_key,
        null::text          as email,
        null::boolean       as is_valid_email,
        null::boolean       as email_had_multiple_values,
        null::text          as phone,
        null::text          as phone_type,
        null::boolean       as is_valid_phone,
        null::text          as address_line_1,
        null::text          as address_line_2,
        null::text          as town,
        null::text          as postcode,
        null::boolean       as is_valid_postcode,
        null::text          as status,
        null::date          as date_added,
        'Synthetic row. Properties referencing a landlord absent from the export point here.' as notes,
        true                as is_unknown_member,
        null::timestamptz   as loaded_at

)

select * from keyed
union all
select * from unknown_member
