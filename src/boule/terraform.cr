require "tempfile"
require "./terraform/*"

module Boule
  class Terraform

    include Utils::Logger

    alias Runners = Hash(String, Utils::Runner)

    property bin = "terraform"
    property store = "terraform_store"
    property runners = {} of String => Runners
    property alive = true
    property halt_notifier = Channel(Nil).new(1)

    # Create a new instance with custom store path and bin file
    #
    # @param store [String] path to stack information storage
    # @param bin [String] path to terraform executable
    # @return [self]
    def initialize(@store : String, @bin : String)
      init!
    end

    # Create a new instance with custom store path
    #
    # @param store [String] path to stack information storage
    # @return [self]
    def initialize(@store : String)
      init!
    end

    # Create a new instance using configuration values
    #
    # @param configuration [Configuration]
    # @return [self]
    def initialize(configuration : Configuration)
      c_dir = configuration.get("terraform", "directory", type: :string)
      c_bin = configuration.get("terraform", "bin", type: :string)
      @store = c_dir ? c_dir.to_s : "terraform_store"
      @bin = c_bin ? c_bin.to_s : "terraform"
      init!
    end

    # Do not allow any more process requests and
    # wait for any existing processes to complete
    def halt!
      @alive = false
      debug "Starting halt process"
      debug "Waiting for running process completion."
      spawn do
        noted_wait = false
        while(runners.values.map(&.values).flatten.any?(&.active?))
          unless(noted_wait)
            noted_wait = true
            debug "Waiting for running processes to complete."
          end
          sleep(0.01)
        end
        debug "All waiting processes are complete."
        halt_notifier.send(nil)
      end
      halt_notifier.receive
      debug "Halt process complete"
    end

    # Generate a plan for a given stack
    def plan(stack_name : String) : Utils::Runner::Status
      inactive_required!(stack_name)
      status = start_runner(type: :plan, action: "plan", stack: stack_name)
    end

    # Apply template to create or update existing stack
    def apply(stack_name : String, template : String, parameters : Hash(String, JSON::Type))
      inactive_required!(stack_name)
      cmd = ["apply"]
      main_tf = tf_path(stack_name)
      param_tf = tfvars_path(stack_name)
      File.open(main_tf, "w+") do |file|
        file.print(parameters.to_json)
      end
      File.open(main_tf, "w+") do |file|
        file.print(template)
      end
      runner = start_runner(type: :apply, action: "apply", stack: stack_name)
      store_events(stack_name, runner)
      runner.on_complete do |status, runner|
        update_stack_info(stack_name) do |info|
          info["updated_at"] = Time.now.epoch_ms
          info["state"] = status.success? ? "complete" : "failed"
          info
        end
      end
      runner.run!
      runner.status
    end

    # Destroy an existing stack
    def destroy(stack_name : String)
      inactive_required!(stack_name)
      runner = start_runner(type: :destroy, action: ["destroy", "-force"], stack: stack_name)
      store_events(stack_name, runner)
      runner.on_complete do |status, runner|
        debug "Deleting destroyed stack working directory `#{stack_name}`"
        FileUtils.rm_r(stack_directory(stack_name))
      end
      runner.run!
      runner.status
    end

    # Get events for an existing stack
    def events(stack_name : String)
      unless(exists?(stack_name))
        debug "Unknown stack name received - #{stack_name}"
        raise Error::Terraform::UnknownStack.new("No stack with given name - `#{stack_name}`")
      else
        info = stack_info(stack_name)
        result = info["events"]?
        if(result.nil?)
          [] of Hash(String, JSON::Type)
        else
          result.as(Array(JSON::Type)).map do |item|
            item = item.as(Hash(String, JSON::Type))
            new_item = item.dup
            parts = item["resource_name"].to_s.split(".")
            new_item["resource_name"] = parts[1]
            new_item["resource_type"] = parts[0]
            new_item
          end
        end
      end
    end

    # Get resources for an existing stack
    #
    # @param stack_name [String]
    # @return [Array<Hash(String, String)>] list of resources
    def resources(stack_name : String)
      unless(exists?(stack_name))
        debug "Unknown stack name received - #{stack_name}"
        raise Error::Terraform::UnknownStack.new("No stack with given name - `#{stack_name}`")
      else
        runner = start_runner(type: :resources, action: "state list", stack: stack_name)
        runner.run!
        status = runner.result(true)
        content = runner.stdout.gets_to_end.split("\n")
        resource_lines = content.map do |line|
          line if line.match(/^[^\s]/)
        end.compact
        result = [] of Hash(String, String)
        resource_lines.each do |line|
          parts = line.split('.')
          resource_info = {"type" => parts[0], "name" => parts[1], "status" => "UPDATE_COMPLETE"}
          runner = start_runner(type: :resources, action: "state show #{line}", stack: stack_name)
          runner.run!
          status = runner.result(true)
          content = runner.stdout.gets_to_end.split("\n")
          info = {} of String => String
          content.each do |line|
            parts = line.split("=").map(&.strip)
            next if parts.size != 2
            info[parts[0]] = parts[1]
          end
          resource_info["physical_id"] = info["id"] if info["id"]?
          result << resource_info
        end
        result
      end
    end

    # Get template for existing stack
    #
    # @param stack_name [String]
    # @return [String]
    def template(stack_name : String)
      unless(exists?(stack_name))
        debug "Unknown stack name received - #{stack_name}"
        raise Error::Terraform::UnknownStack.new("No stack with given name - `#{stack_name}`")
      else
        main_tf = tf_path(stack_name)
        if(File.exists?(main_tf))
          File.read(main_tf)
        else
          "{}"
        end
      end
    end

    # Validate template for correctness
    #
    # @param template [String]
    # @return [Array<String>] List of errors. Valid if empty.
    def validate(template : String) : Array(String)
      tmp_file = Tempfile.new("boule")
      tmp_file.delete
      root_path = tmp_file.path
      Dir.mkdir_p(root_path, 500)
      template_path = File.join(root_path, "main.tf")
      File.write(template_path, template)
      runner = Utils::Runner.new(:validate, "#{bin} validate -no-color", root_path)
      errors = [] of String
      runner.on_io do |line, type, runner|
        if(line.starts_with?("*"))
          errors << line.chomp
        end
      end
      runner.run!
      runner.result(true)
      errors
    end

    # Check if given stack exists
    #
    # @param stack_name [String]
    # @return [Bool]
    def exists?(stack_name : String) : Bool
      stacks_list.includes?(stack_name)
    end

    # Check if given stack is currently actively running
    #
    # @param stack_name [String]
    # @return [Bool]
    def active?(stack_name : String, exceptional = true) : Bool
      unless(exists?(stack_name))
        debug "Unknown stack name received - #{stack_name}"
        if(exceptional)
          raise Error::Terraform::UnknownStack.new("No stack with given name - `#{stack_name}`")
        else
          false
        end
      else
        !!(runners[stack_name]? && runners[stack_name].values.any?(&.active?))
      end
    end

    # List of stack names currently defined within storage directory
    #
    # @return [Array(Hash)]
    def stacks
      stacks_list.map do |stack_name|
        info(stack_name)
      end
    end

    # Generate local stack names list
    #
    # @return [Array(String)]
    def stacks_list : Array(String)
      Dir.entries(store).map do |entry|
        if(File.directory?(File.join(store, entry)))
          entry unless entry.starts_with?(".")
        end
      end.compact.sort
    end

    # Get current stack status information
    #
    # @param stack_name [String]
    # @return [Hash(String, String | Bool)]
    def info(stack_name : String)
      exists?(stack_name)
      if(File.exists?(tf_path(stack_name)))
        file_info = File.lstat(tf_path(stack_name))
        last_update = file_info.mtime.to_utc.to_s
      end
      if(Dir.exists?(File.dirname(tf_path(stack_name))))
        dir_info = File.lstat(File.dirname(tf_path(stack_name)))
        create_time = dir_info.ctime.to_utc.to_s
      end
      stack_data = stack_info(stack_name)
      result = {} of String => String? | Bool | Hash(String, JSON::Type)
      result["id"] = stack_name
      result["name"] = stack_name
      result["state"] = stack_data["state"].to_s
      result["status"] = active?(stack_name) ? "UPDATE_IN_PROGRESS" : "UPDATE_COMPLETE"
      result["updated_time"] = stack_data["updated_at"]?.to_s
      result["creation_time"] = stack_data["created_at"]?.to_s
      result["running"] = active_process(stack_name)
      result["outputs"] = outputs_for(stack_name)
      result
    end

    # Get outputs for given stack
    #
    # @param stack_name [String]
    # @return [Hash<String, JSON::Type>]
    def outputs_for(stack_name)
      outputs = {} of String => JSON::Type
      unless(exists?(stack_name))
        debug "Unknown stack name received - #{stack_name}"
        raise Error::Terraform::UnknownStack.new("No stack with given name - `#{stack_name}`")
      else
        runner = start_runner(type: :outputs, action: ["output", "-json"], stack: stack_name)
        runner.run!
        status = runner.result(true)
        content = runner.stdout.gets_to_end
        data = JSON.parse(content).as_h.as(Hash(String, JSON::Type))
        data.each do |key, o_value|
          outputs[key] = o_value.as(Hash(String, JSON::Type))["value"]
        end
        outputs
      end
    end

    # Initialize the instance by validating bin and setting up
    # configured store directory
    protected def init!
      check = Process.run(bin)
      if(check.exit_code != 1)
        error "Failed to locate `terraform` executable. Using bin `#{bin}`. (Check PATH)"
        raise Error::Terraform::InvalidExecutable.new("Invalid `terraform` path given: #{bin}")
      else
        debug "Successfully located `terraform` executable."
      end
      Dir.mkdir_p(store)
      debug "Terraform root working directory set - `#{store}`"
    end

    # Create a new process runner and register into runners
    #
    # @param type [Symbol] type of process runner
    # @param action [String] action to perform on bin
    # @param stack [String] name of stack
    # @return [Runner]
    protected def start_runner(type : Symbol, action : String | Array(String), stack : String) : Utils::Runner
      if(action.is_a?(String))
        action = action.to_s + " -no-color"
        command = "#{bin} #{action}"
      else
        action = action.as(Array(String))
        action << "-no-color"
        command = [bin] + action
      end
      directory = stack_directory(stack)
      runner = Utils::Runner.new(type, command, directory)
      unless(runners[stack]?)
        runners[stack] = Runners.new
      end
      runners[stack][runner.id] = runner
      info_file = File.join(stack_directory(stack), "info.json")
      runner.on_complete do |status, complete_runner|
        runners[stack].delete(runner.id)
        if(File.exists?(info_file))
          info = {} of String => JSON::Type
          info["id"] = runner.id
          info["type"] = type.to_s
          info["exit_code"] = status.exit_status.to_i64
          info["start_time"] = runner.start_time.epoch_ms
          info["end_time"] = Time.now.epoch_ms
          data = stack_info(stack)
          if(data["actions"]?)
            actions = data["actions"].as(Hash(String, JSON::Type))
          else
            actions = {} of String => JSON::Type
          end
          actions[runner.id] = info.as(JSON::Type)
          data["actions"] = actions.as(JSON::Type)
          write_stack_info(stack, data)
        end
        nil
      end
      runner
    end

    # Get path to working directory for given stack
    #
    # @param stack_name [String]
    # @return [String] path
    def stack_directory(stack_name)
      dir = File.join(store, stack_name)
      unless(Dir.exists?(dir))
        Dir.mkdir_p(dir)
      end
      dir
    end

    # Get path to stack information file
    #
    # @param stack_name [String]
    # @return [String]
    def stack_info_path(stack_name)
      File.join(stack_directory(stack_name), "info.json")
    end

    # Update stack information in data file
    #
    # @param stack_name [String]
    # @return [Bool]
    def update_stack_info(stack_name : String, &block : Hash(String, JSON::Type) -> Hash(String, JSON::Type))
      info = stack_info(stack_name)
      result = block.call(info)
      write_stack_info(stack_name, result)
    end

    # Write stack information to data file
    #
    # @param stack_name [String]
    # @param info [Hash]
    # @param create_missing [Bool] create file if not found
    # @return [Bool] data written
    def write_stack_info(stack_name, info, create_missing=true)
      path = stack_info_path(stack_name)
      if(!File.exists?(path) && !create_missing)
        false
      else
        File.open(path, "w+") do |file|
          file.print(info.to_json)
        end
        true
      end
    end

    # Get locally stored stack information data
    #
    # @param stack_name [String]
    # @return [Smash]
    def stack_info(stack_name)
      path = stack_info_path(stack_name)
      if(File.exists?(path))
        result = JSON.parse(File.read(path)).as_h.as(Hash(String, JSON::Type))
      else
        result = {} of String => JSON::Type
      end
      unless(result["created_at"]?)
        result["created_at"] = Time.now.epoch_ms
      end
      unless(result["state"]?)
        result["state"] = "none"
      end
      result
    end

    # Generate path to stack's main.tf file
    #
    # @param stack_name [String]
    # @return [String] path
    def tf_path(stack_name : String)
      dir = stack_directory(stack_name)
      File.join(dir, "main.tf")
    end

    # Generate path to stack's terraform.tfvars file
    #
    # @param stack_name [String]
    # @return [String] path
    def tfvars_path(stack_name : String)
      dir = stack_directory(stack_name)
      File.join(dir, "terraform.tfvars")
    end

    # Ensure stack is not currently in active state. Raises
    # exception if stack is currently active.
    #
    # @param stack_name [String]
    protected def inactive_required!(stack_name : String)
      if(active?(stack_name, exceptional: false))
        debug "Requested stack is in busy state - #{stack_name}"
        raise Error::Terraform::StackBusy.new("Stack is currently in busy state - #{stack_name}")
      end
    end

    # Register an IO handler into a Runner and extract event information
    # from the process output.
    #
    # @param stack_name [String]
    # @param runner [Utils::Runner]
    protected def store_events(stack_name : String, runner : Utils::Runner)
      runner.on_io do |line, type, runner|
        event_file = File.join(stack_directory(stack_name), "info.json")
        if(File.exists?(event_file))
          data = JSON.parse(File.read(event_file)).as_h.as(Hash(String, JSON::Type))
        else
          data = {} of String => JSON::Type
        end
        if(data["events"]?)
          events = data["events"].as(Array(JSON::Type))
        else
          events = [] of JSON::Type
        end
        result = line.match(/^(\*\s+)?(?<name>[^\s]+): (?<status>.+)$/)
        if(result)
          resource_name = result["name"]
          resource_status = result["status"]
          event = {} of String => JSON::Type
          event["timestamp"] = Time.now.epoch_ms
          event["resource_name"] = resource_name
          event["resource_status"] = resource_status
          event["group_id"] = runner.id
          event["id"] = SecureRandom.uuid
          events << event.as(JSON::Type)
          data["events"] = events.as(JSON::Type)
          File.write(event_file, data.to_json)
        end
        nil
      end
    end

    # Find process ID of active process if available
    #
    # @param stack_name [String]
    # @return [String?]
    protected def active_process(stack_name : String)
      if(runners[stack_name]?)
        result = runners[stack_name].map do |key, value|
          key if value.active?
        end.compact
        result.first unless result.empty?
      end
    end

  end
end
