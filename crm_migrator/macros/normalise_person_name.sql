{#
    normalise_person_name(column)

    WHAT IT DOES
        Takes a name column holding both 'SURNAME, First' and 'First Surname',
        reorders the comma form, strips a leading title, and collapses
        whitespace.

    WHAT IT DELIBERATELY DOES NOT DO: CHANGE THE CASE
        initcap('MCALLISTER') gives 'Mcallister'. It also gives 'O'neill' and
        turns 'Ó Súilleabháin' into 'Ó SúIlleabháin'. There is no case rule
        that survives Irish and Scottish surnames, and a name rendered wrongly
        is worse than one rendered oddly — it is the field a landlord notices
        on a letter.
        The letters come out exactly as the agency had them. If a display
        layer wants title case it can make that mistake itself, visibly.

    WHY THE TITLE IS DROPPED
        'MRS FIONA MCALLISTER' and 'Fiona McAllister' are one person, and the
        title is not part of the name. It is also information: whether someone
        is Dr or Mrs is a real fact about them. It is discarded here, which is
        why every model using this macro keeps a _raw column — that is where
        the title survives.

    FOR MATCHING, USE SOMETHING ELSE
        This produces a name for DISPLAY. Comparing two of these will still
        fail on accents, punctuation and case. Matching needs a separate,
        aggressively normalised key — see stg_crm__landlords, which builds one
        inline. That key is deliberately NOT a macro: it is used once, and
        wrapping a single use in a macro hides SQL that the one reader who
        cares needs to see.
#}

{% macro normalise_person_name(column) %}
    trim(regexp_replace(
        case
            when {{ column }} is null then null
            when {{ column }} like '%,%' then
                trim(regexp_replace(split_part({{ column }}, ',', 2), '\s+', ' ', 'g'))
                || ' ' ||
                trim(regexp_replace(split_part({{ column }}, ',', 1), '\s+', ' ', 'g'))
            else trim(regexp_replace({{ column }}, '\s+', ' ', 'g'))
        end,
        '^(MR|MRS|MS|MISS|DR|PROF)\.?\s+', '', 'i'))
{% endmacro %}
