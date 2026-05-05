require "net/http"
require "json"
require "uri"

class GeminiProposalClient
  API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"

  def initialize(api_key: ENV["GEMINI_API_KEY"], model: ENV["GEMINI_MODEL"] || "gemini-2.5-flash")
    @api_key = api_key.to_s.strip
    @model = model.to_s.strip
  end

  def available?
    !@api_key.empty?
  end

  def model
    @model
  end

  def generate_proposal(task, delivery = nil)
    raise "GEMINI_API_KEY ausente" unless available?

    first_text = request_generation(build_prompt(task, delivery))

    begin
      validate_proposal!(first_text)
      return first_text
    rescue => first_error
      expanded_text = request_generation(build_expansion_prompt(task, delivery, first_text, first_error.message))
      validate_proposal!(expanded_text)
      return expanded_text
    end
  end

  def request_generation(prompt)
    url = URI("#{API_BASE}/#{@model}:generateContent")

    request = Net::HTTP::Post.new(url)
    request["Content-Type"] = "application/json"
    request["x-goog-api-key"] = @api_key

    request.body = JSON.generate(
      {
        contents: [
          {
            role: "user",
            parts: [
              { text: prompt }
            ]
          }
        ],
        generationConfig: {
          temperature: 0.28,
          topP: 0.85,
          maxOutputTokens: 3200
        }
      }
    )

    response = Net::HTTP.start(
      url.hostname,
      url.port,
      use_ssl: true,
      open_timeout: 10,
      read_timeout: 65
    ) do |http|
      http.request(request)
    end

    unless response.code.to_i.between?(200, 299)
      raise "Gemini proposal HTTP #{response.code}: #{response.body[0, 500]}"
    end

    data = JSON.parse(response.body)
    text = data.dig("candidates", 0, "content", "parts", 0, "text").to_s.strip

    raise "Gemini proposal retornou resposta vazia" if text.empty?

    text
  end

  def validate_proposal!(text)
    min_chars = (ENV["AI_MIN_PROPOSAL_CHARS"] || 1000).to_i
    up = text.upcase

    section_groups = {
      "DOR IDENTIFICADA" => ["DOR IDENTIFICADA", "RESUMO DA DOR", "PROBLEMA IDENTIFICADO"],
      "SOLUÇÃO PROPOSTA" => ["SOLUÇÃO PROPOSTA", "SOLUCAO PROPOSTA", "ESCOPO PROPOSTO"],
      "ESCOPO" => ["ESCOPO", "INCLUSO", "O QUE ESTÁ INCLUSO", "O QUE ESTA INCLUSO"],
      "FORA DO ESCOPO" => ["FORA DO ESCOPO", "NÃO INCLUSO", "NAO INCLUSO"],
      "PREÇO SUGERIDO" => ["PREÇO SUGERIDO", "PRECO SUGERIDO", "VALOR SUGERIDO"],
      "PRAZO OPERACIONAL" => ["PRAZO OPERACIONAL", "PRAZO ESTIMADO", "PRAZO"],
      "MENSAGEM DE ABORDAGEM" => ["MENSAGEM DE ABORDAGEM", "ABORDAGEM"],
      "PRÓXIMO PASSO" => ["PRÓXIMO PASSO", "PROXIMO PASSO", "NEXT STEP"]
    }

    missing = section_groups.select do |_name, variants|
      variants.none? { |variant| up.include?(variant) }
    end.keys

    if text.length < min_chars
      raise "Gemini gerou proposta curta demais: #{text.length} caracteres, mínimo #{min_chars}"
    end

    unless missing.empty?
      raise "Gemini gerou proposta incompleta. Seções ausentes: #{missing.join(', ')}"
    end
  end

  def build_prompt(task, delivery)
    delivery_content = delivery ? delivery["content"].to_s[0, 4500] : "Nenhuma entrega técnica disponível."

    <<~PROMPT
      Você é o motor comercial do Sistema Autônomo, uma microstartup privada que transforma oportunidades públicas reais em microserviços técnicos.

      Gere uma PROPOSTA COMERCIAL clara, ética e objetiva para a oportunidade abaixo.

      REGRAS:
      - Escreva em português do Brasil.
      - Não prometa correção garantida.
      - Não finja que já falou com o cliente.
      - Não faça spam.
      - Não invente acesso a sistemas privados.
      - A proposta deve ser revisável por humano antes de contato externo.
      - Foque em microescopo pequeno, simples e vendável.
      - Não mencione automação agressiva.
      - Não inclua dados sensíveis.

      DADOS:
      Fonte: #{task["source"]}
      Título: #{task["title"]}
      URL: #{task["url"]}
      Score: #{task["demand_score"]}/10
      Qualidade: #{task["quality_status"]} - #{task["quality_reason"]}
      Preço sugerido: R$ #{task["suggested_price"]}

      ENTREGA TÉCNICA DISPONÍVEL:
      #{delivery_content}

      FORMATO OBRIGATÓRIO:

      PROPOSTA COMERCIAL — SISTEMA AUTÔNOMO

      Título:
      [título claro da proposta]

      DOR IDENTIFICADA
      [resumo claro do problema]

      SOLUÇÃO PROPOSTA
      [o que será entregue]

      ESCOPO
      [lista do que está incluso]

      FORA DO ESCOPO
      [lista do que não está incluso]

      PREÇO SUGERIDO
      R$ [valor]

      PRAZO OPERACIONAL
      [prazo em linguagem genérica, sem promessa absoluta]

      MENSAGEM DE ABORDAGEM
      [mensagem curta, ética, sem pressão, para revisão humana]

      PRÓXIMO PASSO
      [ação recomendada para o operador humano]

      OBSERVAÇÃO
      [avisar que a proposta precisa de revisão humana e confirmação antes de cobrança]

      Responda somente com a proposta final.
    PROMPT
  end

  def build_expansion_prompt(task, delivery, previous_text, validation_error)
    <<~PROMPT
      A proposta anterior ficou inválida para o Sistema Autônomo.

      ERRO DE VALIDAÇÃO:
      #{validation_error}

      PROPOSTA ANTERIOR:
      #{previous_text}

      Refaça uma proposta completa, em português do Brasil, com no mínimo 1000 caracteres e exatamente estas seções:

      PROPOSTA COMERCIAL — SISTEMA AUTÔNOMO

      Título:
      DOR IDENTIFICADA
      SOLUÇÃO PROPOSTA
      ESCOPO
      FORA DO ESCOPO
      PREÇO SUGERIDO
      PRAZO OPERACIONAL
      MENSAGEM DE ABORDAGEM
      PRÓXIMO PASSO
      OBSERVAÇÃO

      Dados:
      Fonte: #{task["source"]}
      Título: #{task["title"]}
      URL: #{task["url"]}
      Score: #{task["demand_score"]}/10
      Qualidade: #{task["quality_status"]} - #{task["quality_reason"]}
      Preço sugerido: R$ #{task["suggested_price"]}

      Não resuma. Gere proposta comercial completa, pequena, vendável e revisável.
    PROMPT
  end
end
