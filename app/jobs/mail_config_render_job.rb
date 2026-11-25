class MailConfigRenderJob < ApplicationJob
  queue_as :default

  def perform
    MailConfig::Renderer.call
  end
end
