-- Model: dim_zones
-- Maps LocationID integers to human-readable zone names and boroughs

with zones as (
    select
        LocationID      as location_id,
        Borough         as borough,
        Zone            as zone_name,
        service_zone
    from {{ source('bronze_reference', 'taxi_zone_lookup') }}
)

select * from zones
