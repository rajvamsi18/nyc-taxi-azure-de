-- Model: stg_yellow_trips
-- Reads from the silver layer, renames columns to snake_case
-- Adds pickup_hour derived column for time-based analysis

with source as (
    select * from {{ source('silver', 'silver_yellow_trips_2024') }}
),

renamed as (
    select
        VendorID                                        as vendor_id,
        pickup_datetime,
        dropoff_datetime,
        trip_duration_mins,
        DATEPART(HOUR, pickup_datetime)                 as pickup_hour,
        CAST(pickup_datetime AS DATE)                   as pickup_date,
        pickup_location_id,
        dropoff_location_id,
        passenger_count,
        trip_distance,
        fare_amount,
        tip_amount,
        tolls_amount,
        congestion_surcharge,
        Airport_fee                                     as airport_fee,
        total_amount,
        payment_type
    from source
)

select * from renamed
