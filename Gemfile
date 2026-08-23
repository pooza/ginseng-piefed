source 'https://rubygems.org'
gemspec
gem 'ginseng-core', github: 'pooza/ginseng-core', require: 'ginseng'
gem 'ginseng-fediverse', github: 'pooza/ginseng-fediverse', require: 'ginseng/fediverse'
gem 'ricecream'
gem 'test-unit'

group :development, :test do
  # ⚠ rubocop 本体とプラグインはこの gem が依存として持つ。設定の正本も同じ場所。
  gem 'ginseng-style', github: 'pooza/ginseng-style', tag: 'v1.1.3', require: false
end
