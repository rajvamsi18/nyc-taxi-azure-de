-- Model: fact_trips
-- Central fact table of the gold layer, one row per taxi trip
-- 35.5M rows joining silver trips with all dimension tables

with trips as (
    select * from {{ ref('stg_yellow_trips') }}
),

dates as (
    select date_id, full_date
    from {{ ref('dim_date') }}
),

final as (
    select
        t.pickup_location_id,
        t.dropoff_location_id,
        d.date_id,
        t.payment_type                  as payment_type_id,
        t.pickup_datetime,
        t.dropoff_datetime,
        t.pickup_hour,
        t.trip_duration_mins,
        t.vendor_id,
        t.passenger_count,
        t.trip_distance,
        t.fare_amount,
        t.tip_amount,
        t.tolls_amount,
        t.congestion_surcharge,
        t.airport_fee,
        t.total_amount,
        ROUND(t.tip_amount / NULLIF(t.fare_amount, 0) * 100, 2) as tip_percentage
    from trips t
    left join dates d on t.pickup_date = d.full_date
)

select * from final
