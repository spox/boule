require "json"
require "option_parser"
require "logger"
require "crogo"
require "kemal"
require "secure_random"
require "file_utils"
require "signal"
require "./boule/utils"
require "./boule/*"

module Boule

  @@logger = Logger.new(STDOUT)
  @@configuration = Boule::Configuration.new
  @@terraform : Terraform?
  @@running = false

  # @return [Logger] default logger
  def self.logger
    @@logger
  end

  extend Utils::Logger

  def self.run!(cli)
    @@running = true
    if(cli["config"]?)
      @@configuration = Configuration.new(cli["config"].to_s)
    end
    logger_conf = configuration.get("logger", type: :hash)
    if(logger_conf)
      logger_conf = configuration.hashify(logger_conf.as(Hash(String, JSON::Type)))
    else
      logger_conf = {} of String => String
    end
    configure_logger(cli, logger_conf)
    info "Configuration loading and logger setup complete."
    info "Initializing terraform interface."
    @@terraform = Terraform.new(configuration)
    info "Starting REST API interface."
    # Set test env to allow manual control
    start_env = Kemal.config.env
    Kemal.config.env = "test"
    Kemal.config.logger = Rest::Api.new
    Kemal.run
    Kemal.config.env = start_env
    info "REST API interface now active -> " \
         "#{Kemal.config.scheme}://#{Kemal.config.host_binding}:#{Kemal.config.port}"
    Kemal.config.server.listen
  end

  def self.stop!
    info "Clearing terraform interface."
    terraform.halt!
    @@terraform = nil
    @@running = false
    info "Shutting down REST API interface."
    Kemal.config.server.close
    info "System halted."
  end

  def self.terraform : Terraform
    terraform = @@terraform
    if(terraform)
      terraform
    else
      error "Terraform instance instance is not currently instantiated!"
      raise Error::System::NotReady.new("Terraform instance is not yet ready.")
    end
  end

  # @return [Configuration]
  def self.configuration
    @@configuration
  end

  # Configure application logger based on settings/configuration
  #
  # @param cli [Hash(String, String | Bool)] CLI options
  # @param config [Hash(String, String)] logger configuration options
  # @return [Logger]
  def self.configure_logger(cli : Hash(String, String | Bool), config : Hash(String, String))
    path = cli.fetch("log_path", config["path"]?)
    if(path)
      @@logger = Logger.new(File.open(path.to_s, "a+"))
    end
    level = cli.fetch("verbosity", config["verbosity"]?)
    if(level)
      case level.to_s
      when "debug"
        @@logger.level = Logger::DEBUG
      when "info"
        @@logger.level = Logger::INFO
      when "warn"
        @@logger.level = Logger::WARN
      when "error"
        @@logger.level = Logger::ERROR
      when "fatal"
        @@logger.level = Logger::FATAL
      end
    end
    @@logger.progname = config.fetch("name", "boule").to_s
    @@logger
  end

end

cli_options = {} of String => String | Bool

begin
  OptionParser.parse! do |parser|
    parser.banner = "Usage: boule [arguments]"
    parser.on("-v", "--version", "Print current version") do
      cli_options["version"] = true
    end
    parser.on("-c PATH", "--config=PATH", "Path to configuration file") do |path|
      cli_options["config"] = path
    end
    parser.on("-V LEVEL", "--verbosity LEVEL", "Set logging output level") do |level|
      cli_options["verbosity"] = level
    end
    parser.on("-d", "--debug", "Enable debug output") do
      cli_options["debug"] = true
    end
    parser.on("-h", "--help", "Display this help message") do
      cli_options["help"] = true
      puts parser
    end
  end
rescue error
  STDERR.puts "ERROR: Failed to parse CLI options - #{error.message}"
  exit -1
end

if(cli_options["help"]?)
  exit 0
elsif(cli_options["version"]?)
  puts "boule: #{Boule::VERSION}"
  exit 0
end

unless(ENV["BOULE_TEST"]?)
  Signal::INT.trap do
    Boule.stop!
  end
  Signal::TERM.trap do
    Boule.stop!
  end
  begin
    Boule.run!(cli_options)
  rescue error
    STDERR.puts "ERROR: Unexpected error encountered - #{error}"
    exit -2
  end
end
