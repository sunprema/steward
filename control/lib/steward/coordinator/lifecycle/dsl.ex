defmodule Steward.Coordinator.Lifecycle.Dsl do
  @moduledoc false

  alias Steward.Coordinator.Lifecycle
  alias Steward.Coordinator.Lifecycle.Cell

  @cell %Spark.Dsl.Entity{
    name: :cell,
    describe: "One `(believed, authoritative)` cell of doc 13 §6.8.",
    target: Cell,
    schema: [
      believed: [
        type: {:one_of, Lifecycle.believed_states()},
        required: true,
        doc: "What the data plane believes the branch's state is."
      ],
      authoritative: [
        type: {:one_of, Lifecycle.authoritative_states()},
        required: true,
        doc: "The control plane's state for the branch (a branch state, or `:unknown`)."
      ],
      reply: [
        type: {:one_of, Lifecycle.authoritative_states()},
        required: true,
        doc: "The authoritative state the heartbeat reply carries. The data plane adopts it."
      ],
      actions: [
        type: {:list, {:one_of, Lifecycle.actions()}},
        default: [],
        doc:
          "What the control plane does besides replying. `:alert` is the only one that never repairs."
      ]
    ]
  }

  @heartbeat %Spark.Dsl.Section{
    name: :heartbeat,
    describe: "The heartbeat reconciliation matrix (doc 13 §6.8).",
    entities: [@cell]
  }

  use Spark.Dsl.Extension,
    sections: [@heartbeat],
    transformers: [
      Steward.Coordinator.Lifecycle.Transformers.VerifyCoverage,
      Steward.Coordinator.Lifecycle.Transformers.GenerateDecide
    ]
end
