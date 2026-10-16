defmodule Steward.Core.Audit do
  @moduledoc """
  The `Steward.Audit` domain (doc 07 §4): `events`, `audit_log`, `webhooks`,
  `webhook_deliveries`. No other domain's resources are referenced here —
  `Targets`, `Policies`, `Branches`, and `Reviews` all depend on this domain
  (for `AppendEvent`), so this domain must depend on none of them.
  """
  use Boundary,
    exports: [AppendEvent, AppendOnly, BoundaryJson, Event, AuditLog, Webhook, WebhookDelivery]

  use Ash.Domain

  resources do
    resource Steward.Core.Audit.Event
    resource Steward.Core.Audit.AuditLog
    resource Steward.Core.Audit.Webhook
    resource Steward.Core.Audit.WebhookDelivery
  end
end
