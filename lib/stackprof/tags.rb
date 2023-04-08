module StackProf
  module Tag
    # TODO add a way to inherit tags from parent thread by wrapping Thread.new and Fiber.new
    # in a module, and include this module to monkey-patch them with these wrappers.
    # work by passing all of Thread.current.keys with values to Thread.new

    class << self
      def with(tag_source: DEFAULT_TAG_SOURCE, **tags, &block)
        before = current(tag_source: tag_source)
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

      def current(tag_source: DEFAULT_TAG_SOURCE)
        Thread.current.fetch(tag_source, {}).dup
      end
    end
  end
end
