class ProposalBuilder
  def self.build(task, delivery = nil)
    title = task["title"].to_s
    source = task["source"].to_s
    url = task["url"].to_s
    price = task["suggested_price"].to_i
    score = task["demand_score"].to_i
    quality = task["quality_status"].to_s
    reason = task["quality_reason"].to_s

    pain_summary = <<~TXT.strip
      Foi detectada uma oportunidade pública em #{source}: "#{title}".
      O sinal foi classificado como #{quality} por #{reason}, com score #{score}/10.
      A dor aparente envolve um problema técnico, operacional ou de produto que pode ser tratado como uma microentrega objetiva.
    TXT

    solution_scope = <<~TXT.strip
      Escopo proposto:
      1. Revisar o problema original e o contexto disponível.
      2. Produzir diagnóstico objetivo.
      3. Levantar hipóteses de causa.
      4. Propor caminho de correção ou melhoria.
      5. Entregar checklist de validação e próximos passos.
    TXT

    out_of_scope = <<~TXT.strip
      Fora do escopo:
      - Garantia de correção definitiva sem acesso ao ambiente.
      - Alterações diretas em repositório sem autorização.
      - Suporte contínuo após a entrega inicial.
      - Promessas de resultado sem validação técnica.
    TXT

    estimated_timeline = "Entrega inicial revisável em curto prazo após validação manual do contexto."

    approach_message = <<~TXT.strip
      Olá, vi este problema público: "#{title}".

      Montei um diagnóstico inicial com hipóteses de causa, plano de correção e checklist de validação.
      A ideia é uma microentrega objetiva, sem compromisso, para ajudar a destravar esse ponto.

      Origem: #{url}

      Se fizer sentido, posso compartilhar uma versão curta da análise para você avaliar.
    TXT

    {
      title: "Proposta — #{title}",
      pain_summary: pain_summary,
      solution_scope: solution_scope,
      out_of_scope: out_of_scope,
      price: price,
      estimated_timeline: estimated_timeline,
      approach_message: approach_message
    }
  end
end
