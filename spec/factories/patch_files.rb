FactoryBot.define do
  factory :patch_file do
    attachment
    sequence(:filename) { |n| "src/backend/optimizer/path/allpaths#{n}.c" }
    status { "modified" }
    line_changes { 15 }

    trait :added do
      status { "added" }
      filename { "src/backend/new_feature.c" }
    end

    trait :deleted do
      status { "deleted" }
      filename { "src/backend/old_feature.c" }
    end

    trait :renamed do
      status { "renamed" }
      filename { "src/backend/new_name.c" }
      old_filename { "src/backend/old_name.c" }
    end

    trait :contrib_file do
      filename { "contrib/pg_stat_statements/pg_stat_statements.c" }
    end

    trait :backend_file do
      filename { "src/backend/executor/execMain.c" }
    end
  end
end
