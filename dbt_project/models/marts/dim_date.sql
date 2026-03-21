-- Model: dim_date
-- Calendar dimension covering all 366 days of 2024
-- Generated from a date spine, no source table needed
-- Enables queries like "revenue by day of week" and "trips by quarter"

with date_spine as (
    select DATEADD(DAY, number, '2024-01-01') as date_day
    from (
        select TOP 366
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 as number
        from sys.all_objects
    ) numbers
    where DATEADD(DAY, number, '2024-01-01') < '2025-01-01'
),

dates as (
    select
        CAST(CONVERT(VARCHAR(8), date_day, 112) AS INT) as date_id,
        date_day                                as full_date,
        DATEPART(DAY, date_day)                 as day_of_month,
        DATEPART(MONTH, date_day)               as month_number,
        DATENAME(MONTH, date_day)               as month_name,
        DATEPART(QUARTER, date_day)             as quarter_number,
        DATEPART(YEAR, date_day)                as year_number,
        DATEPART(WEEKDAY, date_day)             as day_of_week_number,
        DATENAME(WEEKDAY, date_day)             as day_of_week_name,
        CASE
            WHEN DATEPART(WEEKDAY, date_day) IN (1, 7) THEN 1
            ELSE 0
        END                                     as is_weekend
    from date_spine
)

select * from dates
