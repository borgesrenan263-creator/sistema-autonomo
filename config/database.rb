require "sqlite3"
require "fileutils"

module DatabaseConfig
  ROOT_DIR = File.expand_path("..", __dir__)
  DATA_DIR = File.join(ROOT_DIR, "data")
  DB_PATH = File.join(DATA_DIR, "sistema_autonomo.sqlite3")

  def self.ensure_data_dir!
    FileUtils.mkdir_p(DATA_DIR)
  end

  def self.connect
    ensure_data_dir!

    db = SQLite3::Database.new(DB_PATH)
    db.results_as_hash = true
    db
  end
end
