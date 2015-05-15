require 'fileutils'

module StackProf
  class Middleware
    def initialize(app, options = {})
      @app       = app
      @options   = options
      @num_reqs  = options[:save_every] || nil

      Middleware.mode     = options[:mode] || :cpu
      Middleware.interval = options[:interval] || 1000
      Middleware.raw      = options[:raw] || false
      Middleware.enabled  = options[:enabled]
      Middleware.path     = options[:path] || 'tmp'
      at_exit{ Middleware.save } if options[:save_at_exit]
    end

    def call(env)
      enabled = Middleware.enabled?(env)
      StackProf.start(mode: Middleware.mode, interval: Middleware.interval, raw: Middleware.raw) if enabled
      @app.call(env)
    ensure
      if enabled
        StackProf.stop
        if @num_reqs && (@num_reqs-=1) == 0
          @num_reqs = @options[:save_every]
          Middleware.save
        end
      end
    end

    class << self
      attr_accessor :enabled, :mode, :interval, :raw, :path

      def enabled?(env)
        if enabled.respond_to?(:call)
          enabled.call(env)
        else
          enabled
        end
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
