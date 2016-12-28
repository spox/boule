require "./info"

module Boule
  class Terraform

    class Info::File < Info

      def self.load(path) : self
        file = File.join(path, "boule.json")
        if(File.exists?(path))
          self.from_json(File.read(path))
        else
          self.new(path)
        end
      end

      protected def internal_load

      end

      protected def internal_save
      end

      def info_path
        File.join(directory, "boule.json")
      end

    end

  end
end
