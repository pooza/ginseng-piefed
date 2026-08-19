module Ginseng
  module Piefed
    class ServiceTest < TestCase
      def setup
        @host = Config.instance['/piefed/hosts/default']
        @service = Service.new(url: "https://#{@host}/c/hoge")
      end

      # ⚠ ここでは通信しないものだけを見る。login / clip / communities は
      # サーバーと資格情報が要るので CI では回せない。
      def test_api_version
        assert_equal(Config.instance['/piefed/api/version'], @service.api_version)
      end

      def test_uri
        assert_equal(@host, @service.uri.host)
        assert_equal('https', @service.uri.scheme)
      end

      def test_http
        assert_kind_of(Ginseng::HTTP, @service.http)
      end
    end
  end
end
