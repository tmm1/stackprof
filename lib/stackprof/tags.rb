module StackProf
  module Tag
    class << self
      def with(tag_source: DEFAULT_TAG_SOURCE, **tags, &block)
        set(**tags)
        yield
        unset(*tags.keys)
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
