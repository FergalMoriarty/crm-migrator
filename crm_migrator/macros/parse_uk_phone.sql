{#
    parse_uk_phone(column)

    WHAT IT DOES
        Normalises a UK phone number to E.164: '+44' followed by the national
        number with its leading zero removed. Returns NULL if it cannot.

    THE FORMS IT HANDLES
        '07700 900123', '+44 7700 900123', '0044 7700900123',
        '(028) 9649 612', and bare '7700900123'.

    THE ASSUMPTION WORTH SEEING
        That last form is Excel treating the cell as a number and eating the
        leading zero. A bare nine or ten digit string starting with a valid
        trunk digit is therefore assumed to be missing its zero — and that is
        a GUESS. Nothing in the export says so. It is overwhelmingly likely
        for UK data and it would be wrong for an international number that
        happened to fit the pattern.
        Whatever flag a model derives from this tells you the number PARSED.
        It does not tell you the number is right.

    WHY THIS IS A MACRO
        Only two uses, which is below the bar on repetition alone. It is here
        because of the assumption above: a parsing rule that embeds a guess
        should exist in exactly one place, where the guess can be found,
        argued with and changed. Two copies means two guesses that can drift
        apart without anyone deciding they should.
#}

{% macro parse_uk_phone(column) %}
    {%- set digits -%}regexp_replace({{ column }}, '[^0-9]', '', 'g'){%- endset -%}
    case
        when nullif({{ digits }}, '') is null           then null
        when {{ digits }} like '0044%'                  then '+44' || substring({{ digits }} from 5)
        when {{ digits }} like '44%' and length({{ digits }}) >= 12
                                                        then '+44' || substring({{ digits }} from 3)
        when {{ digits }} like '0%'                     then '+44' || substring({{ digits }} from 2)
        when {{ digits }} ~ '^[1-9][0-9]{8,9}$'         then '+44' || {{ digits }}
        else null
    end
{% endmacro %}
