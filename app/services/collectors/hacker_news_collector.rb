require_relative "../http_client"

class HackerNewsCollector
  BASE = "https://hacker-news.firebaseio.com/v0"

  def initialize(limit: 30)
    @limit = limit
  end

  def call
    ids = []

    ["topstories", "newstories", "beststories"].each do |kind|
      list = HttpClient.get_json("#{BASE}/#{kind}.json")
      ids.concat(Array(list).first(@limit / 3))
    end

    ids.uniq.first(@limit).filter_map do |id|
      item = HttpClient.get_json("#{BASE}/item/#{id}.json")
      next unless item
      next unless item["type"] == "story"
      next if item["title"].to_s.strip.empty?

      {
        external_id: "hn-#{item["id"]}",
        source: "Hacker News",
        title: item["title"].to_s,
        description: item["text"].to_s[0, 1200],
        url: item["url"] || "https://news.ycombinator.com/item?id=#{item["id"]}",
        comments: item["descendants"].to_i,
        points: item["score"].to_i,
        raw: item
      }
    end
  end
end
