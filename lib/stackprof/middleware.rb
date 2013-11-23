require 'fileutils'

module StackProf
  class Middleware
    def initialize(app, options = {})
      @app = app
      @options = options
      @num_reqs = options[:save_every] || nil
      Middleware.mode = options[:mode] || :cpu
      Middleware.interval = options[:interval] || 1000
      Middleware.enabled = options[:enabled]
      at_exit{ Middleware.save? } if options[:save_at_exit]
    end

    def call(env)
      StackProf.start(mode: Middleware.mode, interval: Middleware.interval) if Middleware.enabled?
      @app.call(env)
    ensure
      if Middleware.enabled?
        StackProf.stop
        if @num_reqs && (@num_reqs-=1) == 0
          @num_reqs = @options[:save_every]
          Middleware.save
        end
      end
    end

    class << self
      attr_accessor :enabled, :mode, :interval
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
