-- Model: dim_payment_type
-- Decodes payment_type integer codes to human-readable descriptions

with payment_types as (
    select *
    from (
        values
            (1, 'Credit card',  'Electronic'),
            (2, 'Cash',         'Cash'),
            (3, 'No charge',    'Waived'),
            (4, 'Dispute',      'Exception'),
            (5, 'Unknown',      'Other'),
            (6, 'Voided trip',  'Exception')
    ) as t(payment_type_id, payment_description, payment_category)
)

select * from payment_types
