module DatabaseHelpers
  def db_all(sql, params = [])
    DB.execute(sql, params).map do |row|
      row.reject { |k, _| k.is_a?(Integer) }
    end
  end

  def db_one(sql, params = [])
    row = DB.get_first_row(sql, params)
    row&.reject { |k, _| k.is_a?(Integer) }
  end
end
