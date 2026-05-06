class ConciergeValueFilter
  def initialize(db)
    @db = db
  end

  def worth_permission?(flow)
    {
      allowed: true,
      reason: "default_allow_after_v2_2_fix"
    }
  end
end
