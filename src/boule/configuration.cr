module Boule
  class Configuration

    @path : String?

    include Crogo::Utils::HashyJson

    # Create a new configuration instance
    #
    # @param path [String] path to configuration file
    # @return [self]
    def initialize(@path : String? = nil)
      if(@path.nil? && ENV.has_key?("BOULE_CONFIG"))
        @path = ENV["BOULE_CONFIG"]
      end
      @data = {} of String => JSON::Type
      load_configuration!
    end

    # Create a new instance
    #
    # @param data [Hash(String, JSON::Type)]
    # @return [self]
    def initialize(@data : Hash(String, JSON::Type))
    end

    # Load the configuration file
    #
    # @return [Nil]
    def load_configuration! : Nil
      file_path = @path
      unless(file_path.nil?)
        @data = JSON.parse(File.read(file_path)).as_h
      end
      nil
    end

  end
end
