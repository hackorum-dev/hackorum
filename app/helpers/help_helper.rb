# frozen_string_literal: true

module HelpHelper
  def help_nav_link_class(slug)
    classes = [ "help-nav-link" ]
    classes << "active" if active_help_section == slug
    classes.join(" ")
  end

  def active_help_section
    controller.respond_to?(:active_help_section) ? controller.active_help_section : nil
  end
end
