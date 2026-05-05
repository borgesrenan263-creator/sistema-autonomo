require "net/http"
require "json"
require "uri"

class GeminiClient
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

  def generate_delivery(task)
    raise "GEMINI_API_KEY ausente" unless available?

    first_prompt = build_prompt(task)
    first_text = request_generation(first_prompt)

    begin
      validate_delivery!(first_text)
      return first_text
    rescue => first_error
      expanded_prompt = build_expansion_prompt(task, first_text, first_error.message)
      expanded_text = request_generation(expanded_prompt)
      validate_delivery!(expanded_text)
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
          temperature: 0.25,
          topP: 0.85,
          maxOutputTokens: 4200
        }
      }
    )

    response = Net::HTTP.start(
      url.hostname,
      url.port,
      use_ssl: true,
      open_timeout: 10,
      read_timeout: 70
    ) do |http|
      http.request(request)
    end

    unless response.code.to_i.between?(200, 299)
      raise "Gemini HTTP #{response.code}: #{response.body[0, 500]}"
    end

    data = JSON.parse(response.body)
    text = data.dig("candidates", 0, "content", "parts", 0, "text").to_s.strip

    raise "Gemini retornou resposta vazia" if text.empty?

    text
  end

  private

  def validate_delivery!(text)
    min_chars = (ENV["AI_MIN_DELIVERY_CHARS"] || 1200).to_i
    up = text.upcase

    section_groups = {
      "DIAGNÓSTICO" => ["DIAGNÓSTICO", "DIAGNOSTICO"],
      "HIPÓTESE DE CAUSA" => ["HIPÓTESE DE CAUSA", "HIPOTESE DE CAUSA", "HIPÓTESES", "HIPOTESES"],
      "PLANO DE CORREÇÃO" => ["PLANO DE CORREÇÃO", "PLANO DE CORRECAO", "PLANO DE AÇÃO", "PLANO DE ACAO", "PLANO DE ENTREGA"],
      "CHECKLIST" => ["CHECKLIST", "CHECKLIST DE VALIDAÇÃO", "CHECKLIST DE VALIDACAO"],
      "MENSAGEM DE ABORDAGEM" => ["MENSAGEM DE ABORDAGEM", "ABORDAGEM", "MENSAGEM"],
      "OBSERVAÇÃO OPERACIONAL" => ["OBSERVAÇÃO OPERACIONAL", "OBSERVACAO OPERACIONAL", "OBSERVAÇÃO", "OBSERVACAO"]
    }

    missing = section_groups.select do |_name, variants|
      variants.none? { |variant| up.include?(variant) }
    end.keys

    if text.length < min_chars
      raise "Gemini gerou entrega curta demais: #{text.length} caracteres, mínimo #{min_chars}"
    end

    unless missing.empty?
      raise "Gemini gerou entrega incompleta. Seções ausentes: #{missing.join(', ')}"
    end
  end

  def build_expansion_prompt(task, previous_text, validation_error)
    <<~PROMPT
      A resposta anterior ficou inválida para o Sistema Autônomo.

      ERRO DE VALIDAÇÃO:
      #{validation_error}

      SUA RESPOSTA ANTERIOR:
      #{previous_text}

      Refaça a entrega completa, em português do Brasil, com no mínimo 1200 caracteres e usando exatamente estas seções:

      SISTEMA AUTÔNOMO — ENTREGA IA

      Fonte:
      Link de origem:
      Oportunidade detectada:
      Categoria:
      Score:
      Qualidade:
      Preço sugerido:

      DIAGNÓSTICO
      HIPÓTESE DE CAUSA
      PLANO DE CORREÇÃO / ENTREGA
      CHECKLIST DE VALIDAÇÃO
      ENTREGA COMERCIAL POSSÍVEL
      MENSAGEM DE ABORDAGEM
      OBSERVAÇÃO OPERACIONAL

      Dados da oportunidade:
      Fonte: #{task["source"]}
      Título: #{task["title"]}
      URL: #{task["url"]}
      Score: #{task["demand_score"]}/10
      Qualidade: #{task["quality_status"]} - #{task["quality_reason"]}
      Valor sugerido: R$ #{task["suggested_price"]}
      Descrição: #{task["description"].to_s[0, 2500]}

      Não resuma. Não responda em uma linha. Gere uma entrega completa, prática e revisável.
    PROMPT
  end

  def build_prompt(task)
    description = task["description"].to_s.strip
    description = "Sem descrição longa disponível. Use o título e o contexto da fonte para criar uma entrega inicial revisável." if description.empty?

    <<~PROMPT
      Você é o motor de execução do Sistema Autônomo, uma microstartup privada que transforma oportunidades públicas reais em microentregas técnicas.

      Sua tarefa é gerar uma entrega operacional, útil, segura e comercialmente aplicável para a oportunidade abaixo.

      IMPORTANTE:
      - Escreva em português do Brasil.
      - Gere uma entrega completa, não um resumo curto.
      - Use no mínimo 900 palavras quando houver contexto suficiente.
      - Se houver pouco contexto, ainda gere uma entrega robusta com hipóteses claramente marcadas.
      - Não invente que você corrigiu o problema.
      - Não diga que acessou o repositório inteiro.
      - Não diga que testou comandos se isso não foi informado.
      - Não prometa resultado garantido.
      - Não gere exploração de segurança, bypass, ataque, malware ou instruções abusivas.
      - Mantenha revisão humana antes de contato externo.
      - Seja prático, direto e técnico.
      - A entrega deve ser útil para o operador humano decidir se vale abordar, corrigir ou transformar em microserviço.

      DADOS DA OPORTUNIDADE:
      Fonte: #{task["source"]}
      Título: #{task["title"]}
      URL: #{task["url"]}
      Score: #{task["demand_score"]}/10
      Qualidade: #{task["quality_status"]} - #{task["quality_reason"]}
      Valor sugerido: R$ #{task["suggested_price"]}

      DESCRIÇÃO / CONTEXTO DISPONÍVEL:
      #{description[0, 3500]}

      FORMATO OBRIGATÓRIO:

      SISTEMA AUTÔNOMO — ENTREGA IA

      Fonte:
      [fonte]

      Link de origem:
      [url]

      Oportunidade detectada:
      [título reescrito de forma clara]

      Categoria:
      [categoria operacional: Bug técnico, Build/DevOps, UX/UI, Automação, Produto/API, Dados, Outro]

      Score:
      [score]/10

      Qualidade:
      [quality_status] — [quality_reason]

      Preço sugerido:
      R$ [valor]

      DIAGNÓSTICO
      Explique de forma objetiva o que parece estar acontecendo.
      Diferencie fato observado de hipótese.
      Diga por que isso pode ser uma micro-oportunidade.

      HIPÓTESE DE CAUSA
      Liste de 3 a 6 hipóteses plausíveis.
      Não invente confirmação.
      Use linguagem como "pode ser", "é possível", "a hipótese inicial é".

      PLANO DE CORREÇÃO / ENTREGA
      1. Primeiro passo prático.
      2. Segundo passo prático.
      3. Terceiro passo prático.
      4. Quarto passo prático.
      5. Quinto passo prático.
      6. Resultado esperado da microentrega.

      CHECKLIST DE VALIDAÇÃO
      [ ] Item objetivo de validação
      [ ] Item objetivo de validação
      [ ] Item objetivo de validação
      [ ] Item objetivo de validação
      [ ] Item objetivo de validação

      ENTREGA COMERCIAL POSSÍVEL
      Explique qual microserviço poderia ser oferecido.
      Inclua escopo pequeno.
      Inclua o que fica fora do escopo.
      Inclua prazo operacional estimado em linguagem genérica, sem prometer garantia.

      MENSAGEM DE ABORDAGEM
      Crie uma mensagem curta, ética e não invasiva para o operador humano usar se decidir abordar.
      Não pressione.
      Não faça spam.
      Não finja relação prévia.

      OBSERVAÇÃO OPERACIONAL
      Reforce que a entrega veio de oportunidade pública real, que precisa de revisão humana, e que pagamento só deve ser considerado após validação real.

      SAÍDA:
      Responda somente com a entrega final no formato acima.
      Não inclua comentários fora da entrega.
      Use exatamente os nomes das seções obrigatórias:
      DIAGNÓSTICO
      HIPÓTESE DE CAUSA
      PLANO DE CORREÇÃO / ENTREGA
      CHECKLIST DE VALIDAÇÃO
      ENTREGA COMERCIAL POSSÍVEL
      MENSAGEM DE ABORDAGEM
      OBSERVAÇÃO OPERACIONAL
    PROMPT
  end
end
