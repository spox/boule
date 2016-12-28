require "./spec_helper"

Spec2.describe Boule do
  describe Boule::Rest::Terraform do
    let(:terraform_directory) do
      dir = Tempfile.new("boule")
      dir.delete
      dir.path
    end

    let(:initial_stacks) do
      ("A".."D").to_a.map do |suffix|
        "stack_#{suffix}"
      end
    end

    let(:run_args) do
      {} of String => String | Bool
    end

    before do
      # Create a custom temporary directory store for testing
      Boule.configuration.set("terraform", "directory", value: terraform_directory)
      initial_stacks.each do |stack_name|
        Dir.mkdir_p(File.join(terraform_directory, stack_name))
      end
      Boule.run!(run_args)
    end

    after do
      if(File.directory?(terraform_directory))
        FileUtils.rm_r(terraform_directory)
      end
      Boule.stop!
    end

    context "listing stacks" do

      before do
        get "/terraform/stacks"
      end

      it "provides stack entries within store directory" do
        expect(response.body).to eq(["stack_A", "stack_B", "stack_C", "stack_D"].to_json)
      end

      it "sets content type header as JSON" do
        expect(response.headers["Content-Type"]?.to_s).to match(/json/)
      end

      context "when no stacks exist" do

        let(:initial_stacks){ [] of String }

        it "returns an empty result" do
          expect(response.body).to eq("[]")
        end
      end
    end

    context "stack information" do

      context "when stack exists" do

        it "provides information about requested stack" do
          get "/terraform/stack/stack_A"
          expect(response.body).to match(/stack_A/)
        end
      end

      context "when stack does not exist" do

        it "provides error message and 404 status code" do
          get "/terraform/stack/not_a_stack"
          expect(response.body).to match(/unknown/)
          expect(response.status_code).to eq(404)
        end
      end
    end

    context "stack apply" do

      context "when stack exists" do
      end
    end
  end
end
