#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"
require "net/http"
require "nokogiri"
require "cgi"

class CommitfestImporter
  BASE_URL = "https://commitfest.postgresql.org"

  def initialize(commitfest_ids:, include_closed:, limit:)
    @commitfest_ids = commitfest_ids
    @include_closed = include_closed
    @limit = limit
  end

  def run!
    history = fetch_commitfest_history
    selected = select_commitfests(history)
    puts "Commitfests selected: #{selected.map { |cf| cf[:id] }.join(', ')}"

    patches_by_cf = {}
    patch_ids = []

    selected.each do |entry|
      commitfest = upsert_commitfest(entry)
      patches = fetch_commitfest_patches(commitfest.external_id)
      patches_by_cf[commitfest.external_id] = patches
      patch_ids.concat(patches.map { |p| p[:patch_id] })
      puts "Commitfest #{commitfest.external_id}: #{patches.length} patches"
    end

    unique_patch_ids = patch_ids.uniq
    total_patches = unique_patch_ids.size
    unique_patch_ids.each_with_index do |patch_id, idx|
      puts "Syncing patch #{idx + 1}/#{total_patches} (#{patch_id})"
      sync_patch(patch_id)
    end

    patches_by_cf.each do |cfid, patches|
      commitfest = Commitfest.find_by!(external_id: cfid)
      patches.each do |patch_data|
        patch = CommitfestPatch.find_by!(external_id: patch_data[:patch_id])
        join = CommitfestPatchCommitfest.find_or_initialize_by(
          commitfest: commitfest,
          commitfest_patch: patch
        )
        join.status = patch_data[:status]
        join.ci_status = patch_data[:ci_status]
        join.ci_score = patch_data[:ci_score]
        join.last_synced_at = Time.current
        join.save!
      end
    end
  end

  private

  def fetch_commitfest_history
    html = fetch_html("#{BASE_URL}/commitfest_history/")
    doc = Nokogiri::HTML(html)
    commitfests = []

    doc.xpath("//h1[contains(normalize-space(.), 'Commitfest history')]/following-sibling::ul[1]/li").each do |li|
      link = li.at_css("a[href^='/']")
      next unless link
      id = link["href"]&.match(%r{^/(\d+)/})&.captures&.first
      next unless id

      name = link.text.strip
      text = li.text.strip
      text = text.sub(name, "").strip
      next unless text.match?(/\d{4}-\d{2}-\d{2}/)
      status, start_date, end_date = parse_history_text(text)
      next unless status && start_date && end_date

      commitfests << {
        id: id.to_i,
        name: name,
        status: status,
        start_date: start_date,
        end_date: end_date
      }
    end

    commitfests
  end


  def parse_history_text(text)
    normalized = text.tr("–", "-").tr("—", "-").gsub("â", "-").gsub("â€“", "-").gsub(/\s+/, " ")
    match = normalized.match(/\(?\s*([A-Za-z ]+)\s*-\s*(\d{4}-\d{2}-\d{2})\s*-\s*(\d{4}-\d{2}-\d{2})\s*\)?/)
    return [ nil, nil, nil ] unless match

    status = match[1].strip
    [ status, Date.parse(match[2]), Date.parse(match[3]) ]
  end

  def select_commitfests(history)
    selected = history
    if @commitfest_ids.any?
      selected = history.select { |entry| @commitfest_ids.include?(entry[:id]) }
    elsif !@include_closed
      selected = history.reject { |entry| entry[:status].casecmp("Closed").zero? }
    end

    selected = selected.first(@limit) if @limit
    selected
  end

  def upsert_commitfest(entry)
    commitfest = Commitfest.find_or_initialize_by(external_id: entry[:id])
    commitfest.assign_attributes(
      name: entry[:name],
      status: entry[:status],
      start_date: entry[:start_date],
      end_date: entry[:end_date],
      last_synced_at: Time.current
    )
    commitfest.save!
    commitfest
  end

  def fetch_commitfest_patches(commitfest_id)
    html = fetch_html("#{BASE_URL}/#{commitfest_id}/")
    doc = Nokogiri::HTML(html)
    patches = []

    doc.css("table tbody tr").each do |row|
      link = row.at_css("a[href^='/patch/']")
      next unless link
      patch_id = link["href"]&.match(%r{/patch/(\d+)/})&.captures&.first
      next unless patch_id
      status = row.css("td")[2]&.text&.strip.to_s
      ci_status, ci_score = parse_ci(row.at_css("td.cfbot-summary"))

      patches << {
        patch_id: patch_id.to_i,
        title: link.text.strip,
        status: status,
        ci_status: ci_status,
        ci_score: ci_score
      }
    end

    patches
  end

  def parse_ci(ci_td)
    return [ nil, nil ] unless ci_td

    text = ci_td.text.strip
    if text.include?("Not processed")
      return [ "not_processed", nil ]
    end

    if text.include?("Needs rebase")
      return [ "needs_rebase", nil ]
    end

    counters = ci_td.at_css("span.run-counters")&.text&.strip
    return [ nil, nil ] if counters.nil? || counters.empty?

    completed, total = counters.split("/").map(&:to_i)
    return [ "score", nil ] if total <= 0

    score = ((completed.to_f / total) * 10).round
    score = [ [ score, 0 ].max, 10 ].min
    [ "score", score ]
  end

  def sync_patch(patch_id)
    html = fetch_html("#{BASE_URL}/patch/#{patch_id}/")
    doc = Nokogiri::HTML(html)

    title = extract_cell_text(doc, "Title")
    topic = extract_cell_text(doc, "Topic")
    target_version = extract_cell_text(doc, "Target version")
    reviewers = extract_cell_text(doc, "Reviewers")
    committer = extract_cell_text(doc, "Committer")
    links = extract_links(doc)
    tags = extract_tags(doc)
    message_ids = extract_message_ids(doc)

    patch = CommitfestPatch.find_or_initialize_by(external_id: patch_id)
    patch.assign_attributes(
      title: title.presence || "Patch #{patch_id}",
      topic: topic.presence,
      target_version: target_version.presence,
      reviewers: reviewers.presence,
      committer: committer.presence,
      wikilink: links[:wiki],
      gitlink: links[:git],
      last_synced_at: Time.current
    )
    patch.save!

    update_tags(patch, tags)
    update_messages_and_topics(patch, message_ids)
  rescue StandardError => e
    puts "Patch #{patch_id} failed: #{e.class} #{e.message}"
  end

  def extract_cell_text(doc, label)
    cell = doc.at_xpath("//th[normalize-space(text())='#{label}']/following-sibling::td[1]")
    return "" unless cell

    cell_text = cell.text.gsub(/\s+/, " ").strip
    cell_text.gsub(/\b(Remove from reviewers|Become reviewer|Claim as committer|Unclaim as committer)\b/, "").strip
  end

  def extract_links(doc)
    cell = doc.at_xpath("//th[normalize-space(text())='Links']/following-sibling::td[1]")
    return { wiki: nil, git: nil } unless cell

    links = cell.css("a").map { |a| [ a.text.strip.downcase, a["href"] ] }.to_h
    { wiki: links["wiki"], git: links["git"] }
  end

  def extract_tags(doc)
    cell = doc.at_xpath("//th[normalize-space(text())='Tags']/following-sibling::td[1]")
    return [] unless cell

    cell.css("span.badge").map do |tag|
      {
        name: tag.text.strip,
        description: tag["title"].to_s.strip,
        color: tag["style"].to_s[/background-color:\s*([^;]+);?/, 1]
      }
    end
  end

  def extract_message_ids(doc)
    ids = []
    doc.css("a[href^='https://www.postgresql.org/message-id/']").each do |link|
      href = link["href"].to_s
      next if href.include?("/attachment/")
      message_id = href.split("/message-id/").last
      next unless message_id
      message_id = message_id.sub(/\Aflat\//, "")
      message_id = CGI.unescape(message_id)
      normalized = MessageIdNormalizer.normalize(message_id)
      ids << normalized if normalized.present?
    end
    ids.uniq
  end

  def update_tags(patch, tags)
    tag_records = tags.map do |tag|
      CommitfestTag.find_or_initialize_by(name: tag[:name]).tap do |record|
        record.description = tag[:description] if tag[:description].present?
        record.color = tag[:color] if tag[:color].present?
        record.save!
      end
    end

    patch.commitfest_tags = tag_records
  end

  def update_messages_and_topics(patch, message_ids)
    patch.commitfest_patch_messages.where.not(message_id: message_ids).delete_all
    patch.commitfest_patch_topics.delete_all

    topic_ids = []
    message_ids.each do |message_id|
      message = Message.find_by(message_id: message_id)
      record = patch.commitfest_patch_messages.find_or_initialize_by(message_id: message_id)
      record.message = message
      record.last_synced_at = Time.current
      record.save!
      topic_ids << message.topic_id if message
    end

    topic_ids.uniq.each do |topic_id|
      CommitfestPatchTopic.find_or_create_by!(commitfest_patch: patch, topic_id: topic_id) do |link|
        link.last_synced_at = Time.current
      end
    end
  end

  def fetch_html(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = "Hackorum Commitfest Importer"
    response = http.request(request)
    raise "HTTP #{response.code} for #{url}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end
end

commitfest_ids = []
include_closed = false
limit = nil

ARGV.each_with_index do |arg, idx|
  case arg
  when "--all"
    include_closed = true
  when "--include-closed"
    include_closed = true
  when "--commitfest"
    commitfest_ids << ARGV[idx + 1].to_i if ARGV[idx + 1]
  when "--limit"
    limit = ARGV[idx + 1].to_i if ARGV[idx + 1]
  end
end

CommitfestImporter.new(
  commitfest_ids: commitfest_ids,
  include_closed: include_closed,
  limit: limit
).run!
