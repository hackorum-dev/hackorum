class CreateStatisticsTables < ActiveRecord::Migration[8.0]
  def change
    create_table :stats_daily do |t|
      t.date :interval_start, null: false
      t.date :interval_end, null: false
      t.integer :participants_active, null: false, default: 0
      t.integer :participants_active_committers, null: false, default: 0
      t.integer :participants_active_contributors, null: false, default: 0
      t.integer :participants_new, null: false, default: 0
      t.float :new_participants_lifetime_avg_days, null: false, default: 0.0
      t.float :new_participants_lifetime_median_days, null: false, default: 0.0
      t.float :new_participants_lifetime_max_days, null: false, default: 0.0
      t.float :new_participants_daily_avg_messages, null: false, default: 0.0
      t.integer :retained_365_participants, null: false, default: 0
      t.float :retained_365_lifetime_avg_days, null: false, default: 0.0
      t.float :retained_365_lifetime_median_days, null: false, default: 0.0
      t.float :retained_365_daily_avg_messages, null: false, default: 0.0
      t.integer :topics_new, null: false, default: 0
      t.integer :topics_active, null: false, default: 0
      t.integer :topics_new_by_new_participants, null: false, default: 0
      t.integer :topics_new_by_new_users, null: false, default: 0
      t.integer :topics_new_with_attachments_by_new_users, null: false, default: 0
      t.integer :topics_new_with_contributor_activity, null: false, default: 0
      t.integer :topics_new_without_contributor_activity, null: false, default: 0
      t.integer :topics_new_no_attachments, null: false, default: 0
      t.integer :topics_new_with_attachments_no_commitfest, null: false, default: 0
      t.integer :topics_new_commitfest_abandoned, null: false, default: 0
      t.integer :topics_new_commitfest_committed, null: false, default: 0
      t.integer :topics_new_commitfest_in_progress, null: false, default: 0
      t.integer :messages_total, null: false, default: 0
      t.integer :messages_committers, null: false, default: 0
      t.integer :messages_contributors, null: false, default: 0
      t.integer :messages_new_participants, null: false, default: 0
      t.integer :new_users_replied_to_others, null: false, default: 0
      t.float :topics_messages_avg, null: false, default: 0.0
      t.float :topics_messages_median, null: false, default: 0.0
      t.integer :topics_messages_max, null: false, default: 0
      t.float :topics_created_messages_avg, null: false, default: 0.0
      t.float :topics_created_messages_median, null: false, default: 0.0
      t.integer :topics_created_messages_max, null: false, default: 0
      t.float :topic_longevity_avg_days, null: false, default: 0.0
      t.float :topic_longevity_median_days, null: false, default: 0.0
      t.integer :topic_longevity_max_days, null: false, default: 0

      t.timestamps
    end
    add_index :stats_daily, :interval_start, unique: true

    create_table :stats_weekly do |t|
      t.date :interval_start, null: false
      t.date :interval_end, null: false
      t.integer :participants_active, null: false, default: 0
      t.integer :participants_active_committers, null: false, default: 0
      t.integer :participants_active_contributors, null: false, default: 0
      t.integer :participants_new, null: false, default: 0
      t.float :new_participants_lifetime_avg_days, null: false, default: 0.0
      t.float :new_participants_lifetime_median_days, null: false, default: 0.0
      t.float :new_participants_lifetime_max_days, null: false, default: 0.0
      t.float :new_participants_daily_avg_messages, null: false, default: 0.0
      t.integer :retained_365_participants, null: false, default: 0
      t.float :retained_365_lifetime_avg_days, null: false, default: 0.0
      t.float :retained_365_lifetime_median_days, null: false, default: 0.0
      t.float :retained_365_daily_avg_messages, null: false, default: 0.0
      t.integer :topics_new, null: false, default: 0
      t.integer :topics_active, null: false, default: 0
      t.integer :topics_new_by_new_participants, null: false, default: 0
      t.integer :topics_new_by_new_users, null: false, default: 0
      t.integer :topics_new_with_attachments_by_new_users, null: false, default: 0
      t.integer :topics_new_with_contributor_activity, null: false, default: 0
      t.integer :topics_new_without_contributor_activity, null: false, default: 0
      t.integer :topics_new_no_attachments, null: false, default: 0
      t.integer :topics_new_with_attachments_no_commitfest, null: false, default: 0
      t.integer :topics_new_commitfest_abandoned, null: false, default: 0
      t.integer :topics_new_commitfest_committed, null: false, default: 0
      t.integer :topics_new_commitfest_in_progress, null: false, default: 0
      t.integer :messages_total, null: false, default: 0
      t.integer :messages_committers, null: false, default: 0
      t.integer :messages_contributors, null: false, default: 0
      t.integer :messages_new_participants, null: false, default: 0
      t.integer :new_users_replied_to_others, null: false, default: 0
      t.float :topics_messages_avg, null: false, default: 0.0
      t.float :topics_messages_median, null: false, default: 0.0
      t.integer :topics_messages_max, null: false, default: 0
      t.float :topics_created_messages_avg, null: false, default: 0.0
      t.float :topics_created_messages_median, null: false, default: 0.0
      t.integer :topics_created_messages_max, null: false, default: 0
      t.float :topic_longevity_avg_days, null: false, default: 0.0
      t.float :topic_longevity_median_days, null: false, default: 0.0
      t.integer :topic_longevity_max_days, null: false, default: 0

      t.timestamps
    end
    add_index :stats_weekly, :interval_start, unique: true

    create_table :stats_monthly do |t|
      t.date :interval_start, null: false
      t.date :interval_end, null: false
      t.integer :participants_active, null: false, default: 0
      t.integer :participants_active_committers, null: false, default: 0
      t.integer :participants_active_contributors, null: false, default: 0
      t.integer :participants_new, null: false, default: 0
      t.float :new_participants_lifetime_avg_days, null: false, default: 0.0
      t.float :new_participants_lifetime_median_days, null: false, default: 0.0
      t.float :new_participants_lifetime_max_days, null: false, default: 0.0
      t.float :new_participants_daily_avg_messages, null: false, default: 0.0
      t.integer :retained_365_participants, null: false, default: 0
      t.float :retained_365_lifetime_avg_days, null: false, default: 0.0
      t.float :retained_365_lifetime_median_days, null: false, default: 0.0
      t.float :retained_365_daily_avg_messages, null: false, default: 0.0
      t.integer :topics_new, null: false, default: 0
      t.integer :topics_active, null: false, default: 0
      t.integer :topics_new_by_new_participants, null: false, default: 0
      t.integer :topics_new_by_new_users, null: false, default: 0
      t.integer :topics_new_with_attachments_by_new_users, null: false, default: 0
      t.integer :topics_new_with_contributor_activity, null: false, default: 0
      t.integer :topics_new_without_contributor_activity, null: false, default: 0
      t.integer :topics_new_no_attachments, null: false, default: 0
      t.integer :topics_new_with_attachments_no_commitfest, null: false, default: 0
      t.integer :topics_new_commitfest_abandoned, null: false, default: 0
      t.integer :topics_new_commitfest_committed, null: false, default: 0
      t.integer :topics_new_commitfest_in_progress, null: false, default: 0
      t.integer :messages_total, null: false, default: 0
      t.integer :messages_committers, null: false, default: 0
      t.integer :messages_contributors, null: false, default: 0
      t.integer :messages_new_participants, null: false, default: 0
      t.integer :new_users_replied_to_others, null: false, default: 0
      t.float :topics_messages_avg, null: false, default: 0.0
      t.float :topics_messages_median, null: false, default: 0.0
      t.integer :topics_messages_max, null: false, default: 0
      t.float :topics_created_messages_avg, null: false, default: 0.0
      t.float :topics_created_messages_median, null: false, default: 0.0
      t.integer :topics_created_messages_max, null: false, default: 0
      t.float :topic_longevity_avg_days, null: false, default: 0.0
      t.float :topic_longevity_median_days, null: false, default: 0.0
      t.integer :topic_longevity_max_days, null: false, default: 0

      t.timestamps
    end
    add_index :stats_monthly, :interval_start, unique: true

    create_table :stats_longevity_daily do |t|
      t.date :interval_start, null: false
      t.date :interval_end, null: false
      t.string :bucket, null: false
      t.integer :count, null: false, default: 0

      t.timestamps
    end
    add_index :stats_longevity_daily, [ :interval_start, :bucket ], unique: true, name: "index_stats_longevity_daily_on_interval_bucket"

    create_table :stats_retention_monthly do |t|
      t.date :cohort_start, null: false
      t.integer :months_since, null: false
      t.integer :period_months, null: false, default: 1
      t.string :segment, null: false, default: "all"
      t.integer :cohort_size, null: false, default: 0
      t.integer :active_users, null: false, default: 0
      t.float :avg_messages_per_active_user, null: false, default: 0.0

      t.timestamps
    end
    add_index :stats_retention_monthly, [ :period_months, :segment, :cohort_start, :months_since ], unique: true

    create_table :stats_retention_milestones do |t|
      t.date :cohort_start, null: false
      t.integer :horizon_months, null: false
      t.integer :period_months, null: false, default: 1
      t.string :segment, null: false, default: "all"
      t.integer :cohort_size, null: false, default: 0
      t.integer :retained_users, null: false, default: 0

      t.timestamps
    end
    add_index :stats_retention_milestones, [ :period_months, :segment, :cohort_start, :horizon_months ], unique: true, name: "index_stats_retention_milestones_on_period_segment_horizon"

    create_table :stats_longevity_weekly do |t|
      t.date :interval_start, null: false
      t.date :interval_end, null: false
      t.string :bucket, null: false
      t.integer :count, null: false, default: 0

      t.timestamps
    end
    add_index :stats_longevity_weekly, [ :interval_start, :bucket ], unique: true, name: "index_stats_longevity_weekly_on_interval_bucket"

    create_table :stats_longevity_monthly do |t|
      t.date :interval_start, null: false
      t.date :interval_end, null: false
      t.string :bucket, null: false
      t.integer :count, null: false, default: 0

      t.timestamps
    end
    add_index :stats_longevity_monthly, [ :interval_start, :bucket ], unique: true, name: "index_stats_longevity_monthly_on_interval_bucket"

    add_index :messages, :created_at
    add_index :messages, [ :created_at, :topic_id ]
    add_index :messages, [ :created_at, :sender_id ]
    add_index :topics, :created_at
  end
end
