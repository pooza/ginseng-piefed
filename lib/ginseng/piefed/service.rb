module Ginseng
  module Piefed
    class Service
      include Package

      attr_reader :http

      def initialize(params = {})
        @params = params.deep_symbolize_keys
        @logger = logger_class.new
        @config = config_class.instance
        # ⚠⚠ **`HTTP` と直に書かない (#15)。** 字面どおり `Ginseng::HTTP` に解決される
        # ので、**利用側が `http_class` を差し替えても黙って無視される**。
        # ⚠ 差が出るのは `logger_class` / `config_class` / `environment_class` の側 —
        # 実測で `tomato-shrieker` の PieFed 宛は、**利用側が足したマスク（`auth`）と
        # `/http/retry/limit`（3）と User-Agent** が掛かっていなかった。
        # ⚠⚠ **syslog のプログラム名は変わらない**（`Syslog::Logger` の `@@syslog ||=`
        # はプロセスに 1 つで、最初に開いた名前に固定される）。
        # 🔴 **`tomato-shrieker` の `PiefedShrieker` は `include Package` を書いて
        # いない**ので、いまの利用側 2 本ではこの修正は no-op。向こうが 1 行足して
        # 初めて効く。⚠ `Ginseng::Piefed::HTTP` は無いので**既定は変わらない**。
        #
        # 🔴🔴 **資格情報を運ぶ要求ではリダイレクトを追わない (#17)。** `clip` /
        # `communities` は `Authorization: Bearer` を、`login` はパスワードを本文に
        # 載せる。⚠⚠ HTTParty の既定は追従で、ホストをまたいで外すのは `basic_auth`
        # だけ — **307 / 308 は本文ごと別ホストへ POST し直す**。
        # ⚠ 3xx は `GatewayError` になる（`login` では `AuthError`）。宛先は設定された
        # PieFed 1 つなので、3xx が来た時点で相手が違う。
        # ⚠ `guard_redirects!` は 2.0.0 より古い core には無いので、床を gemspec に持つ。
        @http = http_class.new.guard_redirects!
        @http.base_uri = uri
        @logger.info(clipper: self.class.to_s, method: __method__, url: uri.to_s)
      end

      def api_version
        return @config['/piefed/api/version']
      end

      def uri
        @uri ||= Ginseng::URI.parse("https://#{Ginseng::URI.parse(@params[:url]).host}")
        return @uri
      end

      def username
        return @params[:user]
      end

      def password
        return @params[:password].decrypt rescue @params[:password]
      end

      def login
        return if @jwt
        response = http.post("/api/#{api_version}/user/login", {
          body: {username:, password:},
        })
        @jwt = response['jwt']
      rescue => e
        raise Ginseng::AuthError, e.message, e.backtrace
      end

      def clip(body)
        login unless @jwt
        body ||= {}
        body.deep_symbolize_keys!
        raise Ginseng::RequestError, 'invalid community' unless @params[:community]
        # ⚠ トゥートの URI は 1 回だけ解決し、公開範囲の判定と本文の補完で使い回す。
        # `TootURI#toot` のメモ化はオブジェクト単位なので、解決し直すと `fetch_status`
        # がもう 1 回走り、**判定した投稿と転載する本文が別の取得から来る**。
        uri = status_uri(body[:url])
        return nil unless clippable?(uri)
        data = {community_id: @params[:community], title: body[:name]&.to_s}
        enrich_data(data, uri)
        data[:title] = data[:title].gsub(/[\r\n[:blank:]]/, ' ')
        return http.post("/api/#{api_version}/post", {
          body: data,
          headers: {'Authorization' => "Bearer #{@jwt}"},
        })
      end

      def communities
        login unless @jwt
        communities = []
        uri = self.uri.clone
        uri.path = "/api/#{api_version}/community/list"
        @config['/piefed/community/types'].each do |type_|
          page = 1
          loop do
            uri.query_values = {type_:, page:}
            response = http.get(uri, {headers: {'Authorization' => "Bearer #{@jwt}"}})
            communities.concat(response['communities'])
            break unless response['next_page']
            page += 1
          end
        end
        return communities.to_h {|v| [v.dig('community', 'id').to_i, v.dig('community', 'title')]}
      end

      private

      # クリップしてよいか。
      #
      # ⚠ URL が無い・読めなければ true。**投稿を取得しないので転載にはならず**、
      # 投稿されるのは呼び出し側が渡した `name` だけ。
      #
      # ⚠⚠ **公開でないトゥートは例外にせず false を返す。**`public?` は「外へ出して
      # よい公開範囲か」（`ginseng-fediverse` の判定）。弾くのは「非公開の投稿を外部へ転載しない」という
      # **利用者の操作として正常な結果**。🔴 例外にすると利用側の Sentry に上がり、
      # Sidekiq の再試行で 1 操作が 4 件に膨らんでいた（mulukhiya-toot-proxy#4750 /
      # Sentry `MULUKHIYA-TOOT-PROXY-17`）。
      # ⚠ 弾いたことは warn で残す（黙って消すと、クリップされない理由が誰にも分からない）。
      #
      # 🔴 **ここで弾けるのは、取得できた投稿だけ**（Mastodon の unlisted、Misskey の
      # home / followers / specified）。Mastodon の private / direct は匿名の取得が
      # 404 になるので、ここへ届く前に `GatewayError` が上がる（#21）。
      # 🔴 **連合なし（Misskey の `localOnly` / glitch-soc の `local_only`）を弾くかは、
      # 利用側が刺している `ginseng-fediverse` の版で決まる (#20)。** 弾くのは 4.0.0 以降と
      # 2.0.5 以降の 2.0.x で、**3.0.0〜3.1.4 と 2.0.4 以前では公開として通る**。
      # ⚠ この gem は fediverse の床を宣言していない（宣言すると 2.0.x 系の利用側を締め出す）。
      def clippable?(uri)
        return true unless uri
        return true if uri.public?
        @logger.warn(clipper: self.class.to_s, method: :clip, message: 'not public', url: uri.to_s)
        return false
      end

      def enrich_data(data, uri)
        return unless uri
        data[:url] = uri.to_s
        data[:title] ||= uri.subject.ellipsize(@config['/piefed/subject/max_length'])
        data[:body] ||= "via: #{uri}"
      end

      # トゥート（ノート）の URI。URL が無い・読めなければ nil。
      def status_uri(url)
        return nil unless url
        return create_status_uri(url)
      end

      # 🔴🔴 **渡されたものが既に `TootURI` / `NoteURI` なら、作り直さない (#27)。**
      # ⚠⚠ 利用側は自前のサブクラスを渡してくる（`Mulukhiya::TootURI` など）。文字列へ
      # 戻して gem のクラスで作り直すと、**サブクラスの上書きが黙って外れる** —
      # `ginseng-fediverse 5.0.0` の `host_validator`（自サーバー宛だけ検証を外す口）が
      # 届かず、自サーバーが内部アドレスに解決される構成では、自サーバーの投稿を
      # クリップできなくなる（利用側からは外す手段が無い）。
      # ⚠ `valid?` でないものは従来どおり作り直す（`TootURI` として渡されたノートの URL）。
      def create_status_uri(src)
        return src if status_uri?(src) && src.valid?
        dest = Ginseng::Fediverse::TootURI.parse(src.to_s)
        dest = Ginseng::Fediverse::NoteURI.parse(dest) unless dest&.valid?
        return dest if dest&.valid?
      end

      def status_uri?(src)
        return [Ginseng::Fediverse::TootURI, Ginseng::Fediverse::NoteURI].any? {|c| src.is_a?(c)}
      end
    end
  end
end
