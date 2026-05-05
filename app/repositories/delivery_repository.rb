class DeliveryRepository
  def initialize(db)
    @db = db
  end

  def latest_for_task(task_id)
    clean(
      @db.get_first_row(
        "SELECT * FROM deliveries WHERE task_id = ? ORDER BY version DESC LIMIT 1",
        [task_id]
      )
    )
  end

  def next_version(task_id)
    row = @db.get_first_row(
      "SELECT COALESCE(MAX(version), 0) AS version FROM deliveries WHERE task_id = ?",
      [task_id]
    )

    row["version"].to_i + 1
  end

  private

  def clean(row)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
