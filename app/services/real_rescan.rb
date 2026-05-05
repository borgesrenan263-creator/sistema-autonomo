require_relative "collectors/github_collector"
require_relative "collectors/hacker_news_collector"
require_relative "ingestion/task_ingestor"

class RealRescan
  def initialize(db)
    @db = db
  end

  def call
    items = []

    github_items = GithubCollector.new(limit_per_query: 8).call
    hn_items = HackerNewsCollector.new(limit: 30).call

    items.concat(github_items)
    items.concat(hn_items)

    TaskIngestor.new(@db).ingest(items)
  end
end
