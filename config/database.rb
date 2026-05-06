require "sequel"
require "sqlite3"

begin
  require "pg"
rescue LoadError
end

module DatabaseConfig
  ROOT = File.expand_path("..", __dir__)

  def self.database_url
    ENV["DATABASE_URL"].to_s.strip
  end

  def self.sqlite_path
    File.join(ROOT, "data", "sistema_autonomo.sqlite3")
  end

  def self.connect
    if database_url.empty?
      connect_sqlite
    else
      connect_postgres
    end
  end

  def self.connect_sqlite
    FileUtils.mkdir_p(File.join(ROOT, "data")) if defined?(FileUtils)

    db = Sequel.sqlite(sqlite_path)
    db.extension(:pagination) rescue nil
    db
  end

  def self.connect_postgres
    db = Sequel.connect(database_url)
    db.extension(:pagination) rescue nil
    db
  end

  def self.adapter
    database_url.empty? ? "sqlite" : "postgres"
  end

  def self.production?
    ENV["RACK_ENV"].to_s == "production" || ENV["APP_ENV"].to_s == "production"
  end
end

DB = DatabaseConfig.connect unless defined?(DB)
