module Ginseng
  module Piefed
    class PackageTest < TestCase
      def test_name
        assert_equal('ginseng-piefed', Package.name)
      end

      def test_version
        assert_kind_of(String, Package.version)
        assert_equal(Config.instance['/package/version'], Package.version)
      end

      def test_url
        assert_equal(Config.instance['/package/url'], Package.url)
      end

      def test_full_name
        assert_equal("#{Package.name} #{Package.version}", Package.full_name)
      end
    end
  end
end
