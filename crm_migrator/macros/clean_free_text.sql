{#
    clean_free_text(column)

    WHAT IT DOES
        Turns a free-text field written by humans over a decade into something
        comparable: decodes HTML entities, strips tags, collapses every
        whitespace run to a single space, trims, and returns NULL if nothing
        is left.

    ORDER, AND WHY EACH STEP IS WHERE IT IS
        1. Entities first. '&amp;' must become '&' before anything looks for
           an ampersand, or a search for 'Kavanagh & Co' misses the row.
        2. Tags second, replaced with a SPACE rather than deleted.
           '<p>One.</p><p>Two.</p>' must not become 'One.Two.' — deleting a tag
           welds two sentences together and nobody notices.
        3. Whitespace last, because steps 1 and 2 both introduce it.

    WHY THIS IS A MACRO
        Four uses, and the nesting is six levels deep. Like repair_mojibake,
        the case is not that it repeats but that it is past proofreading by
        eye — a missing bracket in one of the four copies would produce valid
        SQL with subtly different output.

    WHAT IT DESTROYS
        Line breaks. Some of these notes are typed lists and the structure is
        real. Every model using this keeps the original in a _raw column for
        exactly that reason. If paragraph structure later matters, the fix is
        an additional column that preserves it, not the removal of this one.
#}

{% macro clean_free_text(column) %}
    nullif(
        trim(
            regexp_replace(
                regexp_replace(
                    replace(replace(replace(replace(replace(
                        {{ column }},
                        '&nbsp;', ' '), '&amp;', '&'), '&lt;', '<'), '&gt;', '>'), '&#39;', ''''),
                    '<[^>]*>', ' ', 'g'),
                '\s+', ' ', 'g')
        ),
        ''
    )
{% endmacro %}
