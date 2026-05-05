require_relative "../ai/gemini_proposal_client"
require_relative "proposal_builder"

class CommercialProposalGenerator
  def self.generate(task, delivery = nil)
    gemini = GeminiProposalClient.new

    begin
      if gemini.available?
        content = gemini.generate_proposal(task, delivery)
        parsed = parse_ai_proposal(content, task)

        return parsed.merge(
          generator_type: "ai",
          provider: "gemini",
          model: gemini.model,
          error_message: nil,
          raw_content: content
        )
      end

      raise "GEMINI_API_KEY ausente"
    rescue => e
      fallback = ProposalBuilder.build(task, delivery)

      return fallback.merge(
        generator_type: "fallback",
        provider: "local",
        model: "proposal_builder",
        error_message: e.message,
        raw_content: fallback_to_text(fallback, task)
      )
    end
  end

  def self.parse_ai_proposal(content, task)
    {
      title: extract(content, "Título:", "DOR IDENTIFICADA") || "Proposta — #{task["title"]}",
      pain_summary: extract(content, "DOR IDENTIFICADA", "SOLUÇÃO PROPOSTA") || "",
      solution_scope: extract(content, "SOLUÇÃO PROPOSTA", "FORA DO ESCOPO") || extract(content, "SOLUÇÃO PROPOSTA", "ESCOPO") || "",
      out_of_scope: extract(content, "FORA DO ESCOPO", "PREÇO SUGERIDO") || "",
      price: extract_price(content) || task["suggested_price"].to_i,
      estimated_timeline: extract(content, "PRAZO OPERACIONAL", "MENSAGEM DE ABORDAGEM") || "",
      approach_message: extract(content, "MENSAGEM DE ABORDAGEM", "PRÓXIMO PASSO") || "",
      raw_content: content
    }
  end

  def self.extract(text, start_marker, end_marker)
    pattern = /#{Regexp.escape(start_marker)}\s*(.*?)\s*#{Regexp.escape(end_marker)}/mi
    match = text.match(pattern)
    return nil unless match

    match[1].strip
  end

  def self.extract_price(text)
    match = text.match(/R\$\s*([0-9]+(?:[.,][0-9]{2})?)/)
    return nil unless match

    match[1].gsub(".", "").gsub(",", ".").to_f.to_i
  end

  def self.fallback_to_text(proposal, task)
    <<~TXT
      PROPOSTA COMERCIAL — SISTEMA AUTÔNOMO

      Título:
      #{proposal[:title]}

      DOR IDENTIFICADA
      #{proposal[:pain_summary]}

      SOLUÇÃO PROPOSTA
      #{proposal[:solution_scope]}

      FORA DO ESCOPO
      #{proposal[:out_of_scope]}

      PREÇO SUGERIDO
      R$ #{proposal[:price]}

      PRAZO OPERACIONAL
      #{proposal[:estimated_timeline]}

      MENSAGEM DE ABORDAGEM
      #{proposal[:approach_message]}

      PRÓXIMO PASSO
      Revisar a proposta, validar o contexto original e decidir se vale abordagem externa.

      OBSERVAÇÃO
      Esta proposta foi gerada por fallback local e precisa de revisão humana.
    TXT
  end
end
