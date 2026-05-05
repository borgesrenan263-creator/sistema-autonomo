require "json"
require "time"
require_relative "../filters/demand_classifier"
require_relative "../filters/quality_gate"

class TaskIngestor
  def initialize(db)
    @db = db
  end

  def ingest(items)
    inserted = 0
    skipped = 0
    ignored = 0

    items.each do |item|
      gate = QualityGate.evaluate(item)

      if gate[:status] == "ignore"
        ignored += 1
      end

      demand_score = DemandClassifier.score(item)

      if gate[:status] == "ignore"
        demand_score = [demand_score - 5, 1].max
      elsif gate[:status] == "review"
        demand_score = [demand_score - 2, 1].max
      end

      stage = if gate[:status] == "monetizable" && demand_score >= 7
        "filtragem"
      elsif gate[:status] == "review"
        "coleta"
      else
        "coleta"
      end

      price = DemandClassifier.price_for(demand_score)
      now = Time.now.iso8601

      before = @db.total_changes

      @db.execute(
        <<~SQL,
          INSERT OR IGNORE INTO tasks
          (
            external_id,
            source,
            title,
            description,
            url,
            demand_score,
            suggested_price,
            status,
            stage,
            quality_status,
            quality_reason,
            raw_json,
            created_at,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          item[:external_id],
          item[:source],
          item[:title],
          item[:description],
          item[:url],
          demand_score,
          price,
          stage,
          stage,
          gate[:status],
          gate[:reason],
          JSON.generate(item[:raw] || {}),
          now,
          now
        ]
      )

      if @db.total_changes > before
        inserted += 1
      else
        skipped += 1
      end
    end

    {
      inserted: inserted,
      skipped: skipped,
      ignored: ignored,
      total: items.size
    }
  end
end
