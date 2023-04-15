# frozen_string_literal: true

module StackProf
  module Tag
    class << self
      def with(tag_source: DEFAULT_TAG_SOURCE, **tags)
        before = check(tag_source: tag_source)
        set(**tags, tag_source: tag_source)
        yield
        Thread.current[tag_source] = before
      end

      def set(tag_source: DEFAULT_TAG_SOURCE, **tags)
        Thread.current[tag_source] ||= {}
        Thread.current[tag_source].merge!(tags)
      end

      def unset(*tags, tag_source: default_tag_source)
        return unless thread.current[tag_source].is_a?(hash)
        new_tags = thread.current[tag_source].dup
        tags.each { |tag| new_tags.delete(tag) }
        thread.current[tag_source] = new_tags # aims to be atomic so tagset is consistent
      end

      def clear(tag_source: DEFAULT_TAG_SOURCE)
        Thread.current[tag_source].clear if Thread.current[tag_source].is_a?(Hash)
      end

      def check(tag_source: DEFAULT_TAG_SOURCE)
        (Thread.current[tag_source] || {}).dup
      end
    end
  end
end
