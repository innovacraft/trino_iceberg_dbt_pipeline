{% macro direct_sql_sync(kafka_source='kafka.default.events_topic', target_table='iceberg.default.raw_events_streaming', limit=1000) %}

{# This macro uses only direct SQL without any models or views #}
{# Run with: dbt run-operation direct_sql_sync --args '{"kafka_source": "kafka.default.events_topic", "target_table": "iceberg.default.raw_events_streaming", "limit": 1000}' #}

{% set create_table_sql %}
CREATE TABLE IF NOT EXISTS {{ target_table }} (
    id BIGINT,
    name VARCHAR,
    created_at TIMESTAMP(6),
    kafka_partition INTEGER,
    kafka_offset BIGINT,
    kafka_timestamp TIMESTAMP(6),
    processed_at TIMESTAMP(6)
)
WITH (
    format = 'PARQUET'
)
{% endset %}

{% do run_query(create_table_sql) %}
{% do log("Created table if it didn't exist: " ~ target_table, info=True) %}

{% set get_max_offset_sql %}
SELECT COALESCE(MAX(kafka_offset), -1) AS max_offset 
FROM {{ target_table }}
{% endset %}

{% set max_offset_result = run_query(get_max_offset_sql) %}
{% if execute %}
    {% set last_offset = max_offset_result.columns['max_offset'][0] %}
{% else %}
    {% set last_offset = -1 %}
{% endif %}

{% do log("Last processed Kafka offset: " ~ last_offset, info=True) %}

{% set insert_data_sql %}
INSERT INTO {{ target_table }}
SELECT 
    CAST(JSON_EXTRACT_SCALAR(CAST(message AS VARCHAR), '$.id') AS BIGINT) AS id,
    JSON_EXTRACT_SCALAR(CAST(message AS VARCHAR), '$.name') AS name,
    CAST(JSON_EXTRACT_SCALAR(CAST(message AS VARCHAR), '$.created_at') AS TIMESTAMP(6)) AS created_at,
    _kafka_partition AS kafka_partition,
    _kafka_offset AS kafka_offset,
    CAST(_timestamp AS TIMESTAMP(6)) AS kafka_timestamp,
    CAST(CURRENT_TIMESTAMP AS TIMESTAMP(6)) AS processed_at
FROM {{ kafka_source }}
WHERE _kafka_offset > {{ last_offset }}
  AND JSON_EXTRACT_SCALAR(CAST(message AS VARCHAR), '$.id') IS NOT NULL
ORDER BY _kafka_offset
LIMIT {{ limit }}
{% endset %}

{% do run_query(insert_data_sql) %}
{% do log("Inserted new records into " ~ target_table, info=True) %}

{% set count_records_sql %}
SELECT COUNT(*) AS record_count FROM {{ target_table }}
{% endset %}

{% set count_result = run_query(count_records_sql) %}
{% if execute %}
    {% set record_count = count_result.columns['record_count'][0] %}
{% else %}
    {% set record_count = 0 %}
{% endif %}

{% do log("Total records in table: " ~ record_count, info=True) %}

{{ return("Successfully synced data from " ~ kafka_source ~ " to " ~ target_table) }}

{% endmacro %}