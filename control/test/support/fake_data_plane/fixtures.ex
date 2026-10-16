defmodule Steward.FakeDataPlane.Fixtures do
  @moduledoc """
  Synthetic `steward.plane.v1` messages (doc 18 §7: synthetic data only). No
  message built here carries a row: summaries are typed aggregates, impact is
  name → number, assertion results are status + count + `sample_ref`
  (doc 13 invariant 9).
  """
  alias Steward.Plane.V1

  def timestamp(%DateTime{} = at \\ DateTime.utc_now()) do
    %Google.Protobuf.Timestamp{
      seconds: DateTime.to_unix(at),
      nanos: elem(at.microsecond, 0) * 1000
    }
  end

  @doc """
  A `ChangesetReport` for a computed changeset: one table updated, one column
  with a numeric delta, one impact metric, and (by default) no assertion fired.
  Pass `overrides` to change any top-level field, e.g. `assertion_results:` or
  `conflicts_count:`.
  """
  def changeset_report(changeset_id, branch_id, overlay_id, overrides \\ []) do
    base = %V1.ChangesetReport{
      changeset_id: changeset_id,
      branch_id: branch_id,
      overlay_id: overlay_id,
      summary: %V1.Summary{
        truncated: false,
        tables: [%V1.TableSummary{table_name: "products", updates: 12}],
        columns: [
          %V1.ColumnSummary{
            table_name: "products",
            column_name: "price",
            changed_count: 12,
            numeric_delta_min: 0.5,
            numeric_delta_max: 2.0,
            numeric_delta_median: 1.0,
            numeric_pct_median: 3.0,
            distinct_before: 12,
            distinct_after: 12
          }
        ],
        staleness_check: "values"
      },
      impact: [%V1.ImpactMetric{name: "rows_in_catalogue", value: 1200.0}],
      assertion_results: [],
      evidence_refs: [
        %V1.EvidenceRef{
          path: "evidence/#{branch_id}/0001",
          digest: digest("evidence-#{branch_id}")
        }
      ],
      row_delta_digest: digest("row-delta-#{changeset_id}"),
      reversible: "complete",
      conflicts_count: 0,
      touches_revertable_merges: [],
      evidence_query_count: 3,
      evidence_tables_read: ["products"]
    }

    struct!(base, overrides)
  end

  @doc "An `AssertionResult` (status `passed` | `failed` | `error`); never carries sample keys."
  def assertion_result(policy_id, assertion_id, status, opts \\ []) do
    %V1.AssertionResult{
      policy_id: policy_id,
      assertion_id: assertion_id,
      status: status,
      count: Keyword.get(opts, :count, if(status == "failed", do: 3, else: 0)),
      count_capped: false,
      sample_ref: Keyword.get(opts, :sample_ref, "samples/#{policy_id}/#{assertion_id}"),
      error_code: Keyword.get(opts, :error_code),
      duration_ms: 12
    }
  end

  @doc "A `ComputeError` for a `ChangesetReport` (doc 05 typed errors)."
  def compute_error(code, retryable \\ false) do
    %V1.ComputeError{code: code, safe_message: "synthetic #{code}", retryable: retryable}
  end

  def target_description(target_id) do
    %V1.TargetDescription{
      target_id: target_id,
      fidelity: "TRUE_SNAPSHOT",
      schema_json: ~s({"tables":[{"name":"products","primary_key":["id"]}]}),
      reversible_tables: ["products"],
      adapter_version: "fake-0",
      described_at: timestamp()
    }
  end

  def digest(seed), do: :crypto.hash(:sha256, seed)
end
