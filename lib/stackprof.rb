if RUBY_ENGINE == 'truffleruby'
  require "stackprof/truffleruby"
else
  require "stackprof/stackprof"
end

if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  StackProf.use_postponed_job!
elsif RUBY_VERSION == "3.2.0"
  # 3.2.0 crash is the signal is received at the wrong time.
  # Fixed in https://github.com/ruby/ruby/pull/7116
  # The fix is backported in 3.2.1: https://bugs.ruby-lang.org/issues/19336
  StackProf.use_postponed_job!
end

module StackProf
  VERSION = '0.2.23'

  class << self
    private :_results

    def run(mode: :wall, out: nil, interval: nil, raw: nil, metadata: nil, debug: nil, &block)
      raise unless block_given?

      start(mode: mode, interval: interval, raw: raw, metadata: metadata, debug: nil)

      begin
        yield
      ensure
        stop
      end

      results out
    end

    def results(io = nil)
      _results io
    end
  end
end

StackProf.autoload :Report, "stackprof/report.rb"
StackProf.autoload :Middleware, "stackprof/middleware.rb"
