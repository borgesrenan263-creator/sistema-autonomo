require "json"
require "uri"
require_relative "../http_client"

class GithubCollector
  API_URL = "https://api.github.com/search/issues"

  QUERIES = [
    'is:issue is:open label:bug comments:>2',
    'is:issue is:open "help wanted" comments:>1',
    'is:issue is:open "feature request" comments:>2',
    'is:issue is:open "not working" comments:>1',
    'is:issue is:open "automation" comments:>1'
  ]

  def initialize(limit_per_query: 8)
    @limit_per_query = limit_per_query
  end

  def call
    all = []

    QUERIES.each do |query|
      params = URI.encode_www_form(
        q: query,
        sort: "updated",
        order: "desc",
        per_page: @limit_per_query
      )

      headers = {}

      if ENV["GITHUB_TOKEN"] && !ENV["GITHUB_TOKEN"].strip.empty?
        headers["Authorization"] = "Bearer #{ENV["GITHUB_TOKEN"]}"
      end

      data = HttpClient.get_json("#{API_URL}?#{params}", headers)

      next unless data && data["items"].is_a?(Array)

      data["items"].each do |issue|
        next if issue["pull_request"]

        repo_url = issue.dig("repository_url").to_s.sub("https://api.github.com/repos/", "https://github.com/")

        all << {
          external_id: "github-issue-#{issue["id"]}",
          source: "GitHub",
          title: issue["title"].to_s,
          description: issue["body"].to_s[0, 1200],
          url: issue["html_url"],
          comments: issue["comments"].to_i,
          points: 0,
          raw: issue.merge("repo_url" => repo_url)
        }
      end
    end

    all
  end
end
