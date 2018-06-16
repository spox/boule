module Boule
  module Utils
    # Process runner
    class Runner

      include Utils::Logger

      record Status, id : String, type : Symbol, active : Bool, started : Time, exit_code : Int32?

      property id = UUID.random.to_s.as(String)
      property type : Symbol
      property directory : String
      property raw_process : Process?
      property command : String | Array(String)
      property stdout : IO
      property stderr : IO
      property stdout_writer : IO
      property stderr_writer : IO
      property raw_start_time : Time?
      property io_handlers = [] of Proc(String, Symbol, Runner, Nil)
      property complete_handlers = [] of Proc(Process::Status, Runner, Nil)

      @status_result : Concurrent::Future(Process::Status)?
      @status : Process::Status?

      def initialize(@type : Symbol, @command : String | Array(String), @directory = ".")
        @stdout, @stdout_writer = IO.pipe(write_blocking: true)
        @stderr, @stderr_writer = IO.pipe(write_blocking: true)
      end

      # Add a custom handler for processing stderr and stdout
      # output from the raw process
      def on_io(&block : String, Symbol, Runner -> Nil)
        io_handlers << block
      end

      # Add a custom handler for performing action when process is complete
      def on_complete(&block : Process::Status, Runner -> Nil)
        complete_handlers << block
      end

      # Underlying process
      def process : Process
        current_process = @raw_process
        if(current_process.nil?)
          raise Error::Util::Runner::ProcessNotStarted.new
        else
          current_process
        end
      end

      # Time process was started
      def start_time : Time
        current_start_time = @raw_start_time
        if(current_start_time.nil?)
          raise Error::Util::Runner::ProcessNotStarted.new
        else
          current_start_time
        end
      end

      # Start the process
      def run!
        current_process = @raw_process
        if(current_process.nil?)
          if(command.is_a?(Array))
            cmd_split = command.as(Array(String))
          else
            cmd_split = command.as(String).split(" ")
          end
          @raw_start_time = Time.now
          @raw_process = Process.new(
            command: cmd_split.first,
            args: cmd_split[1, cmd_split.size],
            output: stdout_writer,
            error: stderr_writer,
            chdir: directory
          )
          debug "{#{id}} New process running: `#{cmd_split}`"
          @status_result = future do
            @status = process.wait
          end
          unless(io_handlers.empty?)
            {:stdout => stdout, :stderr => stderr}.each do |io_name, io|
              spawn do
                while(line = io.gets)
                  line = line.chomp
                  next if line.empty?
                  debug "{#{id}} #{io_name} -> #{line}"
                  io_handlers.each do |handler|
                    handler.call(line, io_name, self)
                  end
                end
              end
            end
          end
          unless(complete_handlers.empty?)
            spawn do
              result_status = result(true)
              debug "{#{id}} Running complete handlers. Exit status: #{result_status.as(Process::Status).exit_status}"
              if(result_status)
                stdout_writer.close
                stderr_writer.close
                complete_handlers.each do |handler|
                  handler.call(result_status, self)
                end
              end
            end
          end
        else
          raise Error::Util::Runner::ProcessAlreadyStarted.new
        end
      end

      # Check if this runner is actively executing
      #
      # @return [Bool]
      def active? : Bool
        begin
          process.exists? && !process.terminated?
        rescue Error::Util::Runner::ProcessNotStarted
          false
        end
      end

      # Fetch and cache result of process
      #
      # @param wait [Bool] wait for process to finish if active
      # @return [Process::Status?]
      def result(wait=false) : Process::Status?
        if(wait)
          result_future = @status_result
          if(result_future.nil?)
            raise Error::Util::Runner::ProcessNotStarted.new
          else
            result_future.get
          end
        else
          @status
        end
      end

      # @return [Status] status information of process
      def status : Status
        process_status = result
        if(process_status)
          exit_code = process_status.exit_status
        else
          exit_code = nil
        end
        Status.new(id, type, active?, start_time, exit_code)
      end

    end
  end
end
