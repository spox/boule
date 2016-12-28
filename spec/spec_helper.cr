ENV["BOULE_TEST"] = "true"
ENV["KEMAL_ENV"] = "test"

require "spec-kemal"
require "tempfile"
require "file_utils"
require "../src/boule"

# Keep logger silent by default
unless(ENV["DEBUG"]?)
  Boule.configure_logger(
    {"log_path" => "/dev/null"} of String => String,
    {} of String => String
  )
else
  Boule.logger.level = Logger::DEBUG
end

require "spec2"
