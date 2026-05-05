require "sinatra"
require "json"
require "time"
require "fileutils"
require "csv"

require_relative "../../config/database"
require_relative "database_helpers"

require_relative "../services/real_rescan"
require_relative "../services/execution/local_delivery_builder"
require_relative "../services/ai/delivery_generator"
require_relative "../services/commercial/proposal_builder"
require_relative "../services/commercial/commercial_proposal_generator"
require_relative "../services/commercial/deal_event_logger"

require_relative "../repositories/task_repository"
require_relative "../repositories/delivery_repository"
require_relative "../repositories/deal_repository"
