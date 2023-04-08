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
  VERSION = '0.2.24'

  module Tag
    class << self
      def with(tag_source: DEFAULT_TAG_SOURCE, **tags, &block)
        set(**tags)
        yield
        unset(tags.keys)
      end

      def set(tag_source: DEFAULT_TAG_SOURCE, **tags)
        Thread.current[tag_source] ||= {}
        tags.each do |k, v|
          Thread.current[tag_source][k] = v
        end
      end

      def unset(*tags, tag_source: DEFAULT_TAG_SOURCE)
        return unless Thread.current[tag_source].is_a?(Hash)
        tags.each { |tag| Thread.current[tag_source].delete(tag) }
      end

      def clear(tag_source: DEFAULT_TAG_SOURCE)
        Thread.current[tag_source].clear if Thread.current[tag_source].is_a?(Hash)
      end
    end
  end
end

StackProf.autoload :Report, "stackprof/report.rb"
StackProf.autoload :Middleware, "stackprof/middleware.rb"
