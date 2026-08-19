{#
    repair_mojibake(column)

    WHAT THIS DOES
        Reverses a specific, common encoding accident: a UTF-8 file that was
        read as Windows-1252 and written back out, turning 'é' into 'Ã©' and
        '£' into 'Â£' permanently.

    WHY IT IS A MACRO AND NOT PLAIN SQL
        The plan put macros in increment 4, and most of the repetition in
        stg_crm__landlords is deliberately still there so the case for macros
        can be felt rather than asserted. This one could not wait: it is
        eighteen nested replace() calls, applied to eight columns, and written
        out by hand that is 144 string literals in one model with no way to
        check them by eye. The rule of thumb it illustrates: reach for a macro
        when the SQL is too long to *proofread*, not merely when it repeats.

    WHY A REPLACE CHAIN AND NOT THE PROPER FIX
        Postgres can reverse the round-trip correctly:

            convert_from(convert_to(txt, 'WIN1252'), 'UTF8')

        and it raises an exception on any string that is NOT mojibaked but does
        contain an accent — 'Sinéad' encodes to bytes that are not valid UTF-8,
        and the model dies. Plain SQL has no TRY_CAST and no way to catch it,
        so using it means a PL/pgSQL function with an EXCEPTION block, created
        outside dbt, hiding part of the transformation from the lineage graph.

        This chain is narrower and honest about it: it repairs the sequences
        actually present in the data and leaves everything else alone. That
        limitation belongs in the README, not behind a function that mostly
        works. When a real export arrives with a character not on this list,
        the fix is to add it here, deliberately.

    UPPERCASED MOJIBAKE IS A SEPARATE FAMILY
        Some notes were put through an upper-case transform AFTER the encoding
        damage, which mangles the mangling: 'â€“' becomes 'Â€“', because 'â'
        upper-cases to 'Â'. The 'Â€...' entries in the list below exist for
        that reason. Two of them occur in the Harcourt & Vine export and
        neither was in the first version of this macro — they were found by
        querying the built model for leftover '™' and '€' fragments. That is
        the only reliable way to find them: you cannot enumerate this family by
        reasoning about it, you have to look at the output and iterate.

    A NOTE ON WHERE THESE MUST SIT IN THE LIST
        'Â' on its own is the last entry, and it is a prefix of 'Â£', 'Â ' and
        every 'Â€...' sequence. Because the list is applied top to bottom, the
        longer entries must appear above it or the bare 'Â' consumes their
        first character and leaves a fragment behind. This is the concrete
        reason the loop below walks the list forwards.

    ORDER MATTERS
        'â€™' must be replaced before 'â€', and 'Â£' before 'Â', or a longer
        sequence gets eaten by a shorter one and leaves a stray character
        behind. The list below is ordered longest-first and replace() is
        applied in that order.

    UNREPAIRABLE BY DESIGN
        Some characters do not survive the round trip at all. 'Í' encodes to a
        byte that Windows-1252 does not define, so it is destroyed rather than
        mangled and no replacement can bring it back. Nothing here pretends
        otherwise.
#}

{% macro repair_mojibake(column) %}
    {%- set sequences = [
        ('â€™', '’'),
        ('â€˜', '‘'),
        ('â€œ', '“'),
        ('â€“', '–'),
        ('â€”', '—'),
        ('â€¦', '…'),
        ('â‚¬', '€'),
        ('Â€™', '’'),
        ('Â€“', '–'),
        ('Â€”', '—'),
        ('Â€¦', '…'),
        ('Â‚¬', '€'),
        ('Ã©', 'é'),
        ('Ã¡', 'á'),
        ('Ã³', 'ó'),
        ('Ãº', 'ú'),
        ('Ã­', 'í'),
        ('Ã‰', 'É'),
        ('Ã“', 'Ó'),
        ('Ãš', 'Ú'),
        ('Â£', '£'),
        ('Â ', ' '),
        ('Â', '')
    ] -%}
    {#- HOW THE TWO LOOPS BUILD THE EXPRESSION

        The first loop emits an opening 'replace(' per entry and ignores the
        values — the underscores say so. The second emits the argument pairs
        and the closing brackets.

        The APPLICATION order is the order the second loop emits, because the
        first pair after the column closes the innermost replace(), and the
        innermost one runs first. So the second loop must walk the list
        forwards for the list to read in the order it is applied. An earlier
        version had '| reverse' here, which silently applied the list bottom
        upwards — harmless for these particular entries, and exactly the kind
        of thing that stops being harmless the moment someone adds a shorter
        sequence that is a prefix of a longer one. -#}
    {%- for _, _ in sequences -%}replace({% endfor -%}
    {{ column }}
    {%- for bad, good in sequences -%}, '{{ bad }}', '{{ good }}'){% endfor -%}
{% endmacro %}
