# coding: utf-8
require "./rest/*"

# Disable the default 404 handler
error(404){}

module Boule
  module Rest
    class Api < Kemal::BaseLogHandler

      include Utils::Logger

      def call(context)
        time = Time.now
        request_id = UUID.random.to_s
        info "-> #{request_id} #{context.request.method} #{context.request.resource}"
        call_next(context)
        elapsed_text = elapsed_text(Time.now - time)
        info "<- #{request_id} #{context.request.method} " \
             "#{context.request.resource} #{elapsed_text} #{context.response.status_code}"
        context
      end

      def write(message)
        info message
      end

      private def elapsed_text(elapsed)
        millis = elapsed.total_milliseconds
        if(millis >= 1)
          "#{millis.round(2)}ms"
        else
          "#{(millis * 1000).round(2)}µs"
        end
      end

    end
  end
end
