-- Model: agg_revenue_by_zone
-- Pre-aggregated revenue summary by pickup zone, 265 rows
-- Powers the revenue by zone Power BI dashboard visual

with trips as (
    select * from {{ ref('fact_trips') }}
),

zones as (
    select * from {{ ref('dim_zones') }}
),

aggregated as (
    select
        z.borough,
        z.zone_name,
        z.service_zone,
        t.pickup_location_id,
        COUNT(*)                            as total_trips,
        ROUND(SUM(t.total_amount), 2)       as total_revenue,
        ROUND(AVG(t.total_amount), 2)       as avg_revenue_per_trip,
        ROUND(AVG(t.trip_distance), 2)      as avg_distance_miles,
        ROUND(AVG(t.trip_duration_mins), 1) as avg_duration_mins,
        ROUND(AVG(t.tip_percentage), 2)     as avg_tip_percentage,
        ROUND(SUM(t.tip_amount), 2)         as total_tips
    from trips t
    left join zones z on t.pickup_location_id = z.location_id
    group by z.borough, z.zone_name, z.service_zone, t.pickup_location_id
)

select * from aggregated
