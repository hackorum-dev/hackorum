# Only staging gets the interceptor, prod and the old deploy never set HACKORUM_ENV.
if Hackorum.staging?
  Rails.application.config.after_initialize do
    Mail.register_interceptor(StagingMailRouter.from_env)
  end
end
