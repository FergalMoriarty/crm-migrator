/*
    stg_crm__landlords

    WHAT THIS DOES
        Takes raw.landlords — every column text, exactly as Harcourt & Vine
        exported it — and produces one clean row per source row. 154 in, 154
        out, always.

        It does NOT deduplicate. Four of these landlords are the same four
        people twice, and deciding that two records are one person is a
        judgement about the world rather than about the data. That belongs in
        intermediate, where it can be shown its evidence and argued with.
        It also matters mechanically: the validator's first check compares
        source row count to target row count, and a staging layer that quietly
        emitted 150 rows from 154 would be reported as having lost four.

    WHAT CHANGED IN INCREMENT 4
        The cleaning logic moved into macros. The model now reads as a list of
        decisions — "the name is normalised, the date is a UK date, the
        placeholder values become NULL" — rather than as the implementation of
        those decisions. Every macro carries the reasoning that used to be
        here; open the macro to see why, not just what.

    WHICH ORIGINALS ARE KEPT
        landlord_name_raw, email_raw, notes_raw — the title is dropped from
        the name, a second email address is discarded, and the notes lose HTML
        and line structure. None of that can be reconstructed.
        phone_raw is kept for a different reason: parsing embeds a guess about
        leading zeros, and a wrong guess is invisible without the original.
        Postcode gets no twin: unparseable input is passed through unchanged.
*/

with source as (

    select * from {{ source('raw_crm', 'landlords') }}

),

/*
    STEP 1 — REPAIR ENCODING DAMAGE, BEFORE ANYTHING COMPARES STRINGS.
    'Sinéad' and 'SinÃ©ad' are different values: a join on name silently
    misses, a GROUP BY splits one landlord into two, and a report shows a
    person who appears not to exist.
    This runs before the HTML entity decoding in clean_free_text for a
    specific reason: '&nbsp;' decodes to U+00A0, the same character that
    mojibake produces as 'Â '. Repair the damage while it is still
    distinguishable from legitimate content.
*/
repaired as (

    select
        landlordref,
        {{ repair_mojibake('name') }}      as name,
        {{ repair_mojibake('email') }}     as email,
        {{ repair_mojibake('phone') }}     as phone,
        {{ repair_mojibake('addrline1') }} as addrline1,
        {{ repair_mojibake('addrline2') }} as addrline2,
        {{ repair_mojibake('town') }}      as town,
        {{ repair_mojibake('postcode') }}  as postcode,
        {{ repair_mojibake('notes') }}     as notes,
        dateadded,
        status,
        _source_file,
        _loaded_at,
        name  as name_raw,
        email as email_raw,
        phone as phone_raw,
        notes as notes_raw

    from source

),

/*
    STEP 2 — COLLAPSE THE ELEVEN KINDS OF NOTHING.
    See the clean_null_placeholders macro for the list and why it is shared.
    This is the highest-value step in the model: every downstream count, every
    not_null test and every outer join behaves differently depending on which
    spelling of "nothing" arrived.
*/
nulled as (

    select
        landlordref,
        {{ clean_null_placeholders('name') }}      as name,
        {{ clean_null_placeholders('email') }}     as email,
        {{ clean_null_placeholders('phone') }}     as phone,
        {{ clean_null_placeholders('postcode') }}  as postcode,
        {{ clean_null_placeholders('town') }}      as town,
        {{ clean_null_placeholders('addrline1') }} as addrline1,
        {{ clean_null_placeholders('addrline2') }} as addrline2,
        {{ clean_null_placeholders('status') }}    as status,
        {{ clean_null_placeholders('dateadded') }} as dateadded,
        {{ clean_free_text('notes') }}             as notes,
        _source_file,
        _loaded_at,
        name_raw, email_raw, phone_raw, notes_raw

    from repaired

),

/*
    STEP 3 — DERIVE ONCE, USE MANY TIMES.

    email_clean and phone_e164 are each needed three times below: for the
    value, for a validity flag, and for a derived attribute. Computing them in
    this CTE rather than repeating the macro call is not a performance
    decision — Postgres would cope — it is a correctness one.

    THIS CTE EXISTS BECAUSE A REFACTOR BROKE WITHOUT IT. The first version of
    increment 4 called the cleaning inline in three places and one of them was
    subtly different: the validity check tested the address BEFORE the
    trailing ';' was stripped, so two landlords whose email ended in a
    semicolon were reported invalid when they are not. The row counts were
    unchanged and the emails themselves were unchanged; only a boolean moved,
    on two rows out of 154.
    Derive once, name it, then use the name. Every repetition of an expression
    is somewhere the expression can be repeated slightly wrong.
*/
prepared as (

    select
        *,
        case
            when email is null then null
            else lower(trim(trim(trailing ';' from trim(split_part(email, '/', 1)))))
        end as email_clean,
        {{ parse_uk_phone('phone') }} as phone_e164
    from nulled

),

final as (

    select
        landlordref as landlord_id,

        {{ normalise_person_name('name') }} as landlord_name,

        /*
            THE MATCHING KEY — lowercased, accents folded to base letters,
            everything that is not a letter removed. 'Ó Súilleabháin',
            'O Suilleabhain' and "o'suilleabhain" all collapse to
            'osuilleabhain'.

            DELIBERATELY NOT A MACRO. It is used once, and a macro around a
            single use hides SQL from the one reader who needs to see it —
            whoever is deciding, in phase 2, whether two landlords are the
            same person. The rule of thumb: extract when the logic must AGREE
            in several places, not merely when it is long.

            translate() rather than the unaccent extension, because unaccent
            needs CREATE EXTENSION — a privileged DDL step outside dbt, which
            would put part of this transformation somewhere the lineage graph
            cannot see.

            This column is for joining and grouping. It is never displayed and
            it is not a name.
        */
        regexp_replace(
            lower(translate(
                {{ normalise_person_name('name') }},
                'áàâäãåéèêëíìîïóòôöõúùûüýÿñçÁÀÂÄÃÅÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÝÑÇ',
                'aaaaaaeeeeiiiiooooouuuuyyncAAAAAAEEEEIIIIOOOOOUUUUYNC'
            )),
            '[^a-z]', '', 'g'
        ) as landlord_name_key,

        /*
            EMAIL — lowercased, because the local part is case-sensitive in
            the RFC and case-insensitive at every provider anyone uses.
            Treating 'F.McAllister@' and 'f.mcallister@' as distinct would
            split one landlord into two.
            Where two addresses were crammed into one field separated by '/',
            the first is taken and the fact recorded rather than hidden.
        */
        /*
            THE VALIDITY FLAGS ARE THREE-VALUED, AND THAT IS DELIBERATE.
                true  — a value was supplied and it parses
                false — a value was supplied and it does not parse
                NULL  — nothing was supplied, so there is nothing to judge

            The obvious alternative is false for both of the last two, which
            is what an earlier version did for phone. It conflates "the agency
            never recorded a phone number" with "the agency recorded
            something unusable", and those send you to two different people:
            one is a gap to fill, the other is a value to correct.
            The cost is that `WHERE NOT is_valid_phone` no longer returns the
            missing ones, which surprises people once. `WHERE is_valid_phone
            IS NOT TRUE` covers both. That surprise is worth the distinction.
        */
        email_clean as email,
        (email like '%/%') as email_had_multiple_values,
        case
            when email is null then null
            else email_clean ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$'
        end as is_valid_email,

        phone_e164 as phone,
        case
            when phone_e164 like '+447%' then 'mobile'
            when phone_e164 is not null  then 'landline'
        end as phone_type,
        case
            when phone is null then null
            else phone_e164 is not null
        end as is_valid_phone,

        addrline1 as address_line_1,
        addrline2 as address_line_2,
        initcap(town) as town,
        {{ format_uk_postcode('postcode') }} as postcode,
        case
            when postcode is null then null
            else {{ is_valid_uk_postcode(format_uk_postcode('postcode')) }}
        end as is_valid_postcode,

        {{ parse_uk_date('dateadded') }} as date_added,
        {{ keep_if_unparsed('dateadded', parse_uk_date('dateadded')) }} as date_added_unparsed,

        /*
            STATUS — eight spellings of three states.
            'A' is mapped to active on the assumption it abbreviates 'Active'.
            That assumption is not stated anywhere in the export. It is the
            kind of thing to confirm with the agency rather than infer, and it
            is written here so the guess is visible instead of buried.
            Not a macro: this mapping is specific to this agency's status
            column and sharing it would imply other tables use the same codes.
        */
        case
            when status is null                     then null
            when lower(status) in ('active', 'a')   then 'active'
            when lower(status) in ('inactive', 'i') then 'inactive'
            when lower(status) = 'archived'         then 'archived'
            else 'unknown'
        end as status,

        notes,

        split_part(_source_file, '/', 1) as source_agency,
        _source_file                     as source_file,
        _loaded_at                       as loaded_at,

        name_raw as landlord_name_raw,
        email_raw,
        phone_raw,
        notes_raw

    from prepared

)

select * from final
