require "rails_helper"
require "rake"

RSpec.describe "mail:name_conflicts" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["mail:name_conflicts"] }

  before { task.reenable }

  it "lists users and teams holding special names" do
    create(:user).update_columns(username: "Admin")
    create(:team).update_columns(name: "postmaster")
    expect { task.invoke }.to output(/User \d+ Admin\nTeam \d+ postmaster\n/).to_stdout
  end

  it "prints none when clean" do
    expect { task.invoke }.to output("none\n").to_stdout
  end
end
