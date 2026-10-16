defmodule Steward.Core.Types.LifecycleReason do
  @moduledoc """
  Doc 12 §3 `lifecycle_reason`, used by `branches.reason`,
  `changesets.superseded_reason`, and `merges.reason`. Values and
  descriptions are copied literally from `contracts/reasons.yaml`'s
  `reasons:` list, which is the source of truth (CLAUDE.md rule 2); the
  `terminal`/`states_from`/`used_by` metadata that doesn't fit
  `Ash.Type.Enum`'s label/description mechanism is carried separately in
  `metadata/0`, which `mix steward.reasons.export` reads to rewrite the
  YAML and so detect drift.

  Deliberately excluded (contracts/reasons.yaml's "not in this list on
  purpose" note): `heartbeat_lost` (a flag, never a lifecycle reason) and
  `policies`/`policy_error`/`no_policy_coverage`/`revert_conflict` (those
  are `VerdictReason`, its own enum).
  """
  use Ash.Type.Enum,
    values: [
      snapshot_lost: [
        description:
          "Base snapshot no longer resolves (adapter SNAPSHOT_LOST); branch abandoned, merge failed."
      ],
      overlay_lost: [
        description:
          "Overlay lost while the base snapshot survives (data-plane volume loss, doc 14 §8)."
      ],
      stale_base: [
        description:
          "Merge found rows the base snapshot does not match; branch returns to proposed with a conflict changeset."
      ],
      ttl_expired: [
        description: "Open-branch or held-changeset TTL elapsed; branch abandoned."
      ],
      reject_with_retry: [
        description:
          "Reviewer rejected with allow_retry; branch returns to open and the changeset is superseded."
      ],
      compute_failed: [
        description:
          "Changeset computation failed past its retry budget; changeset superseded, branch returns to open."
      ],
      data_plane_unreachable: [
        description:
          "Data plane did not answer before the compensation checkpoint; merge failed, branch returns to proposed."
      ],
      compensation_failed: [
        description:
          "Compensation record could not be persisted; merge failed, branch returns to proposed."
      ],
      adapter_unavailable: [
        description: "Adapter unreachable past the retry budget; merge failed."
      ],
      withdrawn: [
        description:
          "Owning principal withdrew the proposal; branch returns to open and the changeset is superseded."
      ],
      reevaluated: [
        description: "Changeset superseded by a policy-change re-evaluation (doc 06 §5.3)."
      ],
      new_changeset: [
        description: "Changeset superseded because the branch was proposed again."
      ],
      verdict_block: [description: "Verdict outcome block; branch rejected."],
      review_rejected: [description: "Reviewer rejected without retry; branch rejected."],
      review_approved: [description: "Reviewer approved; branch moves to merging."],
      verdict_auto_merge: [
        description: "Verdict outcome auto-merge; branch moves to merging without review."
      ],
      abandoned_by_principal: [
        description: "Owning principal (or a target admin) abandoned the branch."
      ],
      merge_applied: [
        description:
          "Data plane confirmed every row applied and compensation recorded; branch merged."
      ],
      retention_elapsed: [
        description: "Retention window elapsed and the overlay was released; branch closed."
      ]
    ]

  @metadata %{
    snapshot_lost: %{
      terminal: true,
      states_from: [:open, :proposed, :merging],
      used_by: [:branch, :merge]
    },
    overlay_lost: %{terminal: true, states_from: [:open, :proposed, :merging], used_by: [:branch]},
    stale_base: %{
      terminal: false,
      states_from: [:merging],
      used_by: [:branch, :changeset, :merge]
    },
    ttl_expired: %{terminal: true, states_from: [:open, :proposed], used_by: [:branch]},
    reject_with_retry: %{
      terminal: false,
      states_from: [:proposed],
      used_by: [:branch, :changeset]
    },
    compute_failed: %{terminal: false, states_from: [:proposed], used_by: [:branch, :changeset]},
    data_plane_unreachable: %{
      terminal: false,
      states_from: [:merging],
      used_by: [:branch, :merge]
    },
    compensation_failed: %{terminal: false, states_from: [:merging], used_by: [:branch, :merge]},
    adapter_unavailable: %{terminal: false, states_from: [:merging], used_by: [:merge]},
    withdrawn: %{terminal: false, states_from: [:proposed], used_by: [:branch, :changeset]},
    reevaluated: %{terminal: false, states_from: [:proposed], used_by: [:changeset]},
    new_changeset: %{terminal: false, states_from: [:open, :proposed], used_by: [:changeset]},
    verdict_block: %{terminal: true, states_from: [:proposed], used_by: [:branch]},
    review_rejected: %{terminal: true, states_from: [:proposed], used_by: [:branch]},
    review_approved: %{terminal: false, states_from: [:proposed], used_by: [:branch]},
    verdict_auto_merge: %{terminal: false, states_from: [:proposed], used_by: [:branch]},
    abandoned_by_principal: %{terminal: true, states_from: [:open, :proposed], used_by: [:branch]},
    merge_applied: %{terminal: true, states_from: [:merging], used_by: [:branch]},
    retention_elapsed: %{
      terminal: true,
      states_from: [:merged, :rejected, :abandoned],
      used_by: [:branch]
    }
  }

  @doc "Ordered `{name, metadata}` pairs, in `contracts/reasons.yaml` order; read by `mix steward.reasons.export`."
  def metadata do
    for value <- values() do
      {value, Map.fetch!(@metadata, value)}
    end
  end
end
