module Ginseng
  module Piefed
    class ServiceTest < TestCase
      class StubHTTP < Ginseng::HTTP; end

      module StubPackage
        include Package

        def http_class
          return StubHTTP
        end
      end

      class StubService < Service
        include StubPackage
      end

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

      # ⚠⚠ **既定を literal で固定する (#15)。** `assert_equal(http_class, ...)` は
      # **両辺が同じ `http_class` から出る**ので、差し替えても緑のまま
      # （リリース前レビューの観点③。実測で別クラスへ替えても 0 failures だった）。
      def test_http
        assert_instance_of(Ginseng::HTTP, @service.http)
      end

      # ⚠⚠ **利用側が `http_class` を差し替えた形で測る (#15)。**
      # 🔴 既定では `http_class` も直書きの `HTTP` も同じ `Ginseng::HTTP` に解決される
      # ので、**素の `Service` を見ているだけでは直書きに気づけない**。
      # ⚠ 形は「利用側が `include Package` を書いたとき」— 🔴 `tomato-shrieker` の
      # `PiefedShrieker` は**まだ書いていない**（他の Shrieker 5 本は書いている）。
      def test_http_class_is_honored
        assert_instance_of(StubHTTP, StubService.new(url: "https://#{@host}/c/hoge").http)
      end
    end
  end
end
