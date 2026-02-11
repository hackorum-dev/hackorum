# frozen_string_literal: true

class HelpController < ApplicationController
  layout "help"

  PAGES = {
    "search" => "Advanced Search Guide",
    "hackorum-patch" => "Applying Patches with hackorum-patch",
    "account-linking" => "Account Linking & Multiple Emails"
  }.freeze

  def index
    @pages = PAGES
    @outline = []
  end

  def show
    @slug = params[:slug]
    @title = PAGES[@slug]
    return render_not_found unless @title

    markdown_path = Rails.root.join("app/views/help/pages", "#{@slug}.md")
    return render_not_found unless File.exist?(markdown_path)

    markdown_text = File.read(markdown_path)
    @outline = extract_outline(markdown_text)
    @content = render_markdown(markdown_text)
  end

  def active_help_section
    params[:slug]
  end

  private

  def extract_outline(text)
    headings = []
    text.each_line do |line|
      if line =~ /^(\#{2,3})\s+(.+)$/
        level = $1.length
        title = $2.strip
        id = title.downcase.gsub(/[^a-z0-9\s-]/, "").gsub(/\s+/, "-")
        headings << { level: level, title: title, id: id }
      end
    end
    headings
  end

  def render_markdown(text)
    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      link_attributes: { target: "_blank", rel: "noopener" },
      with_toc_data: true
    )
    markdown = Redcarpet::Markdown.new(
      renderer,
      autolink: true,
      fenced_code_blocks: true,
      tables: true,
      no_intra_emphasis: true,
      strikethrough: true,
      superscript: true
    )
    markdown.render(text).html_safe
  end

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
