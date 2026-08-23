{#
    format_uk_postcode(column) / is_valid_uk_postcode(column)

    WHAT THEY DO
        The first normalises a UK postcode to upper case with exactly one
        space before the final three characters — the standard outward/inward
        split and the only format Royal Mail considers correct. The second
        returns true if the result matches the UK postcode pattern.

    THE GUARD IS THE POINT
        An earlier version reformatted unconditionally and turned the
        truncated 'BT27 7R' into 'BT2 77R', splitting off three characters
        from something that never had a valid inward code. That is worse than
        leaving it alone, because it invents a postcode that looks deliberate.
        THE RULE: never reformat a value you could not parse. Unparseable
        input is passed through uppercased and trimmed, and the validity
        function reports the failure.

    SHAPE, NOT EXISTENCE
        'BT99 9ZZ' is well-formed and is not a real postcode. Only a Royal
        Mail PAF lookup knows the difference and this project does not have
        one. Anything built on this is checking format only.
#}

{% macro format_uk_postcode(column) %}
    {%- set compact -%}regexp_replace(upper({{ column }}), '[^A-Z0-9]', '', 'g'){%- endset -%}
    case
        when {{ column }} is null then null
        when {{ compact }} ~ '^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$'
            then left({{ compact }}, length({{ compact }}) - 3) || ' ' || right({{ compact }}, 3)
        else upper(trim(regexp_replace({{ column }}, '\s+', ' ', 'g')))
    end
{% endmacro %}

{% macro is_valid_uk_postcode(column) %}
    ({{ column }} ~ '^[A-Z]{1,2}[0-9][A-Z0-9]? [0-9][A-Z]{2}$')
{% endmacro %}
