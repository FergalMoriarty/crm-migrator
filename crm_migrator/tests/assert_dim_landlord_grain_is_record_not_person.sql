/*
    A SINGULAR TEST THAT ASSERTS A LIMITATION, AND PASSES.

    dim_landlord is one row per landlord RECORD, not one row per landlord.
    Four people appear twice under different refs, so landlord_name_key - the
    aggressively normalised matching key - is NOT unique in this dimension.

    THIS TEST PASSES TODAY AND IS SUPPOSED TO.
        It asserts that duplicate people exist. That reads like a strange
        thing to test until you consider the alternative: a comment in a
        README saying "note, landlords are not deduplicated yet", which
        nobody reads, next to a green test run that looks like a clean bill of
        health.
        Writing the limitation as an executable assertion means the gap is
        visible in the same output as everything else, and it means the day
        someone adds deduplication WITHOUT updating the documentation, this
        test fails and forces the conversation.

    WHEN IT SHOULD BE DELETED
        The moment the intermediate layer resolves landlord identity in phase
        2. At that point the grain genuinely becomes one row per person, the
        duplicates are gone, this test fails, and its failure is the signal to
        replace it with a `unique` test on landlord_name_key.
        A test that is meant to be deleted should say so in the file.

    This is the same technique crm-migration-validator uses for its
    offsetting-errors limitation: assert the limitation, so nobody reads a
    green run and concludes more than it proves.
*/

with duplicate_people as (

    select landlord_name_key, count(*) as records
    from {{ ref('dim_landlord') }}
    where not is_unknown_member
    group by landlord_name_key
    having count(*) > 1

)

-- Fails if the duplicates have disappeared, i.e. if deduplication has been
-- introduced somewhere upstream without this documentation being updated.
select 'expected duplicate landlord records, found none' as failure
where (select count(*) from duplicate_people) = 0
