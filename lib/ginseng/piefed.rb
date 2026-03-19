require 'bundler/setup'

module Ginseng
  module Piefed
    def self.dir
      return File.expand_path('../..', __dir__)
    end

    def self.loader
      config = YAML.load_file(File.join(dir, 'config/autoload.yaml'))
      loader = Zeitwerk::Loader.new
      loader.inflector.inflect(config['inflections'])
      config['entries'].each do |entry|
        loader.push_dir(File.join(dir, entry['path']), namespace: entry['namespace'].constantize)
      end
      return loader
    end

    Bundler.require
    loader.setup
  end
end
