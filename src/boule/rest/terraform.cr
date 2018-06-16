module Boule
  module Rest
    module Terraform

      extend Utils::Logger

      macro error_result(code, message)
        env.response.print({"error" => {"code" => {{code.id}}, "message" => {{message}}}}.to_json)
        env.response.status_code = {{code.id}}
      end

      before_all do |env|
        if(env.request.path.starts_with?("/terraform/"))
          env.response.content_type = "application/json"
        end
      end

      def self.tf_stack(name : String)
        Boule::Terraform::Stack.new(
          container: Boule.configuration.get("terraform", "directory", type: :string).to_s,
          scrub_destroyed: !!Boule.configuration.get("terraform", "scrub_destroyed", type: :bool),
          name: name
        )
      end

      def self.tf_stack(name : String)
        yield(tf_stack(name))
      end

      # Get list of stacks
      get "/terraform/stacks" do |env|
        stack_names = Boule::Terraform::Stack.list(
          Boule.configuration.get("terraform", "directory", type: :string).to_s
        )
        result = stack_names.map do |stack_name|
          debug "Getting info for stack: #{stack_name}"
          tf_stack(stack_name).info
        end
        debug "Generated stack listing: #{result}"
        {"stacks" => result}.to_json
      end

      # Get information of stack
      get "/terraform/stack/:name" do |env|
        begin
          stack_name = env.params.url["name"]
          result = tf_stack(stack_name).info
          debug "Stack information for `#{stack_name}` - #{result}"
          {"stack" => result}.to_json
        rescue Error::Terraform::UnknownStack
          error_result(404, "unknown stack")
        end
      end

      # Create new stack
      # expects: :template, :parameters
      post "/terraform/stack/:name" do |env|
        stack_name = env.params.url["name"]
        if(tf_stack(stack_name).exists?)
          error_result(405, "stack already exists")
        else
          if(env.params.json["template"]?)
            template = env.params.json["template"].as(String)
            if(env.params.json["parameters"]?)
              parameters = env.params.json["parameters"].as(Hash(String, JSON::Type))
            else
              parameters = {} of String => JSON::Type
            end
            result = tf_stack(stack_name) do |stack|
              stack.save(template, parameters)
              stack.info
            end
            {"stack" => result}.to_json
          else
            error_result(412, "template is required")
          end
        end
      end

      # Update stack
      put "/terraform/stack/:name" do |env|
        stack_name = env.params.url["name"]
        unless(tf_stack(stack_name).exists?)
          error_result(405, "stack does not exist")
        else
          if(env.params.json["template"]?)
            template = env.params.json["template"].as(String)
            if(env.params.json["parameters"]?)
              parameters = env.params.json["parameters"].as(Hash(String, JSON::Type))
            else
              parameters = {} of String => JSON::Type
            end
            result = tf_stack(stack_name) do |stack|
              stack.save(template, parameters)
              stack.info
            end
            {"stack" => result}.to_json
          else
            error_result(412, "template is required")
          end
        end
      end

      # Delete stack
      delete "/terraform/stack/:name" do |env|
        stack_name = env.params.url["name"]
        unless(tf_stack(stack_name).exists?)
          error_result(404, "stack does not exist")
        else
          result = tf_stack(stack_name) do |stack|
            stack.destroy!
            stack.info
          end
          {"stack" => result}.to_json
        end
      end

      # Get events for stack
      get "/terraform/events/:name" do |env|
        stack_name = env.params.url["name"]
        unless(tf_stack(stack_name).exists?)
          error_result(405, "stack does not exist")
        else
          {"events" => tf_stack(stack_name).events}.to_json
        end
      end

      # Get resources for stack
      get "/terraform/resources/:name" do |env|
        stack_name = env.params.url["name"]
        unless(tf_stack(stack_name).exists?)
          error_result(404, "unknown stack")
        else
          debug "Fetching resources for `#{stack_name}`"
          result = tf_stack(stack_name).resources
          debug "Stack resources for `#{stack_name}` - #{result}"
          {"resources" => result}.to_json
        end
      end

      # Get template for stack
      get "/terraform/template/:name" do |env|
        stack_name = env.params.url["name"]
        unless(tf_stack(stack_name).exists?)
          error_result(404, "unknown stack")
        else
          debug "Fetching template for `#{stack_name}`"
          result = tf_stack(stack_name).template
          {"template" => result}.to_json
        end
      end

      # Validate template
      post "/terraform/validate" do |env|
        if(env.params.json["template"]?)
          template = env.params.json["template"]
          unless(template.is_a?(String))
            template = template.to_json
          end
          result = tf_stack(UUID.random.to_s).validate(template)
          if(result.empty?)
            {"valid" => true}.to_json
          else
            error_result(400, result)
          end
        else
          error_result(412, "template is required")
        end
      end
    end
  end
end
