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

      # ⚠ 実際の PieFed には繋がない。login / clip / communities は HTTP の `post` / `get` を
      # 差し替えて測る（サーバーと資格情報が要るので CI では回せない）。
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

      # 🔴 **並んだスレッドがそれぞれログインしない (#32)。**
      # ⚠ 通信しない形で測る — HTTP の `post` を、遅い応答に差し替える。
      def test_login_is_done_once_across_threads
        service = Service.new(url: "https://#{@host}/c/hoge", user: 'user', password: 'secret')
        calls = Queue.new
        service.http.define_singleton_method(:post) do |*|
          calls.push(true)
          sleep(0.1)
          next {'jwt' => 'jwt'}
        end
        Array.new(4) {Thread.new {service.login}}.each(&:join)

        assert_equal(1, calls.size)
        assert_equal('jwt', service.instance_variable_get(:@jwt))
      end

      # 🔴 **失敗しても、待っていたスレッドはログインし直さない (#36)。**
      def test_login_failure_is_shared_across_threads
        [
          proc {raise Ginseng::GatewayError, 'Bad response 429'},
          proc {{}},
          proc {{'jwt' => ''}},
          proc {{'jwt' => 123}},
        ].each do |reply|
          service, calls = stub_login(reply)
          results = Array.new(4) {Thread.new {login_result(service)}}.map(&:value)

          assert_equal(1, calls.size)
          assert(results.all?(Ginseng::AuthError))
          assert_nil(service.instance_variable_get(:@jwt))
        end
      end

      # ⚠ 待ち始める前に終わった失敗は上げ直さない。次の呼び出しはログインし直す。
      def test_login_retries_after_failure
        service, calls = stub_login(proc {raise Ginseng::GatewayError, 'Bad response 503'})

        2.times {assert_kind_of(Ginseng::AuthError, login_result(service))}

        assert_equal(2, calls.size)
      end

      # 🔴 **JSON でない応答の本文から JWT を読まない (#30)。** `HTTParty::Response#[]` は
      # 中身へ委譲するので、文字列の本文では `String#[]` になる。
      def test_login_rejects_non_json_response
        body = '<html>login with jwt</html>'
        request = HTTParty::Request.new(Net::HTTP::Post, 'https://piefed.example/')
        response = HTTParty::Response.new(request, Net::HTTPOK.new('1.1', '200', 'OK'), -> {body}, body:)
        service, = stub_login(proc {response})

        assert_kind_of(Ginseng::AuthError, login_result(service))
        assert_nil(service.instance_variable_get(:@jwt))
      end

      # 🔴 **壊れた JSON の本文を例外に載せない。** `JSON::ParserError` は入力を含む。
      def test_login_hides_unreadable_response
        body = '{"jwt": "JWT-SECRET", broken'
        request = HTTParty::Request.new(Net::HTTP::Post, 'https://piefed.example/', format: :json)
        raw = Net::HTTPOK.new('1.1', '200', 'OK')
        raw['content-type'] = 'application/json'
        response = HTTParty::Response.new(request, raw, -> {HTTParty::Parser.call(body, :json)}, body:)
        service, = stub_login(proc {response})
        error = login_result(service)

        assert_kind_of(Ginseng::AuthError, error)
        refute_includes(error.message, 'JWT-SECRET')
      end

      # ⚠⚠ **中断された試行のあと、待っていた側は前の失敗を上げ直さない。**
      # 中断（`Exception` 系）は `rescue` を通らず、番号だけが進む。
      def test_login_after_interrupted_attempt
        interrupt = Class.new(Exception) # rubocop:disable Lint/InheritException
        replies = Queue.new
        replies.push(proc {raise Ginseng::GatewayError, 'Bad response 503'})
        replies.push(proc {raise interrupt})
        replies.push(proc {{'jwt' => 'jwt'}})
        service, calls = stub_login(proc {replies.pop.call})

        assert_kind_of(Ginseng::AuthError, login_result(service))
        owner = Thread.new do
          service.login
        rescue interrupt
          :interrupted
        end
        sleep(0.03)
        waiter = Thread.new {login_result(service)}

        assert_equal(:interrupted, owner.value)
        assert_equal(:ok, waiter.value)
        assert_equal(3, calls.size)
      end

      # 🔴 **資格情報を出さない (#35)。** 既定の `inspect` / `as_json` は ivar を並べる。
      def test_inspect_and_json_hide_credentials
        service = Service.new(url: "https://#{@host}/c/hoge", user: 'user', password: 'pw-SECRET')
        service.instance_variable_set(:@jwt, 'JWT-SECRET')

        [service.inspect, service.to_json, {service:}.to_json].each do |dumped|
          assert_includes(dumped, @host)
          refute_includes(dumped, 'pw-SECRET')
          refute_includes(dumped, 'JWT-SECRET')
        end
        assert_equal({'host' => @host, 'user' => 'user'}, service.as_json)
      end

      # 公開でないトゥートのクリップは、例外にせず投稿もしない。
      # ⚠ 通信しない形で測る — ログイン済みにし、トゥートの URI と HTTP を差し替える。
      def test_clip_skips_non_public_status
        service = Service.new(url: "https://#{@host}/c/hoge", community: 1)
        service.instance_variable_set(:@jwt, 'jwt')
        status = Object.new
        status.define_singleton_method(:valid?) {true}
        status.define_singleton_method(:public?) {false}
        status.define_singleton_method(:to_s) {'https://mstdn.example.com/@a/1'}
        service.define_singleton_method(:create_status_uri) {|_src| status}
        posted = []
        service.http.define_singleton_method(:post) {|*args| posted.push(args)}

        assert_nil(service.clip(url: 'https://mstdn.example.com/@a/1'))
        assert_empty(posted)
      end

      # 公開のトゥートは、URI を 1 回だけ解決し、同じものから本文を補完して投稿する。
      # ⚠ 解決し直すと `fetch_status` が 2 回走る（`TootURI#toot` のメモ化はオブジェクト単位）。
      def test_clip_resolves_status_uri_once
        service = Service.new(url: "https://#{@host}/c/hoge", community: 1)
        service.instance_variable_set(:@jwt, 'jwt')
        status = Object.new
        status.define_singleton_method(:valid?) {true}
        status.define_singleton_method(:public?) {true}
        status.define_singleton_method(:subject) {'件名'}
        status.define_singleton_method(:to_s) {'https://mstdn.example.com/@a/1'}
        resolved = 0
        service.define_singleton_method(:create_status_uri) do |_src|
          resolved += 1
          status
        end
        posted = []
        service.http.define_singleton_method(:post) {|*args| posted.push(args)}

        service.clip(url: 'https://mstdn.example.com/@a/1')

        assert_equal(1, resolved)
        assert_equal(1, posted.size)
        assert_equal('件名', posted.first.last[:body][:title])
        assert_equal('https://mstdn.example.com/@a/1', posted.first.last[:body][:url])
      end

      # ⚠ 利用側を模す。**自前のサブクラスで、検証の口を上書きしている。**
      class OwnTootURI < Ginseng::Fediverse::TootURI
        def host_validator
          return nil
        end
      end

      class OwnNoteURI < Ginseng::Fediverse::NoteURI
        def host_validator
          return nil
        end
      end

      # 🔴🔴 **渡された `TootURI` / `NoteURI` を作り直さない (#27)。** ⚠⚠ 文字列へ戻して
      # gem のクラスで作り直すと、利用側のサブクラスの上書き（`host_validator`）が黙って外れる。
      def test_clip_keeps_the_given_status_uri_object
        service = Service.new(url: "https://#{@host}/c/hoge", community: 1)
        service.instance_variable_set(:@jwt, 'jwt')
        posted = []
        service.http.define_singleton_method(:post) {|*args| posted.push(args)}
        [
          OwnTootURI.parse('https://mstdn.example.com/@a/1'),
          OwnNoteURI.parse('https://misskey.example.com/notes/9abc'),
        ].each do |uri|
          asked = []
          uri.define_singleton_method(:public?) {asked.push(:public?) && true}
          uri.define_singleton_method(:subject) {asked.push(:subject) && '件名'}

          service.clip(url: uri)

          assert_equal([:public?, :subject], asked, uri.class.name)
          assert_equal(uri.to_s, posted.last.last[:body][:url])
        end
      end

      # ⚠ 文字列を渡す利用側は従来どおり（gem のクラスで作る）。
      # ⚠ `valid?` でないオブジェクトも作り直す — `TootURI` として渡されたノートの URL。
      def test_create_status_uri_parses_anything_else
        service = Service.new(url: "https://#{@host}/c/hoge", community: 1)

        toot = service.send(:create_status_uri, 'https://mstdn.example.com/@a/1')
        note = service.send(:create_status_uri,
          OwnTootURI.parse('https://misskey.example.com/notes/9abc'))

        assert_instance_of(Ginseng::Fediverse::TootURI, toot)
        assert_instance_of(Ginseng::Fediverse::NoteURI, note)
        # ⚠ `valid?` を持つだけのもの（素の `Ginseng::URI`）は通さない。`public?` が無い。
        assert_instance_of(Ginseng::Fediverse::TootURI,
          service.send(:create_status_uri, Ginseng::URI.parse('https://mstdn.example.com/@a/1')))
        assert_nil(service.send(:create_status_uri, 'https://example.com/'))
      end

      # ⚠⚠ **利用側が `http_class` を差し替えた形で測る (#15)。**
      # 🔴 既定では `http_class` も直書きの `HTTP` も同じ `Ginseng::HTTP` に解決される
      # ので、**素の `Service` を見ているだけでは直書きに気づけない**。
      # ⚠ 形は「利用側が `include Package` を書いたとき」— 🔴 `tomato-shrieker` の
      # `PiefedShrieker` は**まだ書いていない**（他の Shrieker 5 本は書いている）。
      def test_http_class_is_honored
        assert_instance_of(StubHTTP, StubService.new(url: "https://#{@host}/c/hoge").http)
      end

      private

      # HTTP の `post` を、少し待ってから `reply` を返す（または上げる）ものに差し替える。
      def stub_login(reply)
        service = Service.new(url: "https://#{@host}/c/hoge", user: 'user', password: 'secret')
        calls = Queue.new
        service.http.define_singleton_method(:post) do |*|
          calls.push(true)
          sleep(0.1)
          next reply.call
        end
        return service, calls
      end

      def login_result(service)
        service.login
        return :ok
      rescue => e
        return e
      end
    end
  end
end
