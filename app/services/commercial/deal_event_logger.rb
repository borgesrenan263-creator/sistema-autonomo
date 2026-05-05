require "time"

class DealEventLogger
  def initialize(db)
    @db = db
  end

  def create(deal_id:, event_type:, title:, description: nil, metadata: nil)
    @db.execute(
      <<~SQL,
        INSERT INTO deal_events
        (
          deal_id,
          event_type,
          title,
          description,
          metadata,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
      [
        deal_id,
        event_type,
        title,
        description,
        metadata,
        Time.now.iso8601
      ]
    )
  end
end
