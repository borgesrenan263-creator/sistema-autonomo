require "sqlite3"
require "time"
require "fileutils"

require_relative "../app/services/real_rescan"

ROOT_DIR = File.expand_path("..", __dir__)
DB_PATH = File.join(ROOT_DIR, "data", "sistema_autonomo.sqlite3")
LOG_DIR = File.join(ROOT_DIR, "storage", "logs")
LOG_PATH = File.join(LOG_DIR, "rescan_worker.log")

INTERVAL_SECONDS = (ENV["RESCAN_INTERVAL_SECONDS"] || 900).to_i

FileUtils.mkdir_p(LOG_DIR)

def log(message)
  line = "[#{Time.now.iso8601}] #{message}"
  puts line
  File.open(LOG_PATH, "a") { |f| f.puts(line) }
end

unless File.exist?(DB_PATH)
  log "ERRO: banco não encontrado em #{DB_PATH}"
  exit 1
end

db = SQLite3::Database.new(DB_PATH)
db.results_as_hash = true

log "WORKER_BOOT_OK interval=#{INTERVAL_SECONDS}s db=#{DB_PATH}"

loop do
  started_at = Time.now

  begin
    log "RESCAN_START"

    result = RealRescan.new(db).call

    elapsed = (Time.now - started_at).round(2)

    log "RESCAN_OK inserted=#{result[:inserted]} skipped=#{result[:skipped]} ignored=#{result[:ignored] || 0} total=#{result[:total]} elapsed=#{elapsed}s"
  rescue => e
    log "RESCAN_ERROR #{e.class}: #{e.message}"
    log e.backtrace.first(5).join(" | ") if e.backtrace
  end

  log "SLEEP #{INTERVAL_SECONDS}s"
  sleep INTERVAL_SECONDS
end
