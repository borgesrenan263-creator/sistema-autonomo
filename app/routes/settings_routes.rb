get "/settings" do
  @page = "settings"
  @settings_rows = AppSettings.rows
  @provider_summary = AppSettings.provider_summary
  @env_path = File.expand_path(".env", settings.root)
  @env_exists = File.exist?(@env_path)

  erb :settings
end
