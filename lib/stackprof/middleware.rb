require 'fileutils'

module StackProf
  class Middleware
    def initialize(app)
      @app = app
      at_exit{ Middleware.save if Middleware.enabled? }
    end

    def call(env)
      StackProf.start(mode: :cpu, interval: 1000) if self.class.enabled?
      @app.call(env)
    ensure
      StackProf.stop if self.class.enabled?
    end

    class << self
      attr_accessor :enabled
      alias enabled? enabled

      def save
        if results = StackProf.results
          FileUtils.mkdir_p('tmp')
          File.open("tmp/stackprof-#{results[:mode]}-#{Process.pid}-#{Time.now.to_i}.dump", 'w') do |f|
            f.write Marshal.dump(results)
          end
        end
      end
    end
  end
end
