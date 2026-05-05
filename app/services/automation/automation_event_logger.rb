require "time"

class AutomationEventLogger
  def initialize(db)
    @db = db
  end

  def create(flow_id:, event_type:, title:, description: nil, metadata: nil)
    @db.execute(
      <<~SQL,
        INSERT INTO automation_events
        (
          flow_id,
          event_type,
          title,
          description,
          metadata,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
      [
        flow_id,
        event_type,
        title,
        description,
        metadata,
        Time.now.iso8601
      ]
    )
  end
end
