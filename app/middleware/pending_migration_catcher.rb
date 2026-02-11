# frozen_string_literal: true

class PendingMigrationCatcher
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue ActiveRecord::PendingMigrationError, ActiveRecord::NoDatabaseError
    render_maintenance_page
  end

  private

  def render_maintenance_page
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>Upgrade in Progress</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="30">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
          }
          .container {
            background: white;
            border-radius: 16px;
            padding: 48px;
            max-width: 500px;
            text-align: center;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25);
          }
          .icon {
            font-size: 64px;
            margin-bottom: 24px;
          }
          h1 {
            color: #1a202c;
            font-size: 28px;
            margin-bottom: 16px;
          }
          p {
            color: #4a5568;
            font-size: 16px;
            line-height: 1.6;
            margin-bottom: 24px;
          }
          .spinner {
            width: 40px;
            height: 40px;
            border: 4px solid #e2e8f0;
            border-top-color: #667eea;
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin: 0 auto;
          }
          @keyframes spin {
            to { transform: rotate(360deg); }
          }
          .note {
            color: #718096;
            font-size: 14px;
            margin-top: 24px;
          }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="icon">🚀</div>
          <h1>Upgrade in Progress</h1>
          <p>We're currently upgrading the system to bring you new features and improvements. This should only take a moment.</p>
          <div class="spinner"></div>
          <p class="note">This page will automatically refresh.</p>
        </div>
      </body>
      </html>
    HTML

    [
      503,
      {
        "Content-Type" => "text/html; charset=utf-8",
        "Retry-After" => "30"
      },
      [ html ]
    ]
  end
end
