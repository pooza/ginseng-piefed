module Ginseng
  module Piefed
    class Environment < Ginseng::Environment
      def self.name
        return File.basename(dir)
      end

      def self.dir
        return Ginseng::Piefed.dir
      end
    end
  end
end
