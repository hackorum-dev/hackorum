# frozen_string_literal: true

module AdminHelper
  def admin_nav_link_class(section)
    classes = [ "settings-nav-link" ]
    classes << "active" if active_admin_section == section
    classes.join(" ")
  end

  def active_admin_section
    controller.respond_to?(:active_admin_section) ? controller.active_admin_section : :users
  end
end
