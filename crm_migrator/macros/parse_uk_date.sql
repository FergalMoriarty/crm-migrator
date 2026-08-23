{#
    parse_uk_date(column)

    WHAT IT DOES
        Parses the six date formats present in one text column:
        ISO 'YYYY-MM-DD', UK 'DD/MM/YYYY', 'DD-MM-YYYY', short 'D/M/YY',
        a five-digit Excel serial, and a UK date with a time appended.
        Anything else returns NULL.

    WHY EACH BRANCH IS GUARDED BY A REGEX
        to_date() is lenient. to_date('31/02/2024','DD/MM/YYYY') returns
        2024-03-02 rather than raising, and to_date('BT7 1NN','DD/MM/YYYY')
        returns something absurd. Matching the shape first means anything
        unrecognised becomes NULL and can be counted, instead of becoming a
        plausible wrong date that no one questions.

    THE EXCEL BRANCH
        Excel counts days from 1899-12-30, not 1900-01-01, because it wrongly
        believes 1900 was a leap year and shifts its epoch to compensate.
        Anyone who has debugged a two-day date discrepancy has met this.

    WHY THIS IS A MACRO
        Four uses across three models, six branches each. Same argument as the
        placeholder list: the set of formats we accept is a DECISION, and a
        date that parses in stg_crm__payments but not in stg_crm__tenancies is
        the kind of inconsistency that takes a day to find.

    AMBIGUITY THIS CANNOT RESOLVE
        '03/04/2024' is 3 April under UK convention and 4 March under US. The
        agency is in Belfast so UK is assumed, and it is an assumption: nothing
        in the export states the convention. A US-formatted export would parse
        silently and wrongly, and no test here would catch it.
#}

{% macro parse_uk_date(column) %}
    case
        when {{ column }} is null                          then null
        when {{ column }} ~ '^\d{4}-\d{2}-\d{2}'           then to_date(left({{ column }}, 10), 'YYYY-MM-DD')
        when {{ column }} ~ '^\d{2}/\d{2}/\d{4}'           then to_date(left({{ column }}, 10), 'DD/MM/YYYY')
        when {{ column }} ~ '^\d{2}-\d{2}-\d{4}$'          then to_date({{ column }}, 'DD-MM-YYYY')
        when {{ column }} ~ '^\d{1,2}/\d{1,2}/\d{2}$'      then to_date({{ column }}, 'FMDD/FMMM/YY')
        when {{ column }} ~ '^\d{5}$'                      then date '1899-12-30' + {{ column }}::int
        else null
    end
{% endmacro %}
