{#
    clean_null_placeholders(column)

    WHAT IT DOES
        Trims the value, and returns NULL if what is left is any of the ways
        this export writes "nothing": an empty string, 'N/A', 'n/a', 'na',
        '-', '.', 'none', 'NULL', 'unknown', 'not known', 'tbc'.

    WHY THIS IS A MACRO
        It appeared 29 times across four models. That alone is not the
        argument — repetition is cheap and a macro costs readability, because
        the reader now has to open another file to see what happens to their
        column.
        The argument is that the LIST is a decision. Every model must agree on
        what counts as nothing, or the same landlord is missing in one model
        and present in another. Written out 29 times, the list drifts the first
        time someone adds 'NIL' to one model and forgets the other three.
        A macro makes it impossible to disagree with yourself.

    THE COST, STATED
        Reading stg_crm__payments no longer tells you that 'tbc' becomes NULL.
        That is a real loss and it is why this comment exists and why the
        models name the macro rather than aliasing it to something vague.
#}

{% macro clean_null_placeholders(column) %}
    {%- set nothing = ['', 'n/a', 'na', 'none', 'null', '-', '.', 'unknown', 'not known', 'tbc'] -%}
    case
        when lower(trim({{ column }})) in (
            {%- for value in nothing -%}
                '{{ value }}'{% if not loop.last %}, {% endif %}
            {%- endfor -%}
        ) then null
        else trim({{ column }})
    end
{% endmacro %}
