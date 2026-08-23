\echo '== refactor diff: 0 rows on every line means behaviour is unchanged =='

WITH
landlords AS (
    SELECT 'landlords' AS model,
      (SELECT count(*) FROM (
         SELECT landlord_id,landlord_name,landlord_name_key,email,email_had_multiple_values,
                phone,phone_type,address_line_1,address_line_2,town,postcode,
                date_added,status,notes,source_agency
         FROM checkpoint.landlords
         EXCEPT
         SELECT landlord_id,landlord_name,landlord_name_key,email,email_had_multiple_values,
                phone,phone_type,address_line_1,address_line_2,town,postcode,
                date_added,status,notes,source_agency
         FROM dbt_meridian_staging.stg_crm__landlords) a) AS old_not_new,
      (SELECT count(*) FROM (
         SELECT landlord_id,landlord_name,landlord_name_key,email,email_had_multiple_values,
                phone,phone_type,address_line_1,address_line_2,town,postcode,
                date_added,status,notes,source_agency
         FROM dbt_meridian_staging.stg_crm__landlords
         EXCEPT
         SELECT landlord_id,landlord_name,landlord_name_key,email,email_had_multiple_values,
                phone,phone_type,address_line_1,address_line_2,town,postcode,
                date_added,status,notes,source_agency
         FROM checkpoint.landlords) b) AS new_not_old
),
properties AS (
    SELECT 'properties',
      (SELECT count(*) FROM (
         SELECT property_id,landlord_id,address_line_1,address_line_2,town,postcode,
                bedrooms,property_type,monthly_rent,date_listed,description,source_agency
         FROM checkpoint.properties
         EXCEPT
         SELECT property_id,landlord_id,address_line_1,address_line_2,town,postcode,
                bedrooms,property_type,monthly_rent,date_listed,description,source_agency
         FROM dbt_meridian_staging.stg_crm__properties) a),
      (SELECT count(*) FROM (
         SELECT property_id,landlord_id,address_line_1,address_line_2,town,postcode,
                bedrooms,property_type,monthly_rent,date_listed,description,source_agency
         FROM dbt_meridian_staging.stg_crm__properties
         EXCEPT
         SELECT property_id,landlord_id,address_line_1,address_line_2,town,postcode,
                bedrooms,property_type,monthly_rent,date_listed,description,source_agency
         FROM checkpoint.properties) b)
),
tenancies AS (
    SELECT 'tenancies',
      (SELECT count(*) FROM (
         SELECT tenancy_id,property_id,tenant_name,tenant_email,tenant_phone,
                start_date,end_date,rent,deposit_held,comments,source_agency
         FROM checkpoint.tenancies
         EXCEPT
         SELECT tenancy_id,property_id,tenant_name,tenant_email,tenant_phone,
                start_date,end_date,rent,deposit_held,comments,source_agency
         FROM dbt_meridian_staging.stg_crm__tenancies) a),
      (SELECT count(*) FROM (
         SELECT tenancy_id,property_id,tenant_name,tenant_email,tenant_phone,
                start_date,end_date,rent,deposit_held,comments,source_agency
         FROM dbt_meridian_staging.stg_crm__tenancies
         EXCEPT
         SELECT tenancy_id,property_id,tenant_name,tenant_email,tenant_phone,
                start_date,end_date,rent,deposit_held,comments,source_agency
         FROM checkpoint.tenancies) b)
),
payments AS (
    SELECT 'payments',
      (SELECT count(*) FROM (
         SELECT payment_id,tenancy_id,paid_on,amount,is_refund,payment_method,
                payment_reference,source_agency
         FROM checkpoint.payments
         EXCEPT
         SELECT payment_id,tenancy_id,paid_on,amount,is_refund,payment_method,
                payment_reference,source_agency
         FROM dbt_meridian_staging.stg_crm__payments) a),
      (SELECT count(*) FROM (
         SELECT payment_id,tenancy_id,paid_on,amount,is_refund,payment_method,
                payment_reference,source_agency
         FROM dbt_meridian_staging.stg_crm__payments
         EXCEPT
         SELECT payment_id,tenancy_id,paid_on,amount,is_refund,payment_method,
                payment_reference,source_agency
         FROM checkpoint.payments) b)
)
SELECT * FROM landlords
UNION ALL SELECT * FROM properties
UNION ALL SELECT * FROM tenancies
UNION ALL SELECT * FROM payments
ORDER BY 1;

\echo '== the one expected change: validity flags now NULL where nothing was supplied =='
\echo '== every row here must have an empty email_raw. A populated one is a regression. =='

SELECT o.landlord_id, o.is_valid_email AS old_flag, n.is_valid_email AS new_flag,
       coalesce(nullif(trim(n.email_raw), ''), '(no email supplied)') AS email_raw
FROM   checkpoint.landlords o
JOIN   dbt_meridian_staging.stg_crm__landlords n USING (landlord_id)
WHERE  o.is_valid_email IS DISTINCT FROM n.is_valid_email
    OR o.is_valid_phone IS DISTINCT FROM n.is_valid_phone
ORDER BY 1;