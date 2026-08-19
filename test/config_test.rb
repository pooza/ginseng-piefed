module Ginseng
  module Piefed
    class ConfigTest < TestCase
      def setup
        @config = Config.instance
      end

      def test_api_version
        assert_kind_of(String, @config['/piefed/api/version'])
      end

      def test_default_host
        assert_kind_of(String, @config['/piefed/hosts/default'])
      end

      def test_community_types
        assert_kind_of(Array, @config['/piefed/community/types'])
        assert_includes(@config['/piefed/community/types'], 'Subscribed')
      end

      def test_subject_max_length
        assert_kind_of(Integer, @config['/piefed/subject/max_length'])
        assert_operator(0, :<, @config['/piefed/subject/max_length'])
      end
    end
  end
end
