/*
    stg_crm__landlords

    WHAT THIS DOES
        Takes raw.landlords — every column text, exactly as Harcourt & Vine
        exported it — and produces one clean row per source row. It repairs
        encoding damage, collapses eleven spellings of "nothing" to NULL,
        reorders and de-titles names, normalises phones and postcodes, parses
        six date formats, and cleans the free-text notes.

        It does NOT deduplicate. 154 rows in, 154 rows out, always. Four of
        these landlords are the same four people twice, and deciding that two
        records are one person is a judgement about the world rather than about
        the data. That belongs in intermediate, where it can be shown its
        evidence and argued with.

    WHY EVERY CLEANED COLUMN HAS A _raw TWIN
        The cleaned value is the unsuffixed one, so anything downstream that
        says `email` gets the good version without needing to know this file
        exists. The original survives as `email_raw`.
        This roughly doubles the column count and it is worth it. The question
        a Data Quality Analyst is asked is not "what does the warehouse say",
        it is "what did the agency actually send, and what did you change".
        A model that cannot answer the second half cannot be audited, and an
        unauditable cleaning step is indistinguishable from a guess.
        ALTERNATIVE CONSIDERED: clean in place and rely on raw for the
        original. Rejected — the loader truncates raw on the next load, so that
        evidence has a shelf life of one migration.

    WHY BAD VALUES ARE FLAGGED, NOT NULLED
        'BT7 1N' is truncated and unusable. Nulling it destroys the fact that
        the agency held *something* there, and the difference between "never
        recorded" and "recorded wrongly" is the difference between chasing the
        agency and chasing the tenant. The value stays, is_valid_postcode says
        it failed, and what to do about it is decided downstream by someone who
        can see both.

    WHY THIS FILE IS REPETITIVE
        The trim/nullif treatment is spelled out per column rather than
        factored into a macro. That is deliberate for one increment: the
        duplication is the argument for increment 4, and it is easier to judge
        whether a macro helps once you have read the version without one.
        The single exception is repair_mojibake — see that macro's own comment
        for why it could not wait.
*/

with source as (

    select * from {{ source('raw_crm', 'landlords') }}

),

/*
    STEP 1 — REPAIR ENCODING DAMAGE

    This is done first because everything after it compares strings. 'Sinéad'
    and 'SinÃ©ad' are different values: a join on name silently misses, a
    GROUP BY splits one landlord into two, and a report shows a person who
    appears not to exist. Fixing the bytes before any comparison happens is the
    whole reason this CTE is at the top.
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

        -- Untouched originals, carried through to the _raw columns at the end.
        name     as name_raw,
        email    as email_raw,
        phone    as phone_raw,
        postcode as postcode_raw,
        notes    as notes_raw

    from source

),

/*
    STEP 2 — COLLAPSE THE ELEVEN KINDS OF NOTHING

    This export expresses "no value" as: an unquoted empty field (which COPY
    turned into a real NULL), a quoted empty string, two spaces, 'N/A', 'n/a',
    '-', '.', 'none', 'NONE', 'NULL' and 'unknown'. All of them mean the same
    thing to the person who typed them and none of them mean the same thing to
    SQL.

    This is the highest-value step in the model. Every downstream count, every
    not_null test and every outer join behaves differently depending on which
    spelling arrived, so a staging layer that skips this produces models that
    are correct on Tuesday and wrong on Wednesday because the next agency used
    a different placeholder.

    ORDER MATTERS: trim first, then compare, then null. '  N/A  ' will not
    match a comparison against 'N/A'.

    WHAT THIS DESTROYS, stated plainly: someone who typed 'unknown' meant
    something slightly different from someone who left the field blank — they
    looked, and could not find out. That distinction is gone after this step.
    It is recoverable from the _raw columns, which is why they exist.
*/
nulled as (

    select
        landlordref,

        {%- set nothing = "('', 'n/a', 'na', 'none', 'null', '-', '.', 'unknown', 'not known', 'tbc')" %}

        case when lower(trim(name))      in {{ nothing }} then null else trim(name)      end as name,
        case when lower(trim(email))     in {{ nothing }} then null else trim(email)     end as email,
        case when lower(trim(phone))     in {{ nothing }} then null else trim(phone)     end as phone,
        case when lower(trim(postcode))  in {{ nothing }} then null else trim(postcode)  end as postcode,
        case when lower(trim(town))      in {{ nothing }} then null else trim(town)      end as town,
        case when lower(trim(addrline1)) in {{ nothing }} then null else trim(addrline1) end as addrline1,
        case when lower(trim(addrline2)) in {{ nothing }} then null else trim(addrline2) end as addrline2,
        case when lower(trim(status))    in {{ nothing }} then null else trim(status)    end as status,
        case when lower(trim(dateadded)) in {{ nothing }} then null else trim(dateadded) end as dateadded,

        /*
            NOTES — the free-text field, and the reason this project exists.

            Three things happen, in this order:
              1. HTML entities decoded. '&amp;' is an ampersand; leaving it
                 means a search for 'Kavanagh & Co' misses the row that says
                 'Kavanagh &amp; Co'.
              2. Tags stripped and replaced with a SPACE, not with nothing.
                 '<p>One.</p><p>Two.</p>' must not become 'One.Two.' — deleting
                 a tag can silently weld two sentences together.
              3. Every whitespace run — spaces, tabs, newlines, carriage
                 returns — collapsed to one space, then trimmed.

            WHAT STEP 3 DESTROYS: the line breaks are occasionally meaningful,
            because someone typed a list. Collapsing them makes the text
            greppable and comparable, which is what every downstream use needs,
            and notes_raw keeps the original for the one use that does not. If
            paragraph structure later turns out to matter, the right fix is an
            additional column that preserves it, not the removal of this one.
        */
        nullif(
            trim(
                regexp_replace(
                    regexp_replace(
                        replace(replace(replace(replace(replace(
                            notes,
                            '&nbsp;', ' '), '&amp;', '&'), '&lt;', '<'), '&gt;', '>'), '&#39;', ''''),
                        '<[^>]*>', ' ', 'g'),
                    '\s+', ' ', 'g')
            ),
            ''
        ) as notes,

        _source_file,
        _loaded_at,
        name_raw, email_raw, phone_raw, postcode_raw, notes_raw

    from repaired

),

/*
    STEP 3 — DERIVE THE INTERMEDIATE FORMS

    phone_digits and postcode_compact are used several times each in the next
    CTE. Computing them once here rather than repeating the regexp_replace
    inline keeps the parsing readable and means a change to how digits are
    extracted happens in exactly one place.
*/
prepared as (

    select
        *,
        regexp_replace(phone, '[^0-9]', '', 'g')          as phone_digits,
        regexp_replace(upper(postcode), '[^A-Z0-9]', '', 'g') as postcode_compact
    from nulled

),

/*
    STEP 4 — PARSE
*/
parsed as (

    select
        landlordref as landlord_id,

        /*
            NAME — two forms in one column: 'MCALLISTER, Fiona' and
            'Fiona McAllister', some with titles, some with no space after the
            comma.

            DECISION: the CASE of the name is not normalised.
            initcap('MCALLISTER') gives 'Mcallister'. It also gives 'O'neill'
            and turns 'Ó Súilleabháin' into 'Ó SúIlleabháin'. There is no case
            rule that survives Irish and Scottish surnames, and a name rendered
            wrongly is worse than one rendered oddly — it is the field a
            landlord will notice on a letter.
            So the comma form is reordered, the title is dropped, whitespace is
            fixed, and the letters are left exactly as the agency had them.

            For MATCHING, which is what phase 2 needs, there is a separate
            landlord_name_key below: lowercased, accents folded, punctuation
            gone. Normalise for comparison, never for display. Two jobs, two
            columns.
        */
        case
            when name is null then null
            when name like '%,%' then
                trim(regexp_replace(split_part(name, ',', 2), '\s+', ' ', 'g'))
                || ' ' ||
                trim(regexp_replace(split_part(name, ',', 1), '\s+', ' ', 'g'))
            else trim(regexp_replace(name, '\s+', ' ', 'g'))
        end as name_ordered,

        /*
            EMAIL — lowercased, because the local part is case-sensitive in the
            RFC and case-insensitive at every mail provider anyone actually
            uses. Treating 'F.McAllister@' and 'f.mcallister@' as distinct
            would split one landlord into two.
            Trailing semicolons are stripped. Where two addresses were crammed
            into one field separated by '/', the first is taken and the fact is
            recorded rather than silently dropped.
        */
        case
            when email is null then null
            else lower(trim(trim(trailing ';' from trim(split_part(email, '/', 1)))))
        end as email,
        (email like '%/%') as email_had_multiple_values,

        /*
            PHONE — target is E.164: +44 then the national number without its
            leading zero.

            The input arrives as '07700 900123', '+44 7700 900123',
            '0044 7700900123', '(028) 9649 612' and bare '7700900123'. That
            last one is Excel treating the cell as a number and eating the
            leading zero, which is why a bare 9-or-10-digit string that starts
            with a valid trunk digit is assumed to be missing its zero.

            THE ASSUMPTION WORTH SEEING: that inference is a guess. A ten-digit
            string starting 7 is overwhelmingly a UK mobile that lost its zero,
            but nothing in the export says so. is_valid_phone below tells you
            it parsed; it does not tell you it is the right number.
        */
        case
            when phone_digits is null or phone_digits = '' then null
            when phone_digits like '0044%'          then '+44' || substring(phone_digits from 5)
            when phone_digits like '44%' and length(phone_digits) >= 12
                                                    then '+44' || substring(phone_digits from 3)
            when phone_digits like '0%'             then '+44' || substring(phone_digits from 2)
            when phone_digits ~ '^[1-9][0-9]{8,9}$' then '+44' || phone_digits
            else null
        end as phone_e164,

        /*
            POSTCODE — upper case, exactly one space before the final three
            characters. That is the standard outward/inward split and the only
            format Royal Mail considers correct.
            The validation regex checks SHAPE, not existence: 'BT99 9ZZ' is
            well-formed and not a real postcode. Only a PAF lookup knows the
            difference, and this project does not have one.
        */
        /*
            THE GUARD IS THE POINT. An earlier version reformatted
            unconditionally, and turned the truncated 'BT27 7R' into
            'BT2 77R' — splitting off the last three characters of something
            that never had a valid inward code. That is worse than leaving it
            alone: it invents a postcode that looks deliberate.
            THE RULE: never reformat a value you could not parse. If the
            compact form does not match the UK pattern, it is passed through
            uppercased and trimmed, and is_valid_postcode reports the failure.
        */
        case
            when postcode is null then null
            when postcode_compact ~ '^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$'
                then left(postcode_compact, length(postcode_compact) - 3)
                     || ' ' || right(postcode_compact, 3)
            else upper(trim(regexp_replace(postcode, '\s+', ' ', 'g')))
        end as postcode,

        /*
            DATE ADDED — six formats in one text column.

            The regex guard on each branch is not decoration. to_date() is
            lenient: to_date('31/02/2024','DD/MM/YYYY') returns 2024-03-02
            instead of raising. Matching the shape first means anything
            unrecognised becomes NULL and can be counted, rather than becoming
            a plausible wrong date nobody questions.

            The Excel branch: Excel counts days from 1899-12-30, not
            1900-01-01, because it wrongly believes 1900 was a leap year and
            shifts its epoch to compensate. Anyone who has debugged a two-day
            date discrepancy has met this.
        */
        case
            when dateadded is null                     then null
            when dateadded ~ '^\d{4}-\d{2}-\d{2}'      then to_date(left(dateadded, 10), 'YYYY-MM-DD')
            when dateadded ~ '^\d{2}/\d{2}/\d{4}'      then to_date(left(dateadded, 10), 'DD/MM/YYYY')
            when dateadded ~ '^\d{2}-\d{2}-\d{4}$'     then to_date(dateadded, 'DD-MM-YYYY')
            when dateadded ~ '^\d{1,2}/\d{1,2}/\d{2}$' then to_date(dateadded, 'FMDD/FMMM/YY')
            when dateadded ~ '^\d{5}$'                 then date '1899-12-30' + dateadded::int
            else null
        end as date_added,

        /*
            STATUS — eight spellings of three states.
            'A' is mapped to active on the assumption it abbreviates 'Active'.
            That assumption is not stated anywhere in the export. It is exactly
            the kind of thing to confirm with the agency rather than infer, and
            it is written here so the guess is visible instead of buried.
        */
        case
            when status is null                     then null
            when lower(status) in ('active', 'a')   then 'active'
            when lower(status) in ('inactive', 'i') then 'inactive'
            when lower(status) = 'archived'         then 'archived'
            else 'unknown'
        end as status,

        town,
        addrline1 as address_line_1,
        addrline2 as address_line_2,
        notes,

        split_part(_source_file, '/', 1) as source_agency,
        _source_file                     as source_file,
        _loaded_at                       as loaded_at,

        name_raw, email_raw, phone_raw, postcode_raw, notes_raw

    from prepared

),

final as (

    select
        landlord_id,

        -- NAME
        trim(regexp_replace(name_ordered, '^(MR|MRS|MS|MISS|DR|PROF)\.?\s+', '', 'i'))
            as landlord_name,

        /*
            THE MATCHING KEY — lowercased, accents folded to base letters,
            everything that is not a letter removed. 'Ó Súilleabháin',
            'O Suilleabhain' and "o'suilleabhain" all collapse to
            'osuilleabhain'.

            translate() is used rather than the unaccent extension because
            unaccent needs CREATE EXTENSION — a privileged DDL step outside
            dbt, which would put part of this transformation somewhere the
            lineage graph cannot see. translate() is explicit and its coverage
            is exactly what is written here, which is easier to reason about
            than a dictionary file on the server.

            This column is for joining and grouping. It is never displayed and
            it is not a name.
        */
        regexp_replace(
            lower(translate(
                trim(regexp_replace(name_ordered, '^(MR|MRS|MS|MISS|DR|PROF)\.?\s+', '', 'i')),
                'áàâäãåéèêëíìîïóòôöõúùûüýÿñçÁÀÂÄÃÅÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÝÑÇ',
                'aaaaaaeeeeiiiiooooouuuuyyncAAAAAAEEEEIIIIOOOOOUUUUYNC'
            )),
            '[^a-z]', '', 'g'
        ) as landlord_name_key,

        -- CONTACT
        email,
        email_had_multiple_values,
        (email is not null and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$')
            as is_valid_email,

        phone_e164 as phone,
        case
            when phone_e164 like '+447%' then 'mobile'
            when phone_e164 is not null  then 'landline'
        end as phone_type,
        (phone_e164 is not null) as is_valid_phone,

        -- ADDRESS
        address_line_1,
        address_line_2,
        initcap(town) as town,
        postcode,
        (postcode ~ '^[A-Z]{1,2}[0-9][A-Z0-9]? [0-9][A-Z]{2}$') as is_valid_postcode,

        -- ATTRIBUTES
        date_added,
        status,
        notes,

        -- PROVENANCE
        source_agency,
        source_file,
        loaded_at,

        /*
            THE ORIGINALS. Every column above can be re-derived from these,
            which means any cleaning decision in this file can be audited, and
            reversed, without going back to a raw table that has since been
            truncated by the next load.
        */
        name_raw as landlord_name_raw,
        email_raw,
        phone_raw,
        postcode_raw,
        notes_raw

    from parsed

)

select * from final
