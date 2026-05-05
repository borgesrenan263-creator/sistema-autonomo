get "/sistema" do
  @page = "sistema"

  log_path = File.expand_path("storage/logs/rescan_worker.log", __dir__)

  @logs =
    if File.exist?(log_path)
      File.readlines(log_path).last(80).reverse
    else
      []
    end

  @system_counts = {
    total_tasks: db_one("SELECT COUNT(*) AS c FROM tasks")["c"],
    github_tasks: db_one("SELECT COUNT(*) AS c FROM tasks WHERE source = 'GitHub'")["c"],
    hn_tasks: db_one("SELECT COUNT(*) AS c FROM tasks WHERE source = 'Hacker News'")["c"],
    monetizable: db_one("SELECT COUNT(*) AS c FROM tasks WHERE quality_status = 'monetizable'")["c"],
    review: db_one("SELECT COUNT(*) AS c FROM tasks WHERE quality_status = 'review'")["c"],
    ignored: db_one("SELECT COUNT(*) AS c FROM tasks WHERE quality_status = 'ignore'")["c"],
    deliveries: db_one("SELECT COUNT(*) AS c FROM deliveries")["c"],
    ok_tasks: db_one("SELECT COUNT(*) AS c FROM tasks WHERE status = 'ok'")["c"]
  }

  @last_tasks = db_all(
    <<~SQL
      SELECT id, source, quality_status, demand_score, suggested_price, title, created_at
      FROM tasks
      ORDER BY id DESC
      LIMIT 12
    SQL
  )

  erb :sistema
end
