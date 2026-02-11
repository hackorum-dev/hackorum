# frozen_string_literal: true

module SettingsHelper
  def settings_nav_link_class(section, danger: false)
    classes = [ "settings-nav-link" ]
    classes << "active" if active_settings_section == section
    classes << "danger" if danger
    classes.join(" ")
  end

  def active_settings_section
    controller.respond_to?(:active_settings_section) ? controller.active_settings_section : :account
  end
end
