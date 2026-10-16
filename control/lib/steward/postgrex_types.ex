# Ash's `:duration` attributes (Org.audit_retention, the TargetSettings TTLs)
# are stored as Postgres `interval`; Postgrex must decode intervals as
# `Duration`, and that can only be set when the types module is defined.
Postgrex.Types.define(
  Steward.PostgrexTypes,
  Ecto.Adapters.Postgres.extensions(),
  interval_decode_type: Duration
)
