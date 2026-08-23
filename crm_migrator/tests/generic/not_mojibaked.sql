{#
    A CUSTOM GENERIC TEST — not_mojibaked

    WHAT A GENERIC TEST IS
        A parameterised query that returns the rows that FAIL. dbt runs it,
        counts the rows, and the test passes if the count is zero. That is the
        whole contract: return the offenders, return nothing when there are
        none.

        "Generic" means it takes arguments and can be attached to any column of
        any model from YAML, like unique or not_null — which are themselves
        just generic tests shipped with dbt, written exactly like this one.

    WHY THIS ONE EXISTS
        repair_mojibake is the most fragile thing in the project. Its list of
        sequences was wrong twice: once because the loop applied it backwards,
        once because five uppercased variants were missing. Both were found by
        hand, by querying the output and noticing stray characters.
        This test does that automatically, on every column that should have
        been cleaned, on every run. The next missing sequence gets found by
        `dbt build` instead of by someone reading a report and squinting.

    WHY IT CHECKS FOR FRAGMENTS TOO
        'Ã', 'â€' and 'Â' catch UNREPAIRED damage. '™' and '€' catch
        PARTIALLY repaired damage — the fragment left behind when a short
        sequence eats the front of a longer one. The second is the failure
        that survives a careless fix, so it is the one worth having.

    WHY GENERIC AND NOT SINGULAR
        It applies to seven columns across four models and the logic is
        identical each time. Anything you would otherwise copy into seven
        files with one word changed is a generic test.

    THE FALSE POSITIVE IT WILL EVENTUALLY HIT
        A landlord legitimately called 'Ã…s' — a real Norwegian surname — or a
        note that genuinely mentions a price in euros would fail this. That is
        the correct trade for UK lettings data, where neither is plausible,
        and it is the kind of assumption to revisit if this project ever meets
        a non-UK agency.
#}

{% test not_mojibaked(model, column_name) %}

select
    {{ column_name }} as offending_value,
    count(*) as occurrences
from {{ model }}
where {{ column_name }} ~ 'Ã|â€|Â|™|€'
group by 1

{% endtest %}
