source 'https://rubygems.org'
gemspec
gem 'ginseng-core', github: 'pooza/ginseng-core', require: 'ginseng'
gem 'ginseng-fediverse', github: 'pooza/ginseng-fediverse', require: 'ginseng/fediverse'
gem 'ricecream'
gem 'test-unit'

group :development, :test do
  # ⚠ rubocop 本体とプラグインはこの gem が依存として持つ。設定の正本も同じ場所。
  # ⚠⚠ タグではなく SHA で固定する（pooza/ginseng-style#75）。タグは付け替えられる。
  gem 'ginseng-style', github: 'pooza/ginseng-style',
    ref: '91c49d3b512a31dcd714baf156cd253b84eb4f0f', require: false # v1.1.11
end
