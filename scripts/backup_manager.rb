require "fileutils"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
BACKUP_DIR = "/root/backups"
DB_PATH = File.join(ROOT, "data", "sistema_autonomo.sqlite3")
LOG_PATH = File.join(ROOT, "storage", "logs", "backup_manager.log")

class BackupManager
  attr_reader :tar_path, :sql_path, :errors

  def initialize
    @errors = []
    @timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
    @base_name = "sistema-autonomo-backup-#{@timestamp}"
    @tar_path = File.join(BACKUP_DIR, "#{@base_name}.tar.gz")
    @sql_path = File.join(BACKUP_DIR, "#{@base_name}.sql")
  end

  def run
    FileUtils.mkdir_p(BACKUP_DIR)
    FileUtils.mkdir_p(File.dirname(LOG_PATH))

    create_tar_backup
    create_sql_dump

    write_log

    errors.empty?
  end

  def self.list(limit = 30)
    FileUtils.mkdir_p(BACKUP_DIR)

    Dir.glob(File.join(BACKUP_DIR, "sistema-autonomo-backup-*"))
       .sort_by { |path| File.mtime(path) }
       .reverse
       .first(limit)
       .map do |path|
         {
           path: path,
           name: File.basename(path),
           size: File.size?(path).to_i,
           mtime: File.mtime(path)
         }
       end
  end

  private

  def create_tar_backup
    cmd = [
      "tar",
      "-czf",
      @tar_path,
      "-C",
      File.dirname(ROOT),
      File.basename(ROOT)
    ]

    ok, output = run_cmd(cmd)

    if ok
      log("TAR_OK #{@tar_path}")
    else
      @errors << "TAR_FAILED #{output}"
    end
  end

  def create_sql_dump
    unless File.exist?(DB_PATH)
      @errors << "DB_NOT_FOUND #{DB_PATH}"
      return
    end

    cmd = "sqlite3 #{shell_escape(DB_PATH)} .dump > #{shell_escape(@sql_path)}"
    stdout, stderr, status = Open3.capture3("bash", "-lc", cmd)

    if status.success?
      log("SQL_OK #{@sql_path}")
    else
      @errors << "SQL_FAILED #{stdout} #{stderr}"
    end
  end

  def run_cmd(cmd)
    stdout, stderr, status = Open3.capture3(*cmd)
    [status.success?, stdout + stderr]
  end

  def shell_escape(value)
    "'" + value.to_s.gsub("'", "'\"'\"'") + "'"
  end

  def log(message)
    File.open(LOG_PATH, "a") do |f|
      f.puts "[#{Time.now.iso8601}] #{message}"
    end
  end

  def write_log
    File.open(LOG_PATH, "a") do |f|
      f.puts "[#{Time.now.iso8601}] BACKUP_DONE tar=#{@tar_path} sql=#{@sql_path} errors=#{errors.count}"
      errors.each { |e| f.puts "[#{Time.now.iso8601}] ERROR #{e}" }
    end
  end
end

if __FILE__ == $0
  manager = BackupManager.new
  ok = manager.run

  puts "SISTEMA AUTONOMO — BACKUP MANAGER"
  puts "================================"
  puts "TAR: #{manager.tar_path}"
  puts "SQL: #{manager.sql_path}"
  puts "Erros: #{manager.errors.count}"

  manager.errors.each do |error|
    puts "ERROR: #{error}"
  end

  exit(ok ? 0 : 1)
end
