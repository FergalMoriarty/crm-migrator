{#
    keep_if_unparsed(column, parsed_expression)

    WHAT IT DOES
        Returns the original text ONLY when the value was present and the
        parse produced NULL. Otherwise returns NULL.

    WHY THIS EXISTS
        The rule in this project is that an original is kept when cleaning
        destroys something irrecoverable. A failed parse is exactly that: the
        cleaned column is NULL and the source text is the only evidence of
        what was there.
        Keeping a full _raw twin of every parsed column would store 1,800
        copies of '£750.00' to preserve the four values that failed. This
        stores the four.

    HOW TO READ IT IN A MODEL
        amount           -> the number, or NULL
        amount_unparsed  -> NULL, or the text that defeated the parser
        Exactly one of the pair is populated when the source had a value, and
        both are NULL when it did not. That makes "how many did we fail to
        read" a count, and puts the offending values one query away.

    THE COST
        The parse expression is evaluated twice in the compiled SQL, once for
        the value and once here. On a view over a few thousand rows that is
        free. On a large incremental table it would be worth materialising the
        parse once in an earlier CTE instead.
#}

{% macro keep_if_unparsed(column, parsed_expression) %}
    case
        when {{ column }} is not null and ({{ parsed_expression }}) is null
            then {{ column }}
    end
{% endmacro %}
