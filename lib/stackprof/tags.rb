module StackProf
  module Tag
    # TODO add a way to inherit tags from parent thread by wrapping Thread.new and Fiber.new
    # in a module, and include this module to monkey-patch them with these wrappers.
    # work by passing all of Thread.current.keys with values to Thread.new

    class << self
      def with(tag_source: DEFAULT_TAG_SOURCE, **tags, &block)
        before = check(tag_source: tag_source)
        set(**tags, tag_source: tag_source) # TODO push this onto a stack rather than set / unset, or we will clobber old values
        yield
        Thread.current[tag_source] = before
      end

      def set(tag_source: DEFAULT_TAG_SOURCE, **tags)
        Thread.current[tag_source] ||= {}
        Thread.current[tag_source].merge!(tags)
      end

      def unset(*tags, tag_source: DEFAULT_TAG_SOURCE)
        return unless Thread.current[tag_source].is_a?(Hash)
        tags.each { |tag| Thread.current[tag_source].delete(tag) }
      end

      def clear(tag_source: DEFAULT_TAG_SOURCE)
        Thread.current[tag_source].clear if Thread.current[tag_source].is_a?(Hash)
      end

      def check(tag_source: DEFAULT_TAG_SOURCE)
        Thread.current.fetch(tag_source, {}).dup
      end
    end


    # Persistence is a global API to toggle inheriting tags from parent thread
    # It does this by monkey-patching Thread.new, however, which is why this
    # defaults to disabled
    module Persistence
      extend self

      attr_reader :enabled

      def enable
        @enabled ||= true
        @prepended ||= begin
          Thread.singleton_class.prepend(StackProf::Tag::ExtendedThread)
          true
        end
      end

      def disable
        #puts "Disabling tag persistence"
        @enabled = false
      end
    end

    # ExtendedThread wraps Thread.new constructor in order to toggle inheritence
    # of a specific thread local value
    module ExtendedThread
      def new(*args, &block)
        return super(*args, &block) unless StackProf::Tag::Persistence.enabled
        wrap_block = begin
          thread_vars = Thread.current.fetch(DEFAULT_TAG_SOURCE, nil) # FIXME read the tag source from module variable, don't assume it is default
          if thread_vars.is_a?(Hash) && !thread_vars.empty?
            wrap_block = Proc.new do
              Thread.current[DEFAULT_TAG_SOURCE] = thread_vars.dup
              block.call
            end
          else
            block
          end
        end
        super(*args, &wrap_block)
      end
    end
  end
end
