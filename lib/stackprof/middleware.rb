require 'fileutils'

module StackProf
  class Middleware
    def initialize(app, options = {})
      @app       = app
      @options   = options
      @num_reqs  = options[:save_every] || nil

      Middleware.mode     = options[:mode] || :cpu
      Middleware.interval = options[:interval] || 1000
      Middleware.enabled  = options[:enabled]
      Middleware.path     = options[:path] || 'tmp'
      at_exit{ Middleware.save? } if options[:save_at_exit]
    end

    def call(env)

      if enabled = Middleware.enabled?(env)
        @mode ||= Middleware.mode(env)
        StackProf.start(mode: @mode, interval: Middleware.interval)
      end

      @app.call(env)

    ensure
      if enabled
        StackProf.stop
        if @num_reqs && (@num_reqs-=1) == 0
          @num_reqs = @options[:save_every]
          Middleware.save
          @mode = nil
        end
      end
    end

    class << self
      attr_accessor :enabled, :interval, :path
      attr_writer :mode

      def enabled?(env)
        enabled.respond_to?(:call) ? enabled.call(env) : enabled
      end

      def mode(env)
        @mode.respond_to?(:call) ? @mode.call(env) : @mode
      end

      def save(filename = nil)
        if results = StackProf.results
          FileUtils.mkdir_p(Middleware.path)
          filename ||= "stackprof-#{results[:mode]}-#{Process.pid}-#{Time.now.to_i}.dump"
          File.open(File.join(Middleware.path, filename), 'wb') do |f|
            f.write Marshal.dump(results)
          end
          filename
        end
      end

    end
  end
end
