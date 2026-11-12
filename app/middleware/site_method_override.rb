# frozen_string_literal: true

# The method override of HTML forms, for the site only: an API request
# keeps its method and its body is not parsed here.
class SiteMethodOverride < Rack::MethodOverride
  def call(env)
    return @app.call(env) if ApiExceptionsApp::API_PATH.match?(env["PATH_INFO"].to_s.b)

    super
  end
end
