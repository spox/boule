require "file_utils"
module Boule
  module Terraform
    class Stack

      class Error < Exception
        class Busy < Error; end
        class NotFound < Error; end
        class CommandFailed < Error; end
        class ValidateError < Error; end
      end

      class Action

        include Utils::Logger

        property id = SecureRandom.uuid
        property command : String
        property options : Hash(Symbol, String)
        property waiter : Concurrent::Future(Process::Status)?

        @stderr : IO | Symbol
        @stderr_writer : IO
        @stdout : IO | Symbol
        @stdout_writer : IO
        @cached_output = {stdout: IO::Memory.new(""), stderr: IO::Memory.new("")}
        @io_callbacks = [] of Proc(String, Symbol, Nil)
        @complete_callbacks = [] of Proc(Process::Status, Action, Nil)
        @start_callbacks = [] of Proc(Action, Nil)

        @managed = false
        @managed_complete = Channel(Nil).new(1)
        @status_complete = Channel(Nil).new(1)

        @raw_process : Process?
        @raw_status : Process::Status?

        def initialize(@command : String, @options = {} of Symbol => String)
          @stderr, @stderr_writer = IO.pipe(write_blocking: true)
          @stdout, @stdout_writer = IO.pipe(write_blocking: true)
          debug "Created new action instance `#{@command}`"
          if(@options.delete(:auto_start))
            debug "Auto starting action via options `#{@command}`"
            start!
          end
        end

        def start!
          debug "Starting stack action process `#{command}`"
          Boule::Terraform::Stack.register_action(self)
          cmd = command.split(" ")
          r_process = Process.new(
            command: cmd.first,
            args: cmd[1, cmd.size],
            output: @stdout_writer,
            error: @stderr_writer,
            chdir: @options.fetch(:chdir, ".")
          )
          @raw_process = r_process
          debug "Action process has started `#{@command}`"
          spawn do
            debug "Watching for process completion `#{@command}`"
            @raw_status = r_process.wait
            debug "Process completion detected! Closing notification channels. `#{@command}`"
            @status_complete.send(nil)
            @status_complete.close
          end
          debug "Running action start callbacks. `#{@command}`"
          @start_callbacks.each do |callback|
            callback.call(self)
          end
          unless(@io_callbacks.empty? && @complete_callbacks.empty?)
            debug "Setting up process management to handle callbacks `#{@command}`"
            manage_process!
          end
          true
        end

        def complete!
          r_process = @raw_process
          start! unless r_process
          if(@managed)
            begin
              debug "Waiting for managed action to complete. `#{@command}`"
              @managed_complete.receive
              debug "Managed action has notified completion. `#{@command}`"
            rescue Channel::ClosedError
              debug "Managed action has notified completion via closed channel. `#{@command}`"
            end
          end
          begin
            debug "Waiting for process status completion. `#{@command}`"
            @status_complete.receive
            debug "Action has notified process status completion. `#{@command}`"
          rescue Channel::ClosedError
            debug "Action has notified process status completion via closed channel. `#{@command}`"
          end
          result = @raw_status.as(Process::Status)
          Boule::Terraform::Stack.deregister_action(self)
          result
        end

        def stderr : IO
          c_stderr = @stderr
          if(c_stderr == :managed_io)
            @cached_output[:stderr]
          else
            @stderr.as(IO)
          end
        end

        def stdout : IO
          c_stdout = @stdout
          if(c_stdout == :managed_io)
            @cached_output[:stdout]
          else
            @stdout.as(IO)
          end
        end

        def on_io(&block : String, Symbol -> Nil)
          @io_callbacks << block
          self
        end

        def on_complete(&block : Process::Status, Action -> Nil)
          @complete_callbacks << block
          self
        end

        def on_start(&block : Action -> Nil)
          @start_callbacks << block
          self
        end

        def manage_process!
          unless(@managed)
            @managed = true
            debug "Placing action under managed state. `#{@command}`"
            unless(@io_callbacks.empty?)
              debug "Starting process IO management. `#{@command}`"
              io_stdout = @stdout.as(IO)
              io_stderr = @stderr.as(IO)
              @stdout = @stderr = :managed_io
              {:stdout => io_stdout, :stderr => io_stderr}.each do |type, io|
                spawn do
                  while(alive? && (line = io.gets))
                    line = line.chomp
                    next if line.empty?
                    debug "Received output of `#{type.inspect}` -> #{line}"
                    @io_callbacks.each do |callback|
                      callback.call(line, type)
                    end
                  end
                end
              end
            end
            unless(@complete_callbacks.empty?)
              spawn do
                begin
                  debug "Waiting for process status completion (complete callbacks). `#{@command}`"
                  @status_complete.receive
                  debug "Action has notified process status completion (complete callbacks). `#{@command}`"
                rescue Channel::ClosedError
                  debug "Action has notified process status completion via closed channel (complete callbacks). `#{@command}`"
                end
                status = @raw_status.as(Process::Status)
                @stdout_writer.close
                @stderr_writer.close
                @complete_callbacks.each do |callback|
                  debug "Running complete callback #{callback}. `#{@command}`"
                  callback.call(status, self)
                end
                @managed_complete.send(nil)
                @managed_complete.close
                Boule::Terraform::Stack.deregister_action(self)
              end
            end
            true
          else
            false
          end
        end

        def alive?
          c_process = @raw_process
          c_process && c_process.exists? && !c_process.terminated?
        end

      end

      @@running_actions = [] of Action

      def self.register_action(action : Action)
        unless(@@running_actions.includes?(action))
          @@running_actions << action
        end
        nil
      end

      def self.deregister_action(action : Action)
        @@running_actions.delete(action)
        nil
      end

      def self.cleanup_actions!
        @@running_actions.map(&.complete!)
        nil
      end

      def self.list(container : String)
        if(container.to_s.empty?)
          raise ArgumentError.new "Container directory must be set!"
        end
        if(File.directory?(container))
          Dir.new(container).map do |entry|
            next if entry.starts_with?(".")
            entry if File.directory?(File.join(container, entry))
          end.compact
        else
          [] of String
        end
      end

      property actions = [] of Action
      property directory : String
      property container : String
      property name : String
      property bin : String
      property scrub_destroyed : Bool

      @lock_file : File?

      def initialize(@name : String, @container : String, @bin : String = "terraform", @scrub_destroyed : Bool = false)
        @directory = File.join(@container, @name)
      end

      def exists?
        File.directory?(directory)
      end

      def active?
        actions.any?(&.alive?)
      end

      def save(template : String, parameters : Hash(String, JSON::Type))
        type = exists? ? "update" : "create"
        lock_stack
        write_file(tf_path, template)
        write_file(tfvars_path, parameters.to_json)
        action = run_action("apply")
        store_events(action)
        action.on_start do |_|
          update_info do |info|
            info["state"] = "#{type}_in_progress"
            info
          end
        end.on_complete do |status, this_action|
          update_info do |info|
            if(type == "create")
              info["created_at"] = Time.now.epoch_ms
            end
            info["updated_at"] = Time.now.epoch_ms
            info["state"] = status.success? ? "#{type}_complete" : "#{type}_failed"
            info
          end
          unlock_stack
        end
        action.start!
        true
      end

      def resources
        must_exist do
          if(has_state?)
            action = run_action("state list")
            action.complete!
            successful_action(action) do
              resource_lines = action.stdout.gets_to_end.split("\n").map do |line|
                line if line.match(/^[^\s]/)
              end.compact
              resource_lines.map do |line|
                parts = line.split(".")
                resource_info = {
                  "type" => parts[0],
                  "name" => parts[1],
                  "status" => "UPDATE_COMPLETE"
                } of String => JSON::Type
                action = run_action("state show #{line}")
                action.complete!
                successful_action(action) do
                  info = {} of String => JSON::Type
                  action.stdout.gets_to_end.split("\n").each do |line|
                    parts = line.split("=").map(&.strip)
                    next if parts.size != 2
                    info[parts[0]] = parts[1]
                  end
                  resource_info["physical_id"] = info["id"] if info["id"]?
                end
                resource_info
              end
            end
          else
            [] of Hash(String, JSON::Type)
          end
        end
      end

      def events
        must_exist do
          c_info = load_info
          if(c_info["events"]?)
            c_events = c_info["events"].as(Array(JSON::Type))
          else
            c_events = [] of JSON::Type
          end
          c_events.map do |_item|
            item = _item.as(Hash(String, JSON::Type))
            parts = item["resource_name"].to_s.split(".")
            item["resource_name"] = parts[1]
            item["resource_type"] = parts[0]
            item
          end
        end
      end

      def outputs
        must_exist do
          result = {} of String => JSON::Type
          if(has_state?)
            action = run_action("output -json")
            action.complete!
            successful_action(action) do
              c_out = JSON.parse(action.stdout.gets_to_end).as_h.as(Hash(String, JSON::Type))
              c_out.each do |key, info|
                c_info = info.as(Hash(String, JSON::Type))
                result[key] = c_info["value"]
              end
            end
          end
          result
        end
      end

      def template
        must_exist do
          if(File.exists?(tf_path))
            File.read(tf_path)
          else
            "{}"
          end
        end
      end

      def info
        must_exist do
          stack_data = load_info
          {
            "id" => name,
            "name" => name,
            "state" => stack_data["state"].to_s,
            "status" => stack_data["state"].to_s.upcase,
            "updated_time" => stack_data.fetch("updated_at", nil),
            "creation_time" => stack_data.fetch("created_at", nil),
            "outputs" => outputs
          }
        end
      end

      def validate(template : String)
        errors = [] of String
        tmp_file = Tempfile.new("boule")
        tmp_file.delete
        root_path = tmp_file.path
        Dir.mkdir_p(root_path, 500)
        template_path = File.join(root_path, "main.tf")
        File.write(template_path, template)
        action = run_action("validate")
        action.options[:chdir] = root_path
        action.on_io do |line, type|
          if(line.starts_with?("*"))
            errors << line
          end
        end.on_complete do |_|
          FileUtils.rm_r(root_path)
        end
        action.complete!
        errors
      end

      def destroy!
        must_exist do
          lock_stack
          action = run_action("destroy -force")
          store_events(action)
          action.on_start do |_|
            update_info do |info|
              info["state"] = "delete_in_progress"
              info
            end
          end.on_complete do |*_|
            unlock_stack
          end.on_complete do |result, _|
            unless(result.success?)
              update_info do |info|
                info["state"] = "delete_failed"
                info
              end
            else
              update_info do |info|
                info["state"] = "delete_complete"
                info
              end
              FileUtils.rm_rf(directory) if scrub_destroyed
            end
          end
          action.start!
        end
        true
      end

      protected def run_action(cmd : String, auto_start=false)
        action = Action.new("#{bin} #{cmd} -no-color", {:chdir => directory})
        action.on_start do |this_action|
          actions << this_action
        end.on_complete do |_, this_action|
          actions.delete(this_action)
        end
        action.start! if auto_start
        action
      end

      protected def must_exist(lock=false)
        if(exists?)
          if(lock)
            lock_stack do
              yield
            end
          else
            yield
          end
        else
          raise Error::NotFound.new "Stack does not exist `#{name}`"
        end
      end

      protected def lock_stack
        Dir.mkdir_p(directory)
        lck = File.open(lock_path, "w+")
        @lock_file = lck
        begin
          lck.flock_exclusive(false)
          true
        rescue Errno #::EWOULDBLOCK
          raise Error::Busy.new "Failed to aquire process lock for `#{name}`. Stack busy."
        end
      end

      protected def lock_stack
        lock_stack
        result = yield
        unlock_stack
        result
      end

      protected def unlock_stack
        c_lck = @lock_file
        if(c_lck)
          c_lck.flock_unlock
          @lock_file = nil
          true
        else
          false
        end
      end

      protected def tf_path
        File.join(directory, "main.tf")
      end

      protected def tfvars_path
        File.join(directory, "terraform.tfvars")
      end

      protected def tfstate_path
        File.join(directory, "terraform.tfstate")
      end

      protected def info_path
        File.join(directory, ".info.json")
      end

      protected def lock_path
        File.join(directory, ".lck")
      end

      protected def has_state?
        File.exists?(tfstate_path)
      end

      protected def load_info
        if(File.exists?(info_path))
          result = JSON.parse(File.read(info_path)).as_h.as(Hash(String, JSON::Type))
        else
          result = {} of String => JSON::Type
        end
        result["created_at"] = Time.now.epoch_ms unless result["created_at"]?
        result["state"] = "unknown" unless result["state"]?
        result
      end

      protected def update_info
        result = yield(load_info)
        write_file(info_path, result.to_json)
        true
      end

      protected def successful_action(action)
        status = action.complete!
        unless(status.success?)
          raise Error::CommandFailed.new "Command failed `#{action.command}` - #{action.stderr.gets_to_end}"
        else
          yield
        end
      end

      protected def store_events(action)
        action.on_io do |line, type|
          result = line.match(/^(\*\s+)?(?<name>[^\s]+): (?<status>.+)$/)
          if(result)
            resource_name = result["name"]
            resource_status = result["status"]
            event = {
              "timestamp" => Time.now.epoch_ms,
              "resource_name" => resource_name,
              "resource_status" => resource_status,
              "id" => SecureRandom.uuid
            } of String => JSON::Type
            update_info do |info|
              if(info["events"]?)
                c_events = info["events"].as(Array(JSON::Type))
              else
                c_events = [] of JSON::Type
              end
              c_events.unshift(event)
              info["events"] = c_events.as(JSON::Type)
              info
            end
          end
        end
      end

      protected def write_file(path, contents : String)
        tmp_file = Tempfile.new("boule")
        tmp_file.print(contents.to_s)
        tmp_file.close
        FileUtils.mv(tmp_file.path, path)
        true
      end

      protected def write_file(path)
        tmp_file = Tempfile.new("boule")
        yield(tmp_file)
        tmp_file.close
        FileUtils.mv(tmp_file.path, path)
        true
      end

    end
  end
end
