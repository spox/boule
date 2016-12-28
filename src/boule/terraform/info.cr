module Boule
  class Terraform

    abstract class Info

      class Event
        JSON.mapping(
          id: String,
          timestamp_ms: Int64,
          message: String
        )
      end

      class Process
        JSON.mapping(
          id: String,
          exit_code: Int32,
          start_time_ms: Int64,
          end_time_ms: Int64,
          type: String,
          message: String
        )
      end

      JSON.mapping(
        events: Array(Event),
        process_results: Hash(String, Process),
        directory: String
      )

      def self.load(path) : self
        raise Error::System::AbstractNotImplemented.new("Custom load not implemented.")
      end

      def initialize(@directory : String)
        @events = [] of Event
        @process_results = {} of String => Process
      end

      def save
        internal_save
        nil
      end

      protected abstract def internal_load
      protected abstract def internal_save
    end
  end
end
