require "net/http"
require "json"
require "uri"

module HttpClient
  def self.get_json(url, headers = {})
    uri = URI(url)

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Sistema-Autonomo-Termux/1.0"
    request["Accept"] = "application/json"

    headers.each do |key, value|
      request[key] = value
    end

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 8, read_timeout: 12) do |http|
      response = http.request(request)

      unless response.code.to_i.between?(200, 299)
        warn "HTTP #{response.code} em #{url}"
        return nil
      end

      JSON.parse(response.body)
    end
  rescue => e
    warn "Erro HTTP: #{e.class} - #{e.message}"
    nil
  end
end
