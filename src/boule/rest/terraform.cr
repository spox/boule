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

      # Get list of stacks
      get "/terraform/stacks" do |env|
        result = Boule.terraform.stacks
        debug "Generated stack listing: #{result}"
        {"stacks" => result}.to_json
      end

      # Get information of stack
      get "/terraform/stack/:name" do |env|
        begin
          stack_name = env.params.url["name"]
          result = Boule.terraform.info(stack_name)
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
        if(Boule.terraform.exists?(stack_name))
          error_result(405, "stack already exists")
        else
          if(env.params.json["template"]?)
            template = env.params.json["template"].as(String)
            if(env.params.json["parameters"]?)
              parameters = env.params.json["parameters"].as(Hash(String, JSON::Type))
            else
              parameters = {} of String => JSON::Type
            end
            result = Boule.terraform.apply(stack_name, template, parameters)
            output = {} of String => JSON::Type
            output["id"] = result.id
            output["active"] = result.active
            output["started"] = result.started.epoch_ms
            {"stack" => output}.to_json
          else
            error_result(412, "template is required")
          end
        end
      end

      # Update stack
      put "/terraform/stack/:name" do |env|
        stack_name = env.params.url["name"]
        unless(Boule.terraform.exists?(stack_name))
          error_result(405, "stack does not exist")
        else
          if(env.params.json["template"]?)
            template = env.params.json["template"].as(String)
            if(env.params.json["parameters"]?)
              parameters = env.params.json["parameters"].as(Hash(String, JSON::Type))
            else
              parameters = {} of String => JSON::Type
            end
            result = Boule.terraform.apply(stack_name, template, parameters)
            output = {} of String => JSON::Type
            output["id"] = result.id
            output["active"] = result.active
            output["started"] = result.started.epoch_ms
            {"stack" => output}.to_json
          else
            error_result(412, "template is required")
          end
        end
      end

      # Delete stack
      delete "/terraform/stack/:name" do |env|
        stack_name = env.params.url["name"]
        unless(Boule.terraform.exists?(stack_name))
          error_result(405, "stack does not exist")
        else
          result = Boule.terraform.destroy(stack_name)
          output = {} of String => JSON::Type
          output["id"] = result.id
          output["active"] = result.active
          output["started"] = result.started.epoch_ms
          output.to_json
        end
      end

      # Get events for stack
      get "/terraform/events/:name" do |env|
        stack_name = env.params.url["name"]
        unless(Boule.terraform.exists?(stack_name))
          error_result(405, "stack does not exist")
        else
          result = Boule.terraform.events(stack_name)
          {"events" => result}.to_json
        end
      end

      # Get resources for stack
      get "/terraform/resources/:name" do |env|
        stack_name = env.params.url["name"]
        unless(Boule.terraform.exists?(stack_name))
          error_result(404, "unknown stack")
        else
          debug "Fetching resources for `#{stack_name}`"
          result = Boule.terraform.resources(stack_name)
          debug "Stack resources for `#{stack_name}` - #{result}"
          {"resources" => result}.to_json
        end
      end

      # Get template for stack
      get "/terraform/template/:name" do |env|
        stack_name = env.params.url["name"]
        unless(Boule.terraform.exists?(stack_name))
          error_result(404, "unknown stack")
        else
          debug "Fetching template for `#{stack_name}`"
          result = Boule.terraform.template(stack_name)
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
          result = Boule.terraform.validate(template)
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
