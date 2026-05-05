require "fileutils"
require "open3"
require "time"

begin
  require "sqlite3"
rescue LoadError
  puts "ERRO: gem sqlite3 nao encontrada."
  exit 1
end

ROOT = File.expand_path("..", __dir__)
DB_PATH = File.join(ROOT, "data", "sistema_autonomo.sqlite3")
LOG_PATH = File.join(ROOT, "storage", "logs", "self_repair.log")

class SelfRepair
  REQUIRED_DIRS = [
    "app",
    "app/core",
    "app/routes",
    "app/repositories",
    "app/services",
    "app/views",
    "app/public",
    "app/public/css",
    "config",
    "data",
    "db",
    "docs",
    "scripts",
    "storage",
    "storage/logs",
    "storage/exports",
    "storage/tmp",
    "workers"
  ]

  REQUIRED_ROUTE_FILES = [
    "app/routes/dashboard_routes.rb",
    "app/routes/pipeline_routes.rb",
    "app/routes/static_routes.rb",
    "app/routes/delivery_routes.rb",
    "app/routes/commercial_routes.rb",
    "app/routes/finance_routes.rb",
    "app/routes/contact_routes.rb",
    "app/routes/automation_routes.rb",
    "app/routes/outreach_routes.rb",
    "app/routes/system_routes.rb"
  ]

  REQUIRED_FILES = [
    "app.rb",
    "README.md",
    ".gitignore",
    ".env.example",
    "config/database.rb",
    "app/core/database_helpers.rb",
    "app/core/bootstrap.rb",
    "workers/rescan_worker.rb"
  ]

  REQUIRED_TABLES = [
    "tasks",
    "deliveries",
    "proposals",
    "deals",
    "contacts",
    "payments",
    "deal_events",
    "automation_flows",
    "automation_steps",
    "automation_events",
    "outreach_messages",
    "outreach_events",
    "do_not_contact_entries",
    "outreach_limits"
  ]

  def initialize
    @events = []
    @errors = []
    @warnings = []
    @repairs = []
  end

  def run
    banner
    ensure_dirs
    ensure_keep_files
    ensure_env_example
    ensure_gitignore_rules
    check_required_files
    check_route_files
    check_ruby_syntax
    check_database
    check_git_status
    write_report
    print_summary
  end

  private

  def banner
    event("SELF_REPAIR_START #{Time.now.iso8601}")
  end

  def path(relative)
    File.join(ROOT, relative)
  end

  def event(message)
    @events << "[OK] #{message}"
  end

  def warn(message)
    @warnings << "[WARN] #{message}"
  end

  def error(message)
    @errors << "[ERROR] #{message}"
  end

  def repair(message)
    @repairs << "[REPAIR] #{message}"
  end

  def ensure_dirs
    REQUIRED_DIRS.each do |dir|
      full = path(dir)

      unless Dir.exist?(full)
        FileUtils.mkdir_p(full)
        repair("Diretorio criado: #{dir}")
      else
        event("Diretorio OK: #{dir}")
      end
    end
  end

  def ensure_keep_files
    [
      "storage/logs/.keep",
      "storage/exports/.keep",
      "storage/tmp/.keep"
    ].each do |file|
      full = path(file)

      unless File.exist?(full)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, "")
        repair(".keep criado: #{file}")
      else
        event(".keep OK: #{file}")
      end
    end
  end

  def ensure_env_example
    file = path(".env.example")

    if File.exist?(file)
      event(".env.example OK")
      return
    end

    content = [
      "# Sistema Autonomo — exemplo seguro",
      "APP_ENV=development",
      "APP_HOST=0.0.0.0",
      "APP_PORT=4567",
      "",
      "GEMINI_API_KEY=cole_sua_chave_aqui",
      "GEMINI_MODEL=gemini-2.5-flash",
      "",
      "AI_MIN_DELIVERY_CHARS=1200",
      "AI_MIN_PROPOSAL_CHARS=1000",
      "",
      "RESCAN_INTERVAL_SECONDS=300",
      "",
      "PIX_PROVIDER=manual",
      "PIX_WEBHOOK_SECRET=trocar_em_producao",
      "",
      "EMAIL_PROVIDER=manual",
      "SMTP_HOST=",
      "SMTP_PORT=",
      "SMTP_USER=",
      "SMTP_PASSWORD=",
      "",
      "WHATSAPP_PROVIDER=manual",
      "WHATSAPP_TOKEN=",
      "WHATSAPP_PHONE_NUMBER_ID="
    ].join("\n")

    File.write(file, content + "\n")
    repair(".env.example recriado")
  end

  def ensure_gitignore_rules
    file = path(".gitignore")

    required_rules = [
      ".env",
      ".env.*",
      "!.env.example",
      "data/*.sqlite3",
      "data/*.sqlite3-*",
      "storage/logs/*",
      "!storage/logs/.keep",
      "storage/exports/*",
      "!storage/exports/.keep",
      "storage/tmp/*",
      "!storage/tmp/.keep",
      "*.sql",
      "*.tar.gz"
    ]

    current = File.exist?(file) ? File.read(file) : ""
    changed = false

    required_rules.each do |rule|
      next if current.lines.map(&:strip).include?(rule)

      current += "\n#{rule}\n"
      changed = true
    end

    if changed
      File.write(file, current)
      repair(".gitignore atualizado com regras seguras")
    else
      event(".gitignore OK")
    end
  end

  def check_required_files
    REQUIRED_FILES.each do |file|
      if File.exist?(path(file))
        event("Arquivo OK: #{file}")
      else
        warn("Arquivo ausente: #{file}")
      end
    end
  end

  def check_route_files
    missing = []

    REQUIRED_ROUTE_FILES.each do |file|
      if File.exist?(path(file))
        event("Route OK: #{file}")
      else
        missing << file
      end
    end

    if missing.empty?
      event("Todas as rotas modulares existem")
    else
      warn("Rotas ausentes: #{missing.join(', ')}")
    end
  end

  def check_ruby_syntax
    ok, output = run_cmd("ruby -c app.rb")

    if ok
      event("Ruby syntax OK: app.rb")
    else
      error("Ruby syntax falhou em app.rb")
      error(output)
    end
  end

  def check_database
    unless File.exist?(DB_PATH)
      error("Banco nao encontrado: #{DB_PATH}")
      return
    end

    event("Banco encontrado: #{DB_PATH}")

    db = SQLite3::Database.new(DB_PATH)
    tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten

    missing = REQUIRED_TABLES.reject { |table| tables.include?(table) }

    if missing.empty?
      event("Tabelas principais OK")
      return
    end

    warn("Tabelas ausentes: #{missing.join(', ')}")

    if missing.any? { |t| t.start_with?("automation_") } && File.exist?(path("db/add_automation_engine.rb"))
      ok, output = run_cmd("ruby db/add_automation_engine.rb")
      ok ? repair("Migration automation executada") : error("Falha migration automation: #{output}")
    end

    if missing.any? { |t| t.start_with?("outreach_") || t == "do_not_contact_entries" } && File.exist?(path("db/add_outreach_engine.rb"))
      ok, output = run_cmd("ruby db/add_outreach_engine.rb")
      ok ? repair("Migration outreach executada") : error("Falha migration outreach: #{output}")
    end

    db = SQLite3::Database.new(DB_PATH)
    tables_after = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
    still_missing = REQUIRED_TABLES.reject { |table| tables_after.include?(table) }

    if still_missing.empty?
      event("Tabelas reparadas com sucesso")
    else
      warn("Tabelas ainda ausentes: #{still_missing.join(', ')}")
    end
  rescue => e
    error("Erro verificando banco: #{e.class}: #{e.message}")
  end

  def check_git_status
    ok, output = run_cmd("git status --short")

    if ok
      if output.strip.empty?
        event("Git limpo")
      else
        warn("Git possui alteracoes pendentes:")
        output.lines.each { |line| warn("  #{line.strip}") }
      end
    else
      warn("Nao foi possivel ler git status")
    end
  end

  def run_cmd(command)
    Dir.chdir(ROOT) do
      stdout, stderr, status = Open3.capture3(command)
      [status.success?, stdout + stderr]
    end
  rescue => e
    [false, "#{e.class}: #{e.message}"]
  end

  def write_report
    FileUtils.mkdir_p(File.dirname(LOG_PATH))

    report = []
    report << "SISTEMA AUTONOMO — SELF REPAIR REPORT"
    report << "====================================="
    report << "Gerado em: #{Time.now.iso8601}"
    report << ""
    report << "EVENTOS"
    report += @events
    report << ""
    report << "REPAROS"
    report += (@repairs.empty? ? ["Nenhum reparo aplicado."] : @repairs)
    report << ""
    report << "AVISOS"
    report += (@warnings.empty? ? ["Nenhum aviso."] : @warnings)
    report << ""
    report << "ERROS"
    report += (@errors.empty? ? ["Nenhum erro."] : @errors)
    report << ""

    File.write(LOG_PATH, report.join("\n"))
  end

  def print_summary
    puts
    puts "SISTEMA AUTONOMO — SELF REPAIR"
    puts "=============================="
    puts "Eventos: #{@events.count}"
    puts "Reparos: #{@repairs.count}"
    puts "Avisos: #{@warnings.count}"
    puts "Erros: #{@errors.count}"
    puts "Relatorio: #{LOG_PATH}"
    puts

    if @errors.any?
      puts "STATUS: ATENCAO — existem erros."
      exit 1
    elsif @warnings.any?
      puts "STATUS: OK COM AVISOS"
    else
      puts "STATUS: OK"
    end
  end
end

SelfRepair.new.run
