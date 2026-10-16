defmodule Steward.Core.Types.TargetKind do
  @moduledoc "Doc 12 §2.1 `target_kind`."
  use Ash.Type.Enum,
    values: [:postgres, :mysql, :iceberg, :snowflake, :bigquery, :salesforce, :hubspot]
end
