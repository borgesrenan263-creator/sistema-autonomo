require "securerandom"

module AuthGuard
  PUBLIC_PATHS = [
    "/login",
    "/healthz",
    "/readyz",
    "/manifest.json"
  ]

  WEBHOOK_PREFIXES = [
    "/webhooks/"
  ]

  def self.session_secret
    secret =
      if defined?(AppSettings)
        AppSettings.get("SESSION_SECRET").to_s
      else
        ENV["SESSION_SECRET"].to_s
      end

    if secret.empty? || secret == "trocar_em_producao" || secret.bytesize < 64
      "dev-#{SecureRandom.hex(64)}"
    else
      secret
    end
  end

  def public_request?(path)
    return true if PUBLIC_PATHS.include?(path)
    return true if path.start_with?("/icons/")
    return true if path.start_with?("/css/")
    return true if path.start_with?("/brand/")
    return true if path.start_with?("/public/")
    return true if WEBHOOK_PREFIXES.any? { |prefix| path.start_with?(prefix) }

    false
  end

  def logged_in?
    session[:admin_logged_in] == true
  end

  def require_admin!
    return if logged_in?
    redirect "/login"
  end

  def admin_username
    if defined?(AppSettings)
      AppSettings.get("ADMIN_USERNAME").to_s
    else
      ENV["ADMIN_USERNAME"].to_s
    end
  end

  def admin_password
    if defined?(AppSettings)
      AppSettings.get("ADMIN_PASSWORD").to_s
    else
      ENV["ADMIN_PASSWORD"].to_s
    end
  end

  def valid_admin_login?(username, password)
    expected_user = admin_username.empty? ? "admin" : admin_username
    expected_pass = admin_password

    return false if expected_pass.empty?
    return false if expected_pass == "trocar_em_producao"

    secure_compare(username.to_s, expected_user.to_s) &&
      secure_compare(password.to_s, expected_pass.to_s)
  end

  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize

    Rack::Utils.secure_compare(a, b)
  rescue
    a == b
  end
end
