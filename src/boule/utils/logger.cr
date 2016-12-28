module Boule
  module Utils
    module Logger

      macro extended
        def self.logger_name
          self.name
        end
      end

      macro included
        def logger_name
          self.class.name
        end
      end

      # @return [Logger] application logger instance
      def logger
        Boule.logger
      end

      # Log a debug message
      #
      # @param m [String]
      def debug(m : String)
        logger.debug(logger_format_string(m))
      end

      # Log an info message
      #
      # @param m [String]
      def info(m : String)
        logger.info(logger_format_string(m))
      end

      # Log a warn message
      #
      # @param m [String]
      def warn(m : String)
        logger.warn(logger_format_string(m))
      end

      # Log an error message
      #
      # @param m [String]
      def error(m : String)
        logger.error(logger_format_string(m))
      end

      # Log a fatal message
      #
      # @param m [String]
      def fatal(m : String)
        logger.fatal(logger_format_string(m))
      end

      # Format string for logger output
      #
      # @param m [String]
      # @return [String]
      def logger_format_string(m : String) : String
        "<#{logger_name}> #{m}"
      end

    end
  end
end
