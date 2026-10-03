module Ginseng
  module Piefed
    # PieFed へ出す要求のリダイレクトの扱い (#17)。
    #
    # ⚠⚠ **ガードの実装は `ginseng-core` にある**（`Ginseng::HTTP::RedirectGuard`）。
    # 判定そのもののテストはあちらが正本で、ここは**この gem の口に届いていること**を見る。
    # ⚠ 継ぎ目は `HTTParty.public_send`（`ginseng-fediverse` の同名のテストと同じ形）。
    class RedirectGuardTest < TestCase
      class FakeResponse
        attr_reader :code, :headers, :body

        def initialize(code)
          @code = code
          @headers = {}
          @body = ''
        end

        def [](key)
          return {'jwt' => 'jwt', 'communities' => [], 'next_page' => nil}[key]
        end
      end

      METHODS = [:get, :post].freeze

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
            next FakeResponse.new(owner.code)
          end
        end
      end

      def teardown
        super
        @originals.each {|method, impl| HTTParty.define_singleton_method(method, impl)}
      end

      attr_accessor :code

      # 🔴🔴 **利用側が `http_class` を差し替えていても届くこと。** ⚠⚠ 継承で足すと
      # 継承経路に現れない（pooza/ginseng-fediverse#285 で 3/3 に届いていなかった）。
      def test_guard_reaches_a_replaced_http_class
        http = create.http

        assert_instance_of(ForeignHTTP, http, '利用側の HTTP が使われていること')
        assert_includes(http.singleton_class.ancestors, Ginseng::HTTP::RedirectGuard)
      end

      # 🔴 `clip` は `Authorization: Bearer` と本文を載せる。
      def test_clip_does_not_follow_redirects
        create(jwt: 'jwt').clip(name: '件名')

        assert_equal(:post, @captured.last.first)
        assert_equal('Bearer jwt', options[:headers]['Authorization'])
        assert_false(options[:follow_redirects])
      end

      # 🔴 `login` はヘッダに資格情報を持たないが、**パスワードを本文に載せる**。
      def test_login_does_not_follow_redirects
        create.login

        assert_equal('secret', JSON.parse(options[:body])['password'])
        assert_false(options[:follow_redirects])
      end

      # ⚠ `communities` は GET だが `Authorization` を持つ。
      def test_communities_does_not_follow_redirects
        create(jwt: 'jwt').communities

        assert_equal(:get, @captured.last.first)
        assert_false(options[:follow_redirects])
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

      def options
        return @captured.last.last
      end
    end
  end
end
