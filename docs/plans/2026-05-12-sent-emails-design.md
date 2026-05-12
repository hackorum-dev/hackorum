# Sent Emails Audit Trail & UI

Date: 2026-05-12

## Problem

When a user sends an email via Hackorum, `SendOutgoingMessageJob` destroys the
`OutgoingDraft` row after creating the resulting `Message`. The sent content is
persisted in `messages`, but there is no per-user record of what each user has
sent, no surface for failed-send history, and no UI for users to review their
own activity.

## Goal

1. Keep `outgoing_drafts` rows after a successful send as a permanent per-user
   audit trail.
2. Show users a UI listing their drafts grouped by state: in-progress, failed,
   sent.

## Out of scope

- Admin-wide view (already exists at `admin/outgoing_messages_controller.rb`).
- Soft-delete or retention policy for old sent drafts.
- Editing or resending sent drafts.

## Approach chosen

Extend `outgoing_drafts` in place. Add a `sent` status; on successful send,
update the draft instead of destroying it. Convert the existing unique index to
a partial index so new drafts can still be composed against a parent that
already has a sent draft.

Rejected alternatives:

- Rename `outgoing_drafts` → `outgoing_messages`: high churn for naming.
- Separate `outgoing_sends` audit table: forces a join for the UI; user
  explicitly wants one place.

## Data model

`outgoing_drafts` changes:

- New status value `STATUS_SENT = 'sent'`. Existing values: `idle`, `sending`.
- New column `sent_message_id bigint NULL REFERENCES messages(id)`.
- New column `sent_at timestamp NULL`. Denormalized from
  `messages.sent_at` to make the index/listing query cheap.
- Drop `idx_drafts_user_parent_unique`.
- Add partial unique:
  ```
  CREATE UNIQUE INDEX idx_drafts_user_parent_active_unique
    ON outgoing_drafts(user_id, reply_to_message_id)
    WHERE status IN ('idle','sending');
  ```

Status lifecycle:

- `idle` — user editing, OR last attempt failed (see `last_send_error`).
- `sending` — job in flight.
- `sent` — final, immutable.

`OutgoingDraft` model:

- `STATUS_SENT` constant; include in `STATUSES` validation set.
- `belongs_to :sent_message, class_name: 'Message', optional: true`.
- `scope :sent, -> { where(status: STATUS_SENT) }`.
- Existing `idle` / `sending` / `stale_sending` scopes unchanged.
- Immutability after sent: override `readonly?` to return true when
  `status == STATUS_SENT`, so any update or destroy raises.

## Send job change

`app/jobs/send_outgoing_message_job.rb`, replace `draft.destroy!` (line 32):

```ruby
Message.transaction do
  msg = Message.create!(...)  # unchanged
  draft.update!(
    status:          OutgoingDraft::STATUS_SENT,
    sent_message_id: msg.id,
    sent_at:         Time.current,
    last_send_error: nil
  )
end
```

Same transaction so the Message row and the sent-state flip commit atomically.
Failure branches (`Gmail::AuthRevokedError`, `Gmail::PermanentError`) are
unchanged; they already leave the draft as `idle` with `last_send_error` set.

## Controller / authorization

`DraftsController`:

- `before_action :reject_sent_drafts, only: [:update, :destroy, :edit, :confirm, :send_now]`
  - For sent drafts, redirect to `draft_path(@draft)` (or render 422 for JSON/turbo).
- `create` — unchanged. Partial unique index permits new drafts after the
  earlier reply has been sent.
- New `index` — `current_user.outgoing_drafts.order(...)` with state filter.
- New `show` — read-only view for a single (typically sent) draft.

Scoping: all actions scope by `current_user`. No admin role gating; admin view
is separate.

Routes — `config/routes.rb` around line 98-103, expand the current `drafts`
block:

```ruby
resources :drafts, only: [:index, :show, :create, :update, :destroy] do
  member do
    get  :edit
    get  :confirm
    post :send_now
  end
end
```

## UI

`app/views/drafts/index.html.slim`:

- List ordered by `COALESCE(sent_at, updated_at) DESC`.
- Filter tabs / scope param: **All / In progress / Sent / Failed**.
  - Failed = `status = 'idle' AND last_send_error IS NOT NULL`.
- Pagination: use Kaminari if already in the Gemfile; otherwise `limit/offset`
  is acceptable for v1 (defer pagination polish).
- Per row:
  - State badge.
  - Subject.
  - Recipient (`sent_to_address` if sent; else resolve from identity/topic).
  - Sender alias.
  - Target topic link.
  - Timestamp (`sent_at` when sent, else `updated_at`).
  - Action by state:
    - `idle` no error → Resume → `edit`
    - `idle` with error → Retry → `edit`, show error inline
    - `sending` → no action
    - `sent` → View → `show`

`app/views/drafts/show.html.slim`:

- Read-only render: subject, body, recipient, sent_at, sender alias.
- Link to the resulting `Message` inside its topic
  (`topic_path(@draft.topic, anchor: "msg-#{@draft.sent_message_id}")` or
  whatever pattern the topic view uses).
- No edit/delete buttons.

Nav: add "My emails" link to the user dropdown / sidebar. Locate the current
user menu partial (likely under `app/views/layouts/`) and add a link to
`drafts_path`.

## Edge cases

- **Hard-deleted parent message / topic.** Existing `belongs_to` is non-nullable
  in the schema. Confirm during implementation whether messages or topics are
  ever hard-deleted; if so, either soft-delete those or relax draft FKs to
  nullable. Out of scope unless it actually breaks.
- **Removed identity / alias.** Same concern as today for idle drafts; out of
  scope.
- **Concurrent send.** Job already guards on `draft.sending?` (job line 8).
  Sent drafts are rejected by the controller before they can be re-enqueued.
- **In-flight drafts at deploy.** Migration adds nullable columns; running jobs
  are unaffected; subsequent sends use the new branch.

## Testing

- `spec/jobs/send_outgoing_message_job_spec.rb` — successful send: draft NOT
  destroyed, `status == sent`, `sent_message_id` set, `sent_at` set,
  `last_send_error` cleared. Failure paths remain unchanged.
- `spec/models/outgoing_draft_spec.rb` — `STATUS_SENT`, `sent` scope,
  `readonly?` after sent, association to `sent_message`.
- Request specs for `DraftsController#index`, `#show`, and rejection of mutating
  actions on a sent draft.
- System / feature spec — compose → send → appears under Sent → show page
  renders and links to the message in its topic.
- Schema/index check — partial unique index permits a second active draft to
  the same parent once the first is sent.

## Migration

```ruby
class AddSentStateToOutgoingDrafts < ActiveRecord::Migration[8.0]
  def up
    add_reference :outgoing_drafts, :sent_message,
      foreign_key: { to_table: :messages }, null: true
    add_column :outgoing_drafts, :sent_at, :datetime, null: true

    remove_index :outgoing_drafts, name: :idx_drafts_user_parent_unique
    add_index :outgoing_drafts, [:user_id, :reply_to_message_id],
      unique: true,
      where: "status IN ('idle','sending')",
      name: :idx_drafts_user_parent_active_unique
  end

  def down
    remove_index :outgoing_drafts, name: :idx_drafts_user_parent_active_unique
    add_index :outgoing_drafts, [:user_id, :reply_to_message_id],
      unique: true, name: :idx_drafts_user_parent_unique
    remove_column :outgoing_drafts, :sent_at
    remove_reference :outgoing_drafts, :sent_message,
      foreign_key: { to_table: :messages }
  end
end
```

No backfill: historic sent drafts were destroyed and cannot be recovered.
