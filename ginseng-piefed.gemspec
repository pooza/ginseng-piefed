require 'yaml'
package = YAML.load_file(File.join(__dir__, 'config/lib.yaml'))['package']

Gem::Specification.new do |spec|
  spec.name = 'ginseng-piefed'
  spec.version = package['version']
  spec.authors = package['authors']
  spec.email = package['email']
  spec.summary = package['description']
  spec.description = package['description']
  spec.homepage = package['url']
  spec.license = package['license']
  spec.metadata['homepage_uri'] = package['url']
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>=3.4'

  # ⚠⚠ **`Service` が `Ginseng::HTTP#guard_redirects!` を呼ぶ (#17)。** 2.0.0 より古い
  # core には無く、`Service.new` が落ちる。🔴 床が無いと `bundle` は通ってしまい、
  # 実行時まで分からない（pooza/ginseng-fediverse#301 の Codex P1）。
  # ⚠ **外してよい条件は無い。** 上げるのは、core の新しい口に乗ったとき。
  # 🔴 `ginseng-core` は rubygems.org に無い。**利用側の `Gemfile` に git の参照が要る**
  # （無ければ解決できずに止まる。いまの利用側は全員書いている）。
  spec.add_dependency 'ginseng-core', '>=2.0.0'
end
