require 'active_support/inflector'

module Bookbinder
  module Commands
    module Naming
      def command_for?(test_command_name)
        command_name == test_command_name
      end

      def flag?
        command_name.match(/^--/)
      end

      def command_type
        if flag?
          'flag'
        else
          'command'
        end
      end

      private

      def command_name
        self.class.name.demodulize.underscore
      end
    end
  end
end
