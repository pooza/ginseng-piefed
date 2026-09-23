module Ginseng
  module Piefed
    module Package
      def environment_class
        return Environment
      end

      def package_class
        return Package
      end

      def config_class
        return Config
      end

      def logger_class
        return Logger
      end

      # ⚠⚠ **いま `Ginseng::Piefed::HTTP` は無いので `Ginseng::HTTP` に解決される。**
      # 🔴 この gem に `HTTP` を足すと、**ここの既定が黙って動く** — `Service` が
      # 使う HTTP が変わるので、足すときは `service_test.rb` の `test_http`
      # （既定を literal で固定してある）を見てから決めること (#15)。
      def http_class
        return HTTP
      end

      def self.name
        return 'ginseng-piefed'
      end

      def self.version
        return Config.instance['/package/version']
      end

      def self.url
        return Config.instance['/package/url']
      end

      def self.full_name
        return "#{name} #{version}"
      end
    end
  end
end
