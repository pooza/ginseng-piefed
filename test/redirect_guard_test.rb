module Ginseng
  module Piefed
    # PieFed へ出す要求のリダイレクトの扱い (#17)。
    #
    # ⚠⚠ **ガードの実装は `ginseng-core` にある**（`Ginseng::HTTP::RedirectGuard`）。
    # 判定そのもののテストはあちらが正本で、ここは**この gem の口に届いていること**を見る。
    # ⚠ 継ぎ目は `HTTParty.public_send`（`ginseng-fediverse` の同名のテストと同じ形）。
    #
    # 🔴🔴 **ガードが効いたかは、HTTParty に渡った `follow_redirects` では見ない
    # (pooza/ginseng-core#655)。** core 6.0.0 から既定の経路もリダイレクトを自前で追うので、
    # HTTParty には**常に** `follow_redirects: false` が渡る。⚠⚠ そのまま見ていると
    # **ガードを外しても緑**になる（実測: core 6.0.0 でガードを挿さなくしても 3 本が緑）。
    # ⚠ 代わりに `follows?` で、302 を返されたときに追ったかを見る。
    class RedirectGuardTest < TestCase
      class FakeResponse
        attr_reader :code, :headers, :body

        def initialize(code, location = nil)
          @code = code
          @headers = location ? {'location' => location} : {}
          @body = ''
        end

        # ⚠ `login` は `parsed_response` から JWT を読む（`HTTParty::Response` と同じ口を持たせる）。
        def parsed_response
          return {'jwt' => 'jwt', 'communities' => [], 'next_page' => nil}
        end

        def [](key)
          return parsed_response[key]
        end
      end

      METHODS = [:get, :post].freeze

      # `follows?` のリダイレクト先。
      REDIRECT_TARGET = 'https://elsewhere.example.com/moved'.freeze

      # ⚠ 利用側を模した HTTP。**ガードを知らない**（`Ginseng::HTTP` の子）。
      class ForeignHTTP < Ginseng::HTTP; end

      class ForeignService < Service
        def http_class
          return ForeignHTTP
        end
      end

      def setup
        require 'httparty'
        @code = 200
        @captured = []
        @originals = METHODS.to_h {|method| [method, HTTParty.method(method)]}
        captured = @captured
        owner = self
        METHODS.each do |method|
          HTTParty.define_singleton_method(method) do |uri, options = {}, &_block|
            captured.push([method, uri, options])
            next owner.respond(uri, options)
          end
        end
      end

      def teardown
        super
        @originals.each {|method, impl| HTTParty.define_singleton_method(method, impl)}
      end

      attr_accessor :code

      # ⚠⚠ **`follows?` の中では、1 段目が 302 を返す。** HTTParty に追わせる形（core 5.x の
      # 既定の経路）では、`follow_redirects` が偽でなければ **HTTParty が追い切った**ものとして
      # 200 を返す。自前で追う形（core 6.0.0）では、`Location` の先へ来た 2 回目に 200 を返す。
      # ⚠ どちらの版でも、追わないと決めた要求だけが 302 を受け取り、ガードが `GatewayError` にする。
      def respond(uri, options)
        return FakeResponse.new(code) unless @redirecting
        return FakeResponse.new(200) if uri.to_s == REDIRECT_TARGET
        follow = options.key?(:follow_redirects) ? options[:follow_redirects] : true
        return FakeResponse.new(200) if follow
        return FakeResponse.new(302, REDIRECT_TARGET)
      end

      # 🔴🔴 **利用側が `http_class` を差し替えていても届くこと。** ⚠⚠ 継承で足すと
      # 継承経路に現れない（pooza/ginseng-fediverse#285 で 3/3 に届いていなかった）。
      def test_guard_reaches_a_replaced_http_class
        http = create.http

        assert_instance_of(ForeignHTTP, http, '利用側の HTTP が使われていること')
        assert_includes(http.singleton_class.ancestors, Ginseng::HTTP::RedirectGuard)
      end

      # 🔴 `clip` は `Authorization: Bearer` と本文を載せる。
      def test_clip_does_not_follow_redirects
        assert_false(follows? {create(jwt: 'jwt').clip(name: '件名')})
        assert_equal(:post, @captured.first.first)
        assert_equal('Bearer jwt', first_options[:headers]['Authorization'])
      end

      # 🔴 `login` はヘッダに資格情報を持たないが、**パスワードを本文に載せる**。
      def test_login_does_not_follow_redirects
        assert_false(follows? {create.login})
        assert_equal('secret', JSON.parse(first_options[:body])['password'])
      end

      # ⚠ `communities` は GET だが `Authorization` を持つ。
      def test_communities_does_not_follow_redirects
        assert_false(follows? {create(jwt: 'jwt').communities})
        assert_equal(:get, @captured.first.first)
      end

      # 🔴🔴 **3xx を黙って返さない。** 応答を見ない利用側で「投稿されていないのに成功」
      # になる（`tomato-shrieker` の `PiefedShrieker` は `clip` の返り値をそのまま返す）。
      def test_redirect_is_an_error
        self.code = 307

        error = assert_raise(Ginseng::GatewayError) {create(jwt: 'jwt').clip(name: '件名')}

        assert_equal(307, error.response.code, '応答を添えること')
      end

      # ⚠ `login` は失敗を `AuthError` に包む。**JWT を拾ったことにしない。**
      def test_redirect_on_login_is_an_auth_error
        self.code = 302
        service = create

        assert_raise(Ginseng::AuthError) {service.login}
        assert_nil(service.instance_variable_get(:@jwt))
      end

      private

      def create(jwt: nil)
        service = ForeignService.new(
          url: 'https://piefed.example.com/c/hoge',
          community: 1,
          user: 'user',
          password: 'secret',
        )
        service.instance_variable_set(:@jwt, jwt) if jwt
        return service
      end

      # 直前の `follows?` の 1 段目で HTTParty に渡った options。
      def first_options
        return @captured.first.last
      end

      # 1 段目が 302 を返したときに追ったか。⚠ 追わないと決めた要求は、ガードが `GatewayError` にする。
      # ⚠ `login` はそれを `AuthError` に包む（`test_redirect_on_login_is_an_auth_error`）。
      def follows?
        @captured.clear
        @redirecting = true
        yield
        return true
      rescue Ginseng::AuthError
        return false
      rescue Ginseng::GatewayError => e
        raise unless e.response&.code == 302
        return false
      ensure
        @redirecting = false
      end
    end
  end
end
