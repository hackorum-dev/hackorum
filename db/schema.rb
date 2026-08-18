# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_08_18_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_stat_statements"
  enable_extension "pg_trgm"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "contributor_type", ["core_team", "committer", "major_contributor", "significant_contributor", "past_major_contributor", "past_significant_contributor"]
  create_enum "saved_search_scope", ["global", "user", "team"]
  create_enum "team_member_role", ["member", "admin"]
  create_enum "team_visibility", ["private", "visible", "open"]
  create_enum "user_mention_restriction", ["anyone", "teammates_only"]

  create_table "activities", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "activity_type", null: false
    t.string "subject_type", null: false
    t.bigint "subject_id", null: false
    t.jsonb "payload"
    t.datetime "read_at"
    t.boolean "hidden", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_type", "subject_id"], name: "index_activities_on_subject_type_and_subject_id"
    t.index ["user_id", "id"], name: "index_activities_on_user_id_and_id"
    t.index ["user_id", "read_at"], name: "index_activities_on_user_id_and_read_at"
    t.index ["user_id"], name: "index_activities_on_user_id"
  end

  create_table "admin_email_changes", force: :cascade do |t|
    t.bigint "performed_by_id", null: false
    t.bigint "target_user_id", null: false
    t.string "email", null: false
    t.integer "aliases_attached", default: 0, null: false
    t.boolean "created_new_alias", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["performed_by_id"], name: "index_admin_email_changes_on_performed_by_id"
    t.index ["target_user_id"], name: "index_admin_email_changes_on_target_user_id"
  end

  create_table "aliases", force: :cascade do |t|
    t.bigint "user_id"
    t.string "name", null: false
    t.string "email", null: false
    t.boolean "primary_alias", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.bigint "person_id", null: false
    t.integer "sender_count", default: 0, null: false
    t.index "lower(TRIM(BOTH FROM email))", name: "index_aliases_on_lower_trim_email"
    t.index ["name", "email"], name: "index_aliases_on_name_and_email", unique: true
    t.index ["person_id"], name: "index_aliases_on_person_id"
    t.index ["sender_count"], name: "index_aliases_on_sender_count"
    t.index ["user_id"], name: "index_aliases_on_user_id"
  end

  create_table "attachments", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.string "file_name", null: false
    t.string "content_type"
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_attachments_on_message_id"
  end

  create_table "commit_files", force: :cascade do |t|
    t.bigint "commit_id", null: false
    t.string "path", null: false
    t.index ["commit_id", "path"], name: "index_commit_files_on_commit_id_and_path", unique: true
    t.index ["path"], name: "index_commit_files_on_path"
  end

  create_table "commit_people", force: :cascade do |t|
    t.bigint "commit_id", null: false
    t.string "role", null: false
    t.string "raw_name"
    t.string "raw_email"
    t.bigint "person_id"
    t.index ["commit_id", "role"], name: "index_commit_people_on_commit_id_and_role"
    t.index ["person_id"], name: "index_commit_people_on_person_id"
  end

  create_table "commit_topics", force: :cascade do |t|
    t.bigint "commit_id", null: false
    t.bigint "topic_id", null: false
    t.string "external_message_id"
    t.index ["commit_id", "topic_id"], name: "index_commit_topics_on_commit_id_and_topic_id", unique: true
    t.index ["topic_id"], name: "index_commit_topics_on_topic_id"
  end

  create_table "commitfest_patch_commitfests", force: :cascade do |t|
    t.bigint "commitfest_id", null: false
    t.bigint "commitfest_patch_id", null: false
    t.string "status", null: false
    t.string "ci_status"
    t.integer "ci_score"
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["commitfest_id", "commitfest_patch_id"], name: "index_cf_patch_commitfests_unique", unique: true
    t.index ["commitfest_id"], name: "index_commitfest_patch_commitfests_on_commitfest_id"
    t.index ["commitfest_patch_id"], name: "index_commitfest_patch_commitfests_on_commitfest_patch_id"
  end

  create_table "commitfest_patch_messages", force: :cascade do |t|
    t.bigint "commitfest_patch_id", null: false
    t.string "message_id", null: false
    t.bigint "message_record_id"
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["commitfest_patch_id", "message_id"], name: "index_cf_patch_messages_unique", unique: true
    t.index ["commitfest_patch_id"], name: "index_commitfest_patch_messages_on_commitfest_patch_id"
    t.index ["message_record_id"], name: "index_commitfest_patch_messages_on_message_record_id"
  end

  create_table "commitfest_patch_tags", force: :cascade do |t|
    t.bigint "commitfest_patch_id", null: false
    t.bigint "commitfest_tag_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["commitfest_patch_id", "commitfest_tag_id"], name: "index_cf_patch_tags_unique", unique: true
    t.index ["commitfest_patch_id"], name: "index_commitfest_patch_tags_on_commitfest_patch_id"
    t.index ["commitfest_tag_id"], name: "index_commitfest_patch_tags_on_commitfest_tag_id"
  end

  create_table "commitfest_patch_topics", force: :cascade do |t|
    t.bigint "commitfest_patch_id", null: false
    t.bigint "topic_id", null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["commitfest_patch_id", "topic_id"], name: "index_cf_patch_topics_unique", unique: true
    t.index ["commitfest_patch_id"], name: "index_commitfest_patch_topics_on_commitfest_patch_id"
    t.index ["topic_id"], name: "index_commitfest_patch_topics_on_topic_id"
  end

  create_table "commitfest_patches", force: :cascade do |t|
    t.integer "external_id", null: false
    t.string "title", null: false
    t.string "topic"
    t.string "target_version"
    t.string "wikilink"
    t.string "gitlink"
    t.text "reviewers"
    t.string "committer"
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_commitfest_patches_on_external_id", unique: true
  end

  create_table "commitfest_tags", force: :cascade do |t|
    t.string "name", null: false
    t.string "color"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_commitfest_tags_on_name", unique: true
  end

  create_table "commitfests", force: :cascade do |t|
    t.integer "external_id", null: false
    t.string "name", null: false
    t.string "status", null: false
    t.date "start_date", null: false
    t.date "end_date", null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_commitfests_on_external_id", unique: true
  end

  create_table "commits", force: :cascade do |t|
    t.string "sha", null: false
    t.string "subject", null: false
    t.text "body"
    t.datetime "authored_at", null: false
    t.datetime "committed_at", null: false
    t.string "author_name"
    t.string "author_email"
    t.string "committer_name"
    t.string "committer_email"
    t.string "branches", default: [], null: false, array: true
    t.string "released_in"
    t.datetime "released_at"
    t.string "cherry_picked_from_sha"
    t.string "unresolved_message_ids", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cherry_picked_from_sha"], name: "index_commits_on_cherry_picked_from_sha"
    t.index ["committed_at"], name: "index_commits_on_committed_at"
    t.index ["committed_at"], name: "index_commits_pending_message_ids", where: "(cardinality(unresolved_message_ids) > 0)"
    t.index ["released_in"], name: "index_commits_on_released_in"
    t.index ["sha"], name: "index_commits_on_sha", unique: true
    t.index ["subject", "author_email", "committed_at", "id"], name: "index_commits_on_subject_and_author_email"
  end

  create_table "contributor_memberships", force: :cascade do |t|
    t.bigint "person_id"
    t.enum "contributor_type", null: false, enum_type: "contributor_type"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.string "email"
    t.string "company"
    t.index ["contributor_type"], name: "index_contributor_memberships_on_contributor_type"
    t.index ["person_id", "contributor_type"], name: "index_contributor_memberships_unique", unique: true
    t.index ["person_id"], name: "index_contributor_memberships_on_person_id"
  end

  create_table "identities", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.string "email"
    t.text "raw_info"
    t.datetime "last_used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "refresh_token"
    t.text "access_token"
    t.datetime "access_token_expires_at"
    t.text "scopes"
    t.datetime "send_authorized_at"
    t.datetime "send_revoked_at"
    t.text "last_send_error"
    t.index "lower(TRIM(BOTH FROM email))", name: "index_identities_on_lower_trim_email"
    t.index ["provider", "uid"], name: "index_identities_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "imap_sync_states", force: :cascade do |t|
    t.string "mailbox_label", default: "INBOX", null: false
    t.bigint "last_uid", default: 0, null: false
    t.datetime "last_checked_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_cycle_started_at"
    t.integer "last_cycle_duration_ms"
    t.integer "last_fetched_count"
    t.integer "last_ingested_count"
    t.integer "last_duplicate_count"
    t.integer "last_attachment_count"
    t.integer "last_backlog_count"
    t.integer "consecutive_error_count", default: 0, null: false
    t.string "last_error_class"
    t.integer "backoff_seconds"
    t.index ["mailbox_label"], name: "index_imap_sync_states_on_mailbox_label", unique: true
  end

  create_table "mailing_lists", force: :cascade do |t|
    t.string "identifier", null: false
    t.string "display_name", null: false
    t.string "email"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "alternate_emails", default: [], array: true
    t.string "post_address"
    t.index ["email"], name: "index_mailing_lists_on_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["identifier"], name: "index_mailing_lists_on_identifier", unique: true
  end

  create_table "mentions", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "alias_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "person_id", null: false
    t.index ["alias_id"], name: "index_mentions_on_alias_id"
    t.index ["message_id"], name: "index_mentions_on_message_id"
    t.index ["person_id"], name: "index_mentions_on_person_id"
  end

  create_table "message_mailing_lists", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "mailing_list_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mailing_list_id"], name: "index_message_mailing_lists_on_mailing_list_id"
    t.index ["message_id", "mailing_list_id"], name: "idx_message_mailing_lists_unique", unique: true
    t.index ["message_id"], name: "index_message_mailing_lists_on_message_id"
  end

  create_table "message_moves", force: :cascade do |t|
    t.bigint "topic_merge_id", null: false
    t.bigint "message_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_message_moves_on_message_id"
    t.index ["topic_merge_id", "message_id"], name: "index_message_moves_on_topic_merge_id_and_message_id", unique: true
    t.index ["topic_merge_id"], name: "index_message_moves_on_topic_merge_id"
  end

  create_table "message_read_ranges", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "topic_id", null: false
    t.bigint "range_start_message_id", null: false
    t.bigint "range_end_message_id", null: false
    t.datetime "read_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "message_count", default: 0, null: false
    t.index ["topic_id"], name: "index_message_read_ranges_on_topic_id"
    t.index ["user_id", "topic_id", "range_end_message_id"], name: "index_message_read_ranges_on_user_topic_range_end_desc", order: { range_end_message_id: :desc }
    t.index ["user_id", "topic_id", "range_start_message_id", "range_end_message_id"], name: "index_message_read_ranges_on_user_topic_range"
    t.index ["user_id"], name: "index_message_read_ranges_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "topic_id", null: false
    t.bigint "sender_id", null: false
    t.bigint "reply_to_id"
    t.string "subject", null: false
    t.string "message_id"
    t.text "body", null: false
    t.text "import_log"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "sender_person_id", null: false
    t.string "reply_to_message_id"
    t.virtual "body_tsv", type: :tsvector, as: "to_tsvector('english'::regconfig, COALESCE(body, ''::text))", stored: true
    t.string "state", default: "sent", null: false
    t.datetime "sent_at"
    t.bigint "sent_via_identity_id"
    t.string "sent_to_address"
    t.boolean "is_patch_submission", default: false, null: false
    t.index ["body"], name: "index_messages_on_body_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["body_tsv"], name: "index_messages_on_body_tsv", using: :gin
    t.index ["created_at", "sender_id"], name: "index_messages_on_created_at_and_sender_id"
    t.index ["created_at", "topic_id"], name: "index_messages_on_created_at_and_topic_id"
    t.index ["created_at"], name: "index_messages_on_created_at"
    t.index ["is_patch_submission"], name: "index_messages_on_is_patch_submission", where: "(is_patch_submission = true)"
    t.index ["message_id"], name: "index_messages_on_message_id", unique: true
    t.index ["reply_to_id"], name: "index_messages_on_reply_to_id"
    t.index ["sender_id"], name: "index_messages_on_sender_id"
    t.index ["sender_person_id"], name: "index_messages_on_sender_person_id"
    t.index ["state"], name: "index_messages_on_state"
    t.index ["topic_id", "created_at", "id"], name: "index_messages_on_topic_id_and_created_at_desc_id_desc", order: { created_at: :desc, id: :desc }
    t.index ["topic_id", "created_at", "id"], name: "index_messages_patch_submission_latest", order: { created_at: :desc, id: :desc }, where: "(is_patch_submission = true)"
    t.index ["topic_id"], name: "index_messages_on_topic_id"
  end

  create_table "name_reservations", force: :cascade do |t|
    t.string "name", null: false
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_name_reservations_on_name", unique: true
    t.index ["owner_type", "owner_id"], name: "index_name_reservations_on_owner_type_and_owner_id"
  end

  create_table "note_edits", force: :cascade do |t|
    t.bigint "note_id", null: false
    t.bigint "editor_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["editor_id"], name: "index_note_edits_on_editor_id"
    t.index ["note_id"], name: "index_note_edits_on_note_id"
  end

  create_table "note_mentions", force: :cascade do |t|
    t.bigint "note_id", null: false
    t.string "mentionable_type", null: false
    t.bigint "mentionable_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mentionable_type", "mentionable_id"], name: "index_note_mentions_on_mentionable_type_and_mentionable_id"
    t.index ["note_id", "mentionable_type", "mentionable_id"], name: "index_note_mentions_unique", unique: true
    t.index ["note_id"], name: "index_note_mentions_on_note_id"
  end

  create_table "note_tags", force: :cascade do |t|
    t.bigint "note_id", null: false
    t.string "tag", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["note_id", "tag"], name: "index_note_tags_on_note_id_and_tag", unique: true
    t.index ["note_id"], name: "index_note_tags_on_note_id"
    t.index ["tag"], name: "index_note_tags_on_tag"
  end

  create_table "notes", force: :cascade do |t|
    t.bigint "topic_id", null: false
    t.bigint "message_id"
    t.bigint "author_id", null: false
    t.bigint "last_editor_id"
    t.text "body", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_notes_on_author_id"
    t.index ["last_editor_id"], name: "index_notes_on_last_editor_id"
    t.index ["message_id"], name: "index_notes_on_message_id"
    t.index ["topic_id"], name: "index_notes_on_topic_id"
  end

  create_table "outgoing_drafts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "topic_id", null: false
    t.bigint "reply_to_message_id", null: false
    t.bigint "sender_alias_id", null: false
    t.bigint "identity_id", null: false
    t.string "subject", null: false
    t.text "body", default: "", null: false
    t.string "status", default: "idle", null: false
    t.text "last_send_error"
    t.datetime "sending_started_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "sent_message_id"
    t.datetime "sent_at"
    t.index ["identity_id"], name: "index_outgoing_drafts_on_identity_id"
    t.index ["reply_to_message_id"], name: "index_outgoing_drafts_on_reply_to_message_id"
    t.index ["sender_alias_id"], name: "index_outgoing_drafts_on_sender_alias_id"
    t.index ["sent_message_id"], name: "index_outgoing_drafts_on_sent_message_id"
    t.index ["topic_id"], name: "index_outgoing_drafts_on_topic_id"
    t.index ["user_id", "reply_to_message_id"], name: "idx_drafts_user_parent_active_unique", unique: true, where: "((status)::text = ANY (ARRAY[('idle'::character varying)::text, ('sending'::character varying)::text]))"
    t.index ["user_id"], name: "index_outgoing_drafts_on_user_id"
  end

  create_table "page_load_stats", force: :cascade do |t|
    t.string "url", null: false
    t.string "controller", null: false
    t.string "action", null: false
    t.float "render_time", null: false
    t.boolean "is_turbo", default: false, null: false
    t.datetime "created_at", null: false
    t.index ["controller", "action"], name: "index_page_load_stats_on_controller_and_action"
    t.index ["created_at"], name: "index_page_load_stats_on_created_at"
  end

  create_table "patch_branches", force: :cascade do |t|
    t.bigint "topic_id", null: false
    t.bigint "message_id", null: false
    t.string "branch_name", null: false
    t.string "base_sha"
    t.boolean "on_master", default: false, null: false
    t.string "status", null: false
    t.string "failure_stage"
    t.text "failure_reason"
    t.string "conflict_files", default: [], null: false, array: true
    t.string "patch_content_hash"
    t.datetime "attempted_at"
    t.datetime "pushed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "base_source"
    t.string "pushed_head_sha"
    t.bigint "latest_ci_run_id"
    t.string "ci_status"
    t.string "ci_skip_reason"
    t.datetime "base_committed_at"
    t.integer "base_commit_height"
    t.bigint "superseded_by_id"
    t.datetime "last_master_apply_at"
    t.text "master_apply_error"
    t.integer "pg_major"
    t.string "master_apply_sha"
    t.string "master_conflict_files", default: [], null: false, array: true
    t.index ["attempted_at"], name: "index_patch_branches_on_attempted_at", order: :desc
    t.index ["branch_name"], name: "index_patch_branches_on_branch_name", unique: true
    t.index ["ci_status"], name: "index_patch_branches_on_ci_status"
    t.index ["latest_ci_run_id"], name: "index_patch_branches_on_latest_ci_run_id"
    t.index ["message_id"], name: "index_patch_branches_on_message_id", unique: true
    t.index ["pg_major"], name: "index_patch_branches_on_pg_major"
    t.index ["status", "failure_stage"], name: "index_patch_branches_on_status_and_failure_stage"
    t.index ["superseded_by_id"], name: "index_patch_branches_on_superseded_by_id"
    t.index ["topic_id"], name: "index_patch_branches_current_topic", where: "(superseded_by_id IS NULL)"
    t.index ["topic_id"], name: "index_patch_branches_on_topic_id"
    t.index ["updated_at", "id"], name: "index_patch_branches_on_updated_at_and_id", order: :desc
  end

  create_table "patch_ci_repo_states", force: :cascade do |t|
    t.string "master_sha", null: false
    t.datetime "master_committed_at", null: false
    t.integer "master_commit_height", null: false
    t.datetime "fetched_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "patch_ci_runs", force: :cascade do |t|
    t.bigint "patch_branch_id", null: false
    t.bigint "github_run_id", null: false
    t.integer "run_attempt", default: 1, null: false
    t.string "head_sha"
    t.integer "pg_major"
    t.string "status", null: false
    t.string "conclusion"
    t.datetime "queued_at"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.integer "build_seconds"
    t.integer "test_seconds"
    t.string "failed_tests", default: [], null: false, array: true
    t.string "image_ref"
    t.string "image_digest"
    t.jsonb "payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "tests_total"
    t.index ["completed_at"], name: "index_patch_ci_runs_on_completed_at", order: :desc
    t.index ["created_at", "id"], name: "index_patch_ci_runs_on_created_at_and_id", order: :desc
    t.index ["github_run_id", "run_attempt"], name: "index_patch_ci_runs_on_github_run_id_and_run_attempt", unique: true
    t.index ["patch_branch_id"], name: "index_patch_ci_runs_on_patch_branch_id"
  end

  create_table "patch_submission_files", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.string "path", null: false
    t.index ["message_id", "path"], name: "index_patch_submission_files_on_message_id_and_path", unique: true
  end

  create_table "people", force: :cascade do |t|
    t.bigint "default_alias_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["default_alias_id"], name: "index_people_on_default_alias_id"
  end

  create_table "person_merges", force: :cascade do |t|
    t.bigint "performed_by_id", null: false
    t.bigint "source_person_id", null: false
    t.bigint "target_person_id", null: false
    t.string "source_name"
    t.string "target_name"
    t.string "source_emails", default: [], null: false, array: true
    t.integer "aliases_moved", default: 0, null: false
    t.integer "topics_moved", default: 0, null: false
    t.integer "messages_moved", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["performed_by_id"], name: "index_person_merges_on_performed_by_id"
    t.index ["target_person_id"], name: "index_person_merges_on_target_person_id"
  end

  create_table "release_tags", force: :cascade do |t|
    t.string "name", null: false
    t.string "version"
    t.datetime "released_at"
    t.string "commit_sha"
    t.index ["name"], name: "index_release_tags_on_name", unique: true
  end

  create_table "saved_search_preferences", force: :cascade do |t|
    t.bigint "saved_search_id", null: false
    t.bigint "user_id", null: false
    t.boolean "hidden", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["saved_search_id", "user_id"], name: "idx_saved_search_prefs_unique", unique: true
    t.index ["saved_search_id"], name: "index_saved_search_preferences_on_saved_search_id"
    t.index ["user_id"], name: "index_saved_search_preferences_on_user_id"
  end

  create_table "saved_searches", force: :cascade do |t|
    t.string "name", null: false
    t.text "query", null: false
    t.enum "scope", default: "global", null: false, enum_type: "saved_search_scope"
    t.bigint "user_id"
    t.bigint "team_id"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["scope", "user_id", "team_id", "name"], name: "idx_saved_searches_unique_name", unique: true
    t.index ["team_id"], name: "index_saved_searches_on_team_id"
    t.index ["user_id"], name: "index_saved_searches_on_user_id"
    t.check_constraint "NOT (user_id IS NOT NULL AND team_id IS NOT NULL)", name: "chk_saved_searches_single_owner"
  end

  create_table "stats_daily", force: :cascade do |t|
    t.date "interval_start", null: false
    t.date "interval_end", null: false
    t.integer "participants_active", default: 0, null: false
    t.integer "participants_active_committers", default: 0, null: false
    t.integer "participants_active_contributors", default: 0, null: false
    t.integer "participants_new", default: 0, null: false
    t.float "new_participants_lifetime_avg_days", default: 0.0, null: false
    t.float "new_participants_lifetime_median_days", default: 0.0, null: false
    t.float "new_participants_lifetime_max_days", default: 0.0, null: false
    t.float "new_participants_daily_avg_messages", default: 0.0, null: false
    t.integer "retained_365_participants", default: 0, null: false
    t.float "retained_365_lifetime_avg_days", default: 0.0, null: false
    t.float "retained_365_lifetime_median_days", default: 0.0, null: false
    t.float "retained_365_daily_avg_messages", default: 0.0, null: false
    t.integer "topics_new", default: 0, null: false
    t.integer "topics_active", default: 0, null: false
    t.integer "topics_new_by_new_participants", default: 0, null: false
    t.integer "topics_new_by_new_users", default: 0, null: false
    t.integer "topics_new_with_attachments_by_new_users", default: 0, null: false
    t.integer "topics_new_with_contributor_activity", default: 0, null: false
    t.integer "topics_new_without_contributor_activity", default: 0, null: false
    t.integer "topics_new_no_attachments", default: 0, null: false
    t.integer "topics_new_with_attachments_no_commitfest", default: 0, null: false
    t.integer "topics_new_commitfest_abandoned", default: 0, null: false
    t.integer "topics_new_commitfest_committed", default: 0, null: false
    t.integer "topics_new_commitfest_in_progress", default: 0, null: false
    t.integer "messages_total", default: 0, null: false
    t.integer "messages_committers", default: 0, null: false
    t.integer "messages_contributors", default: 0, null: false
    t.integer "messages_new_participants", default: 0, null: false
    t.integer "new_users_replied_to_others", default: 0, null: false
    t.float "topics_messages_avg", default: 0.0, null: false
    t.float "topics_messages_median", default: 0.0, null: false
    t.integer "topics_messages_max", default: 0, null: false
    t.float "topics_created_messages_avg", default: 0.0, null: false
    t.float "topics_created_messages_median", default: 0.0, null: false
    t.integer "topics_created_messages_max", default: 0, null: false
    t.float "topic_longevity_avg_days", default: 0.0, null: false
    t.float "topic_longevity_median_days", default: 0.0, null: false
    t.integer "topic_longevity_max_days", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["interval_start"], name: "index_stats_daily_on_interval_start", unique: true
  end

  create_table "stats_longevity_daily", force: :cascade do |t|
    t.date "interval_start", null: false
    t.date "interval_end", null: false
    t.string "bucket", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["interval_start", "bucket"], name: "index_stats_longevity_daily_on_interval_bucket", unique: true
  end

  create_table "stats_longevity_monthly", force: :cascade do |t|
    t.date "interval_start", null: false
    t.date "interval_end", null: false
    t.string "bucket", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["interval_start", "bucket"], name: "index_stats_longevity_monthly_on_interval_bucket", unique: true
  end

  create_table "stats_longevity_weekly", force: :cascade do |t|
    t.date "interval_start", null: false
    t.date "interval_end", null: false
    t.string "bucket", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["interval_start", "bucket"], name: "index_stats_longevity_weekly_on_interval_bucket", unique: true
  end

  create_table "stats_monthly", force: :cascade do |t|
    t.date "interval_start", null: false
    t.date "interval_end", null: false
    t.integer "participants_active", default: 0, null: false
    t.integer "participants_active_committers", default: 0, null: false
    t.integer "participants_active_contributors", default: 0, null: false
    t.integer "participants_new", default: 0, null: false
    t.float "new_participants_lifetime_avg_days", default: 0.0, null: false
    t.float "new_participants_lifetime_median_days", default: 0.0, null: false
    t.float "new_participants_lifetime_max_days", default: 0.0, null: false
    t.float "new_participants_daily_avg_messages", default: 0.0, null: false
    t.integer "retained_365_participants", default: 0, null: false
    t.float "retained_365_lifetime_avg_days", default: 0.0, null: false
    t.float "retained_365_lifetime_median_days", default: 0.0, null: false
    t.float "retained_365_daily_avg_messages", default: 0.0, null: false
    t.integer "topics_new", default: 0, null: false
    t.integer "topics_active", default: 0, null: false
    t.integer "topics_new_by_new_participants", default: 0, null: false
    t.integer "topics_new_by_new_users", default: 0, null: false
    t.integer "topics_new_with_attachments_by_new_users", default: 0, null: false
    t.integer "topics_new_with_contributor_activity", default: 0, null: false
    t.integer "topics_new_without_contributor_activity", default: 0, null: false
    t.integer "topics_new_no_attachments", default: 0, null: false
    t.integer "topics_new_with_attachments_no_commitfest", default: 0, null: false
    t.integer "topics_new_commitfest_abandoned", default: 0, null: false
    t.integer "topics_new_commitfest_committed", default: 0, null: false
    t.integer "topics_new_commitfest_in_progress", default: 0, null: false
    t.integer "messages_total", default: 0, null: false
    t.integer "messages_committers", default: 0, null: false
    t.integer "messages_contributors", default: 0, null: false
    t.integer "messages_new_participants", default: 0, null: false
    t.integer "new_users_replied_to_others", default: 0, null: false
    t.float "topics_messages_avg", default: 0.0, null: false
    t.float "topics_messages_median", default: 0.0, null: false
    t.integer "topics_messages_max", default: 0, null: false
    t.float "topics_created_messages_avg", default: 0.0, null: false
    t.float "topics_created_messages_median", default: 0.0, null: false
    t.integer "topics_created_messages_max", default: 0, null: false
    t.float "topic_longevity_avg_days", default: 0.0, null: false
    t.float "topic_longevity_median_days", default: 0.0, null: false
    t.integer "topic_longevity_max_days", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["interval_start"], name: "index_stats_monthly_on_interval_start", unique: true
  end

  create_table "stats_retention_milestones", force: :cascade do |t|
    t.date "cohort_start", null: false
    t.integer "horizon_months", null: false
    t.integer "period_months", default: 1, null: false
    t.string "segment", default: "all", null: false
    t.integer "cohort_size", default: 0, null: false
    t.integer "retained_users", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["period_months", "segment", "cohort_start", "horizon_months"], name: "index_stats_retention_milestones_on_period_segment_horizon", unique: true
  end

  create_table "stats_retention_monthly", force: :cascade do |t|
    t.date "cohort_start", null: false
    t.integer "months_since", null: false
    t.integer "period_months", default: 1, null: false
    t.string "segment", default: "all", null: false
    t.integer "cohort_size", default: 0, null: false
    t.integer "active_users", default: 0, null: false
    t.float "avg_messages_per_active_user", default: 0.0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["period_months", "segment", "cohort_start", "months_since"], name: "idx_on_period_months_segment_cohort_start_months_si_781b1e55b4", unique: true
  end

  create_table "stats_weekly", force: :cascade do |t|
    t.date "interval_start", null: false
    t.date "interval_end", null: false
    t.integer "participants_active", default: 0, null: false
    t.integer "participants_active_committers", default: 0, null: false
    t.integer "participants_active_contributors", default: 0, null: false
    t.integer "participants_new", default: 0, null: false
    t.float "new_participants_lifetime_avg_days", default: 0.0, null: false
    t.float "new_participants_lifetime_median_days", default: 0.0, null: false
    t.float "new_participants_lifetime_max_days", default: 0.0, null: false
    t.float "new_participants_daily_avg_messages", default: 0.0, null: false
    t.integer "retained_365_participants", default: 0, null: false
    t.float "retained_365_lifetime_avg_days", default: 0.0, null: false
    t.float "retained_365_lifetime_median_days", default: 0.0, null: false
    t.float "retained_365_daily_avg_messages", default: 0.0, null: false
    t.integer "topics_new", default: 0, null: false
    t.integer "topics_active", default: 0, null: false
    t.integer "topics_new_by_new_participants", default: 0, null: false
    t.integer "topics_new_by_new_users", default: 0, null: false
    t.integer "topics_new_with_attachments_by_new_users", default: 0, null: false
    t.integer "topics_new_with_contributor_activity", default: 0, null: false
    t.integer "topics_new_without_contributor_activity", default: 0, null: false
    t.integer "topics_new_no_attachments", default: 0, null: false
    t.integer "topics_new_with_attachments_no_commitfest", default: 0, null: false
    t.integer "topics_new_commitfest_abandoned", default: 0, null: false
    t.integer "topics_new_commitfest_committed", default: 0, null: false
    t.integer "topics_new_commitfest_in_progress", default: 0, null: false
    t.integer "messages_total", default: 0, null: false
    t.integer "messages_committers", default: 0, null: false
    t.integer "messages_contributors", default: 0, null: false
    t.integer "messages_new_participants", default: 0, null: false
    t.integer "new_users_replied_to_others", default: 0, null: false
    t.float "topics_messages_avg", default: 0.0, null: false
    t.float "topics_messages_median", default: 0.0, null: false
    t.integer "topics_messages_max", default: 0, null: false
    t.float "topics_created_messages_avg", default: 0.0, null: false
    t.float "topics_created_messages_median", default: 0.0, null: false
    t.integer "topics_created_messages_max", default: 0, null: false
    t.float "topic_longevity_avg_days", default: 0.0, null: false
    t.float "topic_longevity_median_days", default: 0.0, null: false
    t.integer "topic_longevity_max_days", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["interval_start"], name: "index_stats_weekly_on_interval_start", unique: true
  end

  create_table "team_members", force: :cascade do |t|
    t.bigint "team_id", null: false
    t.bigint "user_id", null: false
    t.enum "role", default: "member", null: false, enum_type: "team_member_role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["team_id", "user_id"], name: "index_team_members_on_team_id_and_user_id", unique: true
    t.index ["team_id"], name: "index_team_members_on_team_id"
    t.index ["user_id"], name: "index_team_members_on_user_id"
  end

  create_table "teams", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.enum "visibility", default: "private", null: false, enum_type: "team_visibility"
  end

  create_table "thread_awarenesses", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "topic_id", null: false
    t.bigint "aware_until_message_id", null: false
    t.datetime "aware_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["topic_id"], name: "index_thread_awarenesses_on_topic_id"
    t.index ["user_id", "topic_id"], name: "index_thread_awarenesses_on_user_id_and_topic_id", unique: true
    t.index ["user_id"], name: "index_thread_awarenesses_on_user_id"
  end

  create_table "topic_ignores", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "topic_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["topic_id"], name: "index_topic_ignores_on_topic_id"
    t.index ["user_id", "topic_id"], name: "index_topic_ignores_on_user_id_and_topic_id", unique: true
    t.index ["user_id"], name: "index_topic_ignores_on_user_id"
  end

  create_table "topic_mailing_lists", force: :cascade do |t|
    t.bigint "topic_id", null: false
    t.bigint "mailing_list_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mailing_list_id"], name: "index_topic_mailing_lists_on_mailing_list_id"
    t.index ["topic_id", "mailing_list_id"], name: "idx_topic_mailing_lists_unique", unique: true
    t.index ["topic_id"], name: "index_topic_mailing_lists_on_topic_id"
  end

  create_table "topic_merges", force: :cascade do |t|
    t.bigint "source_topic_id", null: false
    t.bigint "target_topic_id", null: false
    t.bigint "merged_by_id"
    t.text "merge_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["merged_by_id"], name: "index_topic_merges_on_merged_by_id"
    t.index ["source_topic_id"], name: "index_topic_merges_on_source_topic_id", unique: true
    t.index ["target_topic_id"], name: "index_topic_merges_on_target_topic_id"
  end

  create_table "topic_participants", force: :cascade do |t|
    t.bigint "topic_id", null: false
    t.bigint "person_id", null: false
    t.integer "message_count", default: 0, null: false
    t.datetime "first_message_at", null: false
    t.datetime "last_message_at", null: false
    t.boolean "is_contributor", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["person_id", "last_message_at"], name: "index_topic_participants_on_person_id_and_last_message_at", order: { last_message_at: :desc }
    t.index ["person_id"], name: "index_topic_participants_on_person_id"
    t.index ["topic_id", "message_count"], name: "index_topic_participants_on_topic_id_and_message_count", order: { message_count: :desc }
    t.index ["topic_id", "person_id"], name: "index_topic_participants_on_topic_id_and_person_id", unique: true
    t.index ["topic_id"], name: "idx_topic_participants_contributors", where: "(is_contributor = true)"
  end

  create_table "topic_stars", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "topic_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["topic_id"], name: "index_topic_stars_on_topic_id"
    t.index ["user_id", "topic_id"], name: "index_topic_stars_on_user_id_and_topic_id", unique: true
    t.index ["user_id"], name: "index_topic_stars_on_user_id"
  end

  create_table "topics", force: :cascade do |t|
    t.string "title", null: false
    t.bigint "creator_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "creator_person_id", null: false
    t.integer "participant_count", default: 0, null: false
    t.integer "contributor_participant_count", default: 0, null: false
    t.enum "highest_contributor_type", enum_type: "contributor_type"
    t.datetime "last_message_at"
    t.bigint "last_sender_person_id"
    t.integer "message_count", default: 0, null: false
    t.boolean "has_attachments", default: false, null: false
    t.bigint "last_message_id"
    t.bigint "merged_into_topic_id"
    t.virtual "title_tsv", type: :tsvector, as: "to_tsvector('english'::regconfig, (COALESCE(title, ''::character varying))::text)", stored: true
    t.integer "commit_count", default: 0, null: false
    t.datetime "last_commit_at"
    t.index ["created_at"], name: "index_topics_on_created_at"
    t.index ["creator_id"], name: "index_topics_on_creator_id"
    t.index ["creator_person_id"], name: "index_topics_on_creator_person_id"
    t.index ["last_message_at"], name: "index_topics_on_last_message_at"
    t.index ["merged_into_topic_id"], name: "index_topics_on_merged_into_topic_id"
    t.index ["title"], name: "index_topics_on_title_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["title_tsv"], name: "index_topics_on_title_tsv", using: :gin
  end

  create_table "user_features", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "feature", null: false
    t.datetime "created_at", null: false
    t.index ["user_id", "feature"], name: "index_user_features_on_user_id_and_feature", unique: true
    t.index ["user_id"], name: "index_user_features_on_user_id"
  end

  create_table "user_tokens", force: :cascade do |t|
    t.bigint "user_id"
    t.string "email"
    t.string "purpose", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower(TRIM(BOTH FROM email))", name: "index_user_tokens_on_lower_trim_email"
    t.index ["consumed_at"], name: "index_user_tokens_on_consumed_at"
    t.index ["purpose"], name: "index_user_tokens_on_purpose"
    t.index ["token_digest"], name: "index_user_tokens_on_token_digest"
    t.index ["user_id"], name: "index_user_tokens_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "aware_before"
    t.string "username"
    t.string "password_digest"
    t.boolean "admin", default: false, null: false
    t.datetime "deleted_at"
    t.bigint "person_id", null: false
    t.enum "mention_restriction", default: "anyone", null: false, enum_type: "user_mention_restriction"
    t.boolean "open_threads_at_first_unread", default: false, null: false
    t.datetime "last_login_at"
    t.boolean "collapse_read_messages", default: true, null: false
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["person_id"], name: "index_users_on_person_id"
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  add_foreign_key "activities", "users"
  add_foreign_key "admin_email_changes", "users", column: "performed_by_id"
  add_foreign_key "admin_email_changes", "users", column: "target_user_id"
  add_foreign_key "aliases", "people"
  add_foreign_key "aliases", "users", validate: false
  add_foreign_key "attachments", "messages"
  add_foreign_key "commit_files", "commits"
  add_foreign_key "commit_people", "commits"
  add_foreign_key "commit_people", "people"
  add_foreign_key "commit_topics", "commits"
  add_foreign_key "commit_topics", "topics"
  add_foreign_key "commitfest_patch_commitfests", "commitfest_patches"
  add_foreign_key "commitfest_patch_commitfests", "commitfests"
  add_foreign_key "commitfest_patch_messages", "commitfest_patches"
  add_foreign_key "commitfest_patch_messages", "messages", column: "message_record_id"
  add_foreign_key "commitfest_patch_tags", "commitfest_patches"
  add_foreign_key "commitfest_patch_tags", "commitfest_tags"
  add_foreign_key "commitfest_patch_topics", "commitfest_patches"
  add_foreign_key "commitfest_patch_topics", "topics"
  add_foreign_key "contributor_memberships", "people"
  add_foreign_key "identities", "users"
  add_foreign_key "mentions", "aliases"
  add_foreign_key "mentions", "messages"
  add_foreign_key "mentions", "people"
  add_foreign_key "message_mailing_lists", "mailing_lists"
  add_foreign_key "message_mailing_lists", "messages"
  add_foreign_key "message_moves", "messages"
  add_foreign_key "message_moves", "topic_merges"
  add_foreign_key "message_read_ranges", "topics"
  add_foreign_key "message_read_ranges", "users"
  add_foreign_key "messages", "aliases", column: "sender_id"
  add_foreign_key "messages", "identities", column: "sent_via_identity_id", validate: false
  add_foreign_key "messages", "messages", column: "reply_to_id"
  add_foreign_key "messages", "people", column: "sender_person_id"
  add_foreign_key "messages", "topics"
  add_foreign_key "note_edits", "notes"
  add_foreign_key "note_edits", "users", column: "editor_id"
  add_foreign_key "note_mentions", "notes"
  add_foreign_key "note_tags", "notes"
  add_foreign_key "notes", "messages"
  add_foreign_key "notes", "topics"
  add_foreign_key "notes", "users", column: "author_id"
  add_foreign_key "notes", "users", column: "last_editor_id"
  add_foreign_key "outgoing_drafts", "aliases", column: "sender_alias_id"
  add_foreign_key "outgoing_drafts", "identities"
  add_foreign_key "outgoing_drafts", "messages", column: "reply_to_message_id"
  add_foreign_key "outgoing_drafts", "messages", column: "sent_message_id"
  add_foreign_key "outgoing_drafts", "topics"
  add_foreign_key "outgoing_drafts", "users"
  add_foreign_key "patch_branches", "messages", on_delete: :cascade
  add_foreign_key "patch_branches", "patch_branches", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "patch_branches", "patch_ci_runs", column: "latest_ci_run_id", on_delete: :nullify
  add_foreign_key "patch_branches", "topics"
  add_foreign_key "patch_ci_runs", "patch_branches", on_delete: :cascade
  add_foreign_key "patch_submission_files", "messages"
  add_foreign_key "people", "aliases", column: "default_alias_id"
  add_foreign_key "person_merges", "users", column: "performed_by_id"
  add_foreign_key "saved_search_preferences", "saved_searches"
  add_foreign_key "saved_search_preferences", "users"
  add_foreign_key "saved_searches", "teams"
  add_foreign_key "saved_searches", "users"
  add_foreign_key "team_members", "teams"
  add_foreign_key "team_members", "users"
  add_foreign_key "thread_awarenesses", "topics"
  add_foreign_key "thread_awarenesses", "users"
  add_foreign_key "topic_ignores", "topics"
  add_foreign_key "topic_ignores", "users"
  add_foreign_key "topic_mailing_lists", "mailing_lists"
  add_foreign_key "topic_mailing_lists", "topics"
  add_foreign_key "topic_merges", "topics", column: "source_topic_id"
  add_foreign_key "topic_merges", "topics", column: "target_topic_id"
  add_foreign_key "topic_merges", "users", column: "merged_by_id"
  add_foreign_key "topic_participants", "people"
  add_foreign_key "topic_participants", "topics"
  add_foreign_key "topic_stars", "topics"
  add_foreign_key "topic_stars", "users"
  add_foreign_key "topics", "aliases", column: "creator_id"
  add_foreign_key "topics", "messages", column: "last_message_id"
  add_foreign_key "topics", "people", column: "creator_person_id"
  add_foreign_key "topics", "people", column: "last_sender_person_id"
  add_foreign_key "topics", "topics", column: "merged_into_topic_id"
  add_foreign_key "user_features", "users", validate: false
  add_foreign_key "user_tokens", "users"
  add_foreign_key "users", "people"
end
