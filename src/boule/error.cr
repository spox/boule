module Boule
  class Error < Exception

    class System < Error
      EXIT_CODE = 10
      class NotReady < System; end
      class AbstractNotImplemented < System; end
    end

    class Terraform < Error
      EXIT_CODE = 20
      class UnknownStack < Terraform; end
      class StackBusy < Terraform; end
      class InvalidExecutable < Terraform; end
    end

    class Util < Error
      EXIT_CODE = 30
      class Runner < Util
        class ProcessAlreadyStarted < Runner; end
        class ProcessNotStarted < Runner; end
      end
    end

  end
end
