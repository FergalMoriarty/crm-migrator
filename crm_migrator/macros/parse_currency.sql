{#
    parse_currency(column)

    WHAT IT DOES
        Turns currency written as text into a numeric. Handles '£1,250.00',
        '1250', '1,250.00', '£ 1,250.00', 'GBP 1,250.00', '-£120.00' and
        '(120.00)'.

    THE BRACKET CASE IS THE WHOLE POINT
        '(120.00)' is accounting notation for a negative. Strip the
        non-numeric characters and it becomes '120.00' — a refund silently
        recorded as income. Every total downstream would be wrong by twice the
        refund and nothing would look broken.
        So the bracket is detected on the ORIGINAL string, before any
        stripping, and applied as a sign afterwards. That ordering is the
        reason this is a macro rather than four hand-written copies: it is
        exactly the step someone would leave out of the fourth one.

    ON THE VERBOSE OUTPUT
        The compiled SQL repeats the regexp_replace three times. That is ugly
        and it does not matter — nobody types it and Postgres does not care.
        Optimising the generated SQL for human beauty is optimising the wrong
        artefact; optimise the macro for correctness and the model for
        readability.

    PRECISION
        numeric(12,2) — fixed point, not float. Money in a float will
        eventually produce a total ending .9999999 and an argument about
        whether the migration lost a penny.
#}

{% macro parse_currency(column) %}
    case
        when nullif(regexp_replace({{ column }}, '[^0-9.\-]', '', 'g'), '') !~ '^-?[0-9]+(\.[0-9]+)?$'
            then null
        when {{ column }} ~ '^\s*\(.*\)\s*$'
            then -1 * regexp_replace({{ column }}, '[^0-9.\-]', '', 'g')::numeric(12,2)
        else regexp_replace({{ column }}, '[^0-9.\-]', '', 'g')::numeric(12,2)
    end
{% endmacro %}
