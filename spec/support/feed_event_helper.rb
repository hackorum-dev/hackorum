module FeedEventHelper
  # the feed rows written inside the block, as old as `age` on the database clock,
  # or moved to the time `at`; the last one is returned
  def recorded(at: nil, age: 1.minute)
    before = FeedEvent.maximum(:id).to_i
    yield
    rows = FeedEvent.where("id > ?", before).order(:id)
    at ? rows.update_all(created_at: at) : aged(rows, age)
    rows.last
  end

  def aged(rows, age)
    FeedEvent.where(id: rows).update_all(
      [ "created_at = (clock_timestamp() AT TIME ZONE 'UTC') - make_interval(secs => ?)", age.to_f ]
    )
  end

  def message_event(at: nil, age: 1.minute, **attrs)
    row = create(:message, **attrs)
    recorded(at: at, age: age) { FeedEvents::Recorder.message_received(row) }
  end

  def patchset_event(at: nil, age: 1.minute, file_name: "v1-0001-feature.patch", **attrs)
    row = create(:message, **attrs)
    recorded(at: at, age: age) do
      create(:attachment, message: row, file_name: file_name, body: Base64.encode64("not a diff\n" * 3))
    end
  end

  def branch_event(at: nil, age: 1.minute, **attrs)
    row = create(:patch_branch, **attrs)
    recorded(at: at, age: age) { FeedEvents::Recorder.branch_created(row) }
  end

  def ci_event(branch, at: nil, age: 1.minute, **attrs)
    run = create(:patch_ci_run, patch_branch: branch, **attrs)
    recorded(at: at, age: age) { FeedEvents::Recorder.ci_completed(run) }
  end
end

RSpec.configure do |config|
  config.include FeedEventHelper
end
