require_relative "../../scripts/backup_manager"

get "/health" do
  @page = "health"

  db_path = File.expand_path("data/sistema_autonomo.sqlite3", settings.root)
  worker_log = File.expand_path("storage/logs/rescan_worker.log", settings.root)
  repair_log = File.expand_path("storage/logs/self_repair.log", settings.root)
  backup_log = File.expand_path("storage/logs/backup_manager.log", settings.root)

  @db_status = {
    exists: File.exist?(db_path),
    size: File.exist?(db_path) ? File.size(db_path) : 0,
    path: db_path
  }

  @counts = {}

  if @db_status[:exists]
    begin
      @counts[:tasks] = db_one("SELECT COUNT(*) AS c FROM tasks")["c"]
      @counts[:deliveries] = db_one("SELECT COUNT(*) AS c FROM deliveries")["c"]
      @counts[:deals] = db_one("SELECT COUNT(*) AS c FROM deals")["c"]
      @counts[:payments_paid] = db_one("SELECT COUNT(*) AS c FROM payments WHERE status = 'paid'")["c"]
      @counts[:automations] = db_one("SELECT COUNT(*) AS c FROM automation_flows")["c"]
      @counts[:outreach] = db_one("SELECT COUNT(*) AS c FROM outreach_messages")["c"]
    rescue => e
      @counts[:error] = e.message
    end
  end

  @worker = {
    log_exists: File.exist?(worker_log),
    last_lines: File.exist?(worker_log) ? File.readlines(worker_log).last(12).reverse : [],
    path: worker_log
  }

  @self_repair = {
    log_exists: File.exist?(repair_log),
    last_lines: File.exist?(repair_log) ? File.readlines(repair_log).last(30) : [],
    path: repair_log
  }

  @backup = {
    log_exists: File.exist?(backup_log),
    last_lines: File.exist?(backup_log) ? File.readlines(backup_log).last(20).reverse : [],
    path: backup_log,
    files: BackupManager.list
  }

  @settings_summary =
    if defined?(AppSettings)
      AppSettings.provider_summary
    else
      {}
    end

  erb :health
end

post "/backups/run" do
  manager = BackupManager.new
  manager.run

  redirect "/health"
end
