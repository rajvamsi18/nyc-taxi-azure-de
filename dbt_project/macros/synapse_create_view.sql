-- This macro overrides dbt-synapse's default view creation behaviour
-- By default dbt creates a temp view then renames it — Synapse Serverless
-- does not support RENAME on views, causing the "Incorrect syntax near rename" error
-- CREATE OR ALTER VIEW handles both new and existing views in one statement
-- eliminating the need for any rename or drop operations


{% macro synapse__create_view_as(relation, sql) -%}
  CREATE OR ALTER VIEW {{ relation }} AS
    {{ sql }}
{% endmacro %}

{% materialization view, adapter='synapse' %}
  {%- set target_relation = this.incorporate(type='view') -%}
  {{ run_hooks(pre_hooks) }}
  {% call statement('main') -%}
    {{ synapse__create_view_as(target_relation, sql) }}
  {%- endcall %}
  {{ run_hooks(post_hooks) }}
  {% do persist_docs(target_relation, model) %}
  {{ return({'relations': [target_relation]}) }}
{% endmaterialization %}