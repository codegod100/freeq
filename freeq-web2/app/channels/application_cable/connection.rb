# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :session_id

    def connect
      self.session_id = cookies.signed[:freeq_session] || SecureRandom.hex(16)
      logger.debug { "ChatChannel connected session=#{session_id}" }
    end
  end
end