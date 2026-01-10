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

ActiveRecord::Schema[8.0].define(version: 2026_01_10_125815) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_stat_statements"
  enable_extension "pg_trgm"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "contributor_type", ["core_team", "committer", "major_contributor", "significant_contributor", "past_major_contributor", "past_significant_contributor"]
  create_enum "team_member_role", ["member", "admin"]

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

  create_table "aliases", force: :cascade do |t|
    t.bigint "user_id"
    t.string "name", null: false
    t.string "email", null: false
    t.boolean "primary_alias", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.bigint "person_id", null: false
    t.index "lower(TRIM(BOTH FROM email))", name: "index_aliases_on_lower_trim_email"
    t.index ["name", "email"], name: "index_aliases_on_name_and_email", unique: true
    t.index ["person_id"], name: "index_aliases_on_person_id"
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
    t.integer "last_patch_files_count"
    t.integer "last_backlog_count"
    t.integer "consecutive_error_count", default: 0, null: false
    t.string "last_error_class"
    t.integer "backoff_seconds"
    t.index ["mailbox_label"], name: "index_imap_sync_states_on_mailbox_label", unique: true
  end

  create_table "mentions", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "alias_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alias_id"], name: "index_mentions_on_alias_id"
    t.index ["message_id"], name: "index_mentions_on_message_id"
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
    t.index ["body"], name: "index_messages_on_body_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["created_at", "sender_id"], name: "index_messages_on_created_at_and_sender_id"
    t.index ["created_at", "topic_id"], name: "index_messages_on_created_at_and_topic_id"
    t.index ["created_at"], name: "index_messages_on_created_at"
    t.index ["message_id"], name: "index_messages_on_message_id", unique: true
    t.index ["reply_to_id"], name: "index_messages_on_reply_to_id"
    t.index ["sender_id"], name: "index_messages_on_sender_id"
    t.index ["topic_id", "created_at", "id"], name: "index_messages_on_topic_id_and_created_at_desc_id_desc", order: { created_at: :desc, id: :desc }
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

  create_table "patch_files", force: :cascade do |t|
    t.bigint "attachment_id", null: false
    t.string "filename", null: false
    t.string "status"
    t.integer "line_changes"
    t.string "old_filename"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["attachment_id", "filename"], name: "index_patch_files_on_attachment_id_and_filename", unique: true
    t.index ["attachment_id"], name: "index_patch_files_on_attachment_id"
    t.index ["filename"], name: "index_patch_files_on_filename"
  end

  create_table "people", force: :cascade do |t|
    t.bigint "default_alias_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["default_alias_id"], name: "index_people_on_default_alias_id"
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
    t.index ["created_at"], name: "index_topics_on_created_at"
    t.index ["creator_id"], name: "index_topics_on_creator_id"
    t.index ["title"], name: "index_topics_on_title_trgm", opclass: :gin_trgm_ops, using: :gin
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
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["person_id"], name: "index_users_on_person_id"
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  add_foreign_key "activities", "users"
  add_foreign_key "aliases", "people"
  add_foreign_key "aliases", "users"
  add_foreign_key "attachments", "messages"
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
  add_foreign_key "message_read_ranges", "topics"
  add_foreign_key "message_read_ranges", "users"
  add_foreign_key "messages", "aliases", column: "sender_id"
  add_foreign_key "messages", "messages", column: "reply_to_id"
  add_foreign_key "messages", "topics"
  add_foreign_key "note_edits", "notes"
  add_foreign_key "note_edits", "users", column: "editor_id"
  add_foreign_key "note_mentions", "notes"
  add_foreign_key "note_tags", "notes"
  add_foreign_key "notes", "messages"
  add_foreign_key "notes", "topics"
  add_foreign_key "notes", "users", column: "author_id"
  add_foreign_key "notes", "users", column: "last_editor_id"
  add_foreign_key "patch_files", "attachments"
  add_foreign_key "people", "aliases", column: "default_alias_id"
  add_foreign_key "team_members", "teams"
  add_foreign_key "team_members", "users"
  add_foreign_key "thread_awarenesses", "topics"
  add_foreign_key "thread_awarenesses", "users"
  add_foreign_key "topic_stars", "topics"
  add_foreign_key "topic_stars", "users"
  add_foreign_key "topics", "aliases", column: "creator_id"
  add_foreign_key "user_tokens", "users"
  add_foreign_key "users", "people"
end
