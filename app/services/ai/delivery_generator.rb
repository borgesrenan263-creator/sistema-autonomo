require_relative "gemini_client"
require_relative "../execution/local_delivery_builder"

class DeliveryGenerator
  def self.generate(task)
    gemini = GeminiClient.new

    begin
      if gemini.available?
        content = gemini.generate_delivery(task)

        return {
          category: detect_category_from_content(content) || LocalDeliveryBuilder.detect_category(task["title"].to_s),
          content: content,
          generator_type: "ai",
          provider: "gemini",
          model: gemini.model,
          error_message: nil
        }
      end

      raise "GEMINI_API_KEY ausente"
    rescue => e
      fallback = LocalDeliveryBuilder.build(task)

      return {
        category: fallback[:category],
        content: fallback[:content],
        generator_type: "fallback",
        provider: "local",
        model: "local_delivery_builder",
        error_message: e.message
      }
    end
  end

  def self.detect_category_from_content(content)
    match = content.match(/Categoria:\s*\n(.+?)(\n\n|\z)/)
    return nil unless match

    match[1].strip[0, 120]
  end
end
