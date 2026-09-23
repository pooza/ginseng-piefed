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
        @http = http_class.new
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
        data = {community_id: @params[:community], title: body[:name]&.to_s}
        enrich_data(data, body[:url])
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

      def enrich_data(data, url)
        return unless url
        uri = create_status_uri(url)
        return unless uri&.valid?
        raise Ginseng::RequestError, "URI #{uri} not public" unless uri.public?
        data[:url] = uri.to_s
        data[:title] ||= uri.subject.ellipsize(@config['/piefed/subject/max_length'])
        data[:body] ||= "via: #{uri}"
      end

      def create_status_uri(src)
        dest = Ginseng::Fediverse::TootURI.parse(src.to_s)
        dest = Ginseng::Fediverse::NoteURI.parse(dest) unless dest&.valid?
        return dest if dest&.valid?
      end
    end
  end
end
